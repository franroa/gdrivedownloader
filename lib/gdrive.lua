local GDUTILS = require("lib.gdutils")

local M = {}
M.__index = M

local baseConfig = {
    api_key = nil,
    endpoint = "https://www.googleapis.com/drive/v3/",
    endpoint_upload = "https://www.googleapis.com/upload/drive/v3/",
}

function M.new(work_config)
    local self = setmetatable({}, M)
    self.gdUtils = GDUTILS.new()
    
    self.config = {}
    self.gdUtils.copyTable(baseConfig, self.config)
    
    if work_config then
        self.gdUtils.copyTable(work_config, self.config)
    end
    
    return self
end

function M:init()
    return self.config.api_key ~= nil
end

function M:buildUrl(params, endpoint)
    endpoint = endpoint or (self.config.endpoint .. "files")
    local result = url.parse(endpoint)
    result.query = result.query or {}
    result.query.key = self.config.api_key
    result.query.alt = "json"
    self.gdUtils.copyTable(params, result.query)
    return result.build(result)
end

function M:request(request_url, payload, headers, method, options)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    
    local request_headers = headers or {}
    request_headers["Accept"] = "application/json"
    
    local body_data = nil
    if payload then
        if type(payload) == "string" then
            body_data = ltn12.source.string(payload)
        else
            body_data = payload
        end
    end
    
    local response_table = {}
    local _, code_or_error = http.request{
        url = request_url,
        method = method or "GET",
        headers = request_headers,
        source = body_data,
        sink = ltn12.sink.table(response_table),
    }
    
    local content = table.concat(response_table)
    
    if type(code_or_error) == "number" then
        if code_or_error == 200 then
            return content, code_or_error
        else
            return nil, self.gdUtils.formatHttpCodeError(code_or_error)
        end
    else
        return nil, code_or_error
    end
end

function M:listFiles(params)
    local url_str = self:buildUrl(params)
    local content, code = self:request(url_str)
    if content then
        return self.gdUtils.parseJSON(content), code
    end
    return nil, code
end

function M:getFileMetadata(file_id)
    local url_str = self:buildUrl({}, self.config.endpoint .. "files/" .. file_id)
    local content, code = self:request(url_str)
    if content then
        return self.gdUtils.parseJSON(content), code
    end
    return nil, code
end

function M:downloadFile(file_id, write_path)
    local metadata, code = self:getFileMetadata(file_id)
    if not metadata then
        return nil, code
    end
    
    if not metadata.webContentLink and not metadata.downloadUrl then
        return nil, "No download link available"
    end
    
    local download_url = metadata.downloadUrl or metadata.webContentLink
    
    -- Append API key to download URL
    if download_url then
        local separator = download_url:find("?") and "&" or "?"
        download_url = download_url .. separator .. "key=" .. self.config.api_key
    end
    
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    
    local response_table = {}
    local _, code_or_error = http.request{
        url = download_url,
        method = "GET",
        sink = ltn12.sink.table(response_table),
    }
    
    if type(code_or_error) == "number" and code_or_error == 200 then
        local content = table.concat(response_table)
        if write_path then
            local f = io.open(write_path, "wb")
            if f then
                f:write(content)
                f:close()
                return write_path, code_or_error
            else
                return nil, "Cannot write file: " .. write_path
            end
        end
        return content, code_or_error
    else
        return nil, code_or_error
    end
end

function M:uploadFile(file_path, file_name, mime_type)
    local file = {
        name = file_name,
        mimeType = mime_type,
    }
    
    local source
    if file_path then
        local f = io.open(file_path, "rb")
        if f then
            source = f:read("*a")
            f:close()
        else
            return nil, "Cannot read file: " .. file_path
        end
    end
    
    local url_str = self:buildUrl({uploadType = "multipart"}, self.config.endpoint_upload .. "files")
    
    local multipart_data = {
        {data = self.gdUtils.encodeJSON(file), type = "application/json"},
        {data = source, type = mime_type},
    }
    
    local content, content_type = self.gdUtils.buildMultipartRelated(multipart_data)
    local headers = {"Content-Type: " .. content_type}
    
    local result_content, code = self:request(url_str, content, headers, "POST")
    
    if result_content then
        return self.gdUtils.parseJSON(result_content), code
    end
    return nil, code
end

function M:createFolder(folder_name, parent_id)
    local file = {
        name = folder_name,
        mimeType = "application/vnd.google-apps.folder",
    }
    
    if parent_id then
        file.parents = {parent_id}
    end
    
    local url_str = self:buildUrl({})
    local content, code = self:request(url_str, self.gdUtils.encodeJSON(file), {"Content-Type: application/json"}, "POST")
    
    if content then
        return self.gdUtils.parseJSON(content), code
    end
    return nil, code
end

function M:deleteFile(file_id)
    local url_str = self:buildUrl({}, self.config.endpoint .. "files/" .. file_id)
    local _, code = self:request(url_str, nil, nil, "DELETE")
    
    if code == 204 then
        return true, code
    end
    return nil, code
end

function M:searchFiles(query)
    local params = {
        q = query,
        fields = "files(id,name,mimeType,modifiedTime,size,webViewLink)",
    }
    return self:listFiles(params)
end

function M:isAuthenticated()
    return self.config.api_key ~= nil and self.config.api_key ~= ""
end

return M
