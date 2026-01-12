local M = {}

-- Simple URL encoding for OAuth parameters
function M.urlEncode(str)
    if str then
        str = string.gsub(str, "\n", "\r\n")
        str = string.gsub(str, "([^%w])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    end
    return str
end

-- Parse query string into table
function M.parseQueryString(query_str)
    local params = {}
    for key, value in string.gmatch(query_str or "", "([^&=]+)=([^&]*)") do
        params[M.urlDecode(key)] = M.urlDecode(value)
    end
    return params
end

-- URL decoding
function M.urlDecode(str)
    if str then
        str = string.gsub(str, "+", " ")
        str = string.gsub(str, "%%(%x%x)", function(h)
            return string.char(tonumber(h, 16))
        end)
    end
    return str
end

-- Copy table
function M.copyTable(src, dest)
    if src and dest then
        for k, v in pairs(src) do
            dest[k] = v
        end
    end
end

-- Format HTTP error code
function M.formatHttpCodeError(code)
    local messages = {
        [400] = "Bad Request",
        [401] = "Unauthorized",
        [403] = "Forbidden",
        [404] = "Not Found",
        [500] = "Internal Server Error",
        [502] = "Bad Gateway",
        [503] = "Service Unavailable",
    }
    return string.format("HTTP Error %d: %s", code or 0, messages[code] or "Unknown Error")
end

-- Build multipart related content
function M.buildMultipartRelated(data)
    local boundary = "boundary_" .. math.random(1000000, 9999999)
    local content = {}
    
    for i, item in ipairs(data) do
        table.insert(content, "--" .. boundary)
        table.insert(content, "Content-Type: " .. item.type)
        table.insert(content, "")
        table.insert(content, item.data)
    end
    
    table.insert(content, "--" .. boundary .. "--")
    return table.concat(content, "\r\n"), "multipart/related; boundary=" .. boundary
end

-- Stream multipart (for file reading)
function M.streamMultipartRelated(data)
    -- Simplified version - in real implementation would read file in chunks
    return M.buildMultipartRelated(data)
end

return M
