local _M = {}
local cjson = require("cjson")
local shared = require("resty.waf.shared")

function _M.run(modules)
    local config = shared.get_config()
    for i, module in ipairs(modules) do
        require("resty.waf.modules." .. tostring(module)).run(config)
    end
end

function _M.init()
    shared.reload_config()
    shared.reload_list()
end

return _M
