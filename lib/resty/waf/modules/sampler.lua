local _M = {}

local comm = require "resty.waf.lib.comm"
local request_tester = require "resty.waf.lib.tester"
local sampler = ngx.shared.sampler
local cjson_safe = require('cjson.safe')

function _M.run(config, state, prev_rule)

    if ngx.req.is_internal() == true then
        return
    end

    if config.modules.sampler.enable ~= true then
        return
    end

    local matcher_list = config.matchers

    if state == nil or type(state) ~= 'string' or state == '' then
        state = 'accepted'
    end

    for i,rule in ipairs(config.modules.sampler.rules) do
        if rule['enable'] == true and rule['matcher'] == state then
            local key =  state .. ":" .. prev_rule['matcher'] .. "@" .. (prev_rule['by'] or '')
            if  state == 'limited' then
                local time = rule['time'] or 60
                local count = rule['count'] or 60
                key =  key .. "(" ..tostring(count) .. "/" .. tostring(time) .. ")"
            end
            _M.record(key, rule['size'] or 10)
            goto done
        end
    end
    for i,rule in ipairs(config.modules.sampler.rules) do
        local enable = rule['enable']
        local matcher = matcher_list[ rule['matcher'] ]
        if enable == true and request_tester.test( matcher ) == true then
            local key =  state .. ":" .. rule['matcher']
            _M.record(key, rule['size'] or 10)
        end
    end
    ::done::
end

function _M.record(key, size)
    local total = sampler:llen(key)
    if total ~= nil then
        if total >= size then
            local rand = math.random(100)
            if rand <= 25 then
                return
            end
        end
    end
    ngx.req.read_body()
    data = {}
    data['uri'] = ngx.var.uri
    data['http'] = ngx.req.http_version()
    data['method'] = ngx.req.get_method()
    data['headers'] = ngx.req.get_headers()
    data['agent'] = ngx.var.http_user_agent or ''
    data['referer'] = ngx.var.http_referer or ''
    data['ipv4'] = comm.get_client_ip() or ''
    data['uid'] = comm.get_user_id()
    data['device'] = comm.get_device_id() or ''
    data['args'] = ngx.req.get_uri_args()
    local body, _  = cjson_safe.decode(ngx.req.get_body_data())
    if body == nil then
        body = ngx.req.get_post_args()
    end
    data['body'] = body
    local total = sampler:lpush(key, cjson_safe.encode(data))
    if total > size then
        sampler:rpop(key)
    end
end

function _M.query()
    local data = {}
    local inputs, err = require('cjson.safe').decode(ngx.req.get_body_data() or '{}')
    if inputs == nil then comm.error(err) end
    local q = nil
    if inputs['q'] ~= nil and type(inputs['q']) == 'string' and inputs['q'] ~= '' then
        q = inputs['q']
    end
    local pop = true
    if inputs['pop'] ~= nil and type(inputs['pop']) == 'boolean' and inputs['pop'] == false then
        pop = false
    end
    local all = false
    if inputs['all'] ~= nil and type(inputs['all']) == 'boolean' and inputs['all'] == true then
        all = true
    end

    local keys = sampler:get_keys(0)
    for _,key in ipairs(keys) do
        if q ~= nil and ngx.re.find(key, q, 'isjo') == nil then
            goto continue
        end
        local total = 1
        if all then total = sampler:llen(key) end
        for i=1,total,1 do
            local v = sampler:rpop(key)
            if pop == false then
                sampler:lpush(key, v)
            end
            if data[key] == nil then data[key] = {} end
            table.insert(data[key], cjson_safe.decode(v))
        end
        ::continue::
    end
    return require('cjson').encode(data)
end

return _M
