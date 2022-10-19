local _M = {}

function _M.get_client_ip()
    local ipv4 = ngx.req.get_headers()["X-Real-IP"]
    if ipv4 == nil then
        ipv4 = ngx.req.get_headers()["X-Forwarded-For"]
    end
    if ipv4 == nil then
        ipv4 = ngx.var.remote_addr
    end
    return ipv4
end

function _M.get_device_id()
    local headers = ngx.req.get_headers()
    for k,v in pairs(headers) do
        if string.lower(k) == 'x-device-id' then
            return string.lower(v)
        end
    end
    return
end

function _M.get_user_id()
    local jwt = require "resty.jwt"
    local jwt_token = nil
    local auth_header = ngx.var.http_Authorization
    if auth_header then
        _, _, jwt_token = string.find(auth_header, "Bearer%s+(.+)")
    end
    local jwt_obj = (jwt_token ~= nil and jwt:load_jwt(jwt_token) or nil)
    return jwt_obj ~= nil and jwt_obj.payload ~= nil and jwt_obj.payload.sub or 0
end

function _M.response(response_list, code)
    response = response_list[tostring(code)]
    if response ~= nil then
        ngx.status = tonumber(response['status'] or rule['code'])
        ngx.header.content_type = response['mime_type']
        ngx.say( response['body'] )
        ngx.exit(ngx.HTTP_OK)
    else
        ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
    end
end

function _M.contains( list, value )
    if type(list) == 'table' then
        for idx,item in ipairs( list ) do
            if item == value then
                return true
            end
        end
    end
    return false
end

return _M
