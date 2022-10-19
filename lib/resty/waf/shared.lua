local _M = {}

local cjson = require("cjson")
local redis = require("resty.waf.lib.redis")
local nkeys = require("table.nkeys")

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
            "matcher", "response", "modules.manager.auth",
            "modules.filter.rules", "modules.limiter.rules", "modules.counter.rules",
            "modules.filter", "modules.limiter", "modules.counter"
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
            local last_field = nil
            for field in string.gmatch(key, "%w+") do
                sub_config = sub_config[field]
                last_field = field
            end
            for i = 1,nkeys(res),2 do
                local name = tostring(res[i])
                if name == 'enable' then
                    sub_config[name] = cjson.decode(res[i+1])
                    goto continue
                end
                local value = cjson.decode(res[i+1])
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
                end
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
        for i = 1,nkeys(res),2 do
            local identifier = res[i]
            local ttl = tonumber(res[i+1])
            if ttl <= 0 then
                ngx.shared.list:set(identifier, nil)
                rds:zrem("waf:list", identifier)
            elseif ttl >= 2678400 then
                ngx.shared.list:set(identifier, 2678400, 2678400)
            else
                ngx.shared.list:set(identifier, ttl, ttl)
            end
        end

    end, config)
end

return _M
