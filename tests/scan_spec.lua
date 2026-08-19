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
package.preload["logger"] = function() return {} end
package.preload["util"] = function() return {} end

local Engine = assert(loadfile("../iconpack_engine.lua"))()

-- Test 1: With Simple UI installed
local engine = Engine:new{ data_dir = "/ko", settings_dir = "/ko/settings" }
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
local engine_nosui = Engine:new{ data_dir = "/ko_nosui", settings_dir = "/ko_nosui/settings" }
assert(engine_nosui:hasSimpleUI() == false, "Simple UI not detected")

local plan_nosui = assert(engine_nosui:inspectDirectory("/packs/theme"))
assert(plan_nosui.mdlight == 2, "flat mdlight matches")
assert(plan_nosui.simpleui == 0, "no Simple UI target active")
assert(plan_nosui.expected.mdlight == 3 and #plan_nosui.missing.mdlight == 1)
assert(plan_nosui.expected.simpleui == 0 and #plan_nosui.missing.simpleui == 0)
assert(#plan_nosui.entries == 2, "only mdlight targets mapped")

print("scan_spec: OK")
