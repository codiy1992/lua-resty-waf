local _M = {}

local comm = require "resty.waf.lib.comm"
local request_tester = require "resty.waf.lib.tester"
local list = ngx.shared.list

function _M.run(config)
    if ngx.req.is_internal() == true then
        return
    end
    if config.modules.filter.enable ~= true then
        return
    end
    local matcher_list = config.matcher
    local response_list = config.response
    local response = nil

    for i,rule in ipairs(config.modules.filter.rules) do
        local enable = rule['enable']
        local matcher = matcher_list[ rule['matcher'] ]
        local action = rule['action']
        if enable == true and request_tester.test( matcher ) == true then
            if rule['by'] ~= nil then
                if rule['by'] == 'ip:in_list' then
                    local client_ip = comm.get_client_ip()
                    if client_ip ~= nil and list:get(client_ip) ~= nil then
                        if action == 'block' then
                            comm.response(response_list, rule['code'])
                        end
                    end
                    goto continue
                elseif rule['by'] == 'ip:not_in_list' then
                    local client_ip = comm.get_client_ip()
                    if client_ip ~= nil and list:get(client_ip) == nil then
                        if action == 'block' then
                            comm.response(response_list, rule['code'])
                        end
                    end
                    goto continue
                elseif rule['by'] == 'device:in_list' then
                    local device_id = comm.get_device_id()
                    if device_id ~= nil and list:get(string.lower(device_id)) ~= nil then
                        if action == 'block' then
                            comm.response(response_list, rule['code'])
                        end
                    end
                    goto continue
                elseif rule['by'] == 'device:not_in_list' then
                    local device_id = comm.get_device_id()
                    if device_id ~= nil and list:get(string.lower(device_id)) == nil then
                        if action == 'block' then
                            comm.response(response_list, rule['code'])
                        end
                    end
                    goto continue
                elseif rule['by'] == 'uid:in_list' then
                    local uid = comm.get_user_id()
                    if uid ~= nil and list:get(string.lower(uid)) ~= nil then
                        if action == 'block' then
                            comm.response(response_list, rule['code'])
                        end
                    end
                    goto continue
                elseif rule['by'] == 'uid:not_in_list' then
                    local uid = comm.get_user_id()
                    if uid ~= nil and list:get(string.lower(uid)) == nil then
                        if action == 'block' then
                            comm.response(response_list, rule['code'])
                        end
                    end
                    goto continue
                else
                    goto continue
                end
            end
            if action ~= 'block' then
                goto continue
            else
                comm.response(response_list, rule['code'])
            end
        end
        ::continue::
    end
end

return _M
