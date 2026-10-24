-- SPDX-FileCopyrightText: Copyright (C) 2026 THE-XSX
-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- Icon Pack Manager (图标包管理器) - KOReader plugin
-- Released under the GNU Affero General Public License v3.0 or later.
-- See the LICENSE file in the project root for the full license text.

local Archiver = require("ffi/archiver")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Engine = {}
Engine.__index = Engine

local MAX_ICON_COUNT = 1000
local MAX_ICON_SIZE = 2 * 1024 * 1024
local MAX_TOTAL_SIZE = 32 * 1024 * 1024
local TARGET_KEYS = { "mdlight", "simpleui" }

local function join(path, name)
    return path .. "/" .. name
end

local function fileMode(path)
    return lfs.attributes(path, "mode")
end

local function basename(path)
    return path and path:match("([^/]+)/*$") or path
end

local function sortedKeys(values)
    local result = {}
    for value in pairs(values) do
        result[#result + 1] = value
    end
    table.sort(result, function(a, b) return a:lower() < b:lower() end)
    return result
end

local function removeTree(path)
    local mode = fileMode(path)
    if not mode then
        return true
    end
    if mode ~= "directory" then
        return os.remove(path)
    end
    return ffiUtil.purgeDir(path)
end

local function directoryStats(path)
    local count, bytes = 0, 0
    local function scan(dir)
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok then
            return nil, iter
        end
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." then
                local child = join(dir, name)
                local attr = lfs.attributes(child)
                if attr and attr.mode == "directory" then
                    local child_ok, child_err = scan(child)
                    if not child_ok then
                        return nil, child_err
                    end
                elseif attr and attr.mode == "file" then
                    count = count + 1
                    bytes = bytes + (attr.size or 0)
                end
            end
        end
        return true
    end
    local ok, err = scan(path)
    if not ok then
        return nil, err
    end
    return { count = count, bytes = bytes }
end

local function copyTree(source, destination)
    if fileMode(source) ~= "directory" then
        return nil, "源目录不存在：" .. source
    end
    local ok, err = util.makePath(destination)
    if not ok then
        return nil, err
    end

    local iter_ok, iter, dir_obj = pcall(lfs.dir, source)
    if not iter_ok then
        return nil, iter
    end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." then
            local from = join(source, name)
            local to = join(destination, name)
            local attr = lfs.attributes(from)
            if attr and attr.mode == "directory" then
                local copied, copy_err = copyTree(from, to)
                if not copied then
                    return nil, copy_err
                end
            elseif attr and attr.mode == "file" then
                local copy_err = ffiUtil.copyFile(from, to)
                local dest_attr = lfs.attributes(to)
                if copy_err or not dest_attr or dest_attr.mode ~= "file"
                        or dest_attr.size ~= attr.size then
                    return nil, copy_err or ("复制校验失败：" .. from)
                end
            end
        end
    end
    return true
end

local function safeArchivePath(path)
    if type(path) ~= "string" or path == "" or path:find("%z") then
        return nil, "ZIP 内含无效路径"
    end
    path = path:gsub("\\", "/")
    while path:sub(1, 2) == "./" do
        path = path:sub(3)
    end
    if path == "" or path:sub(1, 1) == "/" or path:match("^%a:") then
        return nil, "ZIP 内含绝对路径：" .. path
    end
    for component in path:gmatch("[^/]+") do
        if component == "." or component == ".." then
            return nil, "ZIP 内含不安全路径：" .. path
        end
    end
    return path
end

local PATH_MARKERS = {
    { marker = "resources/icons/mdlight/", target = "mdlight" },
    { marker = "plugins/simpleui.koplugin/icons/", target = "simpleui" },
    { marker = "simpleui.koplugin/icons/", target = "simpleui" },
    { marker = "simpleui/icons/", target = "simpleui" },
    { marker = "mdlight/", target = "mdlight" },
}

local function mapArchivePath(path)
    local lower = path:lower()
    for _, item in ipairs(PATH_MARKERS) do
        local start_at = 1
        while true do
            local pos = lower:find(item.marker, start_at, true)
            if not pos then
                break
            end
            if pos == 1 or lower:sub(pos - 1, pos - 1) == "/" then
                local relative = path:sub(pos + #item.marker)
                if relative ~= "" then
                    return item.target, relative
                end
            end
            start_at = pos + 1
        end
    end
end

local function parentDir(path)
    return path and path:match("^(.*)/[^/]+/*$")
end

local function isEmptyDir(path)
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok then
        return false
    end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." then
            return false
        end
    end
    return true
end

-- Collects SVG names (relative to root) into `names`; missing roots are ignored.
local function listSvgs(root, names, recursive)
    local function scan(dir, prefix)
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok then
            return
        end
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." then
                local path = join(dir, name)
                local relative = prefix == "" and name or join(prefix, name)
                local mode = fileMode(path)
                if mode == "directory" and recursive then
                    scan(path, relative)
                elseif mode == "file" and name:lower():sub(-4) == ".svg" then
                    names[relative] = true
                end
            end
        end
    end
    if fileMode(root) == "directory" then
        scan(root, "")
    end
    return names
end

-- Simple UI may live in the user plugin dir (<data>/plugins, e.g. /sdcard/koreader/plugins
-- on Android), in the install dir (Kindle/Kobo, where both are the same), or next to us.
local function findSimpleUIIcons(data_dir, install_dir, plugin_dir)
    local candidates = {
        join(data_dir, "plugins/simpleui.koplugin"),
        join(install_dir, "plugins/simpleui.koplugin"),
    }
    local parent = parentDir(plugin_dir)
    if parent then
        candidates[#candidates + 1] = join(parent, "simpleui.koplugin")
    end
    for _, dir in ipairs(candidates) do
        local icons = join(dir, "icons")
        -- The "-previous" check keeps an interrupted swap recoverable on next start.
        if fileMode(icons) == "directory"
                or fileMode(icons .. ".iconpackmanager-previous") == "directory" then
            return icons
        end
    end
end

-- Options:
--   data_dir     KOReader data dir (DataStorage:getFullDataDir(), /sdcard/koreader on Android)
--   settings_dir KOReader settings dir
--   plugin_dir   this plugin's own directory (holds the bundled official/ icons)
--   install_dir  KOReader program dir holding resources/ (the working directory)
function Engine:new(options)
    local data_dir = assert(options and options.data_dir, "data_dir is required")
    local settings_dir = assert(options.settings_dir, "settings_dir is required")
    local plugin_dir = options.plugin_dir or "plugins/iconpackmanager.koplugin"
    local install_dir = options.install_dir or "."
    local state_root = join(settings_dir, "iconpackmanager")
    local official_root = options.official_root or join(plugin_dir, "official")
    local object = {
        data_dir = data_dir,
        install_dir = install_dir,
        plugin_dir = plugin_dir,
        state_root = state_root,
        official_root = official_root,
        legacy_backup_root = join(state_root, "original"),
        managed_file = join(state_root, "managed_icons.txt"),
        extraction_root = join(state_root, "extracted"),
        transaction_marker = join(state_root, ".transaction"),
        targets = {
            mdlight = {
                -- KOReader's IconWidget looks here before resources/icons/mdlight,
                -- so we never have to touch the (possibly read-only) program files.
                live = join(data_dir, "icons"),
                builtin = join(install_dir, "resources/icons/mdlight"),
                data_builtin = join(data_dir, "resources/icons/mdlight"),
                official = join(official_root, "mdlight"),
            },
            simpleui = {
                live = findSimpleUIIcons(data_dir, install_dir, plugin_dir),
                official = join(official_root, "simpleui"),
            },
        },
        _inventories = {},
    }
    setmetatable(object, self)
    for _, target in pairs(object.targets) do
        if target.live then
            target.next = target.live .. ".iconpackmanager-next"
            target.previous = target.live .. ".iconpackmanager-previous"
        end
    end
    return object
end

-- Icon names a pack may replace: the bundled official set plus whatever the
-- current installation ships (covers version drift in either direction).
function Engine:_inventory(target_key)
    local cached = self._inventories[target_key]
    if cached then
        return cached
    end
    local target = self.targets[target_key]
    local names = {}
    if target_key == "mdlight" then
        -- IconWidget resolves user icons by bare name, so only flat names count.
        listSvgs(target.official, names, false)
        listSvgs(target.builtin, names, false)
        listSvgs(target.data_builtin, names, false)
    else
        listSvgs(target.official, names, true)
        if target.live then
            listSvgs(target.live, names, true)
        end
    end
    self._inventories[target_key] = names
    return names
end

function Engine:hasSimpleUI()
    return self.targets.simpleui.live ~= nil
end

function Engine:simpleUIPath()
    return self.targets.simpleui.live
end

function Engine:userIconsPath()
    return self.targets.mdlight.live
end

-- The user icon override dir must not double as a pack folder.
function Engine:isReservedFolder(path)
    if not path then
        return false
    end
    local live = self.targets.mdlight.live
    path = path:gsub("/+$", "")
    return path == live or path:sub(1, #live + 1) == live .. "/"
end

function Engine:_activeTargets()
    if self:hasSimpleUI() then
        return { "mdlight", "simpleui" }
    end
    return { "mdlight" }
end

function Engine:_newPlan()
    return {
        mdlight = 0,
        simpleui = 0,
        total = 0,
        bytes = 0,
        unknown = {},
        missing = { mdlight = {}, simpleui = {} },
        expected = { mdlight = 0, simpleui = 0 },
    }
end

function Engine:_finalizePlan(plan, destinations)
    plan.unknown = sortedKeys(plan.unknown)
    local managed = {}
    for destination_key in pairs(destinations) do
        local relative = destination_key:match("^mdlight/(.+)$")
        if relative then
            managed[#managed + 1] = relative
        end
    end
    table.sort(managed)
    plan.managed = managed
    local is_complete = true
    for _, target_key in ipairs(self:_activeTargets()) do
        local inventory = self:_inventory(target_key)
        local missing = {}
        for relative in pairs(inventory) do
            plan.expected[target_key] = plan.expected[target_key] + 1
            if not destinations[target_key .. "/" .. relative] then
                missing[#missing + 1] = relative
            end
        end
        table.sort(missing, function(a, b) return a:lower() < b:lower() end)
        plan.missing[target_key] = missing
        if #missing > 0 then
            is_complete = false
        end
    end
    plan.complete = is_complete
    return plan
end

function Engine:_mapIconPath(path, size)
    local safe_path, path_err = safeArchivePath(path)
    if not safe_path then
        return nil, path_err
    end
    if safe_path:lower():sub(-4) ~= ".svg" then
        return false
    end
    if size < 0 or size > MAX_ICON_SIZE then
        return nil, "图标文件过大：" .. safe_path
    end

    local explicit_target, explicit_relative = mapArchivePath(safe_path)
    if explicit_target then
        if explicit_target == "simpleui" and not self:hasSimpleUI() then
            return false
        end
        local safe_relative, relative_err = safeArchivePath(explicit_relative)
        if not safe_relative then
            return nil, relative_err
        end
        if not self:_inventory(explicit_target)[safe_relative] then
            return false
        end
        return {{ target = explicit_target, relative = safe_relative, size = size }}
    end

    local filename = basename(safe_path)
    local mappings = {}
    for _, target_key in ipairs(self:_activeTargets()) do
        if self:_inventory(target_key)[filename] then
            mappings[#mappings + 1] = {
                target = target_key,
                relative = filename,
                size = size,
            }
        end
    end
    if #mappings == 0 then
        return false
    end
    return mappings
end

function Engine:_readManaged()
    local managed = {}
    local content = util.readFromFile and util.readFromFile(self.managed_file, "rb")
    if content then
        for line in content:gmatch("[^\r\n]+") do
            local safe = safeArchivePath(line)
            if safe and not safe:find("/", 1, true) then
                managed[safe] = true
            end
        end
    end
    return managed
end

function Engine:_writeManaged(managed)
    local names = sortedKeys(managed)
    if #names == 0 then
        os.remove(self.managed_file)
        return true
    end
    local ok, err = util.makePath(self.state_root)
    if not ok then
        return nil, err
    end
    ok, err = util.writeToFile(table.concat(names, "\n") .. "\n", self.managed_file)
    if not ok then
        return nil, err or "无法写入图标记录"
    end
    return true
end

-- Number of icons in each bundled official set.
function Engine:officialStatus()
    local result = {}
    for _, key in ipairs(TARGET_KEYS) do
        local count = 0
        for _ in pairs(listSvgs(self.targets[key].official, {}, true)) do
            count = count + 1
        end
        result[key] = count
    end
    return result
end

-- Plugin versions <= 1.1 rewrote resources/icons/mdlight in place and kept a backup.
function Engine:hasLegacyBackup()
    return fileMode(join(self.legacy_backup_root, ".complete")) == "file"
end

function Engine:_restoreLegacyBuiltin()
    if not self:hasLegacyBackup() then
        return true
    end
    local source = join(self.legacy_backup_root, "mdlight")
    local builtin = self.targets.mdlight.builtin
    if fileMode(source) == "directory" and fileMode(builtin) == "directory" then
        local ok, err = copyTree(source, builtin)
        if not ok then
            return nil, err
        end
    end
    removeTree(self.legacy_backup_root)
    return true
end

function Engine:_mapEntry(entry)
    local mappings, err = self:_mapIconPath(entry.path, tonumber(entry.size))
    if mappings then
        for _, mapped in ipairs(mappings) do
            mapped.archive_path = entry.path
        end
    end
    return mappings, err
end

function Engine:inspectArchive(zip_path)
    if fileMode(zip_path) ~= "file" or zip_path:lower():sub(-4) ~= ".zip" then
        return nil, "不是可读取的 ZIP 文件"
    end
    local archive = Archiver.Reader:new()
    if not archive:open(zip_path) then
        local err = archive.err or "无法打开 ZIP"
        archive:close()
        return nil, err
    end
    local plan = self:_newPlan()
    local destinations = {}
    local source_count = 0
    for entry in archive:iterate() do
        local safe_path, path_err = safeArchivePath(entry.path)
        if not safe_path then
            archive:close()
            return nil, path_err
        end
        if entry.mode == "file" then
            local mappings, map_err = self:_mapEntry(entry)
            if mappings == nil then
                archive:close()
                return nil, map_err
            elseif mappings then
                source_count = source_count + 1
                plan.bytes = plan.bytes + tonumber(entry.size)
                for _, mapped in ipairs(mappings) do
                    local destination_key = mapped.target .. "/" .. mapped.relative
                    if destinations[destination_key] then
                        archive:close()
                        return nil, "ZIP 内含重复图标：" .. mapped.relative
                    end
                    destinations[destination_key] = true
                    plan[mapped.target] = plan[mapped.target] + 1
                    plan.total = plan.total + 1
                end
                if source_count > MAX_ICON_COUNT or plan.bytes > MAX_TOTAL_SIZE then
                    archive:close()
                    return nil, "图标包超过安全大小限制"
                end
            elseif safe_path:lower():sub(-4) == ".svg" then
                plan.unknown[safe_path] = true
            end
        end
    end
    local archive_err = archive.err
    archive:close()
    if archive_err then
        return nil, archive_err
    end
    if plan.total == 0 then
        return nil, "未找到可匹配当前安装的 SVG 图标"
    end
    return self:_finalizePlan(plan, destinations)
end

function Engine:inspectDirectory(pack_path)
    if fileMode(pack_path) ~= "directory" then
        return nil, "图标包文件夹不存在"
    end
    local plan = self:_newPlan()
    local destinations = {}
    local source_count = 0
    plan.entries = {}

    local function scan(dir, prefix)
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok then
            return nil, iter
        end
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." then
                local path = join(dir, name)
                local relative = prefix == "" and name or join(prefix, name)
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" then
                    local child_ok, child_err = scan(path, relative)
                    if not child_ok then
                        return nil, child_err
                    end
                elseif attr and attr.mode == "file" and name:lower():sub(-4) == ".svg" then
                    local mappings, map_err = self:_mapIconPath(relative, attr.size or 0)
                    if mappings == nil then
                        return nil, map_err
                    elseif mappings then
                        source_count = source_count + 1
                        plan.bytes = plan.bytes + (attr.size or 0)
                        for _, mapped in ipairs(mappings) do
                            local destination_key = mapped.target .. "/" .. mapped.relative
                            if destinations[destination_key] then
                                return nil, "文件夹内含重复图标：" .. mapped.relative
                            end
                            destinations[destination_key] = true
                            plan[mapped.target] = plan[mapped.target] + 1
                            plan.total = plan.total + 1
                            plan.entries[#plan.entries + 1] = {
                                source = path,
                                target = mapped.target,
                                relative = mapped.relative,
                                size = mapped.size,
                            }
                        end
                        if source_count > MAX_ICON_COUNT or plan.bytes > MAX_TOTAL_SIZE then
                            return nil, "图标包超过安全大小限制"
                        end
                    else
                        plan.unknown[relative] = true
                    end
                end
            end
        end
        return true
    end

    local ok, err = scan(pack_path, "")
    if not ok then
        return nil, tostring(err)
    end
    if plan.total == 0 then
        return nil, "未找到可匹配当前安装的 SVG 图标"
    end
    return self:_finalizePlan(plan, destinations)
end

local function hasDirectSvg(folder)
    local ok, iter, dir_obj = pcall(lfs.dir, folder)
    if not ok then
        return false
    end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." and name:lower():sub(-4) == ".svg"
                and fileMode(join(folder, name)) == "file" then
            return true
        end
    end
    return false
end

local function hasStructuredChild(folder)
    local structured = {
        mdlight = true,
        simpleui = true,
        ["simpleui.koplugin"] = true,
        resources = true,
        plugins = true,
    }
    local ok, iter, dir_obj = pcall(lfs.dir, folder)
    if not ok then
        return false
    end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." and structured[name:lower()]
                and fileMode(join(folder, name)) == "directory" then
            return true
        end
    end
    return false
end

local function directoryContainsSvg(folder)
    local found = false
    local function scan(dir)
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok then return end
        for name in iter, dir_obj do
            if found then return end
            if name ~= "." and name ~= ".." then
                local path = join(dir, name)
                local mode = fileMode(path)
                if mode == "directory" then
                    scan(path)
                elseif mode == "file" and name:lower():sub(-4) == ".svg" then
                    found = true
                end
            end
        end
    end
    scan(folder)
    return found
end

function Engine:_addDirectoryPack(packs, name, path)
    local plan, err = self:inspectDirectory(path)
    packs[#packs + 1] = {
        kind = "folder",
        name = name,
        path = path,
        plan = plan,
        error = err,
    }
end

function Engine:scanFolder(folder)
    if self:isReservedFolder(folder) then
        return nil, "该目录是 KOReader 的图标覆盖目录，请把图标包放在其他文件夹（如 iconpacks）"
    end
    local packs = {}
    local ok, iter, dir_obj = pcall(lfs.dir, folder)
    if not ok then
        return nil, "无法读取文件夹：" .. tostring(iter)
    end

    local current_is_pack = hasDirectSvg(folder) or hasStructuredChild(folder)
    if current_is_pack then
        self:_addDirectoryPack(packs, basename(folder), folder)
    end

    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." then
            local path = join(folder, name)
            local mode = fileMode(path)
            if mode == "file" and name:lower():sub(-4) == ".zip" then
                local plan, err = self:inspectArchive(path)
                packs[#packs + 1] = {
                    kind = "zip",
                    name = name,
                    path = path,
                    plan = plan,
                    error = err,
                }
            elseif mode == "directory" and not current_is_pack
                    and not self:isReservedFolder(path) and directoryContainsSvg(path) then
                if hasDirectSvg(path) or hasStructuredChild(path) then
                    self:_addDirectoryPack(packs, name, path)
                else
                    local child_ok, child_iter, child_obj = pcall(lfs.dir, path)
                    if child_ok then
                        for child_name in child_iter, child_obj do
                            local child_path = join(path, child_name)
                            if child_name ~= "." and child_name ~= ".."
                                    and fileMode(child_path) == "directory"
                                    and directoryContainsSvg(child_path) then
                                self:_addDirectoryPack(packs, name .. "/" .. child_name, child_path)
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(packs, function(a, b) return a.name:lower() < b.name:lower() end)
    return packs
end

function Engine:_extractArchive(zip_path, expected_plan)
    removeTree(self.extraction_root)
    local ok, err = util.makePath(self.extraction_root)
    if not ok then
        return nil, err
    end
    local archive = Archiver.Reader:new()
    if not archive:open(zip_path) then
        err = archive.err or "无法打开 ZIP"
        archive:close()
        removeTree(self.extraction_root)
        return nil, err
    end
    local extracted = { mdlight = 0, simpleui = 0, total = 0 }
    for entry in archive:iterate() do
        if entry.mode == "file" then
            local mappings, map_err = self:_mapEntry(entry)
            if mappings == nil then
                archive:close()
                removeTree(self.extraction_root)
                return nil, map_err
            elseif mappings then
                local first_destination
                for index, mapped in ipairs(mappings) do
                    local destination = join(join(self.extraction_root, mapped.target), mapped.relative)
                    ok, err = util.makePath(ffiUtil.dirname(destination))
                    if not ok then
                        archive:close()
                        removeTree(self.extraction_root)
                        return nil, err
                    end
                    if index == 1 then
                        if not archive:extractToPath(entry.path, destination) then
                            err = archive.err or ("无法解压：" .. entry.path)
                            archive:close()
                            removeTree(self.extraction_root)
                            return nil, err
                        end
                        first_destination = destination
                    else
                        local copy_err = ffiUtil.copyFile(first_destination, destination)
                        if copy_err then
                            archive:close()
                            removeTree(self.extraction_root)
                            return nil, copy_err
                        end
                    end
                    local attr = lfs.attributes(destination)
                    if not attr or attr.mode ~= "file" or attr.size ~= mapped.size then
                        archive:close()
                        removeTree(self.extraction_root)
                        return nil, "解压校验失败：" .. mapped.relative
                    end
                    extracted[mapped.target] = extracted[mapped.target] + 1
                    extracted.total = extracted.total + 1
                end
            end
        end
    end
    local archive_err = archive.err
    archive:close()
    if archive_err then
        removeTree(self.extraction_root)
        return nil, archive_err
    end
    if extracted.total ~= expected_plan.total
            or extracted.mdlight ~= expected_plan.mdlight
            or (self:hasSimpleUI() and extracted.simpleui ~= expected_plan.simpleui) then
        removeTree(self.extraction_root)
        return nil, "ZIP 在校验后发生变化，请重新扫描"
    end
    return extracted
end

function Engine:_copyDirectoryPack(plan)
    removeTree(self.extraction_root)
    local ok, err = util.makePath(self.extraction_root)
    if not ok then
        return nil, err
    end
    local copied = { mdlight = 0, simpleui = 0, total = 0 }
    for _, entry in ipairs(plan.entries or {}) do
        local source_attr = lfs.attributes(entry.source)
        if not source_attr or source_attr.mode ~= "file" or source_attr.size ~= entry.size then
            removeTree(self.extraction_root)
            return nil, "图标包在检测后发生变化，请重新扫描：" .. entry.relative
        end
        local destination = join(join(self.extraction_root, entry.target), entry.relative)
        ok, err = util.makePath(ffiUtil.dirname(destination))
        if not ok then
            removeTree(self.extraction_root)
            return nil, err
        end
        local copy_err = ffiUtil.copyFile(entry.source, destination)
        local destination_attr = lfs.attributes(destination)
        if copy_err or not destination_attr or destination_attr.mode ~= "file"
                or destination_attr.size ~= entry.size then
            removeTree(self.extraction_root)
            return nil, copy_err or ("复制校验失败：" .. entry.relative)
        end
        copied[entry.target] = copied[entry.target] + 1
        copied.total = copied.total + 1
    end
    if copied.total ~= plan.total or copied.mdlight ~= plan.mdlight
            or (self:hasSimpleUI() and copied.simpleui ~= plan.simpleui) then
        removeTree(self.extraction_root)
        return nil, "图标包在检测后发生变化，请重新扫描"
    end
    return copied
end

function Engine:_discardStages()
    for _, key in ipairs(self:_activeTargets()) do
        removeTree(self.targets[key].next)
    end
end

-- Builds <live>.iconpackmanager-next for every active target:
--   mdlight:  current <data>/icons minus files we installed earlier (user's own icons survive)
--   simpleui: current icons with the bundled official set laid over them
-- then (optionally) overlays the freshly extracted pack.
function Engine:_prepareStages(with_overlay)
    local managed = self:_readManaged()
    for _, key in ipairs(self:_activeTargets()) do
        local target = self.targets[key]
        removeTree(target.next)
        local ok, err
        if key == "mdlight" then
            if fileMode(target.live) == "directory" then
                ok, err = copyTree(target.live, target.next)
            else
                ok, err = util.makePath(target.next)
            end
            if not ok then
                return nil, err
            end
            for name in pairs(managed) do
                local path = join(target.next, name)
                if fileMode(path) == "file" and not os.remove(path) then
                    return nil, "无法移除旧图标：" .. name
                end
            end
        elseif key == "simpleui" then
            if fileMode(target.official) == "directory" then
                ok, err = copyTree(target.official, target.next)
            elseif fileMode(target.live) == "directory" then
                ok, err = copyTree(target.live, target.next)
            else
                ok, err = util.makePath(target.next)
            end
            if not ok then
                return nil, err
            end
        end
        if with_overlay and fileMode(join(self.extraction_root, key)) == "directory" then
            ok, err = copyTree(join(self.extraction_root, key), target.next)
            if not ok then
                return nil, err
            end
        end
    end
    return true
end

function Engine:_rollbackTransaction()
    local all_ok = true
    for _, key in ipairs(TARGET_KEYS) do
        local target = self.targets[key]
        if target.live then
            if fileMode(target.previous) == "directory" then
                removeTree(target.live)
                local ok = os.rename(target.previous, target.live)
                all_ok = all_ok and ok and true or false
            end
            removeTree(target.next)
        end
    end
    os.remove(self.transaction_marker)
    return all_ok
end

function Engine:recoverTransaction()
    local transaction_active = fileMode(self.transaction_marker) == "file"
    if transaction_active then
        local ok = self:_rollbackTransaction()
        if not ok then
            return nil, "上次更换中断，自动回滚未能完整完成"
        end
        return true, "已回滚上次未完成的图标更换"
    end
    for _, key in ipairs(TARGET_KEYS) do
        local target = self.targets[key]
        if target.live then
            if fileMode(target.live) ~= "directory" and fileMode(target.previous) == "directory" then
                os.rename(target.previous, target.live)
            elseif fileMode(target.previous) == "directory" then
                removeTree(target.previous)
            end
            removeTree(target.next)
        end
    end
    if self:hasLegacyBackup() then
        self:_restoreLegacyBuiltin()
    end
    return true
end

function Engine:_commitStages()
    local ok, err = util.makePath(self.state_root)
    if not ok then
        return nil, "无法创建状态目录：" .. tostring(err)
    end
    ok = util.writeToFile("active\n", self.transaction_marker)
    if not ok then
        return nil, "无法创建事务标记"
    end
    for _, key in ipairs(self:_activeTargets()) do
        local target = self.targets[key]
        removeTree(target.previous)
        -- <data>/icons may not exist yet; an empty placeholder keeps the swap uniform.
        if fileMode(target.live) ~= "directory" then
            ok, err = util.makePath(target.live)
        else
            ok = true
        end
        if ok then
            ok, err = os.rename(target.live, target.previous)
        end
        if ok then
            ok, err = os.rename(target.next, target.live)
        end
        if not ok then
            local rolled_back = self:_rollbackTransaction()
            if not rolled_back then
                return nil, "更换失败且自动回滚不完整：" .. tostring(err)
            end
            return nil, "更换失败，已回滚到更换前的状态：" .. tostring(err)
        end
    end
    os.remove(self.transaction_marker)
    for _, key in ipairs(self:_activeTargets()) do
        removeTree(self.targets[key].previous)
    end
    -- Leave no empty override dir behind once everything is back to official.
    local user_icons = self.targets.mdlight.live
    if fileMode(user_icons) == "directory" and isEmptyDir(user_icons) then
        os.remove(user_icons)
    end
    return true
end

function Engine:_applyPreparedPlan(path, plan, prepare_func)
    local prepared, err = prepare_func()
    if not prepared then
        return nil, err
    end
    local ok
    ok, err = self:_prepareStages(true)
    if not ok then
        self:_discardStages()
        removeTree(self.extraction_root)
        return nil, "准备图标失败：" .. tostring(err)
    end

    local previous_managed = self:_readManaged()
    local new_managed = {}
    for _, relative in ipairs(plan.managed or {}) do
        new_managed[relative] = true
    end
    -- Record old + new before swapping so an interruption never orphans installed icons.
    local union = {}
    for relative in pairs(previous_managed) do union[relative] = true end
    for relative in pairs(new_managed) do union[relative] = true end
    ok, err = self:_writeManaged(union)
    if not ok then
        self:_discardStages()
        removeTree(self.extraction_root)
        return nil, "无法记录已安装图标：" .. tostring(err)
    end

    ok, err = self:_commitStages()
    removeTree(self.extraction_root)
    if not ok then
        self:_writeManaged(previous_managed)
        return nil, err
    end
    self:_writeManaged(new_managed)
    logger.info("iconpackmanager: applied", path, plan.mdlight, plan.simpleui)
    return plan
end

function Engine:applyArchive(zip_path)
    local plan, err = self:inspectArchive(zip_path)
    if not plan then
        return nil, err
    end
    return self:_applyPreparedPlan(zip_path, plan, function()
        return self:_extractArchive(zip_path, plan)
    end)
end

function Engine:applyDirectory(pack_path)
    local plan, err = self:inspectDirectory(pack_path)
    if not plan then
        return nil, err
    end
    return self:_applyPreparedPlan(pack_path, plan, function()
        return self:_copyDirectoryPack(plan)
    end)
end

function Engine:applyPack(pack)
    if not pack or not pack.path then
        return nil, "图标包信息无效"
    end
    if pack.kind == "folder" then
        return self:applyDirectory(pack.path)
    end
    return self:applyArchive(pack.path)
end

-- Back to the official look: drop our overrides from <data>/icons and lay the
-- bundled official Simple UI icons over the plugin's icons dir.
-- Returns true[, warning].
function Engine:restoreOriginal()
    local ok, err = self:_prepareStages(false)
    if not ok then
        self:_discardStages()
        return nil, "准备恢复失败：" .. tostring(err)
    end
    ok, err = self:_commitStages()
    if not ok then
        return nil, err
    end
    self:_writeManaged({})
    logger.info("iconpackmanager: restored official icons")
    local legacy_ok, legacy_err = self:_restoreLegacyBuiltin()
    if not legacy_ok then
        return true, "旧版插件改动过的程序图标未能还原：" .. tostring(legacy_err)
    end
    return true
end

return Engine
