local _M = {}

local comm = require "resty.waf.lib.comm"
local request_tester = require "resty.waf.lib.tester"

local counter = ngx.shared.counter

function _M.run(config, group)

    if ngx.req.is_internal() == true then
        return
    end

    if config.modules.counter.enable ~= true then
        return
    end

    local matcher_list = config.matcher

    if group == nil or type(group) ~= 'string' or group == '' then
        group = 'accepted'
    end

    for i, rule in ipairs( config.modules.counter.rules ) do
        local enable = rule['enable']
        local matcher = matcher_list[ rule['matcher'] ]
        if enable == true and request_tester.test( matcher ) == true then
            if rule['time'] > 86400 then
                rule['time'] = 86400
            end
            local time = tonumber(rule['time'])
            local key = group .. ":" .. rule['time'] .. ";"
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
                    else
                        goto continue
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

function _M.query()
    local counter = ngx.shared.counter
    local data = {}
    local inputs, err = require('cjson.safe').decode(ngx.req.get_body_data() or '{}')
    if inputs == nil then comm.error(err) end
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
                local group,time,by,key = v:match"^([^:]+):([^;]+);(.+):([^:]*)$"
                if data[group] == nil then data[group] = {} end
                if data[group][time] == nil then data[group][time] = {} end
                if data[group][time][by] == nil then data[group][time][by] = {} end
                data[group][time][by][key] = total
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
            local group,time,by,key = v:match"^([^:]+):([^;]+);(.+):([^:]*)$"
            local total = counter:get(v)
            if total >= count then
                if data[group] == nil then data[group] = {} end
                if data[group][time] == nil then data[group][time] = {} end
                if data[group][time][by] == nil then data[group][time][by] = {} end
                data[group][time][by][key] = counter:get(v)
            end
            ::continue::
        end
    end
    return require('cjson').encode(data)
end
return _M
