local _M = {}

local comm = require "resty.waf.lib.comm"
local limiter = require "resty.waf.modules.limiter"
local counter = require "resty.waf.modules.counter"
local sampler = require "resty.waf.modules.sampler"

function _M.run(config)
    if config.modules.manager.enable ~= true then
        return
    end
    local base_uri = '/waf'
    local method = ngx.req.get_method()
    local path = string.sub( ngx.var.uri, string.len( base_uri ) + 1 )
    for i,item in ipairs( _M.routes) do
        if method == item['method'] and path == item['path'] then
            _M.auth_check(config.modules.manager.auth)
            ngx.header.content_type = "application/json"
            ngx.header.charset = "utf-8"
            ngx.say(item['handle'](config))
            ngx.exit(ngx.HTTP_OK)
        end
    end
end

function _M.config_get(config)
    return require('cjson').encode(config)
end

function _M.config_set(config)
    local inputs, err = require('cjson.safe').decode(ngx.req.get_body_data() or '{}')
    if inputs == nil then comm.error(err) end
    local keys = {
        "matchers", "responses", "modules:manager:auth",
        "modules:filter:rules", "modules:limiter:rules",
        "modules:counter:rules", "modules:sampler:rules",
        "modules:filter:enable", "modules:limiter:enable",
        "modules:counter:enable", "modules:sampler:enable"
    }
    for i,key in pairs(keys) do
        local field = nil
        local module = nil
        local sub_inputs = inputs
        local sub_config = config
        for v in string.gmatch(key, "%w+") do
            if v == 'enable' and sub_inputs[v] ~= nil then
                sub_config[v] = sub_inputs[v]
                goto continue
            end
            sub_inputs = sub_inputs[v]
            sub_config = sub_config[v]
            if sub_inputs == nil then
                goto continue
            end
            if comm.in_array(v, {'filter', 'limiter', 'counter'}) then
                module = v
            end
            field = v
        end

        if type(sub_inputs) ~= 'table' then
            goto continue
        end

        if field == 'rules' then
            for pos,rule in pairs(sub_config) do
                sub_config[pos] = nil
            end
        end

        for name,value in pairs(sub_inputs) do
            if field == 'rules' then
                -- validate matcher
                if value['matcher'] == nil or type(value['matcher']) ~= 'string' then
                    comm.error('Required rule.matcher in module: ' .. module)
                end
                if config['matchers'][value['matcher']] == nil then
                    if comm.in_array(value['matcher'], {'filtered', 'limited'}) ~= true then
                        comm.error('Unexpected rule.matcher `' .. value['matcher'] ..'` found in module: ' .. module)
                    end
                end
                -- validate by
                if comm.in_array(module, {'filter'}) then
                    if value['by'] ~= nil and type(value['by']) ~= 'string' then
                        comm.error('Unexpected rule.by found in module: ' .. module)
                    end
                    if value['by'] ~= nil and type(value['by']) == 'string' then
                        if comm.in_array(value['by'], {
                            'ip:in_list', 'ip:not_in_list', 'device:in_list',
                            'uid:in_list', 'uid:not_in_list', 'device:not_in_list'
                        }) ~= true then
                            comm.error('Unexpected rule.by `'.. value['by'] ..'` found in module: ' .. module)
                        end
                    end
                end
                -- validate action
                if comm.in_array(module, {'filter'}) then
                    if value['action'] == nil or type(value['action']) ~= 'string' then
                        comm.error('Required rule.action in module: ' .. module)
                    end
                    if comm.in_array(value['action'], {'block', 'accept'}) ~= true then
                        comm.error('Unexpected rule.action `'.. value['action'] ..'` found in module: ' .. module)
                    end
                end
                -- validate time
                if comm.in_array(module, {'limiter', 'counter'}) then
                    if value['time'] == nil or tonumber(value['time']) == nil then
                        comm.error('Required rule.time in module: ' .. module)
                    end
                end
                -- validate count
                if comm.in_array(module, {'limiter'}) then
                    if value['count'] == nil or tonumber(value['count']) == nil then
                        comm.error('Required rule.count in module: ' .. module)
                    end
                end
                if value['enable'] ~= nil and value['enable'] == true then
                    table.insert(sub_config, value)
                end
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
            ["sampler"] = {
                ["free"] = ngx.shared.sampler:free_space()/1024,
                ["capacity"] = ngx.shared.sampler:capacity()/1024,
            },
        }
    }
   return require('cjson').encode(data)
end

function _M.list_get()
    local list = ngx.shared.list
    local data = {}
    local inputs, err = require('cjson.safe').decode(ngx.req.get_body_data() or '{}')
    if inputs == nil then comm.error(err) end
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
    if inputs == nil then comm.error(err) end
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
    { ['method'] = "GET", ["path"] = "/module/limiter", ['handle'] = limiter.query},
    { ['method'] = "GET", ["path"] = "/module/counter", ['handle'] = counter.query},
    { ['method'] = "GET", ["path"] = "/module/sampler", ['handle'] = sampler.query},
}

return _M
