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
local SUPPORTED_EXTS = { [".svg"] = true, [".png"] = true }

local PRIO_SUI_CANONICAL = 1
local PRIO_SUI_ALIAS     = 2
local PRIO_SUI_LEGACY    = 3
local PRIO_SUI_EXPLICIT  = 4
local PRIO_MDLIGHT       = 5

-- Modern Simple UI icon slots (stored in <settings_dir>/simpleui/sui_settings.lua).
-- Priority order determines which file wins when a pack provides multiple
-- overlapping names (e.g. both mdlight/appbar.menu.svg and simpleui/sui_menu.svg).
local SIMPLEUI_SLOTS = {
    -- Titlebar
    { id = "sui_menu",   key = "simpleui_sysicon_sui_menu",
      sources = { { "sui_menu", PRIO_SUI_CANONICAL }, { "more-options", PRIO_SUI_LEGACY }, { "appbar.menu", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_search", key = "simpleui_sysicon_sui_search",
      sources = { { "sui_search", PRIO_SUI_CANONICAL }, { "appbar.search", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_back",   key = "simpleui_sysicon_sui_back",
      sources = { { "sui_back", PRIO_SUI_CANONICAL }, { "back", PRIO_SUI_LEGACY }, { "chevron.left", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    -- Browse Meta
    { id = "sui_browse_normal", key = "simpleui_sysicon_sui_browse_normal",
      sources = { { "sui_browse_normal", PRIO_SUI_CANONICAL }, { "default", PRIO_SUI_LEGACY }, { "custom", PRIO_SUI_EXPLICIT } } },
    { id = "sui_browse_author", key = "simpleui_sysicon_sui_browse_author",
      sources = { { "sui_browse_author", PRIO_SUI_CANONICAL }, { "author", PRIO_SUI_LEGACY } } },
    { id = "sui_browse_series", key = "simpleui_sysicon_sui_browse_series",
      sources = { { "sui_browse_series", PRIO_SUI_CANONICAL }, { "series", PRIO_SUI_LEGACY } } },
    { id = "sui_browse_tags",   key = "simpleui_sysicon_sui_browse_tags",
      sources = { { "sui_browse_tags", PRIO_SUI_CANONICAL }, { "tags", PRIO_SUI_LEGACY } } },
    -- Pagination chevrons
    { id = "sui_pager_prev",  key = "simpleui_sysicon_sui_pager_prev",
      sources = { { "sui_pager_prev", PRIO_SUI_CANONICAL }, { "chevron.left", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_pager_next",  key = "simpleui_sysicon_sui_pager_next",
      sources = { { "sui_pager_next", PRIO_SUI_CANONICAL }, { "chevron.right", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_pager_first", key = "simpleui_sysicon_sui_pager_first",
      sources = { { "sui_pager_first", PRIO_SUI_CANONICAL }, { "chevron.first", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_pager_last",  key = "simpleui_sysicon_sui_pager_last",
      sources = { { "sui_pager_last", PRIO_SUI_CANONICAL }, { "chevron.last", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    -- Navpager arrows
    { id = "sui_navpager_prev", key = "simpleui_sysicon_sui_navpager_prev",
      sources = { { "sui_navpager_prev", PRIO_SUI_CANONICAL }, { "chevron.left", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_navpager_next", key = "simpleui_sysicon_sui_navpager_next",
      sources = { { "sui_navpager_next", PRIO_SUI_CANONICAL }, { "chevron.right", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    -- Collections back
    { id = "sui_coll_back", key = "simpleui_sysicon_sui_coll_back",
      sources = { { "sui_coll_back", PRIO_SUI_CANONICAL }, { "back.top", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    -- Quick Settings Exit
    { id = "sui_qs_exit", key = "simpleui_sysicon_sui_qs_exit",
      sources = { { "sui_qs_exit", PRIO_SUI_CANONICAL }, { "exit", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    -- Quick Actions Defaults
    { id = "sui_qa_folder", key = "simpleui_sysicon_sui_qa_folder",
      sources = { { "sui_qa_folder", PRIO_SUI_CANONICAL }, { "custom", PRIO_SUI_LEGACY } } },
    { id = "sui_qa_plugin", key = "simpleui_sysicon_sui_qa_plugin",
      sources = { { "sui_qa_plugin", PRIO_SUI_CANONICAL }, { "plugin", PRIO_SUI_LEGACY } } },
    { id = "sui_qa_system", key = "simpleui_sysicon_sui_qa_system",
      sources = { { "sui_qa_system", PRIO_SUI_CANONICAL }, { "appbar.settings", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_qa_group",  key = "simpleui_sysicon_sui_qa_group",
      sources = { { "sui_qa_group", PRIO_SUI_CANONICAL }, { "group", PRIO_SUI_LEGACY } } },
    -- Folder Covers
    { id = "sui_fc_empty", key = "simpleui_sysicon_sui_fc_empty",
      sources = { { "sui_fc_empty", PRIO_SUI_CANONICAL }, { "custom", PRIO_SUI_LEGACY } } },
    -- Touch menu tab bar
    { id = "sui_tab_main",        key = "simpleui_sysicon_sui_tab_main",        is_tab = true,
      sources = { { "sui_tab_main", PRIO_SUI_CANONICAL }, { "appbar.menu", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_tab_setting",     key = "simpleui_sysicon_sui_tab_setting",     is_tab = true,
      sources = { { "sui_tab_setting", PRIO_SUI_CANONICAL }, { "appbar.settings", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_tab_tools",       key = "simpleui_sysicon_sui_tab_tools",       is_tab = true,
      sources = { { "sui_tab_tools", PRIO_SUI_CANONICAL }, { "appbar.tools", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_tab_search",      key = "simpleui_sysicon_sui_tab_search",      is_tab = true,
      sources = { { "sui_tab_search", PRIO_SUI_CANONICAL }, { "appbar.search", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_tab_fm_settings", key = "simpleui_sysicon_sui_tab_fm_settings", is_tab = true,
      sources = { { "sui_tab_fm_settings", PRIO_SUI_CANONICAL }, { "appbar.filebrowser", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_tab_navigation",  key = "simpleui_sysicon_sui_tab_navigation",  is_tab = true,
      sources = { { "sui_tab_navigation", PRIO_SUI_CANONICAL }, { "appbar.navigation", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_tab_typeset",     key = "simpleui_sysicon_sui_tab_typeset",     is_tab = true,
      sources = { { "sui_tab_typeset", PRIO_SUI_CANONICAL }, { "appbar.typeset", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_tab_filebrowser", key = "simpleui_sysicon_sui_tab_filebrowser", is_tab = true,
      sources = { { "sui_tab_filebrowser", PRIO_SUI_CANONICAL }, { "appbar.filebrowser", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_tab_qs_panel",    key = "simpleui_sysicon_sui_tab_qs_panel",    is_tab = true,
      sources = { { "sui_tab_qs_panel", PRIO_SUI_CANONICAL }, { "settings", PRIO_SUI_LEGACY }, { "appbar.settings", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    -- Built-in Quick Actions
    { id = "sui_action_library",          key = "simpleui_action_home_icon",
      sources = { { "sui_action_library", PRIO_SUI_CANONICAL }, { "sui_action_home", PRIO_SUI_ALIAS }, { "library", PRIO_SUI_LEGACY } } },
    { id = "sui_action_homescreen",       key = "simpleui_action_homescreen_icon",
      sources = { { "sui_action_homescreen", PRIO_SUI_CANONICAL }, { "home", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_action_collections",      key = "simpleui_action_collections_icon",
      sources = { { "sui_action_collections", PRIO_SUI_CANONICAL }, { "collections", PRIO_SUI_LEGACY } } },
    { id = "sui_action_history",          key = "simpleui_action_history_icon",
      sources = { { "sui_action_history", PRIO_SUI_CANONICAL }, { "history", PRIO_SUI_LEGACY } } },
    { id = "sui_action_recent",           key = "simpleui_action_recent_icon",
      sources = { { "sui_action_recent", PRIO_SUI_CANONICAL }, { "recent", PRIO_SUI_LEGACY }, { "last_document", PRIO_SUI_EXPLICIT } } },
    { id = "sui_action_continue",         key = "simpleui_action_continue_icon",
      sources = { { "sui_action_continue", PRIO_SUI_CANONICAL }, { "continue", PRIO_SUI_LEGACY }, { "last_document", PRIO_SUI_EXPLICIT } } },
    { id = "sui_action_random_document",  key = "simpleui_action_random_document_icon",
      sources = { { "sui_action_random_document", PRIO_SUI_CANONICAL }, { "random", PRIO_SUI_LEGACY } } },
    { id = "sui_action_favorites",        key = "simpleui_action_favorites_icon",
      sources = { { "sui_action_favorites", PRIO_SUI_CANONICAL }, { "favorites", PRIO_SUI_LEGACY }, { "star.empty", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_action_bookmark_browser", key = "simpleui_action_bookmark_browser_icon",
      sources = { { "sui_action_bookmark_browser", PRIO_SUI_CANONICAL }, { "bookmark", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_action_search_library",   key = "simpleui_action_search_library_icon",
      sources = { { "sui_action_search_library", PRIO_SUI_CANONICAL }, { "appbar.search", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_action_wifi_toggle",      key = "simpleui_action_wifi_toggle_icon",
      sources = { { "sui_action_wifi_toggle", PRIO_SUI_CANONICAL }, { "wifi.open.100", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_action_frontlight",       key = "simpleui_action_frontlight_icon",
      sources = { { "sui_action_frontlight", PRIO_SUI_CANONICAL }, { "frontlight", PRIO_SUI_LEGACY } } },
    { id = "sui_action_night_mode",       key = "simpleui_action_night_mode_icon",
      sources = { { "sui_action_night_mode", PRIO_SUI_CANONICAL }, { "night", PRIO_SUI_LEGACY } } },
    { id = "sui_action_stats_calendar",   key = "simpleui_action_stats_calendar_icon",
      sources = { { "sui_action_stats_calendar", PRIO_SUI_CANONICAL }, { "stats", PRIO_SUI_LEGACY } } },
    { id = "sui_action_power",            key = "simpleui_action_power_icon",
      sources = { { "sui_action_power", PRIO_SUI_CANONICAL }, { "power", PRIO_SUI_LEGACY } } },
    { id = "sui_action_settings",         key = "simpleui_action_sui_settings_icon",
      sources = { { "sui_action_settings", PRIO_SUI_CANONICAL }, { "sui_action_sui_settings", PRIO_SUI_ALIAS }, { "settings", PRIO_SUI_LEGACY }, { "appbar.settings", PRIO_MDLIGHT, PRIO_SUI_EXPLICIT, true } } },
    { id = "sui_action_backup_export",    key = "simpleui_action_backup_export_icon",
      sources = { { "sui_action_backup_export", PRIO_SUI_CANONICAL }, { "backup", PRIO_SUI_LEGACY } } },
    { id = "sui_action_browse_authors",   key = "simpleui_action_browse_authors_icon",
      sources = { { "sui_action_browse_authors", PRIO_SUI_CANONICAL }, { "author", PRIO_SUI_LEGACY } } },
    { id = "sui_action_browse_series",    key = "simpleui_action_browse_series_icon",
      sources = { { "sui_action_browse_series", PRIO_SUI_CANONICAL }, { "series", PRIO_SUI_LEGACY } } },
    { id = "sui_action_browse_tags",      key = "simpleui_action_browse_tags_icon",
      sources = { { "sui_action_browse_tags", PRIO_SUI_CANONICAL }, { "tags", PRIO_SUI_LEGACY } } },
}

local SIMPLEUI_SLOT_BY_ID = {}
local SIMPLEUI_MAPPINGS_BY_NAME = {}
local SIMPLEUI_SETTINGS_KEYS = {}
local SIMPLEUI_TAB_SLOTS = {}

for _, slot in ipairs(SIMPLEUI_SLOTS) do
    slot.canonical = slot.id .. ".svg"
    SIMPLEUI_SLOT_BY_ID[slot.id] = slot
    SIMPLEUI_SETTINGS_KEYS[slot.key] = true
    if slot.is_tab then
        SIMPLEUI_TAB_SLOTS[#SIMPLEUI_TAB_SLOTS + 1] = slot.id
    end
    for _, src in ipairs(slot.sources) do
        local name, priority, explicit_priority, from_mdlight = src[1], src[2], src[3], src[4]
        local list = SIMPLEUI_MAPPINGS_BY_NAME[name]
        if not list then
            list = {}
            SIMPLEUI_MAPPINGS_BY_NAME[name] = list
        end
        list[#list + 1] = {
            slot_id = slot.id,
            canonical = slot.canonical,
            key = slot.key,
            priority = priority,
            explicit_priority = explicit_priority or priority,
            from_mdlight = from_mdlight or false,
        }
    end
end

local function splitIconName(name)
    if type(name) ~= "string" then
        return nil
    end
    local stem, ext = name:match("^(.+)(%.[^./]+)$")
    if not stem or stem == "" or not ext then
        return nil
    end
    local ext_lower = ext:lower()
    if not SUPPORTED_EXTS[ext_lower] then
        return nil
    end
    return stem, ext_lower
end

local function sameDir(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then
        return false
    end
    return a:gsub("/+$", "") == b:gsub("/+$", "")
end

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
    { marker = "simpleui/", target = "simpleui", check_top = true },
    { marker = "mdlight/", target = "mdlight" },
}

local function mapArchivePath(path, allow_top_simpleui)
    local lower = path:lower()
    for _, item in ipairs(PATH_MARKERS) do
        local start_at = 1
        while true do
            local pos = lower:find(item.marker, start_at, true)
            if not pos then
                break
            end
            if (pos == 1 or lower:sub(pos - 1, pos - 1) == "/")
                    and (not item.check_top or pos > 1 or allow_top_simpleui ~= false) then
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

-- Collects icon names (relative to root) into `names`; missing roots are ignored.
local function listIcons(root, names, recursive)
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
                elseif mode == "file" and splitIconName(name) then
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
-- Modern Simple UI (with infra/sui_store.lua) stores icon overrides in sui_settings.lua
-- rather than reading simpleui.koplugin/icons/*.svg; older builds read icons/ directly.
local function findSimpleUI(data_dir, install_dir, plugin_dir)
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
        local has_store = fileMode(join(dir, "infra/sui_store.lua")) == "file"
        -- The "-previous" check keeps an interrupted legacy swap recoverable on next start.
        local has_icons = fileMode(icons) == "directory"
            or fileMode(icons .. ".iconpackmanager-previous") == "directory"
        if has_store or has_icons then
            return {
                root = dir,
                icons_dir = icons,
                mode = has_store and "settings" or "legacy",
            }
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
    local simpleui_info = findSimpleUI(data_dir, install_dir, plugin_dir)
    local simpleui_target = {
        official = join(official_root, "simpleui"),
    }
    if simpleui_info then
        simpleui_target.mode = simpleui_info.mode
        simpleui_target.plugin_icons = simpleui_info.icons_dir
        if simpleui_info.mode == "settings" then
            simpleui_target.live = join(state_root, "simpleui")
            simpleui_target.settings_file = join(settings_dir, "simpleui/sui_settings.lua")
        else
            simpleui_target.live = simpleui_info.icons_dir
        end
    end
    local object = {
        data_dir = data_dir,
        settings_dir = settings_dir,
        install_dir = install_dir,
        plugin_dir = plugin_dir,
        state_root = state_root,
        official_root = official_root,
        legacy_backup_root = join(state_root, "original"),
        managed_file = join(state_root, "managed_icons.txt"),
        managed_simpleui_file = join(state_root, "managed_simpleui.txt"),
        extraction_root = join(state_root, "extracted"),
        transaction_marker = join(state_root, ".transaction"),
        sui_store = options.sui_store,
        targets = {
            mdlight = {
                -- KOReader's IconWidget looks here before resources/icons/mdlight,
                -- so we never have to touch the (possibly read-only) program files.
                live = join(data_dir, "icons"),
                builtin = join(install_dir, "resources/icons/mdlight"),
                data_builtin = join(data_dir, "resources/icons/mdlight"),
                official = join(official_root, "mdlight"),
            },
            simpleui = simpleui_target,
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

local function buildInventoryFromNames(names)
    local canonical = {}
    local by_stem = {}
    -- Process .svg before .png so .svg stays the canonical display name when both exist.
    local ordered = sortedKeys(names)
    for _, pass_ext in ipairs({ ".svg", ".png" }) do
        for _, rel in ipairs(ordered) do
            local stem, ext = splitIconName(rel)
            if stem and ext == pass_ext and not by_stem[stem] then
                canonical[rel] = true
                by_stem[stem] = rel
            end
        end
    end
    return { canonical = canonical, by_stem = by_stem }
end

-- Icon names a pack may replace: the bundled official set plus whatever the
-- current installation ships (covers version drift in either direction).
function Engine:_inventory(target_key)
    local cached = self._inventories[target_key]
    if cached then
        return cached
    end
    local target = self.targets[target_key]
    local inv
    if target_key == "mdlight" then
        -- IconWidget resolves user icons by bare name, so only flat names count.
        local names = {}
        listIcons(target.official, names, false)
        listIcons(target.builtin, names, false)
        listIcons(target.data_builtin, names, false)
        inv = buildInventoryFromNames(names)
    elseif target.mode == "settings" then
        local canonical = {}
        local by_stem = {}
        for _, slot in ipairs(SIMPLEUI_SLOTS) do
            canonical[slot.canonical] = true
            by_stem[slot.id] = slot.canonical
        end
        inv = { canonical = canonical, by_stem = by_stem }
    else
        local names = {}
        listIcons(target.official, names, true)
        if target.live then
            listIcons(target.live, names, true)
        end
        inv = buildInventoryFromNames(names)
    end
    self._inventories[target_key] = inv
    return inv
end

function Engine:hasSimpleUI()
    return self.targets.simpleui.live ~= nil
end

function Engine:simpleUIMode()
    return self.targets.simpleui.mode
end

function Engine:simpleUIPath()
    return self.targets.simpleui.plugin_icons or self.targets.simpleui.live
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

function Engine:_finalizePlan(plan, resolved, duplicate_err)
    if duplicate_err then
        return nil, duplicate_err
    end
    plan.unknown = sortedKeys(plan.unknown)

    local covered = {}
    local managed = {}
    local simpleui_settings = {}
    local managed_simpleui = {}
    local seen_sources = {}
    local entries = {}
    local archive_sources = {}

    local sorted_dest_keys = sortedKeys(resolved)
    for _, destination_key in ipairs(sorted_dest_keys) do
        local item = resolved[destination_key]
        covered[item.target .. "/" .. item.canonical] = true
        plan[item.target] = plan[item.target] + 1
        plan.total = plan.total + 1

        local src_id = item.source or item.archive_path
        if src_id and not seen_sources[src_id] then
            seen_sources[src_id] = true
            plan.bytes = plan.bytes + (item.size or 0)
        end

        if item.target == "mdlight" then
            managed[#managed + 1] = item.relative
        elseif item.target == "simpleui" and item.settings_key then
            simpleui_settings[item.settings_key] = item.relative
            managed_simpleui[#managed_simpleui + 1] = item.settings_key
        end

        if item.source then
            entries[#entries + 1] = {
                source = item.source,
                target = item.target,
                relative = item.relative,
                size = item.size,
            }
        elseif item.archive_path then
            local rec = archive_sources[item.archive_path]
            if not rec then
                rec = { size = item.size, destinations = {} }
                archive_sources[item.archive_path] = rec
            end
            rec.destinations[#rec.destinations + 1] = {
                target = item.target,
                relative = item.relative,
                size = item.size,
            }
        end
    end

    if plan.total == 0 then
        return nil, "未找到可匹配当前安装的 SVG/PNG 图标"
    end
    if plan.bytes > MAX_TOTAL_SIZE then
        return nil, "图标包超过安全大小限制"
    end

    table.sort(managed)
    table.sort(managed_simpleui)
    plan.managed = managed
    plan.simpleui_settings = simpleui_settings
    plan.managed_simpleui = managed_simpleui
    if next(entries) then
        plan.entries = entries
    end
    if next(archive_sources) then
        plan.archive_sources = archive_sources
    end

    local is_complete = true
    for _, target_key in ipairs(self:_activeTargets()) do
        local canonical = self:_inventory(target_key).canonical
        local missing = {}
        for name in pairs(canonical) do
            plan.expected[target_key] = plan.expected[target_key] + 1
            if not covered[target_key .. "/" .. name] then
                missing[#missing + 1] = name
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

function Engine:_isSimpleUIName(stem)
    if self.targets.simpleui.mode == "settings" then
        return SIMPLEUI_MAPPINGS_BY_NAME[stem] ~= nil
    end
    return self:_inventory("simpleui").by_stem[stem] ~= nil
end

local function effectivePriority(base_priority, ext)
    return base_priority * 2 - (ext == ".svg" and 1 or 0)
end

function Engine:_appendSimpleUIMappings(mappings, stem, ext, size, from_explicit_simpleui, only_mdlight_fallback)
    local target = self.targets.simpleui
    if target.mode == "settings" then
        local defs = SIMPLEUI_MAPPINGS_BY_NAME[stem]
        if not defs then
            return
        end
        for _, def in ipairs(defs) do
            if not only_mdlight_fallback or def.from_mdlight then
                local base_priority = def.priority
                if from_explicit_simpleui and def.from_mdlight then
                    base_priority = def.explicit_priority
                end
                mappings[#mappings + 1] = {
                    target = "simpleui",
                    slot_key = def.slot_id,
                    canonical = def.canonical,
                    relative = def.slot_id .. ext,
                    size = size,
                    priority = effectivePriority(base_priority, ext),
                    settings_key = def.key,
                }
            end
        end
    else
        local canonical = self:_inventory("simpleui").by_stem[stem]
        if canonical then
            mappings[#mappings + 1] = {
                target = "simpleui",
                slot_key = canonical,
                canonical = canonical,
                relative = stem .. ext,
                size = size,
                priority = effectivePriority(1, ext),
            }
        end
    end
end

function Engine:_mapIconPath(path, size, allow_top_simpleui)
    local safe_path, path_err = safeArchivePath(path)
    if not safe_path then
        return nil, path_err
    end
    if not splitIconName(safe_path) then
        return false
    end
    if size < 0 or size > MAX_ICON_SIZE then
        return nil, "图标文件过大：" .. safe_path
    end

    local explicit_target, explicit_relative = mapArchivePath(safe_path, allow_top_simpleui)
    if explicit_target then
        if explicit_target == "simpleui" and not self:hasSimpleUI() then
            return false
        end
        local safe_relative, relative_err = safeArchivePath(explicit_relative)
        if not safe_relative then
            return nil, relative_err
        end
        local rel_stem, rel_ext = splitIconName(safe_relative)
        if not rel_stem then
            return false
        end
        local mappings = {}
        if explicit_target == "simpleui" then
            if self.targets.simpleui.mode == "settings" then
                if not rel_stem:find("/", 1, true) then
                    self:_appendSimpleUIMappings(mappings, rel_stem, rel_ext, size, true, false)
                end
            else
                self:_appendSimpleUIMappings(mappings, rel_stem, rel_ext, size, true, false)
            end
        else
            local canonical = self:_inventory("mdlight").by_stem[rel_stem]
            if not canonical then
                return false
            end
            mappings[#mappings + 1] = {
                target = "mdlight",
                slot_key = canonical,
                canonical = canonical,
                relative = rel_stem .. rel_ext,
                size = size,
                priority = effectivePriority(1, rel_ext),
            }
            if self.targets.simpleui.mode == "settings" then
                self:_appendSimpleUIMappings(mappings, rel_stem, rel_ext, size, false, true)
            end
        end
        if #mappings == 0 then
            return false
        end
        return mappings
    end

    local filename = basename(safe_path)
    local stem, ext = splitIconName(filename)
    if not stem then
        return false
    end
    local mappings = {}
    local md_canonical = self:_inventory("mdlight").by_stem[stem]
    if md_canonical then
        mappings[#mappings + 1] = {
            target = "mdlight",
            slot_key = md_canonical,
            canonical = md_canonical,
            relative = stem .. ext,
            size = size,
            priority = effectivePriority(1, ext),
        }
    end
    if self:hasSimpleUI() then
        self:_appendSimpleUIMappings(mappings, stem, ext, size, false, false)
    end
    if #mappings == 0 then
        return false
    end
    return mappings
end

local function readListFile(path, allow_slash)
    local values = {}
    local content = util.readFromFile and util.readFromFile(path, "rb")
    if content then
        for line in content:gmatch("[^\r\n]+") do
            local safe = safeArchivePath(line)
            if safe and (allow_slash or not safe:find("/", 1, true)) then
                values[safe] = true
            end
        end
    end
    return values
end

function Engine:_writeListFile(path, values)
    local names = sortedKeys(values)
    if #names == 0 then
        os.remove(path)
        return true
    end
    local ok, err = util.makePath(self.state_root)
    if not ok then
        return nil, err
    end
    ok, err = util.writeToFile(table.concat(names, "\n") .. "\n", path)
    if not ok then
        return nil, err or "无法写入图标记录"
    end
    return true
end

function Engine:_readManaged()
    return readListFile(self.managed_file, false)
end

function Engine:_writeManaged(managed)
    return self:_writeListFile(self.managed_file, managed)
end

function Engine:_readManagedSimpleUI()
    return readListFile(self.managed_simpleui_file, false)
end

function Engine:_writeManagedSimpleUI(managed)
    return self:_writeListFile(self.managed_simpleui_file, managed)
end

function Engine:_resolveLiveSuiStore()
    if self.sui_store == false then
        return nil
    end
    if self.sui_store then
        return self.sui_store
    end
    local loaded = package.loaded["infra/sui_store"]
    if type(loaded) ~= "table" then
        return nil
    end
    local ds = package.loaded["datastorage"]
    if ds and type(ds.getSettingsDir) == "function" then
        local ds_dir = ds:getSettingsDir()
        if ds_dir == "./settings" and self.data_dir:sub(1, 1) == "/" then
            ds_dir = join(self.data_dir, "settings")
        end
        if not sameDir(ds_dir, self.settings_dir) then
            return nil
        end
    end
    return loaded
end

function Engine:_syncSimpleUISettings(new_entries, reset_all_slots)
    local target = self.targets.simpleui
    if target.mode ~= "settings" or not target.settings_file then
        return true
    end

    local previous_managed = self:_readManagedSimpleUI()
    local next_values = {}
    for key, relative in pairs(new_entries or {}) do
        next_values[key] = join(target.live, relative)
    end

    local keys_to_clear = {}
    for key in pairs(previous_managed) do
        if next_values[key] == nil then
            keys_to_clear[key] = true
        end
    end
    if reset_all_slots then
        for key in pairs(SIMPLEUI_SETTINGS_KEYS) do
            if next_values[key] == nil then
                keys_to_clear[key] = true
            end
        end
    end

    local live_store = self:_resolveLiveSuiStore()
    if live_store and type(live_store.setNoFlush) == "function"
            and type(live_store.delNoFlush) == "function"
            and type(live_store.flush) == "function" then
        local ok_dir, dir_err = util.makePath(ffiUtil.dirname(target.settings_file))
        if not ok_dir then
            return nil, dir_err
        end
        for key in pairs(keys_to_clear) do
            live_store:delNoFlush(key)
        end
        for key, value in pairs(next_values) do
            live_store:setNoFlush(key, value)
        end
        live_store:flush()
    elseif next(keys_to_clear) ~= nil or next(next_values) ~= nil
            or fileMode(target.settings_file) == "file" then
        local ok_ls, LuaSettings = pcall(require, "luasettings")
        if not ok_ls or not LuaSettings then
            return nil, "无法加载 LuaSettings 模块"
        end
        local ok_dir, dir_err = util.makePath(ffiUtil.dirname(target.settings_file))
        if not ok_dir then
            return nil, dir_err
        end
        local store = LuaSettings:open(target.settings_file)
        for key in pairs(keys_to_clear) do
            store:delSetting(key)
        end
        for key, value in pairs(next_values) do
            store:saveSetting(key, value)
        end
        store:flush()
    end

    local new_managed = {}
    for key in pairs(next_values) do
        new_managed[key] = true
    end
    return self:_writeManagedSimpleUI(new_managed)
end

-- Best-effort cleanup of legacy v1.2 overrides inside simpleui.koplugin/icons/.
function Engine:_restorePluginIcons()
    local target = self.targets.simpleui
    if target.mode ~= "settings" or not target.plugin_icons
            or fileMode(target.official) ~= "directory"
            or fileMode(target.plugin_icons) ~= "directory" then
        return
    end
    local official_files = listIcons(target.official, {}, false)
    for name in pairs(official_files) do
        local src = join(target.official, name)
        local dst = join(target.plugin_icons, name)
        if fileMode(dst) == "file" then
            pcall(ffiUtil.copyFile, src, dst)
        end
    end
end

-- Number of icons in each bundled official set.
function Engine:officialStatus()
    local result = {}
    for _, key in ipairs(TARGET_KEYS) do
        local count = 0
        for _ in pairs(listIcons(self.targets[key].official, {}, true)) do
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

function Engine:_mapEntry(entry, allow_top_simpleui)
    local mappings, err = self:_mapIconPath(entry.path, tonumber(entry.size), allow_top_simpleui)
    if mappings then
        for _, mapped in ipairs(mappings) do
            mapped.archive_path = entry.path
        end
    end
    return mappings, err
end

local function isWrapperTopSimpleUI(items, is_sui_name)
    if #items == 0 then
        return true
    end
    local has_mdlight_only = false
    for _, item in ipairs(items) do
        local lower = item.path:lower()
        if lower:sub(1, 9) ~= "simpleui/" then
            return true
        end
        local rest = item.path:sub(10)
        local stem = splitIconName(rest)
        if stem and not stem:find("/", 1, true) and not is_sui_name(stem) then
            has_mdlight_only = true
        end
    end
    return not has_mdlight_only
end

function Engine:_buildPlan(items, dup_prefix, allow_top_simpleui)
    local plan = self:_newPlan()
    local resolved = {}
    local source_count = 0
    local raw_bytes = 0

    for _, item in ipairs(items) do
        local mappings, map_err = self:_mapIconPath(item.path, item.size, allow_top_simpleui)
        if mappings == nil then
            return nil, map_err
        elseif mappings then
            source_count = source_count + 1
            raw_bytes = raw_bytes + item.size
            if source_count > MAX_ICON_COUNT or raw_bytes > MAX_TOTAL_SIZE then
                return nil, "图标包超过安全大小限制"
            end
            for _, mapped in ipairs(mappings) do
                mapped.source = item.source
                mapped.archive_path = item.archive_path
                local dest_key = mapped.target .. "/" .. mapped.slot_key
                local existing = resolved[dest_key]
                if not existing or mapped.priority < existing.priority then
                    resolved[dest_key] = mapped
                elseif mapped.priority == existing.priority then
                    return nil, dup_prefix .. mapped.canonical
                end
            end
        else
            plan.unknown[item.path] = true
        end
    end

    return self:_finalizePlan(plan, resolved)
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
    local items = {}
    for entry in archive:iterate() do
        local safe_path, path_err = safeArchivePath(entry.path)
        if not safe_path then
            archive:close()
            return nil, path_err
        end
        if entry.mode == "file" and splitIconName(safe_path) then
            local size = tonumber(entry.size) or -1
            if size < 0 or size > MAX_ICON_SIZE then
                archive:close()
                return nil, "图标文件过大：" .. safe_path
            end
            items[#items + 1] = {
                path = safe_path,
                archive_path = entry.path,
                size = size,
            }
            if #items > MAX_ICON_COUNT * 4 then
                archive:close()
                return nil, "图标包超过安全大小限制"
            end
        end
    end
    local archive_err = archive.err
    archive:close()
    if archive_err then
        return nil, archive_err
    end

    local allow_top_simpleui = isWrapperTopSimpleUI(items, function(stem)
        return self:_isSimpleUIName(stem)
    end)
    return self:_buildPlan(items, "ZIP 内含重复图标：", allow_top_simpleui)
end

function Engine:inspectDirectory(pack_path)
    if fileMode(pack_path) ~= "directory" then
        return nil, "图标包文件夹不存在"
    end
    local items = {}

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
                elseif attr and attr.mode == "file" and splitIconName(name) then
                    items[#items + 1] = {
                        path = relative,
                        source = path,
                        size = attr.size or 0,
                    }
                    if #items > MAX_ICON_COUNT * 4 then
                        return nil, "图标包超过安全大小限制"
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
    return self:_buildPlan(items, "文件夹内含重复图标：", true)
end

local function hasDirectIcon(folder)
    local ok, iter, dir_obj = pcall(lfs.dir, folder)
    if not ok then
        return false
    end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." and splitIconName(name)
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

local function directoryContainsIcon(folder)
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
                elseif mode == "file" and splitIconName(name) then
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

    local current_is_pack = hasDirectIcon(folder) or hasStructuredChild(folder)
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
                    and not self:isReservedFolder(path) and directoryContainsIcon(path) then
                if hasDirectIcon(path) or hasStructuredChild(path) then
                    self:_addDirectoryPack(packs, name, path)
                else
                    local child_ok, child_iter, child_obj = pcall(lfs.dir, path)
                    if child_ok then
                        for child_name in child_iter, child_obj do
                            local child_path = join(path, child_name)
                            if child_name ~= "." and child_name ~= ".."
                                    and fileMode(child_path) == "directory"
                                    and directoryContainsIcon(child_path) then
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
    local archive_sources = expected_plan.archive_sources or {}
    local extracted = { mdlight = 0, simpleui = 0, total = 0 }
    for entry in archive:iterate() do
        if entry.mode == "file" then
            local source_info = archive_sources[entry.path]
            if source_info then
                if tonumber(entry.size) ~= source_info.size then
                    archive:close()
                    removeTree(self.extraction_root)
                    return nil, "ZIP 在校验后发生变化，请重新扫描"
                end
                local first_destination
                for index, mapped in ipairs(source_info.destinations) do
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
--   simpleui: settings mode uses clean <state>/simpleui stage; legacy mode overlays official icons
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
            if self.targets.simpleui.mode == "settings" then
                for _, slot_id in ipairs(SIMPLEUI_TAB_SLOTS) do
                    for ext in pairs(SUPPORTED_EXTS) do
                        local tab_file = join(target.next, "simpleui_" .. slot_id .. ext)
                        if fileMode(tab_file) == "file" then
                            os.remove(tab_file)
                        end
                    end
                end
            end
        elseif key == "simpleui" then
            if target.mode == "settings" then
                ok, err = util.makePath(target.next)
            else
                if fileMode(target.live) == "directory" then
                    ok, err = copyTree(target.live, target.next)
                else
                    ok, err = util.makePath(target.next)
                end
                if ok and fileMode(target.official) == "directory" then
                    ok, err = copyTree(target.official, target.next)
                end
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
    -- Also recover any interrupted swap of simpleui.koplugin/icons left by v1.2.
    local plugin_icons = self.targets.simpleui.plugin_icons
    if plugin_icons and plugin_icons ~= self.targets.simpleui.live then
        local prev = plugin_icons .. ".iconpackmanager-previous"
        local next_dir = plugin_icons .. ".iconpackmanager-next"
        if fileMode(plugin_icons) ~= "directory" and fileMode(prev) == "directory" then
            os.rename(prev, plugin_icons)
        elseif fileMode(prev) == "directory" then
            removeTree(prev)
        end
        removeTree(next_dir)
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
    -- Leave no empty override / managed dir behind once everything is back to official.
    for _, key in ipairs(self:_activeTargets()) do
        local dir = self.targets[key].live
        if (key == "mdlight" or self.targets[key].mode == "settings")
                and fileMode(dir) == "directory" and isEmptyDir(dir) then
            os.remove(dir)
        end
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
    local sui_ok, sui_err = self:_syncSimpleUISettings(plan.simpleui_settings, true)
    if not sui_ok then
        return nil, "同步 Simple UI 图标配置失败：" .. tostring(sui_err)
    end
    self:_restorePluginIcons()
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

-- Back to the official look: drop our overrides from <data>/icons and restore
-- Simple UI to its official defaults (via sui_settings.lua or plugin icons dir).
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
    local sui_ok, sui_err = self:_syncSimpleUISettings({}, true)
    if not sui_ok then
        return nil, "恢复 Simple UI 默认配置失败：" .. tostring(sui_err)
    end
    self:_restorePluginIcons()
    logger.info("iconpackmanager: restored official icons")
    local legacy_ok, legacy_err = self:_restoreLegacyBuiltin()
    if not legacy_ok then
        return true, "旧版插件改动过的程序图标未能还原：" .. tostring(legacy_err)
    end
    return true
end

return Engine
