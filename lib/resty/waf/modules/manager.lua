local _M = {}

local comm = require "resty.waf.lib.comm"

function _M.run(config)
    if config.modules.manager.enable ~= true then
        return
    end

    local base_uri = '/waf'
    if string.find(ngx.var.uri, base_uri) ~= 1 then
        return
    end

    _M.auth_check(config.modules.manager.auth)

    local uri = ngx.var.uri
    local method = ngx.req.get_method()
    local path = string.sub( ngx.var.uri, string.len( base_uri ) + 1 )
    for i,item in ipairs( _M.routes) do
        if method == item['method'] and path == item['path'] then
            ngx.header.content_type = "application/json"
            ngx.header.charset = "utf-8"
            ngx.say(item['handle'](config))
            ngx.exit(ngx.HTTP_OK)
        end
    end
    ngx.status = ngx.HTTP_NOT_FOUND
    ngx.header.content_type = "application/json"
    ngx.say('{"code": 404, "message":"Not Found"}')
    ngx.exit(ngx.HTTP_OK)
end

function _M.config_get(config)
    return require('cjson').encode(config)
end

function _M.config_set(config)
    local inputs, err = require('cjson.safe').decode(ngx.req.get_body_data() or '{}')
    if inputs == nil then
        ngx.say('{"code": 422, "message":' .. err .. '}')
        return
    end
    local keys = {
        "matcher", "response", "modules.manager.auth",
        "modules.filter.rules", "modules.limiter.rules", "modules.counter.rules",
        "modules.filter.enable", "modules.limiter.enable", "modules.counter.enable"
    }
    for i,key in pairs(keys) do
        local last_field = nil
        local sub_inputs = inputs
        local sub_config = config
        for field in string.gmatch(key, "%w+") do
            if field == 'enable' and sub_inputs[field] ~= nil then
                sub_config[field] = sub_inputs[field]
                goto continue
            end
            sub_inputs = sub_inputs[field]
            sub_config = sub_config[field]
            if sub_inputs == nil then
                goto continue
            end
            last_field = field
        end
        if type(sub_inputs) ~= 'table' then
            goto continue
        end
        for name,value in pairs(sub_inputs) do
            if last_field == 'rules' then
                for pos,rule in ipairs(sub_config) do
                    if rule['matcher'] == value['matcher'] then
                        if rule['by'] ~= nil then
                            if rule['by'] == value['by'] then
                                table.remove(sub_config, pos)
                            end
                        else
                            table.remove(sub_config, pos)
                        end
                    end
                end
                table.insert(sub_config, value)
            else
                sub_config[name] = value
            end
        end
        ::continue::
    end
    ngx.shared.waf:set('config', require('cjson').encode(config))
    return require('cjson').encode(config)
end

function _M.config_reload()
    return require('cjson').encode(require("resty.waf.shared").reload_config())
end

function _M.list_reload()
    require("resty.waf.shared").reload_list()
    return require('cjson').encode({["code"] = 200, ["message"] = "success"})
end

function _M.counter_get(config)
    local counter = ngx.shared.counter
    local data = {}
    local inputs, err = require('cjson.safe').decode(ngx.req.get_body_data() or '{}')
    if inputs == nil then
        ngx.say('{"code": 422, "message":' .. err .. '}')
        return
    end
    local scale = 1024
    if inputs['scale'] ~= nil then
        scale = tonumber(inputs['scale'])
    end
    local count = 1
    if inputs['count'] ~=nil then
        count = tonumber(inputs['count'])
    end

    if type(inputs['q']) == 'table' and table.getn(inputs['q']) > 0 then
        for _,v in ipairs(inputs['q']) do
            local total = counter:get(v)
            if total ~= nil then
                local time,by,key = v:match"^([^;]+);(.+):([^:]*)$"
                if data[time] == nil then data[time] = {} end
                if data[time][by] == nil then data[time][by] = {} end
                data[time][by][key] = total
            end
        end
    else
        local keys = counter:get_keys(scale)
        for i,v in ipairs(keys) do
            if inputs['q'] ~= nil and type(inputs['q']) == 'string' and inputs['q'] ~= '' then
                if ngx.re.find(v, inputs['q'], 'isjo') == nil then
                    goto continue
                end
            else
                if i > 2048 then
                    goto continue
                end
            end
            local time,by,key =v:match"^([^;]+);(.+):([^:]*)$"
            local total = counter:get(v)
            if total >= count then
                if data[time] == nil then data[time] = {} end
                if data[time][by] == nil then data[time][by] = {} end
                data[time][by][key] = counter:get(v)
            end
            ::continue::
        end
    end
    return require('cjson').encode(data)
end

function _M.limiter_get(config)
    local limiter = ngx.shared.limiter
    local data = {}
    local inputs,err = require('cjson.safe').decode(ngx.req.get_body_data() or '{}')
    if inputs == nil then
        ngx.say('{"code": 422, "message":' .. err .. '}')
        return
    end
    local scale = 1024
    if inputs['scale'] ~= nil then
        scale = tonumber(inputs['scale'])
    end
    local count = 1
    if inputs['count'] ~=nil then
        count = tonumber(inputs['count'])
    end

    if type(inputs['q']) == 'table' and table.getn(inputs['q']) > 0 then
        for _,v in ipairs(inputs['q']) do
            local total = limiter:get(v)
            if total ~= nil then
                local time,matcher, by, key = v:match"^([^:]+):([^;]+);(.+):([^:]*)$"
                if data[time] == nil then data[time] = {} end
                if data[time][matcher] == nil then data[time][matcher] = {} end
                if data[time][matcher][by] == nil then data[time][matcher][by] = {} end
                data[time][matcher][by][key] = total
            end
        end
    else
        local keys = limiter:get_keys(scale)
        for i,v in ipairs(keys) do
            if inputs['q'] ~= nil and type(inputs['q']) == 'string' and inputs['q'] ~= '' then
                if ngx.re.find(v, inputs['q'], 'isjo') == nil then
                    goto continue
                end
            else
                if i > 2048 then
                    goto continue
                end
            end
            local time,matcher, by, key = v:match"^([^:]+):([^;]+);(.+):([^:]*)$"
            local total = limiter:get(v)
            if total >= count then
                if data[time] == nil then data[time] = {} end
                if data[time][matcher] == nil then data[time][matcher] = {} end
                if data[time][matcher][by] == nil then data[time][matcher][by] = {} end
                data[time][matcher][by][key] = total
            end
            ::continue::
        end
    end
    return require('cjson').encode(data)
end

function _M.auth_check(auth)
    local token = nil
    local header = ngx.var.http_Authorization
    if header ~= nil then
        _, _, token = string.find(header, "Basic%s+(.+)")
    end
    if token ~= nil then
        token = ngx.decode_base64(token)
        if token == auth.user .. ":" .. auth.pass then
            return
        end
    end
    ngx.status = ngx.HTTP_UNAUTHORIZED
    ngx.header["WWW-Authenticate"] = [[Basic realm="restricted"]]
    ngx.say('{"code": 401, "message":"401 Unauthorized"}')
    ngx.exit(ngx.HTTP_OK)
    return
end

function _M.status_get()
    data = {
        ["ngx.worker"] = {
            ["count"] = ngx.worker.count(),
        },
        ["ngx.config"] = {
            ["nginx_version"] = ngx.config.nginx_version,
            ["ngx_lua_version"] = ngx.config.ngx_lua_version,
        },
        ["ngx.shared.dict"] = {
            ["waf"] = {
                ["free"] = ngx.shared.waf:free_space()/1024,
                ["capacity"] = ngx.shared.waf:capacity()/1024,
            },
            ["list"] = {
                ["free"] = ngx.shared.list:free_space()/1024,
                ["capacity"] = ngx.shared.list:capacity()/1024,
            },
            ["limiter"] = {
                ["free"] = ngx.shared.limiter:free_space()/1024,
                ["capacity"] = ngx.shared.limiter:capacity()/1024,
            },
            ["counter"] = {
                ["free"] = ngx.shared.counter:free_space()/1024,
                ["capacity"] = ngx.shared.counter:capacity()/1024,
            },
        }
    }
   return require('cjson').encode(data)
end

function _M.list_get()
    local list = ngx.shared.list
    local data = {}
    local inputs, err = require('cjson.safe').decode(ngx.req.get_body_data() or '{}')
    if inputs == nil then
        ngx.say('{"code": 422, "message":' .. err .. '}')
        return
    end
    local scale = 1024
    if inputs['scale'] ~= nil then
        scale = tonumber(inputs['scale'])
    end
    if type(inputs['q']) == 'table' and table.getn(inputs['q']) > 0 then
        for _,key in ipairs(inputs['q']) do
            local total = list:get(key)
            if total ~= nil then
                data[key] = string.format('%.0f', list:ttl(key)) .. "/" .. tostring(total)
            end
        end
    else
        local keys = list:get_keys(scale)
        for i,key in ipairs(keys) do
            if inputs['q'] ~= nil and type(inputs['q']) == 'string' and inputs['q'] ~= '' then
                if ngx.re.find(key, inputs['q'], 'isjo') ~= nil then
                    data[key] = list:get(key)
                end
            else
                if i <= 2048 then
                    data[key] = list:get(key)
                end
            end
        end
        local size = table.getn(data)
        if  size <= 2048 then
            for k,v in pairs(data) do
                local ttl = list:ttl(k)
                if inputs['ttl'] ~=nil then
                    if ttl <= tonumber(inputs['ttl']) then
                        data[k] = string.format('%.0f', ttl) .. "/" .. v
                    else
                        data[k] = nil
                    end
                else
                    data[k] = string.format('%.0f', ttl) .. "/" .. v
                end
            end
        end
    end
    return require('cjson').encode(data)
end

function _M.list_set()
    local list = ngx.shared.list
    local data = {}
    local inputs, err  = require('cjson.safe').decode(ngx.req.get_body_data() or '{}')
    if inputs == nil then
        ngx.say('{"code": 422, "message":' .. err .. '}')
        return
    end
    for identifier,v in pairs(inputs) do
        local ttl = tonumber(v)
        if ttl == nil or ttl <= 0 then
            ngx.shared.list:set(identifier, nil)
        elseif ttl >= 2678400 then
            ngx.shared.list:set(identifier, 2678400, 2678400)
        else
            ngx.shared.list:set(identifier, ttl, ttl)
        end
    end
   return require('cjson').encode(data)
end

_M.routes = {
    { ['method'] = "GET", ["path"] = "/status", ['handle'] = _M.status_get},
    { ['method'] = "GET", ["path"] = "/config", ['handle'] = _M.config_get},
    { ['method'] = "POST", ["path"] = "/config", ['handle'] = _M.config_set},
    { ['method'] = "POST", ["path"] = "/config/reload", ['handle'] = _M.config_reload},
    { ['method'] = "GET", ["path"] = "/list", ['handle'] = _M.list_get},
    { ['method'] = "POST", ["path"] = "/list", ['handle'] = _M.list_set},
    { ['method'] = "POST", ["path"] = "/list/reload", ['handle'] = _M.list_reload},
    { ['method'] = "GET", ["path"] = "/module/counter", ['handle'] = _M.counter_get},
    { ['method'] = "GET", ["path"] = "/module/limiter", ['handle'] = _M.limiter_get},
}

return _M
