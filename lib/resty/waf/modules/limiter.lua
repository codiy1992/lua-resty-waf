local _M = {}

local comm = require "resty.waf.lib.comm"
local request_tester = require "resty.waf.lib.tester"

local limiter = ngx.shared.limiter

function _M.run(config)

    if ngx.req.is_internal() == true then
        return
    end

    if config.modules.limiter.enable ~= true then
        return
    end

    local matcher_list = config.matcher
    local response_list = config.response
    local response = nil

    for i, rule in ipairs( config.modules.limiter.rules ) do
        local enable = rule['enable']
        local matcher = matcher_list[ rule['matcher'] ]
        if enable == true and request_tester.test( matcher ) == true then

            local time = rule['time'] or 60
            local count = rule['count'] or 60
            local key = tostring(count) .. "/" .. tostring(time) .. ":" .. rule['matcher'] .. ";"
            if rule['by'] ~= nil then
                for by in string.gmatch(rule['by'], '[^,]+') do
                    if by == 'ip' then
                        local client_ip = comm.get_client_ip()
                        if client_ip == nil then
                            goto continue
                        end
                        key = key ..'ip:'.. client_ip .. ';'
                    elseif by == 'uri' then
                        key = key..'uri:'..ngx.var.uri .. ';'
                    elseif by == 'uid' then
                        local uid = comm.get_user_id()
                        if uid == 0 then
                            goto continue
                        end
                        key = key..'uid:'.. uid .. ';'
                    elseif by == 'device' then
                        local device_id = comm.get_device_id()
                        if device_id == nil then
                            goto continue
                        end
                        key = key..'device:'.. device_id .. ';'
                    end
                end
            end

            local count_now = limiter:get(key)

            key = string.gsub(key, "^(.*);$", "%1")
            local count_now = limiter:incr( key, 1, 0, tonumber(time) )
            if count_now > tonumber(count) then
                comm.response(response_list, rule['code'])
            end

        end
        ::continue::
    end
end

return _M
