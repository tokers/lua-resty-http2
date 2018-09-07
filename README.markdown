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
  * [resty.http2](#restyhttp2)
    * [http2.new](#http2new)
    * [client:process](#clientprocess)
    * [client:keepalive](#clientkeepalive)
  * [resty.http2.protocol](#restyhttp2protocol)
    * [protocol.session](#protocolsession)
    * [session:adjust_window](#sessionadjust_window)
    * [session:frame_queue](#sessionframe_queue)
    * [session:flush_queue](#sessionflush_queue)
    * [session:submit_request](#sessionsubmit_request)
    * [session:submit_window_update](#sessionsubmit_window_update)
    * [session:recv_frame](#sessionrecv_frame)
    * [session:close](#sessionclose)
    * [session:detach](#sessiondetach)
    * [session:attach](#sessionattach)
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

There are some inherent limitations which are not solved, however.

**Cannot be used over the SSL/TLS handshaked connections**. The `tcpsock:sslhandshake` doesn't support the ALPN or NPN extensions,
so currently only the plain connections can be used, the library will start
HTTP/2 session with sending the connection preface, i.e. the string:

```
PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n
```

Perhaps this awkward situation can be solved in the future if the ALPN or NPN extensions are supported.

**Only a HTTP request can be submitted**. Currently the implemented APIs support for submitting just one HTTP request. PRs are welcome to solve this.

**HTTP/2 session reuse**. The HTTP/2 protocol is designed as persistent, while the Cosocket object is binded to a specific HTTP request. One has to close the Cosocket object or set it alive before the request is over, this model is conflict with the reuse of HTTP/2 session, just a work-around way can solve this, see [client:keepalive](#client:keepalive) for the details.

[Back to TOC](#table-of-contents)


API Implemented
===============

[Back to TOC](#table-of-contents)


resty.http2
-----------

To load this module, just do this:

```lua
local http2 = require "resty.http2"
```

[Back to TOC](#table-of-contents)

### http2.new

**syntax**: *local client, err = http2.new(opts)*

Creates a HTTP/2 client by specifying the options. In case of failure, `nil`
and a error message string will be returned.

The sole parameter `opts`, which is a Lua table, contains some fields:

* `recv`, a Lua function which used to read bytes;

* `send`, a Lua function which used to send bytes;

* `ctx`, an opaque data, acts as the callers' context;

The `recv` and `send` function will be called like:

```lua
local data, err = recv(ctx, size)
local ok, err = send(ctx, data)
```

* `preread_size`, a Lua number which influences the peer's initial send window size (advertise through the SETTINGS frame), default is `65535`;

* `max_concurrent_stream`, a Lua number which limits the max concurrent streams in a HTTP/2 session, default is `128`;

* `max_frame_size`, a Lua number which limits the max frame size that peer can send, default is `16777215`.

* `prepare_request`, a Lua function, which is used to generate the pending HTTP request headers and request body, it will be called like:

```lua
local headers, body = prepare_request(ctx)
```

the `headers`, should be a hash-like Lua table represent the HTTP request headers, it is worth noting that this library doesn't take care of the HTTP headers' semantics, so it's callers' responsibility to supply this, and callers should transform any necessary pesudo headers. For example, `:authority` should be passed rather `Host`.

The `body`, can be a Lua string represents the HTTP request body. It also can be a Lua function to implement the stream-way uploading. When `body` is a Lua function, it will be called like:

```lua
local part_data, last, err = body(size)
```

In case of failure, `body` should provide the 3rd return value `err` to tell this library that some fatal errors happen, then the session will be aborted immediately.

When all data has been generated, the 2nd return value `last` should be provided, and it's value must be `true`.

* `on_headers_reach`, a Lua function, as a callback which will be called when complete HTTP response headers are received, it will be called like:

```lua
local abort = on_headers_reach(ctx, headers)
```

The 2nd parameter `headers` is a hash-like Lua table which represents the HTTP response headers received from peer.

`on_headers_reach` can decide whether aborts the HTTP/2 session by returning a boolean value `abort` to the library, the HTTP/2 session will be aborted if `on_headers_reach` returns a true value.

* `on_data_reach`, a Lua function, acts as the callback which will be called when response body are received every time, it will be called like:

```lua
local abort = on_data_reach(ctx, data)
```

The 2nd parameter `data` is a Lua string represents the HTTP respose body received this time.

The meaning of return value is same as the `on_headers_reach`.

* `key`, a Lua string which represents which cached HTTP/2 session the callers want to resue, if not found, new HTTP/2 session will be created. See [client:keepalive](client:keepalive) for more details.

[Back to TOC](#table-of-contents)

### client:process

**syntax**: *local ok, err = client:process()*

Starts the current HTTP/2 session, this function will return once:

* any protocol errors or connection errors happen;
* the HTTP/2 session closed due to GOAWAY frame was received or sent;
* the underlying stream (deliverying callers' HTTP request) is end or reset;

In case of any abormal return, `ok` will be `nil` and `err` will describe the error message.

[Back to TOC](#table-of-contents)

### client:keepalive

**syntax**: *client:keepalive(key)*

Caches current HTTP/2 session for the reuse, note malformed HTTP/2 session will never be cached. The HTTP/2 session will detached from the connection, precisely, the current Cosocket object.

The detached HTTP/2 session will be saved in an internal hash-like table, the unique parameter `key` will be used to index this session when callers want to reuse it.

After set this session as alive, callers should also set the Cosocket object as keepalive.

There is an inherent limitation between the mapping of HTTP/2 session and the underlying connection. A HTTP/2 session can only be used in a TCP connection becasue it is stateful, if callers store the connection to a pool which caches multiple connections, the binding relations is lost, since which connection is picked to the Cosocket object is not sure, thereby which HTTP/2 session shall be matched is also unknown.

This is no elegant way to solve this, unless the Cosocket model can assign an identifier to the underlying connection. Now what callers can do is use the single size connection pool to bypass this limitation, for example:

```lua
...

sock:connect(host, port, { pool = "h2" })

...

sock:setkeepalive(75, 1)
client:keepalive("test")
```

[Back to TOC](#table-of-contents)

resty.http2.protocol
-------------------

To load this module, just do this:

```lua
local protocol = require "resty.http2.protocol"
```

[Back to TOC](#table-of-contents)

### protocol.session

**syntax**: *local session, err = protocol.session(recv, send, ctx, preread_size?, max_concurrent_stream?, max_frame_size?)*

Creates a new HTTP/2 session, in case of failure, `nil` and a Lua string which
describes the error reason will be given.

The meaning of every parameter is same as these described in [http2.new](#http2new).

The initial SETTINGS frame and WINDOW_UPDATE frame will be sent before this
function returns.

[Back to TOC](#table-of-contents)

### session:adjust_window

**syntax**: *local ok = session:adjust_window(delta)*

Adjusts each streams send window size, stream will be reset if the altered send window size exceeds MAX_WINDOW_SIZE, in this case, `ok` will be `nil`.

[Back to TOC](#table-of-contents)

### session:frame_queue

**syntax**: *session:frame_queue(frame)*

Appends `frame` to current session's output queue.

[Back to TOC](#table-of-contents)

### session:flush_queue

**syntax**: *local ok, err = session:flush_queue()*

Packs and flushes the queueing frames, in case of failure, `nil` and a Lua
string which described the error reason will be given.

[Back to TOC](#table-of-contents)

### session:submit_request

**syntax**: *local ok, err = session:submit_request(headers, no_body, priority?, pad?)*

Submits a HTTP request to the current HTTP/2 session, in case of failure, `nil`
and a Lua string which described the error reason wil be given.

Meaning of each parameter:

* `headers`, should be a hash-like Lua table represent the HTTP request headers, it is worth noting that this library doesn't take care of the HTTP headers' semantics, so it's callers' responsibility to supply this, and callers should transform any necessary pesudo headers. For example, `:authority` should be passed rather `Host`;

* `no_body`, a boolean value, indicates whether this request has body. When it
is true, the generated HEADERS frame will contains the END_HEADERS flag;

* `priority`, a hash-like Lua table, which used to define a custom stream dependencies:
  * `priority.sid` represents the dependent stream identifier;
  * `priority.excl`, whether the new stream becomes the sole dependency of the
  stream indicated by `priority.sid`;
  * `priority.weight` defines weight of new stream;

* `pad`, the padding data.

[Back to TOC](#table-of-contents)

### session:submit_window_update

**syntax**: *local ok, err = session:submit_window_update(incr)*

Submits a WINDOW_UPDATE frame for the whole HTTP/2 session with an increment `incr`, in case of failure, `nil` and a Lua string which describes the error reason will be given.

[Back to TOC](#table-of-contents)

### session:recv_frame

**syntax**: *local frame, err = session:recv_frame()*

Receives a HTTP/2 frame, in case of failure, `nil` and a Lua string which describes the error reason will be given.

The corresponding action will be taken automatically, for example, GOAWAY frame will be sent if peer violates the HTTP/2 protocol conventions; WINDOW_UPDATE frame will be sent if peer's send window becomes too small.

[Back to TOC](#table-of-contents)

### session:close

**syntax**: *session:close(code?, debug_data?)*

Generates a GOAWAY frame with the error code `code` and debug data `debug_data`, the default error code is NO_ERROR and the debug_data is `nil`.

Note this function just queues the GOAWAY frame to the output queue, callers
should call `session:flush_queue` to really send the frames.

[Back to TOC](#table-of-contents)

### session:detach

**syntax**: *session:detach()*

Detachs the current HTTP/2 session with the Cosocket object.

[Back to TOC](#table-of-contents)

### session:attach

**syntax**: *local ok, err = session:attach(recv, send, ctx)*

Attachs the current HTTP/2 session with a Cosocket object, in case of failure, `nil` and a Lua string which describes the error reason will be given.

The meanings of `recv`, `send` and `ctx` are same as these described in [http.new](#http2new).

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
