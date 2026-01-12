local OAUTILS = require("lib.oauth2utils")
local http = require("socket.http")
local ltn12 = require("ltn12")
local url = require("socket.url")
local logger = require("logger")

local M = {}
M.__index = M

-- Google OAuth2 endpoints
M.google_config = {
    auth_url = "https://accounts.google.com/o/oauth2/v2/auth",
    token_url = "https://oauth2.googleapis.com/token",
}

function M.new(config, work_config)
    local self = setmetatable({}, M)
    self.config = {}
    self.work_config = work_config or {}
    self.oaUtils = OAUTILS.new()
    
    -- Copy base config
    if config then
        self.oaUtils.copyTable(config, self.config)
    end
    if self.work_config then
        self.oaUtils.copyTable(self.work_config, self.config)
    end
    
    return self
end

function M:init()
    -- Load saved tokens if available
    self.token_file = self.config.tokens_file
    self.creds_file = self.config.creds_file
    self.tokens = {}
    self.credentials = {}
    
    -- Load tokens
    if self.token_file and io.open(self.token_file, "r") then
        local tokens_content = readSetting(self.token_file)
        if tokens_content then
            self.tokens = tokens_content
        end
    end
    
    -- Load credentials
    if self.creds_file and io.open(self.creds_file, "r") then
        local creds_content = readSetting(self.creds_file)
        if creds_content then
            self.credentials = creds_content
        end
    end
    
    return true
end

function M:getAuthUrl()
    local params = {
        client_id = self.credentials.client_id,
        redirect_uri = self.config.redirect_uri or "urn:ietf:wg:oauth:2.0:oob",
        response_type = "code",
        scope = self.config.scope or "https://www.googleapis.com/auth/drive",
        access_type = "offline",
        prompt = "consent",
    }
    
    local auth_url = self.google_config.auth_url .. "?"
    local query_parts = {}
    for k, v in pairs(params) do
        table.insert(query_parts, k .. "=" .. self.oaUtils.urlEncode(v))
    end
    auth_url = auth_url .. table.concat(query_parts, "&")
    
    return auth_url
end

function M:exchangeCodeForToken(code)
    local params = {
        client_id = self.credentials.client_id,
        client_secret = self.credentials.client_secret,
        code = code,
        grant_type = "authorization_code",
        redirect_uri = self.config.redirect_uri or "urn:ietf:wg:oauth:2.0:oob",
    }
    
    local body = {}
    for k, v in pairs(params) do
        table.insert(body, k .. "=" .. self.oaUtils.urlEncode(v))
    end
    local post_data = table.concat(body, "&")
    
    local response = {}
    local _, code_or_error = http.request{
        url = self.google_config.token_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Content-Length"] = #post_data,
        },
        source = ltn12.source.string(post_data),
        sink = ltn12.sink.table(response),
    }
    
    if type(code_or_error) == "number" and code_or_error == 200 then
        local content = table.concat(response)
        local tokens = self.oaUtils.parseQueryString(content)
        self.tokens = tokens
        
        -- Save tokens
        if self.token_file then
            saveSetting(self.token_file, tokens)
        end
        
        return tokens
    else
        logger.error("Token exchange failed:", code_or_error)
        return nil, code_or_error
    end
end

function M:refreshAccessToken()
    if not self.tokens.refresh_token then
        return nil, "No refresh token available"
    end
    
    local params = {
        client_id = self.credentials.client_id,
        client_secret = self.credentials.client_secret,
        refresh_token = self.tokens.refresh_token,
        grant_type = "refresh_token",
    }
    
    local body = {}
    for k, v in pairs(params) do
        table.insert(body, k .. "=" .. self.oaUtils.urlEncode(v))
    end
    local post_data = table.concat(body, "&")
    
    local response = {}
    local _, code_or_error = http.request{
        url = self.google_config.token_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Content-Length"] = #post_data,
        },
        source = ltn12.source.string(post_data),
        sink = ltn12.sink.table(response),
    }
    
    if type(code_or_error) == "number" and code_or_error == 200 then
        local content = table.concat(response)
        local tokens = self.oaUtils.parseQueryString(content)
        
        -- Preserve refresh token
        if self.tokens.refresh_token then
            tokens.refresh_token = self.tokens.refresh_token
        end
        
        self.tokens = tokens
        
        -- Save tokens
        if self.token_file then
            saveSetting(self.token_file, tokens)
        end
        
        return tokens
    else
        return nil, code_or_error
    end
end

function M:request(request_url, payload, headers, method, options)
    local access_token = self.tokens.access_token
    if not access_token then
        return nil, 401
    end
    
    local request_headers = headers or {}
    request_headers["Authorization"] = "Bearer " .. access_token
    
    local sink = options and options.write and ltn12.sink.file(io.stdout) or ltn12.sink.table(response)
    
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
    
    if type(code_or_error) == "number" then
        if code_or_error == 401 and self.tokens.refresh_token then
            -- Try to refresh token
            local new_tokens, err = self:refreshAccessToken()
            if new_tokens then
                -- Retry request with new token
                return self:request(request_url, payload, headers, method, options)
            else
                return nil, 401
            end
        end
        return table.concat(response_table), code_or_error
    else
        return nil, code_or_error
    end
end

-- Helper functions for settings
function readSetting(file_path)
    local ok, result = pcall(dofile, file_path)
    if ok and type(result) == "table" then
        return result
    end
    return nil
end

function saveSetting(file_path, data)
    local ok, err = pcall(function()
        local f = io.open(file_path, "w")
        if f then
            f:write("return " .. require("dkjson").encode(data))
            f:close()
        end
    end)
    if not ok then
        logger.error("Failed to save setting:", err)
    end
end

return M
