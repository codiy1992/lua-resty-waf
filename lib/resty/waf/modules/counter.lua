local _M = {}

local comm = require "resty.waf.lib.comm"
local request_tester = require "resty.waf.lib.tester"

local counter = ngx.shared.counter

function _M.run(config, state)

    if ngx.req.is_internal() == true then
        return
    end

    if config.modules.counter.enable ~= true then
        return
    end

    local matcher_list = config.matchers

    if state == nil or type(state) ~= 'string' or state == '' then
        state = 'accepted'
    end

    local keys = {}
    for i, rule in ipairs( config.modules.counter.rules ) do
        local enable = rule['enable']
        local matcher = matcher_list[ rule['matcher'] ]
        if enable == true and request_tester.test( matcher ) == true then
            if rule['time'] > 86400 then
                rule['time'] = 86400
            end
            local time = tonumber(rule['time'])
            local key = state .. ":" .. rule['time'] .. ";"
            local fields = {}
            if rule['by'] ~= nil then
                for by in string.gmatch(rule['by'], '[^,]+') do
                    if by == 'ip' then
                        local client_ip = comm.get_client_ip()
                        if client_ip == nil then
                            goto continue
                        end
                        fields['ip'] = "ip:" .. client_ip .. ';'
                    elseif by == 'device' then
                        local device_id = comm.get_device_id()
                        if device_id == nil then
                            goto continue
                        end
                        fields['device'] = "device:" .. device_id .. ';'
                    elseif by == 'uid' then
                        local uid = comm.get_user_id()
                        if uid == 0 then
                            goto continue
                        end
                        fields['uid'] = "uid:" .. uid .. ';'
                    elseif by == 'uri' then
                        fields['uri'] = "uri:" .. ngx.var.uri .. ';'
                    else
                        goto continue
                    end
                end
                for _, field in ipairs({'ip', 'uid', 'device', 'uri'}) do
                    if fields[field] ~= nil then
                        key = key .. fields[field]
                    end
                end
            else
                key = key .. "matcher:" .. rule['matcher'] .. ';'
            end
            if keys[key] == nil then
                keys[key] = counter:incr( key, 1, 0, time )
            end
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
                local state,time,by,key = v:match"^([^:]+):([^;]+);(.+):([^:]*)$"
                if data[state] == nil then data[state] = {} end
                if data[state][time] == nil then data[state][time] = {} end
                if data[state][time][by] == nil then data[state][time][by] = {} end
                data[state][time][by][key] = total
            end
        end
    else
        if inputs['key'] ~= nil and type(inputs['key']) == 'string' then
            if comm.in_array(inputs['key'], {'ip', 'uid', 'device', 'uri'}) ~= true then
                inputs['key'] = nil
            end
        end
        local i = 0
        local keys = counter:get_keys(scale)
        for _,v in ipairs(keys) do
            if inputs['q'] ~= nil and type(inputs['q']) == 'string' and inputs['q'] ~= '' then
                if ngx.re.find(v, inputs['q'], 'isjo') == nil then
                    goto continue
                end
            else
                if i > 2048 then
                    goto done
                end
            end
            i = i + 1
            local total = counter:get(v)
            if total >= count then
                local state,time,by,key = v:match"^([^:]+):([^;]+);(.+):([^:]*);$"
                if inputs['key'] ~= nil then
                    local state,time, group = v:match"^([^:]+):([^;]+);(.+)$"
                    local from, to, err = ngx.re.find(group, inputs['key'] .. ":([^;]+);", 'isjo', nil, 1)
                    if from ~= nil then
                        key = string.sub(group, from, to)
                        by = ngx.re.gsub(
                            group,
                            "(.*)" ..  inputs['key'] .. ":" .. key .. ";" .. "(.*)",
                            "$1$2",
                            "isjo"
                        ) .. inputs['key']
                    end
                end
                if data[state] == nil then data[state] = {} end
                if data[state][time] == nil then data[state][time] = {} end
                if data[state][time][by] == nil then data[state][time][by] = {} end
                data[state][time][by][key] = total
            end
            ::continue::
        end
        ::done::
    end
    return require('cjson').encode(data)
end
return _M
