local _M = {}

local host = os.getenv("REDIS_HOST")
local port = os.getenv("REDIS_PORT")
local database = os.getenv("REDIS_DB")

if host == nil then
    local f = io.open('/data/.env', "r")
    if f ~= nil then
        local content = f:read("*all")
        f:close()
        _,_,host = string.find(content, "REDIS_HOST=([^%s]+)")
        _,_,port = string.find(content, "REDIS_PORT=([^%s]+)")
        _,_,database = string.find(content, "REDIS_DB=([^%s]+)")
        if database == nil then
            _,_,database = string.find(content, "REDIS_DATABASE=([^%s]+)")
        end
    end
end

if host == nil then
    host = '127.0.0.1'
end

if port == nil then
    port = 6379
end

if database == nil then
    database = 0
end

function _M.exec(fn, ...)
    local redis = require("resty.redis")
    local rds = redis:new()

    rds:set_timeouts(1000, 1000, 1000)

    local ok, err = rds:connect(host, port)
    if not ok then
        if string.find(err, "no resolver") then
            local address = require("resty.waf.lib.resolver").query(host)
            local ok, err = rds:connect(address, port)
            if not ok then
                ngx.log(ngx.ERR, "failed to connect: ", err)
                return
            end
        else
            ngx.log(ngx.ERR, "failed to connect: ", err)
            return
        end
    end

    rds:select(database)

    fn(rds, ...)

    -- pool keepalive_timeout = 10s, pool_size = ngx.worker.count()
    local ok, err = rds:set_keepalive(10000, ngx.worker.count())
    if not ok then
        ngx.log(ngx.ERR, "failed to set keepalive: ", err)
        return
    end
end

return _M
