local _M = {}

local nameserver = nil
local f = assert(io.open('/etc/resolv.conf', "r"))
local content = f:read("*all")
f:close()
_, _, nameserver = string.find(content, "nameserver%s+(%d+%.%d+%.%d+%.%d+)")


function _M.query(domain)
    local resolver = require("resty.dns.resolver")
    if nameserver == nil then
        ngx.log(ngx.ERR, "failed to get nameserver")
        return
    end
    local r, err = resolver:new{
        nameservers = { {nameserver, 53} },
        retrans = 5,
        timeout = 2000,
        no_random = true,
    }
    if not r then
        ngx.log(ngx.ERR, "failed to instantiate the resolver: ", err)
        return
    end

    local answers, err, tries = r:query(domain, nil, {})
    if not answers then
        ngx.log(ngx.ERR, "failed to query the DNS server: ", err)
        ngx.log(ngx.ERR, "retry historie:\n  ", table.concat(tries, "\n  "))
        return
    end

    if answers.errcode then
        ngx.log(ngx.ERR, "server returned error code: ", answers.errcode,
                ": ", answers.errstr)
        return
    end

    local address = nil
    for i, ans in ipairs(answers) do
        address = ans.address or ans.cname
    end
    return address
end

return _M
