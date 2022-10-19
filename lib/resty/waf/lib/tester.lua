local _M = {}

local tester = {}

function _M.test( matcher )
    if matcher == nil then
        return false
    end

	for name, v in pairs( matcher ) do
        if tester[name] ~= nil then
            if tester[name]( v ) ~= true then
                return false
			end
		end
	end

	return true
end

--test_var is a basic test method, used by other test method
function _M.test_var( match_operator, match_value, target_var )

   if match_operator == "=" then
        if type(target_var) == 'string' and type(match_value) == 'string' then
            if string.lower(target_var) == string.lower(match_value) then
                return true
            end
        else
            if target_var == match_value then
                return true
            end
        end
    elseif match_operator == "==" then
        if target_var == match_value then
            return true
        end
    elseif match_operator == "*" then
        return true
    elseif match_operator == "#" then
        if type(match_value) == 'table' then
            for k, v in pairs(match_value) do
                if string.lower(v) == string.lower(target_var) then
                    return true
                end
            end
        end
    elseif match_operator == "!=" then
        if target_var ~= match_value then
            return true
        end
    elseif match_operator == '≈' then
        if type(target_var) == 'string' and ngx.re.find( target_var, match_value, 'isjo' ) ~= nil then
            return true
        end
    elseif match_operator == '!≈' then
        if type(target_var) ~= 'string' or ngx.re.find( target_var, match_value, 'isjo' ) == nil then
            return true
        end
    elseif match_operator == 'Exist' then
        if target_var ~= nil then
            return true
        end
    elseif match_operator == '!Exist' then
        if target_var == nil then
            return true
        end
    elseif match_operator == '!' then
        if target_var == nil then
            return true
        end
    end

    return false
end


--test a group of var in table with a condition
function _M.test_many_var( var_table, condition )

    local find = ngx.re.find
    local test_var = _M.test_var

    local name_operator = condition['name_operator'] or "="
    local name_value = condition['name']
    local operator = condition['operator'] or condition['value_operator']
    local value = condition['value']

     -- Insert !Exist Check here as it is only applied to operator
    if operator == '!Exist' then
        for k, v in pairs(var_table) do
            if test_var ( name_operator, name_value, k ) == true then
                return false
            end
        end
        return true
    else
     -- Normal process
        for k, v in pairs(var_table) do
            if test_var( name_operator, name_value, k ) == true then
                if test_var( operator, value, v ) == true then -- if any one value match the condition, means the matcher has been hited
                    return true
                end
            end
        end
    end

    return false
end

function _M.test_uri( condition )
    local uri = ngx.var.uri;
    -- ngx.log(ngx.ERR, uri);
    return _M.test_var( condition['operator'], condition['value'], uri )
end

function _M.test_ip( condition )
    local ipv4 = ngx.req.get_headers()["X-Real-IP"]
    if ipv4 == nil then
        ipv4 = ngx.req.get_headers()["X-Forwarded-For"]
    end
    if ipv4 == nil then
        ipv4 = ngx.var.remote_addr
    end
    return _M.test_var( condition['operator'], condition['value'], ipv4 )
end

function _M.test_ua( condition )
    local http_user_agent = ngx.var.http_user_agent;
    return _M.test_var( condition['operator'], condition['value'], http_user_agent )
end

function _M.test_referer( condition )
    local http_referer = ngx.var.http_referer;
    return _M.test_var( condition['operator'], condition['value'], http_referer )
end

--uncompleted
function _M.test_method( condition )
    local method_name = ngx.req.get_method()
    return _M.test_var( condition['operator'], condition['value'], method_name )
end

function _M.test_args( condition )
    local find = ngx.re.find
    local test_var = _M.test_var

    local name_operator = condition['name_operator']  or '≈'
    local name_value = condition['name']
    local operator = condition['operator'] or condition['value_operator']
    local value = condition['value']

    --handle args behind uri
    for k,v in pairs( ngx.req.get_uri_args()) do
        if test_var( name_operator, name_value, k ) == true then
            if type(v) == "table" then
                for arg_idx,arg_value in ipairs(v) do
                    if test_var( operator, value, arg_value ) == true then
                        return true
                    end
                end
            else
                if test_var( operator, value, v ) == true then
                    return true
                end
            end
        end
    end

    ngx.req.read_body()
    --ensure body has not be cached into temp file
    if ngx.req.get_body_file() ~= nil then
        return false
    end

    local body_args, err  = require('cjson.safe').decode(ngx.req.get_body_data())
    if body_args == nil then
        body_args,err = ngx.req.get_post_args()
        if body_args == nil then
            ngx.say("failed to get post args: ", err)
            return false
        end
    end
    --check args in body
    for k,v in pairs( body_args ) do
        if test_var( name_operator, name_value, k ) == true then
            if type(v) == "table" then
                for arg_idx,arg_value in ipairs(v) do
                    if test_var( operator, value, arg_value ) == true then
                        return true
                    end
                end
            else
                if test_var( operator, value, v ) == true then
                    return true
                end
            end
        end
    end

    return false
end

function _M.test_host( condition )
    local hostname = ngx.var.host
    return _M.test_var( condition['operator'], condition['value'], hostname )
end

function _M.test_header( condition )
    local header_table = ngx.req.get_headers()
    return _M.test_many_var( header_table, condition )
end

tester["URI"] = _M.test_uri
tester["IP"] = _M.test_ip
tester["UserAgent"] = _M.test_ua
tester["Method"] = _M.test_method
tester["Args"] = _M.test_args
tester["Referer"] = _M.test_referer
tester["Host"] = _M.test_host
tester["Header"] = _M.test_header


return _M
