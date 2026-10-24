-- SPDX-FileCopyrightText: Copyright (C) 2026 THE-XSX
-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- Icon Pack Manager (图标包管理器) - KOReader plugin
-- Released under the GNU Affero General Public License v3.0 or later.
-- See the LICENSE file in the project root for the full license text.

local files = {}
local directories = { [""] = {} }

local function normalize(path)
    path = path:gsub("\\", "/"):gsub("/+", "/")
    if #path > 1 then path = path:gsub("/$", "") end
    return path
end

local function addChild(parent, name)
    directories[parent] = directories[parent] or {}
    directories[parent][name] = true
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

local function addFile(path, size)
    path = normalize(path)
    local parent, name = path:match("^(.*)/([^/]+)$")
    if parent == "" then parent = "/" end
    addDirectory(parent)
    addChild(parent, name)
    files[path] = size or 10
end

for _, path in ipairs({
    "/ko/resources/icons/mdlight/a.svg",
    "/ko/resources/icons/mdlight/b.svg",
    "/ko/resources/icons/mdlight/shared.svg",
    "/ko/plugins/simpleui.koplugin/icons/s.svg",
    "/ko/plugins/simpleui.koplugin/icons/shared.svg",
    "/ko_nosui/resources/icons/mdlight/a.svg",
    "/ko_nosui/resources/icons/mdlight/b.svg",
    "/ko_nosui/resources/icons/mdlight/shared.svg",
    -- Android simulation: install_dir has builtin resources, data_dir (/sdcard/koreader) has user plugins
    "/android_app/resources/icons/mdlight/a.svg",
    "/android_app/resources/icons/mdlight/b.svg",
    "/android_app/resources/icons/mdlight/shared.svg",
    "/sdcard/koreader/plugins/simpleui.koplugin/icons/s.svg",
    "/sdcard/koreader/plugins/simpleui.koplugin/icons/shared.svg",
    -- Bundled official icons in plugin dir
    "/plugin/official/mdlight/a.svg",
    "/plugin/official/mdlight/b.svg",
    "/plugin/official/mdlight/shared.svg",
    "/plugin/official/simpleui/s.svg",
    "/plugin/official/simpleui/shared.svg",
    -- Test packs
    "/packs/theme/a.svg",
    "/packs/theme/shared.svg",
    "/packs/theme/unknown.svg",
    "/packs/theme/plugins/s.svg",
    "/packs/variants/bw/a.svg",
    "/packs/variants/coloured/b.svg",
}) do
    addFile(path)
end

package.preload["ffi/archiver"] = function() return {} end
package.preload["ffi/util"] = function()
    return {
        dirname = function(path) return path:match("^(.*)/[^/]+$") end,
        copyFile = function(src, dst)
            addFile(dst, files[src] or 10)
            return nil
        end,
        purgeDir = function(dir)
            directories[dir] = nil
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
            addFile(path, #content)
            return true
        end,
        readFromFile = function(path)
            return files[path] and "content" or nil
        end,
    }
end

local script_dir = debug.getinfo(1, "S").source:match("@?(.*)[/\\]")
local engine_path = (script_dir and (script_dir .. "/../iconpack_engine.lua")) or "iconpack_engine.lua"
local Engine = assert((loadfile(engine_path) or loadfile("../iconpack_engine.lua") or loadfile("iconpack_engine.lua"))())

-- Test 1: With Simple UI installed (Desktop/Linux/Kindle style)
local engine = Engine:new{ data_dir = "/ko", settings_dir = "/ko/settings", plugin_dir = "/plugin" }
assert(engine:hasSimpleUI() == true, "Simple UI detected")

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

-- Test 3: Android simulation (data_dir=/sdcard/koreader, install_dir=/android_app)
local engine_android = Engine:new{
    data_dir = "/sdcard/koreader",
    settings_dir = "/sdcard/koreader/settings",
    install_dir = "/android_app",
    plugin_dir = "/plugin",
}
assert(engine_android:hasSimpleUI() == true, "Android Simple UI in user storage detected")
assert(engine_android:userIconsPath() == "/sdcard/koreader/icons", "Android writes to user icons override dir")
assert(engine_android:isReservedFolder("/sdcard/koreader/icons") == true, "user icons dir is reserved")
assert(engine_android:isReservedFolder("/sdcard/koreader/icons/sub") == true, "user icons sub-dir is reserved")
assert(engine_android:isReservedFolder("/sdcard/koreader/iconpacks") == false, "iconpacks folder is not reserved")

local plan_android = assert(engine_android:inspectDirectory("/packs/theme"))
assert(plan_android.mdlight == 2, "Android mdlight matches")
assert(plan_android.simpleui == 2, "Android Simple UI matches")

local status = engine_android:officialStatus()
assert(status.mdlight == 3, "Official mdlight has 3 icons")
assert(status.simpleui == 2, "Official Simple UI has 2 icons")

print("scan_spec: OK")
