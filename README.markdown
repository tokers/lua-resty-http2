Name
====

lua-resty-http2 - The HTTP/2 Protocol (Client Side) Implementation for OpenResty. Still Pending.

![Build Status](https://travis-ci.org/tokers/lua-resty-http2.svg?branch=master)

Table of Contents
=================

* [Name](#name)
* [Status](#status)
* [Synopsis](#synopsis)
* [Description](#description)
* [API Implemented](#api-implemented)
* [Author](#author)
* [Copyright and License](#copyright-and-license)
* [See Also](#see-also)

Status
======

This Lua module is currently considered experimental.

Synopsis
========

```lua
local http2 = require "resty.http2"

local host = "127.0.0.1"
local port = 8080
local sock = ngx.socket.tcp()
local ok, err = sock:connect(host, port)
if not ok then
    ngx.log(ngx.ERR, "failed to connect ", host, ":", port, ": ", err)
    return
end

-- Prepare request headers and body
-- body can be a Lua string or a Lua function
local prepare_request = function()
    local headers = {
        { name = ":authority", value = "test.com" },
        { name = ":method", value = "GET" },
        { name = ":path", value = "/index.html" },
        { name = ":scheme", value = "http" },
        { name = "accept-encoding", value = "gzip" },
        { name = "user-agent", value = "example/client" },
    }

    return headers
end

local on_headers_reach = function(ctx, headers)
    -- Process the response headers
end

local on_data_reach = function(ctx, data)
    -- Process the response body
end

local opts = {
    ctx = sock,
    recv = sock.receive,
    send = sock.send,
    prepare_request = prepare_request,
    on_headers_reach = on_headers_reach,
    on_data_reach = on_data_reach,
}

local client, err = http2.new(opts)
if not client then
    ngx.log(ngx.ERR, "failed to create HTTP/2 client: ", err)
    return
end

local ok, err = client:process()
if not ok then
    ngx.log(ngx.ERR, "client:process() failed: ", err)
    return
end


sock:close()
```

As a more formal exemplify, please read the [util/example.lua](util/example.lua).

Description
===========

This pure Lua library implements the client side HTTP/2 protocol, but not all
details are covered, for example, the stream dependencies is maintained but
never used.

[Back to TOC](#table-of-contents)


API Implemented
===============

[Back to TOC](#table-of-contents)

Author
======

Alex Zhang (张超) zchao1995@gmail.com, UPYUN Inc.

[Back to TOC](#table-of-contents)


Copyright and License
=====================

Please see the [LICENSE](LICENSE) file.

[Back to TOC](#table-of-contents)

See Also
========

* upyun-resty: https://github.com/upyun/upyun-resty
* lua-resty-httpipe: https://github.com/timebug/lua-resty-httpipe
* lua-resty-requests: https://github.com/tokers/lua-resty-requests

[Back to TOC](#table-of-contents)
