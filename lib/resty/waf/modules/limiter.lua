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

    local matcher_list = config.matchers

    local keys = {}
    for i, rule in ipairs( config.modules.limiter.rules ) do
        local enable = rule['enable']
        local matcher = matcher_list[ rule['matcher'] ]
        if enable == true and request_tester.test( matcher ) == true then

            local time = rule['time'] or 60
            local count = rule['count'] or 60
            local key = tostring(count) .. "/" .. tostring(time) .. ":" .. rule['matcher'] .. ";"
            local fields = {}
            if rule['by'] ~= nil then
                for by in string.gmatch(rule['by'], '[^,]+') do
                    if by == 'ip' then
                        local client_ip = comm.get_client_ip()
                        if client_ip == nil then
                            goto continue
                        end
                        fields['ip'] = "ip:" .. client_ip .. ';'
                    elseif by == 'uri' then
                        fields['uri'] = "uri:" .. ngx.var.uri .. ';'
                    elseif by == 'uid' then
                        local uid = comm.get_user_id()
                        if uid == 0 then
                            goto continue
                        end
                        fields['uid'] = "uid:" .. uid .. ';'
                    elseif by == 'device' then
                        local device_id = comm.get_device_id()
                        if device_id == nil then
                            goto continue
                        end
                        fields['device'] = "device:" .. device_id .. ';'
                    else
                        goto continue
                    end
                end
                for _, field in ipairs({'ip', 'uid', 'device', 'uri'}) do
                    if fields[field] ~= nil then
                        key = key .. fields[field]
                    end
                end
            end

            if keys[key] == nil then
                local count_now = limiter:get(key) or 0
                if (count_now + 1) > tonumber(count) then
                    _M.response(config, rule)
                else
                    keys[key] = limiter:incr( key, 1, 0, tonumber(time) )
                end
            end
        end
        ::continue::
    end
end

function _M.query()
    local limiter = ngx.shared.limiter
    local data = {}
    local inputs,err = require('cjson.safe').decode(ngx.req.get_body_data() or '{}')
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
            local total = limiter:get(v)
            if total ~= nil then
                local time,matcher, by, key = v:match"^([^:]+):([^;]+);(.+):([^:]*)$"
                if key == nil then
                    time, matcher = v:match"^([^:]+):([^;]+);$";
                end
                if data[time] == nil then data[time] = {} end
                if data[time][matcher] == nil then data[time][matcher] = {} end
                if by ~= nil and key ~= nil then
                    if data[time][matcher][by] == nil then data[time][matcher][by] = {} end
                    data[time][matcher][by][key] = total
                else
                    data[time][matcher] = total
                end
           end
        end
    else
        if inputs['key'] ~= nil and type(inputs['key']) == 'string' then
            if comm.in_array(inputs['key'], {'ip', 'uid', 'device', 'uri'}) ~= true then
                inputs['key'] = nil
            end
        end
        local i = 0
        local keys = limiter:get_keys(scale)
        for _,v in ipairs(keys) do
            if inputs['q'] ~= nil and type(inputs['q']) == 'string' and inputs['q'] ~= '' then
                if ngx.re.find(v, inputs['q'], 'isjo') == nil then
                    goto continue
                end
            end
            i = i + 1
            if i > 10240 then
                goto done
            end
            local total = limiter:get(v)
            if total >= count then
                local time,matcher, by, key = v:match"^([^:]+):([^;]+);(.+):([^:]*)$"
                if key == nil then
                    time, matcher = v:match"^([^:]+):([^;]+);$";
                end
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
                if data[time] == nil then data[time] = {} end
                if data[time][matcher] == nil then data[time][matcher] = {} end
                if by ~= nil and key ~= nil then
                    if data[time][matcher][by] == nil then data[time][matcher][by] = {} end
                    data[time][matcher][by][key] = total
                else
                    data[time][matcher] = total
                end
            end
            ::continue::
        end
        ::done::
    end
    return require('cjson').encode(data)
end

function _M.response(config, rule)
    require('resty.waf.modules.counter').run(config, 'limited')
    require('resty.waf.modules.sampler').run(config, 'limited', rule)
    local response_list = config.responses
    response = response_list[tostring(rule['code'] or nil)]
    if response ~= nil then
        ngx.status = tonumber(response['status'] or ngx.HTTP_FORBIDDEN)
        ngx.header.content_type = response['mime_type'] or 'application/json'
        ngx.say( response['body'] or '{"code": 403, "message":"Forbidden"}')
        ngx.exit(ngx.HTTP_OK)
    end
    data = {
        ['code'] = ngx.HTTP_FORBIDDEN,
        ['message'] = 'Forbidden'
    }
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.header.content_type = 'application/json'
    ngx.say(require('cjson').encode(data))
    ngx.exit(ngx.HTTP_FORBIDDEN)
end

return _M
