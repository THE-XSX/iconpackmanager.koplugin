-- SPDX-FileCopyrightText: Copyright (C) 2026 THE-XSX
-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- Icon Pack Manager (图标包管理器) - KOReader plugin
-- Released under the GNU Affero General Public License v3.0 or later.
-- See the LICENSE file in the project root for the full license text.

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Engine = require("iconpack_engine")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local PathChooser = require("ui/widget/pathchooser")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = ffiUtil.template

local IconPackManager = WidgetContainer:extend{
    name = "iconpackmanager",
    is_doc_only = false,
    settings_file = DataStorage:getSettingsDir() .. "/iconpackmanager.lua",
}

local function basename(path)
    return path and path:match("([^/]+)/*$") or nil
end

local function getPluginDir(data_dir)
    local src = debug.getinfo(1, "S").source
    local dir = src and src:match("@?(.*iconpackmanager%.koplugin)")
    if dir and dir ~= "" then
        return dir
    end
    local candidate = data_dir .. "/plugins/iconpackmanager.koplugin"
    if lfs.attributes(candidate, "mode") == "directory" then
        return candidate
    end
    return "plugins/iconpackmanager.koplugin"
end

function IconPackManager:init()
    local data_dir = DataStorage:getFullDataDir() or DataStorage:getDataDir()
    local settings_dir = DataStorage:getSettingsDir()
    if settings_dir == "./settings" and data_dir:sub(1, 1) == "/" then
        settings_dir = data_dir .. "/settings"
    end
    local plugin_dir = getPluginDir(data_dir)
    self.settings = LuaSettings:open(self.settings_file)
    self.engine = Engine:new{
        data_dir = data_dir,
        settings_dir = settings_dir,
        plugin_dir = plugin_dir,
    }
    local ok, message = self.engine:recoverTransaction()
    if not ok then
        logger.err("iconpackmanager:", message)
        UIManager:scheduleIn(1, function() self:showMessage(message) end)
    elseif message then
        logger.warn("iconpackmanager:", message)
        UIManager:scheduleIn(1, function() self:showMessage(message) end)
    end
    self.ui.menu:registerToMainMenu(self)
end

function IconPackManager:showMessage(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout,
    })
end

function IconPackManager:selectedFolder()
    local folder = self.settings:readSetting("pack_folder")
    if folder and lfs.attributes(folder, "mode") == "directory" and not self.engine:isReservedFolder(folder) then
        return folder
    end
    local data_dir = DataStorage:getFullDataDir() or DataStorage:getDataDir()
    local candidate = data_dir .. "/iconpacks"
    if lfs.attributes(candidate, "mode") == "directory" then
        return candidate
    end
    return data_dir
end

function IconPackManager:chooseFolder(touchmenu_instance)
    UIManager:show(PathChooser:new{
        title = _("长按文件夹名称以选择图标包目录"),
        path = self:selectedFolder(),
        select_directory = true,
        select_file = false,
        show_files = false,
        onConfirm = function(path)
            if self.engine:isReservedFolder(path) then
                self:showMessage(_("不能选择 KOReader 的图标覆盖目录作为图标包文件夹，请新建一个专门的目录（如 iconpacks）"), 5)
                return
            end
            self.settings:saveSetting("pack_folder", path)
            self.settings:flush()
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
            local packs, err = self.engine:scanFolder(path)
            if not packs then
                self:showMessage(err)
            else
                self:showMessage(T(_("扫描完成：找到 %1 个图标包"), #packs), 3)
            end
        end,
    })
end

function IconPackManager:applyPack(pack)
    local has_simpleui = self.engine:hasSimpleUI()
    UIManager:show(ConfirmBox:new{
        text = T(_("应用图标包“%1”？\n\n缺少的图标会自动使用官方默认图标。更换失败时自动回滚。"), pack.name),
        ok_text = _("一键更换"),
        ok_callback = function()
            local result, err = self.engine:applyPack(pack)
            if not result then
                self:showMessage(_("更换失败：") .. tostring(err))
                return
            end
            self.settings:saveSetting("active_pack", pack.name)
            self.settings:flush()
            local msg
            if has_simpleui and result.simpleui and result.simpleui > 0 then
                msg = T(_("图标包“%1”已应用（KOReader %2 个，Simple UI %3 个）。重启后生效。"),
                    pack.name, result.mdlight, result.simpleui)
            else
                msg = T(_("图标包“%1”已应用（KOReader %2 个）。重启后生效。"),
                    pack.name, result.mdlight)
            end
            UIManager:askForRestart(msg)
        end,
    })
end

local function reportList(items)
    if not items or #items == 0 then
        return _("无")
    end
    return table.concat(items, "\n")
end

function IconPackManager:showPackReport(pack)
    if not pack.plan then
        self:showMessage(_("图标包无效：") .. tostring(pack.error))
        return
    end
    local plan = pack.plan
    local source_type = pack.kind == "folder" and _("文件夹") or _("ZIP")
    local has_simpleui = self.engine:hasSimpleUI()
    local lines = {
        T(_("类型：%1"), source_type),
        T(_("KOReader：覆盖 %1 / %2，缺少 %3"),
            plan.mdlight, plan.expected.mdlight, #plan.missing.mdlight),
    }
    if has_simpleui then
        lines[#lines + 1] = T(_("Simple UI：覆盖 %1 / %2，缺少 %3"),
            plan.simpleui, plan.expected.simpleui, #plan.missing.simpleui)
    else
        lines[#lines + 1] = _("Simple UI：未安装（已跳过）")
    end
    lines[#lines + 1] = T(_("未匹配图标：%1"), #plan.unknown)
    lines[#lines + 1] = ""
    lines[#lines + 1] = _("KOReader 缺少的图标：")
    lines[#lines + 1] = reportList(plan.missing.mdlight)
    if has_simpleui then
        lines[#lines + 1] = ""
        lines[#lines + 1] = _("Simple UI 缺少的图标：")
        lines[#lines + 1] = reportList(plan.missing.simpleui)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = _("未匹配、不会安装的图标：")
    lines[#lines + 1] = reportList(plan.unknown)

    local text = table.concat(lines, "\n")
    UIManager:show(TextViewer:new{
        title = T(_("图标检测：%1"), pack.name),
        title_multilines = true,
        text = text,
        text_type = "file_content",
    })
end

function IconPackManager:restoreOriginal()
    local has_simpleui = self.engine:hasSimpleUI()
    local text = has_simpleui
        and _("恢复官方默认的 KOReader 与 Simple UI 图标？")
        or _("恢复官方默认的 KOReader 图标？")
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("恢复默认"),
        ok_callback = function()
            local ok, err = self.engine:restoreOriginal()
            if not ok then
                self:showMessage(_("恢复失败：") .. tostring(err))
                return
            end
            self.settings:saveSetting("active_pack", nil)
            self.settings:flush()
            local msg = _("官方默认图标已恢复。重启后生效。")
            if type(err) == "string" then
                msg = msg .. "\n" .. err
            end
            UIManager:askForRestart(msg)
        end,
    })
end

function IconPackManager:packMenuItems()
    local packs, err = self.engine:scanFolder(self:selectedFolder())
    if not packs then
        return {{ text = err, enabled = false }}
    end
    if #packs == 0 then
        return {{ text = _("此文件夹中没有图标包文件夹或 ZIP"), enabled = false }}
    end
    local has_simpleui = self.engine:hasSimpleUI()
    local items = {}
    for idx, pack in ipairs(packs) do
        local pack_entry = pack
        if pack_entry.plan then
            local text
            if has_simpleui then
                text = T(_("%1（KO %2/%3，SUI %4/%5）"),
                    pack_entry.name,
                    pack_entry.plan.mdlight, pack_entry.plan.expected.mdlight,
                    pack_entry.plan.simpleui, pack_entry.plan.expected.simpleui)
            else
                text = T(_("%1（KO %2/%3）"),
                    pack_entry.name,
                    pack_entry.plan.mdlight, pack_entry.plan.expected.mdlight)
            end
            items[#items + 1] = {
                text = text,
                callback = function() self:applyPack(pack_entry) end,
            }
        else
            items[#items + 1] = {
                text = pack_entry.name .. _("（无效）"),
                keep_menu_open = true,
                callback = function()
                    self:showMessage(_("图标包无效：") .. tostring(pack_entry.error))
                end,
            }
        end
    end
    return items
end

function IconPackManager:detectionMenuItems()
    local packs, err = self.engine:scanFolder(self:selectedFolder())
    if not packs then
        return {{ text = err, enabled = false }}
    end
    if #packs == 0 then
        return {{ text = _("此文件夹中没有图标包文件夹或 ZIP"), enabled = false }}
    end
    local has_simpleui = self.engine:hasSimpleUI()
    local items = {}
    for idx, pack in ipairs(packs) do
        local pack_entry = pack
        if pack_entry.plan then
            local plan = pack_entry.plan
            local text
            if has_simpleui then
                text = T(_("%1（KO 缺 %2，SUI 缺 %3，未知 %4）"),
                    pack_entry.name,
                    #plan.missing.mdlight,
                    #plan.missing.simpleui,
                    #plan.unknown)
            else
                text = T(_("%1（KO 缺 %2，未知 %3）"),
                    pack_entry.name,
                    #plan.missing.mdlight,
                    #plan.unknown)
            end
            items[#items + 1] = {
                text = text,
                callback = function() self:showPackReport(pack_entry) end,
            }
        else
            items[#items + 1] = {
                text = pack_entry.name .. _("（无效）"),
                callback = function() self:showPackReport(pack_entry) end,
            }
        end
    end
    return items
end

function IconPackManager:statusText()
    local active = self.settings:readSetting("active_pack")
    if active then
        return T(_("状态：正在使用 %1"), active)
    end
    return _("状态：官方默认图标")
end

function IconPackManager:addToMainMenu(menu_items)
    menu_items.iconpackmanager = {
        text = _("图标包管理器"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function() return self:statusText() end,
                enabled = false,
            },
            {
                text_func = function()
                    return T(_("图标包文件夹：%1"), basename(self:selectedFolder()) or self:selectedFolder())
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:chooseFolder(touchmenu_instance)
                end,
                separator = true,
            },
            {
                text = _("扫描到的图标包"),
                sub_item_table_func = function() return self:packMenuItems() end,
            },
            {
                text = _("图标完整性检测"),
                sub_item_table_func = function() return self:detectionMenuItems() end,
                separator = true,
            },
            {
                text = _("恢复官方默认图标"),
                callback = function() self:restoreOriginal() end,
            },
        },
    }
end

return IconPackManager
