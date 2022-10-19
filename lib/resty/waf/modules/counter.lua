local _M = {}

local comm = require "resty.waf.lib.comm"
local request_tester = require "resty.waf.lib.tester"

local counter = ngx.shared.counter

function _M.run(config)

    if ngx.req.is_internal() == true then
        return
    end

    if config.modules.counter.enable ~= true then
        return
    end

    local matcher_list = config.matcher

    for i, rule in ipairs( config.modules.counter.rules ) do
        local enable = rule['enable']
        local matcher = matcher_list[ rule['matcher'] ]
        if enable == true and request_tester.test( matcher ) == true then
            if rule['time'] > 86400 then
                rule['time'] = 86400
            end
            local time = tonumber(rule['time'])
            local key = rule['time'] .. ";"
            if rule['by'] ~= nil then
                for by in string.gmatch(rule['by'], '[^,]+') do
                    if by == 'ip' then
                        key = key .. "ip:" .. comm.get_client_ip() .. ';'
                    elseif by == 'device' then
                        key = key .. "device:" .. comm.get_device_id() .. ';'
                    elseif by == 'uid' then
                        key = key .. "uid:" .. comm.get_user_id() .. ';'
                    elseif by == 'uri' then
                        key = key .. "uri:" .. ngx.var.uri .. ';'
                    end
                end
            else
                key = key .. "matcher:" .. rule['matcher'] .. ';'
            end
            key = string.gsub(key, "^(.*);$", "%1")
            counter:incr( key, 1, 0, time )
        end
        ::continue::
    end
end

return _M
