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

function Engine:new(options)
    local data_dir = assert(options and options.data_dir, "data_dir is required")
    local settings_dir = assert(options.settings_dir, "settings_dir is required")
    local state_root = join(settings_dir, "iconpackmanager")
    local object = {
        data_dir = data_dir,
        state_root = state_root,
        backup_root = join(state_root, "original"),
        backup_marker = join(join(state_root, "original"), ".complete"),
        extraction_root = join(state_root, "extracted"),
        transaction_marker = join(state_root, ".transaction"),
        targets = {
            mdlight = {
                live = join(data_dir, "resources/icons/mdlight"),
                backup_name = "mdlight",
            },
            simpleui = {
                live = join(data_dir, "plugins/simpleui.koplugin/icons"),
                backup_name = "simpleui",
            },
        },
    }
    setmetatable(object, self)
    for _, target in pairs(object.targets) do
        target.backup = join(object.backup_root, target.backup_name)
        target.next = target.live .. ".iconpackmanager-next"
        target.previous = target.live .. ".iconpackmanager-previous"
    end
    return object
end

function Engine:_inventory(target_key)
    local root = self.targets[target_key].live
    local names = {}
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
                    names[relative] = true
                end
            end
        end
        return true
    end
    local ok, err = scan(root, "")
    if not ok then
        return nil, err
    end
    return names
end

function Engine:hasSimpleUI()
    if fileMode(self.backup_marker) == "file" then
        local marker = util.readFromFile(self.backup_marker, "rb")
        if marker then
            local _, _, sc = marker:match("^(%d+) (%d+) ?(%d*) ?(%d*)%s*$")
            if sc and tonumber(sc) and tonumber(sc) > 0 then
                return true
            end
            if marker:match("^(%d+) (%d+)$") or (sc and tonumber(sc) == 0) then
                return false
            end
        end
    end
    return fileMode(self.targets.simpleui.live) == "directory"
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
    local is_complete = true
    for _, target_key in ipairs(self:_activeTargets()) do
        local inventory, err = self:_inventory(target_key)
        if not inventory then
            return nil, err
        end
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
        if fileMode(join(self.targets[explicit_target].live, safe_relative)) ~= "file" then
            return nil, "图标名不属于当前安装：" .. safe_relative
        end
        return {{ target = explicit_target, relative = safe_relative, size = size }}
    end

    local filename = basename(safe_path)
    local mappings = {}
    for _, target_key in ipairs(self:_activeTargets()) do
        if fileMode(join(self.targets[target_key].live, filename)) == "file" then
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

function Engine:_targetStats(root, target_keys)
    target_keys = target_keys or self:_activeTargets()
    local result = {}
    for _, key in ipairs(target_keys) do
        local stats, err = directoryStats(join(root, self.targets[key].backup_name))
        if not stats then
            return nil, err
        end
        result[key] = stats
    end
    return result
end

function Engine:backupStatus()
    if fileMode(self.backup_marker) ~= "file" then
        return false, "尚未备份原版图标"
    end
    local marker = util.readFromFile(self.backup_marker, "rb")
    if not marker then
        return false, "备份标记无法读取"
    end
    local mc, mb, sc, sb = marker:match("^(%d+) (%d+) ?(%d*) ?(%d*)%s*$")
    if not mc or not mb then
        return false, "备份标记已损坏"
    end
    local has_sui = sc and tonumber(sc) and tonumber(sc) > 0
    local target_keys = has_sui and { "mdlight", "simpleui" } or { "mdlight" }
    local stats, err = self:_targetStats(self.backup_root, target_keys)
    if not stats then
        return false, "备份无法读取：" .. tostring(err)
    end
    if stats.mdlight.count ~= tonumber(mc) or stats.mdlight.bytes ~= tonumber(mb) then
        return false, "KOReader 备份校验失败"
    end
    if stats.mdlight.count == 0 then
        return false, "KOReader 备份内容不完整"
    end
    if has_sui then
        if stats.simpleui.count ~= tonumber(sc) or stats.simpleui.bytes ~= tonumber(sb) then
            return false, "Simple UI 备份校验失败"
        end
        if stats.simpleui.count == 0 then
            return false, "Simple UI 备份内容不完整"
        end
    else
        stats.simpleui = { count = 0, bytes = 0 }
    end
    return true, stats
end

function Engine:createBackup()
    local valid = self:backupStatus()
    if valid then
        return nil, "原版图标已经备份；为防止覆盖，不能重复备份"
    end
    if fileMode(self.targets.mdlight.live) ~= "directory" then
        return nil, "找不到目标目录：" .. self.targets.mdlight.live
    end
    local has_sui = fileMode(self.targets.simpleui.live) == "directory"
    local active_keys = has_sui and { "mdlight", "simpleui" } or { "mdlight" }

    local ok, err = util.makePath(self.state_root)
    if not ok then
        return nil, err
    end
    local staging = self.backup_root .. ".next"
    removeTree(staging)
    ok, err = util.makePath(staging)
    if not ok then
        return nil, err
    end
    for _, key in ipairs(active_keys) do
        ok, err = copyTree(self.targets[key].live, join(staging, self.targets[key].backup_name))
        if not ok then
            removeTree(staging)
            return nil, "备份失败：" .. tostring(err)
        end
    end
    local source_stats = {}
    for _, key in ipairs(active_keys) do
        source_stats[key], err = directoryStats(self.targets[key].live)
        if not source_stats[key] then
            removeTree(staging)
            return nil, err
        end
    end
    local backup_stats
    backup_stats, err = self:_targetStats(staging, active_keys)
    if not backup_stats then
        removeTree(staging)
        return nil, err
    end
    for _, key in ipairs(active_keys) do
        if source_stats[key].count ~= backup_stats[key].count
                or source_stats[key].bytes ~= backup_stats[key].bytes then
            removeTree(staging)
            return nil, "备份文件数量或大小校验失败"
        end
    end
    local marker
    if has_sui then
        marker = string.format("%d %d %d %d\n",
            backup_stats.mdlight.count, backup_stats.mdlight.bytes,
            backup_stats.simpleui.count, backup_stats.simpleui.bytes)
    else
        marker = string.format("%d %d 0 0\n",
            backup_stats.mdlight.count, backup_stats.mdlight.bytes)
        backup_stats.simpleui = { count = 0, bytes = 0 }
    end
    if not util.writeToFile(marker, join(staging, ".complete")) then
        removeTree(staging)
        return nil, "无法写入备份校验标记"
    end
    removeTree(self.backup_root)
    ok, err = os.rename(staging, self.backup_root)
    if not ok then
        return nil, "无法完成备份：" .. tostring(err)
    end
    return true, backup_stats
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
            elseif mode == "directory" and not current_is_pack and directoryContainsSvg(path) then
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

function Engine:_prepareStages(with_overlay)
    for _, key in ipairs(self:_activeTargets()) do
        local target = self.targets[key]
        removeTree(target.next)
        local ok, err = copyTree(target.backup, target.next)
        if not ok then
            return nil, err
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
        if fileMode(target.previous) == "directory" then
            removeTree(target.live)
            local ok = os.rename(target.previous, target.live)
            all_ok = all_ok and ok and true or false
        end
        removeTree(target.next)
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
        if fileMode(target.live) ~= "directory" and fileMode(target.previous) == "directory" then
            os.rename(target.previous, target.live)
        elseif fileMode(target.previous) == "directory" then
            removeTree(target.previous)
        end
        removeTree(target.next)
    end
    return true
end

function Engine:_commitStages()
    local ok, err = util.writeToFile("active\n", self.transaction_marker)
    if not ok then
        return nil, "无法创建事务标记"
    end
    for _, key in ipairs(self:_activeTargets()) do
        local target = self.targets[key]
        removeTree(target.previous)
        ok, err = os.rename(target.live, target.previous)
        if ok then
            ok, err = os.rename(target.next, target.live)
        end
        if not ok then
            local rolled_back = self:_rollbackTransaction()
            if not rolled_back then
                return nil, "更换失败且自动回滚不完整：" .. tostring(err)
            end
            return nil, "更换失败，已恢复原版图标：" .. tostring(err)
        end
    end
    os.remove(self.transaction_marker)
    for _, key in ipairs(self:_activeTargets()) do
        removeTree(self.targets[key].previous)
    end
    return true
end

function Engine:_applyPreparedPlan(path, plan, prepare_func)
    local backup_ok, backup_err = self:backupStatus()
    if not backup_ok then
        return nil, backup_err
    end
    local prepared, err = prepare_func()
    if not prepared then
        return nil, err
    end
    local ok
    ok, err = self:_prepareStages(true)
    if not ok then
        removeTree(self.extraction_root)
        return nil, "准备图标失败：" .. tostring(err)
    end
    ok, err = self:_commitStages()
    removeTree(self.extraction_root)
    if not ok then
        return nil, err
    end
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

function Engine:restoreOriginal()
    local backup_ok, backup_err = self:backupStatus()
    if not backup_ok then
        return nil, backup_err
    end
    local ok, err = self:_prepareStages(false)
    if not ok then
        return nil, "准备恢复失败：" .. tostring(err)
    end
    ok, err = self:_commitStages()
    if not ok then
        return nil, err
    end
    logger.info("iconpackmanager: restored original icons")
    return true
end

return Engine
