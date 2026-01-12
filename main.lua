local BD = require("ui/bidi")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template

local GDrive = require("lib.gdrive")

local GoogleDriveDownloader = WidgetContainer:extend{
    name = "gdrivedownloader",
    is_doc_only = false,
}

local CONF_KEY_API_KEY = "gdrive_api_key"
local CONF_KEY_DOWNLOAD_DIR = "gdrive_download_dir"

function GoogleDriveDownloader:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/gdrive.lua")
    self.gdrive = nil
    self.download_dir = self:getDownloadDir()
    
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    
    self:initGoogleDrive()
end

function GoogleDriveDownloader:initGoogleDrive()
    local api_key = self.settings:readSetting(CONF_KEY_API_KEY)
    
    if api_key and api_key ~= "" then
        self.gdrive = GDrive.new({
            api_key = api_key,
        })
        
        if self.gdrive:init() then
            logger.info("Google Drive initialized with API key")
            return true
        end
    end
    return false
end

function GoogleDriveDownloader:onDispatcherRegisterActions()
    Dispatcher:registerAction("gdrive_browse", {
        category = "none",
        event = "GDriveBrowse",
        title = _("Google Drive"),
        general = true,
    })
    Dispatcher:registerAction("gdrive_upload", {
        category = "none",
        event = "GDriveUpload",
        title = _("Upload to Google Drive"),
        general = true,
    })
end

function GoogleDriveDownloader:addToMainMenu(menu_items)
    local is_configured = self:isConfigured()
    
    if is_configured then
        menu_items.gdrive = {
            text = _("Google Drive"),
            sub_item_table = {
                {
                    text = _("Browse Google Drive"),
                    callback = function()
                        self:browseGoogleDrive()
                    end,
                },
                {
                    text = _("Upload current book"),
                    callback = function()
                        self:uploadCurrentBook()
                    end,
                },
                {
                    text = _("Download folder"),
                    keep_menu_open = true,
                    callback = function()
                        self:showDownloadFolderDialog()
                    end,
                },
                {
                    text = _("API Key"),
                    keep_menu_open = true,
                    sub_item_table = {
                        {
                            text = _("Change API Key"),
                            callback = function()
                                self:showApiKeyDialog()
                            end,
                        },
                        {
                            text = _("Clear API Key"),
                            callback = function()
                                self:clearApiKey()
                            end,
                        },
                    },
                },
                {
                    text = _("Download directory"),
                    keep_menu_open = true,
                    callback = function()
                        self:showDownloadDirDialog()
                    end,
                },
            },
        }
    else
        menu_items.gdrive = {
            text = _("Google Drive"),
            sub_item_table = {
                {
                    text = _("Setup API Key"),
                    callback = function()
                        self:showApiKeyDialog()
                    end,
                },
            },
        }
    end
end

function GoogleDriveDownloader:isConfigured()
    local api_key = self.settings:readSetting(CONF_KEY_API_KEY)
    return api_key and api_key ~= ""
end

function GoogleDriveDownloader:showApiKeyDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Google Drive API Key"),
        fields = {
            {
                text = self.settings:readSetting(CONF_KEY_API_KEY) or "",
                input_type = "string",
                hint = _("Enter your Google Drive API Key"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local fields = dialog:getFields()
                        if fields[1] and fields[1] ~= "" then
                            self.settings:saveSetting(CONF_KEY_API_KEY, fields[1])
                            self.settings:flush()
                            
                            self.gdrive = GDrive.new({
                                api_key = fields[1],
                            })
                            self.gdrive:init()
                            
                            UIManager:close(dialog)
                            
                            UIManager:show(InfoMessage:new{
                                text = _("API Key saved! You can now browse Google Drive."),
                            })
                            
                            if self.ui.menu then
                                self.ui.menu:updateMenu()
                            end
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function GoogleDriveDownloader:clearApiKey()
    self.settings:delSetting(CONF_KEY_API_KEY)
    self.settings:flush()
    self.gdrive = nil
    
    UIManager:show(InfoMessage:new{
        text = _("API Key cleared."),
    })
    
    if self.ui.menu then
        self.ui.menu:updateMenu()
    end
end

function GoogleDriveDownloader:browseGoogleDrive()
    if not self.gdrive or not self.gdrive:isAuthenticated() then
        UIManager:show(InfoMessage:new{
            text = _("Please set API Key first."),
        })
        return
    end
    
    self:listRootFolder()
end

function GoogleDriveDownloader:listRootFolder()
    local result, err = self.gdrive:searchFiles("'root' in parents and trashed=false")
    
    if result and result.files then
        self:showFileList(result.files, _("Google Drive - Root"))
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to list files: %1"), tostring(err)),
        })
    end
end

function GoogleDriveDownloader:showFileList(files, title)
    local file_items = {}
    
    for _, file in ipairs(files) do
        local is_folder = file.mimeType == "application/vnd.google-apps.folder"
        local file_type = is_folder and _("Folder") or file.mimeType
        local modified = file.modifiedTime or ""
        
        table.insert(file_items, {
            text = file.name,
            path = file.id,
            file = file,
            is_folder = is_folder,
            details = T("%1 - %2", file_type, modified),
        })
    end
    
    table.sort(file_items, function(a, b)
        if a.is_folder ~= b.is_folder then
            return a.is_folder
        end
        return a.text < b.text
    end)
    
    if #file_items == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No files found."),
        })
        return
    end
    
    local menu_table = {}
    for i, item in ipairs(file_items) do
        table.insert(menu_table, {
            text = item.text,
            details = item.details,
            enabled = true,
            callback = function()
                if item.is_folder then
                    self:browseFolder(item.path, item.text)
                else
                    self:downloadFile(item.file)
                end
            end,
        })
    end
    
    local Menu = require("ui/widget/menu")
    local menu = Menu:new{
        title = title,
        item_table = menu_table,
        on_close = function()
            UIManager:close(menu)
        end,
    }
    UIManager:show(menu)
end

function GoogleDriveDownloader:browseFolder(folder_id, folder_name)
    local result, err = self.gdrive:searchFiles("'" .. folder_id .. "' in parents and trashed=false")
    
    if result and result.files then
        self:showFileList(result.files, T(_("Google Drive - %1"), folder_name))
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to list files: %1"), tostring(err)),
        })
    end
end

function GoogleDriveDownloader:downloadFile(file)
    local download_path = self:getDownloadDir()
    
    if not download_path or download_path == "" then
        UIManager:show(InfoMessage:new{
            text = _("Please set download folder first."),
        })
        return
    end
    
    local file_path = download_path .. "/" .. file.name
    
    UIManager:show(InfoMessage:new{
        text = T(_("Downloading %1..."), file.name),
    })
    
    local ok, err = self.gdrive:downloadFile(file.id, file_path)
    
    if ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Downloaded: %1"), file.name),
        })
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Download failed: %1"), tostring(err)),
        })
    end
end

function GoogleDriveDownloader:uploadCurrentBook()
    local current_book = self.ui.file_chooser and self.ui.file_chooser.path
    if not current_book then
        UIManager:show(InfoMessage:new{
            text = _("No book selected."),
        })
        return
    end
    
    self:uploadFile(current_book)
end

function GoogleDriveDownloader:uploadFile(file_path)
    if not self.gdrive or not self.gdrive:isAuthenticated() then
        UIManager:show(InfoMessage:new{
            text = _("Please set API Key first."),
        })
        return
    end
    
    if not io.open(file_path, "rb") then
        UIManager:show(InfoMessage:new{
            text = T(_("Cannot read file: %1"), file_path),
        })
        return
    end
    
    local file_name = file_path:match("/([^/]+)$") or file_name
    local mime_type = self:getMimeType(file_path)
    
    UIManager:show(InfoMessage:new{
        text = T(_("Uploading %1..."), file_name),
    })
    
    local result, err = self.gdrive:uploadFile(file_path, file_name, mime_type)
    
    if result then
        UIManager:show(InfoMessage:new{
            text = T(_("Uploaded successfully: %1"), file_name),
        })
        logger.info("Uploaded to Google Drive:", result.id)
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Upload failed: %1"), tostring(err)),
        })
    end
end

function GoogleDriveDownloader:showDownloadFolderDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Download from Google Drive"),
        fields = {
            {
                text = self:getDownloadDir() or "",
                input_type = "string",
                hint = _("Download folder path"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Download"),
                    callback = function()
                        local fields = dialog:getFields()
                        if fields[1] and fields[1] ~= "" then
                            self:setDownloadDir(fields[1])
                            self:syncFromGoogleDrive()
                            UIManager:close(dialog)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function GoogleDriveDownloader:syncFromGoogleDrive()
    local download_path = self:getDownloadDir()
    
    if not download_path or download_path == "" then
        UIManager:show(InfoMessage:new{
            text = _("Please set download folder first."),
        })
        return
    end
    
    if not lfs.attributes(download_path, "mode") then
        lfs.mkdir(download_path)
    end
    
    local result, err = self.gdrive:searchFiles("trashed=false")
    
    if not result or not result.files then
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to list files: %1"), tostring(err)),
        })
        return
    end
    
    local downloaded_count = 0
    local failed_count = 0
    
    for _, file in ipairs(result.files) do
        if not (file.mimeType == "application/vnd.google-apps.folder") then
            local file_path = download_path .. "/" .. file.name
            
            local ok, err = self.gdrive:downloadFile(file.id, file_path)
            
            if ok then
                downloaded_count = downloaded_count + 1
            else
                failed_count = failed_count + 1
                logger.error("Download failed:", file.name, err)
            end
        end
    end
    
    UIManager:show(InfoMessage:new{
        text = T(_("Downloaded %1 files, failed %2"), downloaded_count, failed_count),
    })
end

function GoogleDriveDownloader:showDownloadDirDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Set Download Directory"),
        fields = {
            {
                text = self:getDownloadDir() or "",
                input_type = "string",
                hint = _("Full path to download folder"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local fields = dialog:getFields()
                        if fields[1] then
                            self:setDownloadDir(fields[1])
                            UIManager:close(dialog)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function GoogleDriveDownloader:getDownloadDir()
    return self.settings:readSetting(CONF_KEY_DOWNLOAD_DIR)
end

function GoogleDriveDownloader:setDownloadDir(path)
    self.download_dir = path
    self.settings:saveSetting(CONF_KEY_DOWNLOAD_DIR, path)
    self.settings:flush()
end

function GoogleDriveDownloader:getMimeType(file_path)
    local ext = file_path:lower():match("%.(%w+)$")
    local mime_types = {
        epub = "application/epub+zip",
        pdf = "application/pdf",
        fb2 = "application/x-fictionbook",
        mobi = "application/x-mobipocket-ebook",
        azw3 = "application/x-mobipocket-ebook",
        txt = "text/plain",
        html = "text/html",
        djvu = "image/vnd.djvu",
        cbr = "application/x-cbz",
        cbz = "application/x-cbz",
        cbt = "application/x-cbt",
        cb7 = "application/x-cb7",
    }
    return mime_types[ext] or "application/octet-stream"
end

function GoogleDriveDownloader:onGDriveBrowse()
    self:browseGoogleDrive()
end

function GoogleDriveDownloader:onGDriveUpload()
    self:uploadCurrentBook()
end

return GoogleDriveDownloader
