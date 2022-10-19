# 项目说明

## 0. 安装使用

* 本项目基于 OpenResty，所以需要先安装好 OpenResty, Linux各发行版安装详见[OpenResty® Linux 包](https://openresty.org/cn/linux-packages.html)
* 通过 OpenResty 的包管理器 `opm` 安装本项目 `opm get codiy1992/lua-resty-waf`
* 如下配置nginx, 即可正常工作

```nginx
http {
    # 在 http 区块添加如下设定
    lua_code_cache on;
    lua_need_request_body on;
    lua_shared_dict waf 32k;
    lua_shared_dict list 10m;
    lua_shared_dict limiter 10m;
    lua_shared_dict counter 10m;
    init_worker_by_lua_block {
        if ngx.worker.id() == 0 then
            ngx.timer.at(0, require("resty.waf").init)
        end
    }
    access_by_lua_block {
        local waf = require("resty.waf")
        waf.run({
            "filter",
            "limiter",
            "counter",
            "manager",
        })
    }
}
```

## 1. 几个共享内存

* `lua_shared_dict waf 32k;` 存放 waf 配置等信息
* `lua_shared_dict list 10m;` 存放ip/device/uid名单, 用于提供`matcher`之外的匹配功能
* `lua_shared_dict limiter 10m;` 存放请求频率限制信息
* `lua_shared_dict counter 10m;` 存放请求次数统计信息

## 2. 执行流程

* `init_worker_by_lua` 阶段, 读入默认配置, 并从 redis 获取最新配置信息, 合并两者放入共享内存
* `access_by_lua` 阶段, 从共享内存读取配置, 顺序执行对应模块

## 3. 配置的结构

配置由三大部分组成如下
* `matcher` 一些匹配规则, 可在各模块间共用, 用于匹配特定请求
* `response` 自定义响应格式, 可在各模块间共用, 用于waf模块内的http响应
* `modules` 模块配置, 包含 `filter`, `limiter`, `counter`, `manager` 四大模块

### 3.1 Matcher

在模块内根据HTTP请求的 `ip`, `uri`, `args`, `header`, `body`, `user_agent`, `referer` 等信息匹配请求, 匹配命中的请求将在模块内进行下一步操作比如,限制访问直接返回或者记录请求频次等

**matcher里的操作符(operator)**

* `*` 默认返回 `true`, 即默认匹配
* `=` 判断两个值否相等, 字符串将忽略大小写
* `==` 判断两个值是否相等, 大小写敏感
* `!=` 判断两个值是否不相等
* `≈` 判断字符串是否包含于另一字符串中, 或匹配正则
* `!≈` 判断字符串是否不包含在另一字符串中, 或不匹配正则
* `#` 判断某个值是否出现在`table`中
* `Exist` 判断某值是否不为`nil`
* `!Exist` or `!` 判断某值是否为`nil`

以下为内置的默认配置, 可以根据需求使用`redis`或者`/waf/config`接口进行配置:
```json
{
    "any": {}, // 匹配任意请求, 可以有其他名字, 如 `"*": {}`
    "attack_sql": {// 从args中匹配sql注入字符, 默认配置仅提供简单示例, 可以自行增加/修改配置
        "Args": {
            "name": ".*",
            "operator": "≈",
            "value": "select.*from"
        }
    },
    "attack_file_ext": {// 匹配URI中以特定字符结尾的请求
        "URI": {
            "value": "\\.(htaccess|bash_history|ssh|sql)$",
            "operator": "≈"
        }
    },
    "attack_agent": { // 匹配特定UserAgent请求
        "UserAgent": {
            "value": "(nmap|w3af|netsparker|nikto|fimap|wget)",
            "operator": "≈"
        }
    },
    "post": {
        "Method": {
            "value": "(put|post)",
            "operator": "≈"
        }
    },
    "trusted_referer": {
        "Method": {
            "value": {},
            "operator": "#"
        }
    },
    "wan": { // 匹配来自公网的请求
        "IP": {
            "value": "(10.|192.168|172.1[6-9].|172.2[0-9].|172.3[01].).*",
            "operator": "!≈"
        }
    },
    "app_id": { // 匹配头信息X-App-ID的值出现在value中的请求
        "Header": {
            "name": "x-app-id",
            "operator": "#",
            "value": [
                0
            ]
        }
    },
    "app_version": { // 匹配头信息X-App-Version的值出现在value中的请求
        "Header": {
            "name": "x-app-version",
            "operator": "#",
            "value": [
                "0.0.0"
            ]
        }
    }
}
```

### 3.2 Response

用于`waf`模块拒绝请求时候响应给客户端

默认配置如下, 可自行增加或修改配置
```json
{
    "403": { // 对于各模块规则中的`code`, 不需要与HTTP的`status code`对应
        "status": 403, // HTTP的`status code`
        "body": "{\"code\":\"403\", \"message\":\"403 Forbidden\"}",
        "mime_type": "application/json"
    }
}
```

### 3.3 Filter 模块

用于过滤请求,流程如下
* `matcher`匹配上的请求, 执行放行`accept`或者拒绝`block`操作
* 执行`accept`将请求交给下一模块处理
* 执行`block`将根据过滤规则`rule`中指定的`code` 匹配相应`response`作为返回

模块默认配置如下:
```json
{
    "enable": true, // 可配置关闭此模块, 默认开启
    "rules": [
        {
            "action": "block", // accept or block
            "matcher": "any", // 详见 matcher 说明
            "code": 403, // 执行block时用于匹配对应response
            "enable": true, // 规则开关
            "by": "ip:in_list" // Optional, 使用在nginx共享内存维护的名单(`list`)来扩展matcher功能
        },
        {
            "action": "block",
            "matcher": "any",
            "code": 403,
            "enable": true,
            "by": "device:in_list"
        },
        {
            "action": "block",
            "matcher": "any",
            "code": 403,
            "enable": true,
            "by": "uid:in_list"
        },
        {
            "enable": true,
            "action": "block",
            "matcher": "attack_sql",
            "code": 403
        },
        {
            "enable": true,
            "action": "block",
            "matcher": "attack_file_ext",
            "code": 403
        },
        {
            "enable": true,
            "action": "block",
            "matcher": "attack_agent",
            "code": 403
        },
        {
            "enable": false,
            "action": "block",
            "matcher": "app_id",
            "code": 403
        },
        {
            "enable": false,
            "action": "block",
            "matcher": "app_version",
            "code": 403
        }
    ]
}
```

### 3.4 limiter 模块

用于请求频率限制,对于匹配`matcher`的请求, 可基于`ip`,`uri`,`uid`,`device`及其组合建立频率控制规则

模块默认配置如下:
```json
{
    "enable": true, // 可配置关闭此模块, 默认开启
    "rules": [
        { // 每个IP对所有URI,每分钟至多通过60个请求, 超过则拒绝
            "time": 60, // 时间: 单位秒
            "code": 403, // 拒绝时用于匹配对应response的响应码
            "enable": false, // 默认关闭
            "count": 60, // 允许请求数
            "matcher": "any",
            "by": "ip"
        },
        { // 每个IP对单一URI,每分钟至多通过10个请求, 超过则拒绝
            "time": 60,
            "code": 403,
            "enable": false, // 默认关闭
            "count": 10,
            "matcher": "any",
            "by": "ip,uri"
        }
    ]
}
```

可用接口`/waf/module/limiter` 查询此模块信息
```shell
curl --location --request GET 'http://127.0.0.1/waf/module/limiter' \
--header 'Content-Type: application/json' \
--header 'Authorization: Basic d2FmOlRUcHNYSHRJNW13cQ==' \
--data-raw '{
    "count": 1, // 请求数量 >= 1
    "scale": 1024, // 数据规模设置为0可取全部统计数据,默认1024
    "q": "", // 查询匹配, 可以是字符串或者正则表达式
    "keys": [], // 指定查询特定key, 当指定此参数时, 参数q将失效
}'
```
![](https://s3.codiy.net/repo/lua-resty-waf/19154731.png?d=200x200)

### 3.5 counter 模块

统计请求次数,根据 `ip`, `uri`, `uid` `device`及其任意组合如`ip,uri`, `uri,ip`,来统计请求次数

模块默认配置如下:
```json
{
    "enable": true, // 可配置关闭此模块, 默认开启
    "rules": [
        { // 对于任意请求, 按IP统计请求次数, 默认关闭
            "enable": false,
            "matcher": "any",
            "time": 60,
            "by": "ip"
        },
        {// 对于任意请求, 按IP+URI统计请求次数, 默认关闭
            "enable": false,
            "matcher": "any",
            "time": 60,
            "by": "ip,uri"
        }
    ]
}
```

可用接口`/waf/module/limiter` 观察统计信息
```shell
curl --location --request GET 'http://127.0.0.1/waf/module/counter' \
--header 'Content-Type: application/json' \
--header 'Authorization: Basic d2FmOlRUcHNYSHRJNW13cQ==' \
--data-raw '{
    "count": 1, // 请求数量 >= 1
    "scale": 1024, // 数据规模设置为0可取全部统计数据,默认1024
    "q": "", // 查询匹配, 可以是字符串或者正则表达式
    "keys": [], // 指定查询特定key, 当指定此参数时, 参数q将失效
}'
```
![](https://s3.codiy.net/repo/lua-resty-waf/19155058.png?d=200x200)

### 3.6 manager 模块

用于 waf 的管理, 提供一系列以 `/waf` 开头的路由, 需要通过 Basic Authorizaton 认证
默认账号密码 `waf:TTpsXHtI5mwq` 或者指定头信息 `Authorization: Basic d2FmOlRUcHNYSHRJNW13cQ==`

| 路由 | METHOD | 用途 |
|-|-|-|
|`/waf/status`| GET | 获取状态信息 |
|`/waf/config`| GET | 获取当前配置 |
|`/waf/config`| POST | 临时变更配置| 在nginx重启或执行`/waf/config/reload` 后**失效** |
|`/waf/config/reload`| POST | 重载配置, 将使`/waf/config`提交的临时配置**失效** |
|`/waf/list`| GET | 查看当前`list`中的名单及其ttl |
|`/waf/list`| POST | 临时增加/修改名单, 在nginx重启或执行`/waf/list/reload`后**失效** |
|`/waf/list/reload`| POST | 重载名单配置, 将**覆盖**`/waf/list`提交的临时配置 |
|`/waf/module/counter`| GET | 查询请求计数器统计情况 |
|`/waf/module/limiter`| GET | 查询请求频次限制器情况 |

### 3.7 完整的默认配置

```json
{
    "matcher": {
        "attack_sql": {
            "Args": {
                "operator": "≈",
                "name": ".*",
                "value": "select.*from"
            }
        },
        "attack_file_ext": {
            "URI": {
                "value": "\\.(htaccess|bash_history|ssh|sql)$",
                "operator": "≈"
            }
        },
        "any": {},
        "attack_agent": {
            "UserAgent": {
                "value": "(nmap|w3af|netsparker|nikto|fimap|wget)",
                "operator": "≈"
            }
        },
        "app_id": {
            "Header": {
                "operator": "#",
                "name": "x-app-id",
                "value": [
                    0
                ]
            }
        },
        "method_post": {
            "Method": {
                "value": "(put|post|delete)",
                "operator": "≈"
            }
        },
        "app_version": {
            "Header": {
                "operator": "#",
                "name": "x-app-version",
                "value": [
                    "0.0.0"
                ]
            }
        },
        "trusted_referer": {
            "Method": {
                "value": {},
                "operator": "#"
            }
        },
        "wan": {
            "IP": {
                "value": "(10.|192.168|172.1[6-9].|172.2[0-9].|172.3[01].).*",
                "operator": "!≈"
            }
        }
    },
    "response": {
        "403": {
            "status": 403,
            "mime_type": "application/json",
            "body": "{\"code\":\"403\", \"message\":\"403 Forbidden\"}"
        }
    },
    "modules": {
        "manager": {
            "enable": true,
            "auth": {
                "pass": "TTpsXHtI5mwq",
                "user": "waf"
            }
        },
        "limiter": {
            "rules": [
                {
                    "matcher": "any",
                    "time": 60,
                    "count": 60,
                    "enable": false,
                    "by": "ip",
                    "code": 403
                },
                {
                    "matcher": "any",
                    "time": 60,
                    "count": 10,
                    "enable": false,
                    "by": "ip,uri",
                    "code": 403
                }
            ],
            "enable": true
        },
        "counter": {
            "rules": [
                {
                    "by": "ip",
                    "matcher": "any",
                    "time": 60,
                    "enable": false
                },
                {
                    "by": "ip,uri",
                    "matcher": "any",
                    "time": 60,
                    "enable": false
                }
            ],
            "enable": true
        },
        "filter": {
            "rules": [
                {
                    "matcher": "any",
                    "enable": true,
                    "by": "ip:in_list",
                    "action": "block",
                    "code": 403
                },
                {
                    "matcher": "any",
                    "enable": true,
                    "by": "device:in_list",
                    "action": "block",
                    "code": 403
                },
                {
                    "matcher": "any",
                    "enable": true,
                    "by": "uid:in_list",
                    "action": "block",
                    "code": 403
                },
                {
                    "code": 403,
                    "matcher": "attack_sql",
                    "action": "block",
                    "enable": true
                },
                {
                    "code": 403,
                    "matcher": "attack_file_ext",
                    "action": "block",
                    "enable": true
                },
                {
                    "code": 403,
                    "matcher": "attack_agent",
                    "action": "block",
                    "enable": true
                },
                {
                    "code": 403,
                    "matcher": "app_id",
                    "action": "block",
                    "enable": false
                },
                {
                    "code": 403,
                    "matcher": "app_version",
                    "action": "block",
                    "enable": false
                }
            ],
            "enable": true
        }
    }
}
```

## 4. 自定义配置(临时生效, 通过HTTP接口)

### 4.1 自定义配置config

自定义配置将以**覆盖模式**和默认配置**合并**, **在nginx重启或者通过接口`/waf/config/reload`重载配置后失效**

```shell
curl --request POST 'http://127.0.0.1/waf/config' \
--header 'Content-Type: application/json' \
--header 'Authorization: Basic d2FmOlRUcHNYSHRJNW13cQ==' \
--data-raw '{
    "modules": {
        "counter": {
            "enable": true,
            "rules": [
                {
                    "matcher": "any",
                    "by": "ip",
                    "time": 86400,
                    "enable": true
                },
                {
                    "matcher": "any",
                    "by": "ip,uri",
                    "time": 86400,
                    "enable": true
                }
            ]
        }
    }
}'
```

### 4.2 自定义配置list

自定义配置将以**覆盖模式**和当前`list`**合并**

```json
curl --location --request POST 'http://127.0.0.1/waf/list' \
--header 'Content-Type: application/json' \
--header 'Authorization: Basic d2FmOlRUcHNYSHRJNW13cQ==' \
--data-raw '{
    "127.0.0.1": 6000, // 将IP:127.0.0.1放入名单, ttl为6000秒
    "30000000": 86400,
    "832489A9-2442-4E87-BD6B-24D85B05FB25": 3600 
}'
```


## 5. 自定义配置(持续生效, 通过Redis)

默认读取环境变量`REDIS_HOST`,`REDIS_PORT`,`REDIS_DB` 来获取redis配置, 否则从 `/data/.env` 读取

### 5.1 自定义配置config

* config存放在 redis 中以 `waf:config:` 为开头的`hset` 中
* 目前支持几个配置项, 
    * **`waf:config:matcher`**
    * **`waf:config:response`**
    * **`waf:config:modules.manager.auth`**
    * **`waf:config:modules.filter.rules`**
    * **`waf:config:modules.limiter.rules`**
    * **`waf:config:modules.counter.rules`**
    * **`waf:config:modules.filter`**(仅支持对`enable`进行设置)
    * **`waf:config:modules.limiter`**(仅支持对`enable`进行设置)
    * **`waf:config:modules.counter`**(仅支持对`enable`进行设置)
* 如在`redis`中执行命令 **`hset waf:config:modules.counter enable false`**
* 在 redis 配置后需执行 **`/waf/config/reload`** 将配置与默认配置进行合并,方可生效

### 5.2 自定义配置list

* 自定义的list放在 redis 中以 **`waf:list`** 为key的 `zset` 中
* 如在`redis`中执行命令 **`zadd waf:list 86400 127.0.0.1`**
* 在 redis 配置后需执行 **`/waf/list/reload`** 将配置与当前共享内存名单合并后生效

## 6. 应用场景示范

### 6.1 维护IP/uid/device名单

**示例一: 限制访问**(默认配置已经在`filter`模块中开启了对`list`名单的支持, 默认为黑名单)
```shell
// 限制设备号`X-Device-ID` = `f14268d542f919d5` 访问, 时间为 86400 秒
zadd waf:list 86400 f14268d542f919d5
// 限制IP `13.251.156.174` 的访问, 时间为 3600 秒
zadd waf:list 3600 13.251.156.174
// 重载配置
curl --request POST 'http://127.0.0.1/waf/list/reload' \
    --header 'Authorization: Basic d2FmOlRUcHNYSHRJNW13cQ=='
```
**示例二**: **允许访问** (修改默认配置,将`list`用作白名单)

在 redis 中执行
```shell
hset waf:config:modules.filter.rules 1 '{"matcher":"any","action":"accept","enable":true,"by":"ip:in_list"}'
hset waf:config:modules.filter.rules 0 '{"matcher":"any","action":"block","enable":true,"by":"ip:not_in_list"}'
zadd waf:list 86400 13.251.156.174
```
重载配置及名单后生效
```shell
curl --request POST 'http://127.0.0.1/waf/config/reload' \
    --header 'Authorization: Basic d2FmOlRUcHNYSHRJNW13cQ=='
curl --request POST 'http://127.0.0.1/waf/list/reload' \
    --header 'Authorization: Basic d2FmOlRUcHNYSHRJNW13cQ=='
```

### 6.2 配置 matcher

```shell
// 匹配头部参数 X-App-ID = 4 的请求
hset waf:config:matcher app_id '{"Header":{"operator":"#","name_value":"x-app-id","value":[4],"name_operator":"="}}'
// 匹配 UserAgent 包含 "postman" 的请求
hset waf:config:matcher attack_agent '{"UserAgent":{"value":"(postman)","operator":"≈"}}'
// 重载配置
curl --request POST 'http://127.0.0.1/waf/config/reload' \
--header 'Authorization: Basic d2FmOlRUcHNYSHRJNW13cQ=='
```
### 6.3 配置 response

```shell
// Redis 命令
hset waf:config:response 503 '{"status":503,"mime_type":"application/json","body":"{\"code\":\"503\", \"message\":\"Custom Message\"}"}'
// 重载配置
curl --request POST 'http://127.0.0.1/waf/config/reload' \
    --header 'Authorization: Basic d2FmOlRUcHNYSHRJNW13cQ=='
```
### 6.4 modules.filter.rules

```shell
// Redis 命令
hset waf:config:modules.filter.rules 0 '{"matcher":"any","action":"block","enable":true,"by":"ip:not_in_list"}'
// 重载配置
curl --request POST 'http://127.0.0.1/waf/config/reload' \
    --header 'Authorization: Basic d2FmOlRUcHNYSHRJNW13cQ=='
```

### 6.5 modules.limiter.rules

```shell
// Redis 命令
hset waf:config:modules.limiter.rules 0 '{"code":403,"count":60,"time":60,"matcher":"any","by":"ip","enable":true}'
// 重载配置
curl --request POST 'http://127.0.0.1/waf/config/reload' \
    --header 'Authorization: Basic d2FmOlRUcHNYSHRJNW13cQ=='
```

### 6.6 modules.counter.rules

```shell
// Redis 命令
hset waf:config:modules.counter.rules 0 '{"matcher":"any","by":"ip,uri","time":60,"enable":true}'
// 重载配置
curl --request POST 'http://127.0.0.1/waf/config/reload' \
    --header 'Authorization: Basic d2FmOlRUcHNYSHRJNW13cQ=='
```

### 6.7 修改 modules.manager

```shell
// Redis 命令
hset waf:config:modules.manager.auth '{"user": "test", "pass": "123" }'
// 重载配置
curl --request POST 'http://127.0.0.1/waf/config/reload' \
    --header 'Authorization: Basic d2FmOlRUcHNYSHRJNW13cQ=='
```

## 7. 参考项目

* [VeryNginx](https://github.com/alexazhou/VeryNginx)

## 8. OpenResty 一些知识

### 8.1 模块里的变量

* 处于模块级别的变量在每个 worker 间是相互独立的，且在 worker 的生命周期中是只读的, 只在第一次导入模块时初始化.
* 模块里函数的局部变量,则在调用时初始化

### 8.2 `ngx.var.*`

* [lua-nginx-module#ngxvarvariable](https://github.com/openresty/lua-nginx-module#ngxvarvariable)
* 使用代价较高
* 续先预定义才可使用(可在server 或 location 中定义)
* 类型只能是字符串
* 内部重定向会破坏原始请求的 `ngx.var.*` 变量 (如 `error_page`, `try_files`, `index` 等)

### 8.3 `ngx.ctx.*`

* [lua-nginx-module#ngxctx](https://github.com/openresty/lua-nginx-module#ngxctx)
* 内部重定向会破坏原始请求的 `ngx.ctx.*` 变量 (如 `error_page`, `try_files`, `index` 等)

### 8.4 `ngx.shared.DICT.*`

* 可在不同 worker 间共享数据
* [lua-nginx-module#ngxshareddict](https://github.com/openresty/lua-nginx-module#ngxshareddict)
* [data-sharing-within-an-nginx-worker](https://github.com/openresty/lua-nginx-module/#data-sharing-within-an-nginx-worker)


### 8.5 `resty.lrucache`

* [lua-resty-lrucache](https://github.com/openresty/lua-resty-lrucache)
* 不同 worker 间数据相互隔离
* 同一 worker 不同请求共享数据

[https://github.com/openresty/lua-nginx-module/#data-sharing-within-an-nginx-worker](https://github.com/openresty/lua-nginx-module/#data-sharing-within-an-nginx-worker)

### 8.6 table 与 metatable

[https://www.cnblogs.com/liekkas01/p/12728712.html](https://www.cnblogs.com/liekkas01/p/12728712.html)


## 9. 一些相关链接

* OpenResty LuaJIT2 [https://github.com/openresty/luajit2#tablenkeys](https://github.com/openresty/luajit2#tablenkeys)
* Lua 手册[Lua 5.4](https://www.lua.org/manual/5.4/)
* Resty 模块[OpenResty](https://openresty.org/cn/linux-packages.html)
* Resty 模块[Lua-Resty-JWT](https://github.com/SkyLothar/lua-resty-jwt)

