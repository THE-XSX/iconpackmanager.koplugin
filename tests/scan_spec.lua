-- SPDX-FileCopyrightText: Copyright (C) 2026 THE-XSX
-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- Icon Pack Manager (图标包管理器) - KOReader plugin
-- Released under the GNU Affero General Public License v3.0 or later.
-- See the LICENSE file in the project root for the full license text.

local files = {}
local file_contents = {}
local directories = { [""] = {} }
local mock_archives = {}
local mock_luasettings = {}

local function normalize(path)
    path = path:gsub("\\", "/"):gsub("/+", "/")
    if #path > 1 then path = path:gsub("/$", "") end
    return path
end

local function addChild(parent, name)
    directories[parent] = directories[parent] or {}
    directories[parent][name] = true
end

local function removeChild(parent, name)
    if directories[parent] then
        directories[parent][name] = nil
    end
end

local function addDirectory(path)
    path = normalize(path)
    if directories[path] then return end
    directories[path] = {}
    if path ~= "/" then
        local parent, name = path:match("^(.*)/([^/]+)$")
        if parent == "" then parent = "/" end
        addDirectory(parent)
        addChild(parent, name)
    end
end

local function addFile(path, size, content)
    path = normalize(path)
    local parent, name = path:match("^(.*)/([^/]+)$")
    if parent == "" then parent = "/" end
    addDirectory(parent)
    addChild(parent, name)
    if content ~= nil then
        file_contents[path] = content
        files[path] = size or #content
    else
        file_contents[path] = string.rep("x", size or 10)
        files[path] = size or 10
    end
end

local function removePath(path)
    path = normalize(path)
    local parent, name = path:match("^(.*)/([^/]+)$")
    if parent == "" then parent = "/" end
    if files[path] then
        files[path] = nil
        file_contents[path] = nil
        removeChild(parent, name)
        return true
    elseif directories[path] then
        local prefix = path .. "/"
        for p in pairs(files) do
            if p:sub(1, #prefix) == prefix then
                files[p] = nil
                file_contents[p] = nil
            end
        end
        for d in pairs(directories) do
            if d == path or d:sub(1, #prefix) == prefix then
                directories[d] = nil
            end
        end
        removeChild(parent, name)
        return true
    end
    return nil, "missing"
end

local function renamePath(src, dst)
    src = normalize(src)
    dst = normalize(dst)
    if files[src] then
        local size, content = files[src], file_contents[src]
        removePath(dst)
        addFile(dst, size, content)
        removePath(src)
        return true
    elseif directories[src] then
        removePath(dst)
        addDirectory(dst)
        local src_prefix = src .. "/"
        local to_move_dirs = {}
        for d in pairs(directories) do
            if d:sub(1, #src_prefix) == src_prefix then
                to_move_dirs[#to_move_dirs + 1] = d
            end
        end
        for _, d in ipairs(to_move_dirs) do
            addDirectory(dst .. "/" .. d:sub(#src_prefix + 1))
        end
        local to_move_files = {}
        for f, sz in pairs(files) do
            if f:sub(1, #src_prefix) == src_prefix then
                to_move_files[#to_move_files + 1] = { f, sz, file_contents[f] }
            end
        end
        for _, item in ipairs(to_move_files) do
            addFile(dst .. "/" .. item[1]:sub(#src_prefix + 1), item[2], item[3])
        end
        removePath(src)
        return true
    end
    return nil, "missing"
end

local orig_remove = os.remove
local orig_rename = os.rename
os.remove = function(path)
    if path and path:sub(1, 1) == "/" then
        return removePath(path)
    end
    return orig_remove(path)
end
os.rename = function(src, dst)
    if src and src:sub(1, 1) == "/" then
        return renamePath(src, dst)
    end
    return orig_rename(src, dst)
end

for _, path in ipairs({
    -- Legacy Simple UI install (no infra/sui_store.lua)
    "/ko/resources/icons/mdlight/a.svg",
    "/ko/resources/icons/mdlight/b.svg",
    "/ko/resources/icons/mdlight/shared.svg",
    "/ko/plugins/simpleui.koplugin/icons/s.svg",
    "/ko/plugins/simpleui.koplugin/icons/shared.svg",
    -- Standalone KOReader (no Simple UI)
    "/ko_nosui/resources/icons/mdlight/a.svg",
    "/ko_nosui/resources/icons/mdlight/b.svg",
    "/ko_nosui/resources/icons/mdlight/shared.svg",
    -- Android simulation with modern Simple UI (infra/sui_store.lua present)
    "/android_app/resources/icons/mdlight/appbar.menu.svg",
    "/android_app/resources/icons/mdlight/appbar.search.svg",
    "/android_app/resources/icons/mdlight/appbar.settings.svg",
    "/android_app/resources/icons/mdlight/chevron.left.svg",
    "/android_app/resources/icons/mdlight/check.svg",
    "/android_app/resources/icons/mdlight/home.svg",
    "/sdcard/koreader/plugins/simpleui.koplugin/infra/sui_store.lua",
    "/sdcard/koreader/plugins/simpleui.koplugin/icons/library.svg",
    "/sdcard/koreader/plugins/simpleui.koplugin/icons/settings.svg",
    -- Bundled official icons in plugin dir
    "/plugin/official/mdlight/a.svg",
    "/plugin/official/mdlight/b.svg",
    "/plugin/official/mdlight/shared.svg",
    "/plugin/official/simpleui/s.svg",
    "/plugin/official/simpleui/shared.svg",
    "/plugin_modern/official/mdlight/appbar.menu.svg",
    "/plugin_modern/official/mdlight/appbar.search.svg",
    "/plugin_modern/official/mdlight/appbar.settings.svg",
    "/plugin_modern/official/mdlight/chevron.left.svg",
    "/plugin_modern/official/mdlight/check.svg",
    "/plugin_modern/official/mdlight/home.svg",
    "/plugin_modern/official/simpleui/library.svg",
    "/plugin_modern/official/simpleui/settings.svg",
    -- Test packs (legacy)
    "/packs/theme/a.svg",
    "/packs/theme/shared.svg",
    "/packs/theme/unknown.svg",
    "/packs/theme/plugins/s.svg",
    "/packs/variants/bw/a.svg",
    "/packs/variants/coloured/b.svg",
    -- Modern Simple UI test packs
    "/modern_packs/mdlight_only/appbar.menu.svg",
    "/modern_packs/mdlight_only/appbar.settings.svg",
    "/modern_packs/mdlight_only/chevron.left.svg",
    "/modern_packs/mdlight_only/check.svg",
    "/modern_packs/mdlight_only/home.svg",
    "/modern_packs/mixed_priority/mdlight/appbar.menu.svg",
    "/modern_packs/mixed_priority/mdlight/chevron.left.svg",
    "/modern_packs/mixed_priority/simpleui/more-options.svg",
    "/modern_packs/mixed_priority/simpleui/sui_menu.png",
    "/modern_packs/mixed_priority/simpleui/library.svg",
    "/modern_packs/mixed_priority/simpleui/appbar.settings.svg",
    "/modern_packs/mixed_priority/sui_action_collections.png",
    "/modern_packs/partial_png/sui_menu.png",
    "/modern_packs/dup_slot/sui_menu.svg",
    "/modern_packs/dup_slot/nested/sui_menu.png",
}) do
    addFile(path)
end

-- Give distinct content so we can verify which source won priority resolution.
addFile("/modern_packs/mixed_priority/mdlight/appbar.menu.svg", 11, "MD_MENU_SVG")
addFile("/modern_packs/mixed_priority/simpleui/more-options.svg", 12, "LEG_MORE_OPT")
addFile("/modern_packs/mixed_priority/simpleui/sui_menu.png", 13, "SUI_MENU_PNG")
addFile("/modern_packs/mixed_priority/simpleui/appbar.settings.svg", 14, "SUI_APPSET_S")
addFile("/modern_packs/mixed_priority/simpleui/library.svg", 15, "LEG_LIB_SVG")
addFile("/modern_packs/mixed_priority/sui_action_collections.png", 16, "SUI_COLL_PNG")
addFile("/modern_packs/partial_png/sui_menu.png", 17, "PARTIAL_PNG")
addFile("/plugin_modern/official/simpleui/settings.svg", 18, "OFF_SUI_SET")
-- Simulate legacy v1.2 custom settings.svg in simpleui.koplugin/icons/ + stale tab icon
addFile("/sdcard/koreader/plugins/simpleui.koplugin/icons/settings.svg", 19, "OLD_V12_SET")
addFile("/sdcard/koreader/icons/simpleui_sui_tab_main.svg", 20, "STALE_TAB_ICON")

package.preload["ffi/archiver"] = function()
    local Reader = {}
    Reader.__index = Reader
    function Reader:new()
        return setmetatable({}, self)
    end
    function Reader:open(path)
        self._entries = mock_archives[normalize(path)]
        if not self._entries then
            self.err = "missing archive"
            return false
        end
        return true
    end
    function Reader:iterate()
        local i = 0
        local list = self._entries or {}
        return function()
            i = i + 1
            return list[i]
        end
    end
    function Reader:extractToPath(archive_path, dst)
        for _, e in ipairs(self._entries or {}) do
            if e.path == archive_path then
                addFile(dst, e.size, e.content)
                return true
            end
        end
        return false
    end
    function Reader:close() end
    return { Reader = Reader }
end

package.preload["ffi/util"] = function()
    return {
        dirname = function(path) return path:match("^(.*)/[^/]+$") end,
        copyFile = function(src, dst)
            src = normalize(src)
            addFile(dst, files[src] or 10, file_contents[src])
            return nil
        end,
        purgeDir = function(dir)
            removePath(dir)
            return true
        end,
    }
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, attribute)
            path = normalize(path)
            local value
            if files[path] then
                value = { mode = "file", size = files[path] }
            elseif directories[path] then
                value = { mode = "directory", size = 0 }
            end
            if attribute then return value and value[attribute] end
            return value
        end,
        dir = function(path)
            path = normalize(path)
            assert(directories[path], "missing mock directory: " .. path)
            local names = { ".", ".." }
            for name in pairs(directories[path]) do names[#names + 1] = name end
            table.sort(names)
            local index = 0
            return function()
                index = index + 1
                return names[index]
            end
        end,
    }
end

package.preload["logger"] = function() return { info = function() end, warn = function() end, err = function() end } end

package.preload["util"] = function()
    return {
        makePath = function(path)
            addDirectory(path)
            return true
        end,
        writeToFile = function(content, path)
            addFile(path, #content, content)
            return true
        end,
        readFromFile = function(path)
            path = normalize(path)
            return file_contents[path]
        end,
    }
end

package.preload["luasettings"] = function()
    return {
        open = function(_, path)
            path = normalize(path)
            if not mock_luasettings[path] then
                mock_luasettings[path] = {
                    file = path,
                    data = {},
                    readSetting = function(self, k) return self.data[k] end,
                    saveSetting = function(self, k, v) self.data[k] = v end,
                    delSetting = function(self, k) self.data[k] = nil end,
                    flush = function(self)
                        addFile(self.file, 10, "flushed")
                        return self
                    end,
                }
            end
            return mock_luasettings[path]
        end,
    }
end

local script_dir = debug.getinfo(1, "S").source:match("@?(.*)[/\\]")
local engine_path = (script_dir and (script_dir .. "/../iconpack_engine.lua")) or "iconpack_engine.lua"
local Engine = assert((loadfile(engine_path) or loadfile("../iconpack_engine.lua") or loadfile("iconpack_engine.lua"))())

-- Test 1: With Legacy Simple UI installed (no infra/sui_store.lua)
local engine = Engine:new{ data_dir = "/ko", settings_dir = "/ko/settings", plugin_dir = "/plugin" }
assert(engine:hasSimpleUI() == true, "Simple UI detected")
assert(engine:simpleUIMode() == "legacy", "Legacy Simple UI mode")

local plan = assert(engine:inspectDirectory("/packs/theme"))
assert(plan.mdlight == 2, "flat mdlight matches")
assert(plan.simpleui == 2, "flat Simple UI matches, including shared filename")
assert(plan.expected.mdlight == 3 and #plan.missing.mdlight == 1)
assert(plan.missing.mdlight[1] == "b.svg")
assert(plan.expected.simpleui == 2 and #plan.missing.simpleui == 0)
assert(#plan.unknown == 1 and plan.unknown[1] == "unknown.svg")
assert(#plan.entries == 4, "one shared source should map to both targets")

local packs = assert(engine:scanFolder("/packs"))
assert(#packs == 3, "theme plus two nested variants")
assert(packs[1].name == "theme")
assert(packs[2].name == "variants/bw")
assert(packs[3].name == "variants/coloured")

-- Test 2: Without Simple UI installed (standalone KOReader)
local engine_nosui = Engine:new{ data_dir = "/ko_nosui", settings_dir = "/ko_nosui/settings", plugin_dir = "/plugin" }
assert(engine_nosui:hasSimpleUI() == false, "Simple UI not detected")

local plan_nosui = assert(engine_nosui:inspectDirectory("/packs/theme"))
assert(plan_nosui.mdlight == 2, "flat mdlight matches")
assert(plan_nosui.simpleui == 0, "no Simple UI target active")
assert(plan_nosui.expected.mdlight == 3 and #plan_nosui.missing.mdlight == 1)
assert(plan_nosui.expected.simpleui == 0 and #plan_nosui.missing.simpleui == 0)
assert(#plan_nosui.entries == 2, "only mdlight targets mapped")

-- Test 3: Android simulation with Modern Simple UI (infra/sui_store.lua present)
local sui_settings_path = "/sdcard/koreader/settings/simpleui/sui_settings.lua"
local live_sui_store = {
    data = {
        simpleui_sysicon_sui_menu = "/old/simpleui/pack/sui_menu.svg",
        simpleui_qa_custom_qa_1 = { label = "KeepMe", icon = "/user/custom.svg" },
    },
    flushed = 0,
    setNoFlush = function(self, k, v) self.data[k] = v end,
    delNoFlush = function(self, k) self.data[k] = nil end,
    flush = function(self) self.flushed = self.flushed + 1 end,
}

local engine_android = Engine:new{
    data_dir = "/sdcard/koreader",
    settings_dir = "/sdcard/koreader/settings",
    install_dir = "/android_app",
    plugin_dir = "/plugin_modern",
    sui_store = live_sui_store,
}
assert(engine_android:hasSimpleUI() == true, "Android Simple UI in user storage detected")
assert(engine_android:simpleUIMode() == "settings", "Modern Simple UI uses settings mode")
assert(engine_android:userIconsPath() == "/sdcard/koreader/icons", "Android writes to user icons override dir")
assert(engine_android:isReservedFolder("/sdcard/koreader/icons") == true, "user icons dir is reserved")
assert(engine_android:isReservedFolder("/sdcard/koreader/icons/sub") == true, "user icons sub-dir is reserved")
assert(engine_android:isReservedFolder("/sdcard/koreader/iconpacks") == false, "iconpacks folder is not reserved")

-- Test 4: Pure mdlight pack automatically maps into Modern Simple UI slots
local plan_mdonly = assert(engine_android:inspectDirectory("/modern_packs/mdlight_only"))
assert(plan_mdonly.mdlight == 5, "all 5 mdlight icons matched")
assert(plan_mdonly.expected.simpleui == 49, "Modern Simple UI reports all 49 slots")
assert(plan_mdonly.simpleui == 10, "mdlight fallback covers menu/back/pager/navpager/system/tabs/actions")
assert(plan_mdonly.simpleui_settings.simpleui_sysicon_sui_menu == "sui_menu.svg")
assert(plan_mdonly.simpleui_settings.simpleui_sysicon_sui_pager_prev == "sui_pager_prev.svg")
assert(plan_mdonly.simpleui_settings.simpleui_action_homescreen_icon == "sui_action_homescreen.svg")

-- Test 5: Priority resolution & PNG support & applying + live sui_store sync
local applied = assert(engine_android:applyDirectory("/modern_packs/mixed_priority"))
assert(applied.mdlight == 2, "mdlight only gets mdlight/ icons, not simpleui/appbar.settings.svg")
assert(applied.simpleui_settings.simpleui_sysicon_sui_menu == "sui_menu.png", "sui_menu.png beats more-options.svg and appbar.menu.svg")
assert(applied.simpleui_settings.simpleui_sysicon_sui_tab_main == "sui_tab_main.svg", "mdlight/appbar.menu.svg still populates sui_tab_main")
assert(applied.simpleui_settings.simpleui_sysicon_sui_qa_system == "sui_qa_system.svg", "simpleui/appbar.settings.svg populates sui_qa_system without touching mdlight")
assert(applied.simpleui_settings.simpleui_action_home_icon == "sui_action_library.svg", "legacy library.svg maps to simpleui_action_home_icon")
assert(applied.simpleui_settings.simpleui_action_collections_icon == "sui_action_collections.png", "sui_action_collections.png preserves .png extension")

assert(file_contents["/sdcard/koreader/settings/iconpackmanager/simpleui/sui_menu.png"] == "SUI_MENU_PNG")
assert(file_contents["/sdcard/koreader/settings/iconpackmanager/simpleui/sui_qa_system.svg"] == "SUI_APPSET_S")
assert(file_contents["/sdcard/koreader/icons/appbar.menu.svg"] == "MD_MENU_SVG")
assert(files["/sdcard/koreader/icons/appbar.settings.svg"] == nil, "explicit simpleui/appbar.settings.svg must not leak into mdlight")
assert(files["/sdcard/koreader/icons/simpleui_sui_tab_main.svg"] == nil, "stale simpleui_sui_tab_* cleaned from mdlight icons")
assert(live_sui_store.data.simpleui_sysicon_sui_menu == "/sdcard/koreader/settings/iconpackmanager/simpleui/sui_menu.png")
assert(live_sui_store.data.simpleui_action_collections_icon == "/sdcard/koreader/settings/iconpackmanager/simpleui/sui_action_collections.png")
assert(live_sui_store.data.simpleui_qa_custom_qa_1.label == "KeepMe", "user custom QAs preserved")
assert(live_sui_store.flushed == 1, "live sui_store flushed")
assert(file_contents["/sdcard/koreader/plugins/simpleui.koplugin/icons/settings.svg"] == "OFF_SUI_SET", "legacy v1.2 plugin override cleaned up")

-- Test 6: Switching to partial pack clears previous Simple UI slots & mdlight icons
local applied_partial = assert(engine_android:applyDirectory("/modern_packs/partial_png"))
assert(applied_partial.mdlight == 0 and applied_partial.simpleui == 1)
assert(files["/sdcard/koreader/icons/appbar.menu.svg"] == nil, "old mdlight icon removed")
assert(live_sui_store.data.simpleui_sysicon_sui_menu == "/sdcard/koreader/settings/iconpackmanager/simpleui/sui_menu.png")
assert(file_contents["/sdcard/koreader/settings/iconpackmanager/simpleui/sui_menu.png"] == "PARTIAL_PNG")
assert(live_sui_store.data.simpleui_action_home_icon == nil, "previous Simple UI action cleared")
assert(live_sui_store.data.simpleui_sysicon_sui_tab_main == nil, "previous Simple UI tab cleared")

-- Test 7: Restore original clears both mdlight and Simple UI settings
assert(engine_android:restoreOriginal())
assert(live_sui_store.data.simpleui_sysicon_sui_menu == nil, "restore clears sui_settings keys")
assert(live_sui_store.data.simpleui_qa_custom_qa_1.label == "KeepMe", "restore keeps user custom QAs")
assert(directories["/sdcard/koreader/settings/iconpackmanager/simpleui"] == nil, "empty simpleui staging removed")

-- Test 8: Duplicate detection at equal priority fails cleanly
local dup_plan, dup_err = engine_android:inspectDirectory("/modern_packs/dup_slot")
assert(dup_plan == nil and dup_err:find("重复图标"), "equal-priority sui_menu.svg + sui_menu.png rejected")

-- Test 9: Archive (ZIP) inspection, priority extraction, and wrapper vs subfolder simpleui/
addFile("/zips/wrapper_mdlight.zip", 10, "zip")
mock_archives["/zips/wrapper_mdlight.zip"] = {
    { path = "simpleui/check.svg", mode = "file", size = 5, content = "CHECK" },
    { path = "simpleui/appbar.menu.svg", mode = "file", size = 6, content = "APPMNU" },
}
local wrap_plan = assert(engine_android:inspectArchive("/zips/wrapper_mdlight.zip"))
assert(wrap_plan.mdlight == 2, "ZIP single root wrapper named 'simpleui/' still maps mdlight icons")
assert(wrap_plan.simpleui == 2, "appbar.menu inside wrapper maps to Simple UI fallback")

addFile("/zips/structured.zip", 10, "zip")
mock_archives["/zips/structured.zip"] = {
    { path = "Theme/mdlight/appbar.menu.svg", mode = "file", size = 6, content = "ZIP_MD" },
    { path = "Theme/simpleui/sui_menu.svg", mode = "file", size = 7, content = "ZIP_SUI" },
    { path = "Theme/simpleui/sui_tab_qs_panel.png", mode = "file", size = 7, content = "ZIP_TAB" },
}
local zip_applied = assert(engine_android:applyArchive("/zips/structured.zip"))
assert(zip_applied.mdlight == 1 and zip_applied.simpleui == 3)
assert(file_contents["/sdcard/koreader/icons/appbar.menu.svg"] == "ZIP_MD")
assert(file_contents["/sdcard/koreader/settings/iconpackmanager/simpleui/sui_menu.svg"] == "ZIP_SUI")
assert(file_contents["/sdcard/koreader/settings/iconpackmanager/simpleui/sui_tab_qs_panel.png"] == "ZIP_TAB")
assert(live_sui_store.data.simpleui_sysicon_sui_tab_qs_panel == "/sdcard/koreader/settings/iconpackmanager/simpleui/sui_tab_qs_panel.png")

-- Test 10: Fallback to LuaSettings on disk when live sui_store is not loaded
local engine_disk_sui = Engine:new{
    data_dir = "/sdcard/koreader",
    settings_dir = "/sdcard/koreader/settings",
    install_dir = "/android_app",
    plugin_dir = "/plugin_modern",
    sui_store = false,
}
assert(engine_disk_sui:applyArchive("/zips/structured.zip"))
local disk_store = mock_luasettings[sui_settings_path]
assert(disk_store and disk_store:readSetting("simpleui_sysicon_sui_menu") == "/sdcard/koreader/settings/iconpackmanager/simpleui/sui_menu.svg")

local status = engine:officialStatus()
assert(status.mdlight == 3, "Official mdlight has 3 icons")
assert(status.simpleui == 2, "Official Simple UI has 2 icons")

local status_modern = engine_android:officialStatus()
assert(status_modern.mdlight == 6, "Modern test official mdlight has 6 icons")
assert(status_modern.simpleui == 2, "Modern test official Simple UI has 2 icons")

print("scan_spec: OK")
