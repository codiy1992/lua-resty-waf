local _M = {}

local cjson = require("cjson")
local cjson_safe = require("cjson.safe")
local redis = require("resty.waf.lib.redis")
local nkeys = require("table.nkeys")
local comm = require "resty.waf.lib.comm"

function _M.get_config()
    local config = ngx.shared.waf:get('config');
    if config ~= nil then
        return cjson.decode(config)
    end
    return nil
end

function _M.reload_config()
    local config = require('resty.waf.config');
    redis.exec(function (rds, config)
        local keys = {
            "matchers", "responses", "modules:manager:auth",
            "modules:filter:rules", "modules:limiter:rules", "modules:counter:rules",
            "modules:filter", "modules:limiter", "modules:counter"
        }
        for i,key in pairs(keys) do

            local res, err = rds:hgetall("waf:config:"..key);
            if err then
                ngx.log(ngx.ERR, "failed:", err)
                goto continue
            end

            if next(res) == nil then
                goto continue
            end

            local sub_config = config
            local sub_inputs = {}
            local field = nil
            local module = nil
            for v in string.gmatch(key, "%w+") do
                sub_config = sub_config[v]
                field = v
                if comm.in_array(v, {'filter', 'limiter', 'counter'}) then
                    module = v
                end
            end
            for i = 1,nkeys(res),2 do
                local name = tostring(res[i])
                if name == 'enable' then
                    local v = cjson_safe.decode(res[i+1])
                    if v ~= nil then sub_config[name] = v end
                    goto continue
                end
                local v = cjson_safe.decode(res[i+1])
                if  v ~= nil then
                    if field == 'rules' then
                        table.insert(sub_inputs, v)
                    else
                        sub_config[name] = v
                    end
                end
            end

            -- handle rules data
            if table.getn(sub_inputs) > 0 then
                for pos,rule in pairs(sub_config) do
                    sub_config[pos] = nil
                end
            end
            for _,value in pairs(sub_inputs) do
                -- validate matcher
                if value['matcher'] == nil or type(value['matcher']) ~= 'string' then
                    goto next
                end
                if config['matchers'][value['matcher']] == nil then
                    goto next
                end
                -- validate by
                if comm.in_array(module, {'filter'}) then
                    if value['by'] ~= nil and type(value['by']) ~= 'string' then
                        goto next
                    end
                    if value['by'] ~= nil and type(value['by']) == 'string' then
                        if comm.in_array(value['by'], {
                            'ip:in_list', 'ip:not_in_list', 'device:in_list',
                            'uid:in_list', 'uid:not_in_list', 'device:not_in_list'
                        }) ~= true then
                            goto next
                        end
                    end
                end
                -- validate action
                if comm.in_array(module, {'filter'}) then
                    if value['action'] == nil or type(value['action']) ~= 'string' then
                        goto next
                    end
                    if comm.in_array(value['action'], {'block', 'accept'}) ~= true then
                        goto next
                    end
                end
                -- validate time
                if comm.in_array(module, {'limiter', 'counter'}) then
                    if value['time'] == nil or tonumber(value['time']) == nil then
                        goto next
                    end
                end
                -- validate count
                if comm.in_array(module, {'limiter'}) then
                    if value['count'] == nil or tonumber(value['count']) == nil then
                        goto next
                    end
                end
                if value['enable'] ~= nil and value['enable'] == true then
                    table.insert(sub_config, value)
                end
                ::next::
            end
            ::continue::
        end
    end, config)
    -- ngx.log(ngx.ERR, "---- config reloaded ----")
    ngx.shared.waf:set('config', cjson.encode(config))
    return config
end

function _M.reload_list()
    redis.exec(function (rds)
        local res, err = rds:zrange("waf:list", 0, -1, 'WITHSCORES');
        if err then
            ngx.log(ngx.ERR, "zrange failed:", err)
            return
        end
        local now = os.time(os.date("!*t"))
        for i = 1,nkeys(res),2 do
            local identifier = res[i]
            local expiry = tonumber(res[i+1])
            if expiry <= now then
                ngx.shared.list:set(identifier, nil)
                rds:zrem("waf:list", identifier)
            else
                ttl = expiry - now
                ngx.shared.list:set(identifier, ttl, ttl)
            end
        end

    end, config)
end

return _M
