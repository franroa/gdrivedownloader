local M = {}

-- OAuth2 configuration for Google
M.google_config = {
    auth_url = "https://accounts.google.com/o/oauth2/v2/auth",
    token_url = "https://oauth2.googleapis.com/token",
}

function M.new()
    local self = setmetatable({}, M)
    return self
end

function M.copyTable(src, dest)
    if src and dest then
        for k, v in pairs(src) do
            dest[k] = v
        end
    end
end

function M.urlEncode(str)
    if str then
        str = string.gsub(str, "\n", "\r\n")
        str = string.gsub(str, "([^%w])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    end
    return str
end

function M.urlDecode(str)
    if str then
        str = string.gsub(str, "+", " ")
        str = string.gsub(str, "%%(%x%x)", function(h)
            return string.char(tonumber(h, 16))
        end)
    end
    return str
end

function M.parseQueryString(query_str)
    local params = {}
    if query_str then
        for key, value in string.gmatch(query_str, "([^&=]+)=([^&]*)") do
            params[self.urlDecode(key)] = self.urlDecode(value)
        end
    end
    return params
end

return M
