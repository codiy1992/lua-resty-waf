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
    local user_id = 0
    local jwt_obj = (jwt_token ~= nil and jwt:load_jwt(jwt_token) or nil)
    if jwt_obj ~= nil and jwt_obj.payload ~= nil and type(jwt_obj.payload) == 'number' then
        user_id = jwt_obj.payload
    elseif jwt_obj ~= nil and jwt_obj.payload ~= nil and jwt_obj.payload.sub ~= nil then
        user_id = jwt_obj.payload.sub
    else
        user_id = 0
    end
    return user_id
end

function _M.error(err)
    data = {
        ['code'] = ngx.HTTP_BAD_REQUEST,
        ['message'] = err or 'Unknown Error'
    }
    ngx.status = ngx.HTTP_BAD_REQUEST
    ngx.header.content_type = 'application/json'
    ngx.say(require('cjson').encode(data))
    ngx.exit(ngx.HTTP_BAD_REQUEST)
end

function _M.in_array( value, list )
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
