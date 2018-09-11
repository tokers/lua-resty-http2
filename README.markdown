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
  * [resty.http2.stream](#restyhttp2stream)
    * [h2_stream.new](#h2_streamnew)
    * [h2_stream.new_root](#h2_streamnew_root)
    * [stream:submit_headers](#streamsubmit_headers)
    * [stream:submit_data](#streamsubmit_data)
    * [stream:submit_window_update](#streamsubmit_window_update)
    * [stream:set_dependency](#streamset_dependency)
  * [resty.http2.frame](#restyhttp2frame)
    * [h2_frame.header.new](#h2_frameheadernew)
    * [h2_frame.header.pack](#h2_frameheaderpack)
    * [h2_frame.header.unpack](#h2_frameheaderunpack)
    * [h2_frame.priority.pack](#h2_frameprioritypack)
    * [h2_frame.priority.unpack](#h2_framepriorityunpack)
    * [h2_frame.rst_stream.pack](#h2_framerst_streampack)
    * [h2_frame.rst_stream.unpack](#h2_framerst_streamunpack)
    * [h2_frame.rst_stream.new](#h2_framerst_streamunnew)
    * [h2_frame.settings.pack](#h2_framesettingspack)
    * [h2_frame.settings.unpack](#h2_framesettingsunpack)
    * [h2_frame.settings.new](#h2_framesettingsnew)
    * [h2_frame.ping.pack](#h2_framepingpack)
    * [h2_frame.ping.unpack](#h2_framepingunpack)
    * [h2_frame.goaway.pack](#h2_framegoawaypack)
    * [h2_frame.goaway.unpack](#h2_framegoawayunpack)
    * [h2_frame.goaway.new](#h2_framegoawaynew)
    * [h2_frame.window_update.pack](#h2_framewindow_updatepack)
    * [h2_frame.window_update.unpack](#h2_framewindow_updateunpack)
    * [h2_frame.window_update.new](#h2_framewindow_updatenew)
    * [h2_frame.headers.pack](#h2_frameheaderspack)
    * [h2_frame.headers.unpack](#h2_frameheadersunpack)
    * [h2_frame.headers.new](#h2_frameheadersnew)
    * [h2_frame.continuation.pack](#h2_framecontinuationpack)
    * [h2_frame.continuation.unpack](#h2_framecontinuationunpack)
    * [h2_frame.continuation.new](#h2_framecontinuationnew)
    * [h2_frame.data.pack](#h2_framedatapack)
    * [h2_frame.data.unpack](#h2_framedataunpack)
    * [h2_frame.data.new](#h2_framedatannew)
    * [h2_frame.push_promise.unpack](#h2_framepush_promiseunpack)
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

the `headers`, should be a hash-like Lua table represent the HTTP request headers, it is worth noting that this library doesn't take care of the HTTP headers' semantics, so it's callers' responsibility to supply this, and callers should implement any necessary conversions, for example, `Host` should be converted to `:authority`. Also, the following headers will be ignored as they are CONNECTION specific.

  * `Connection`
  * `Keep-Alive`
  * `Proxy-Connection`
  * `Upgrade`
  * `Transfer-Encoding`

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

The detached HTTP/2 session will be saved in an internal hash-like Lua table, the unique parameter `key` will be used to index this session when callers want to reuse it.

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

resty.http2.stream
------------------

To load this module, just do this:

```lua
local h2_stream = require "resty.http2.stream"
```

[Back to TOC](#table-of-contents)

### h2_stream.new

**syntax**: *local stream = h2_stream.new(sid, weight, session)*

Creates a new stream with the identifier `sid`, weight `weight` and the HTTP/2 session which it belongs.

[Back to TOC](#table-of-contents)

### h2_stream.new_root

**syntax**: *local root_stream = h2_stream.new_root(session)*

Creates the root stream with it's session.

The root stream's identifier is `0x0` and is really a virtual stream which is used to manipulate the whole HTTP/2 session.

[Back to TOC](#table-of-contents)

### stream:submit_headers

**syntax**: *local ok, err = stream:submit_headers(headers, end_stream, priority?, pad?)*

Submits some HTTP headers to the stream.

The first parameter `headers`, should be a hash-like Lua table represent the HTTP request headers, it is worth noting that this library doesn't take care of the HTTP headers' semantics, so it's callers' responsibility to supply this, and callers should transform any necessary pesudo headers. For example, `:authority` should be passed rather `Host`;

The `end_stream` parameter should be a boolean value and is used to control whether the HEADERS frame should take the END_STREAM flag, basically callers can set it true if there is no request body need to send.

`priority` should be a hash-like Lua table (if any), which used to define a custom stream dependencies:
  * `priority.sid` represents the dependent stream identifier;
  * `priority.excl`, whether the new stream becomes the sole dependency of the
  stream indicated by `priority.sid`;
  * `priority.weight` defines weight of new stream;

The last parameter `pad`, represents the padding data.

In case of failure, `nil` and a Lua string which describes the corresponding error will be given.

[Back to TOC](#table-of-contents)

### stream:submit_data

**syntax**: *local ok, err = stream:submit_data(data, pad, last)*

Submits some request body to the stream, `data` should be a Lua string, with optional padding data.

The last parameter `last` is indicated whether this is the last submittion, the current DATA frame will attach the END_STREAM flag if `last` is true.

In case of failure, `nil` and a Lua string which describes the corresponding error will be given.

[Back to TOC](#table-of-contents)

### stream:submit_window_update

**syntax**: *local ok, err = session:submit_window_update(incr)*

Submits a WINDOW_UPDATE frame for the stream with an increment `incr`, in case of failure, `nil` and a Lua string which describes the error reason will be given.

[Back to TOC](#table-of-contents)

### stream:set_dependency

**syntax**: *stream:set_dependency(depend, excl)*

Sets current stream's dependencies to a stream with the identifier `depend`.

The second parameter `excl`, indicates whether current stream will be the sole child of `depend`.

When `depend` is absent, the target stream will be the root and `excl` will be treat as `false`.

[Back to TOC](#table-of-contents)

### stream:rst

**syntax**: *stream:rst(code)*

Generates a RST_STREAM frame with the error code `code`. In the case of `code` is absent, the NO_ERROR code will be selected.

Note this method just **generates** a RST_STREAM frame rather than send it, caller should send this frame by calling [session:flush_queue](#sessionflush_queue).

[Back to TOC](#table-of-contents)

resty.http2.frame
-----------------

To load this module, just do this:

```lua
local h2_frame = require "resty.http2.frame"
```

[Back to TOC](#table-of-contents)

### h2_frame.header.new

**syntax**: *local hd = h2_frame.header.new(length, typ, flags, id)*

Creates a frame header, with the payload length `length`, frame type `type` and
takes `flags` as the frame flags, which belongs to the stream `id`.

[Back to TOC](#table-of-contents)

### h2_frame.header.pack

**syntax**: *h2_frame.header.pack(hd, dst)*

Serializes the frame header `hd` to the destination `dst`. The `dst` must be a
array-like Lua table.

[Back to TOC](#table-of-contents)

### h2_frame.header.unpack

**syntax**: *h2_frame.header.unpack(src)*

Deserializes a frame header from a Lua string `src`, the length of `src` must be at least 9 octets.
[Back to TOC](#table-of-contents)

### h2_frame.priority.pack

**syntax**: *h2_frame.priority.pack(pf, dst)*

Serializes a PRIORITY frame to the destination `dst`. The `dst` must be a array-like Lua table.

The `pf` must be a hash-like Lua table which contians:

* `header`, the frame header;
* `depend`, the dependent stream identifier
* `excl`, specifies whether the current stream where this PRIORITY frame stays becomes the sole child of the stream identified by `depend`;
* `weight`, assigns a new weight `weight` to current stream;

[Back to TOC](#table-of-contents)

### h2_frame.priority.unpack

**syntax**: *local ok, err = h2_frame.priority.unpack(pf, src, stream)*

Deserializes a PRIORITY frame from a Lua string `src`, the length of `src` must
be at least the size specified in the `pf.header.length`.

The `pf` should be a hash-like Lua table which already contains the current
PRIORITY frame's header, i.e. `pf.header`.

The last parameter `stream` specifies the stream that current PRIORITY frame
belongs.

Corresponding actions will be taken automatically inside this method like
building the new dependencies.

In case of failure, `nil` and a Lua string which describes the error reason
will be given.

[Back to TOC](#table-of-contents)

### h2_frame.rst_stream.pack

**syntax**: *h2_frame.rst_stream.pack(rf, dst)*

Serializes a RST_STREAM frame to the destination `dst`. The `dst` must be a array-like Lua table.

The `rf` must be a hash-like Lua table which contains:

* `header`, the frame header;
* `error_code`, the error code;

[Back to TOC](#table-of-contents)

### h2_frame.rst_stream.unpack

**syntax**: *h2_frame.rst_stream.unpack(rf, src, stream)*

Deserializes a RST_STREAM frame from a Lua string `src`. The length of `src`
must be at least the size specified in the `rf.header.length`.

The `rf` should be a hash-like Lua table which already contains the current
RST_STREAM frame's header, i.e. `rf.header`.

The last parameter `stream` specifies the stream that current RST_STREAM frame
belongs.

Corresponding actions will be taken automatically inside this method like
changing the stream's state.

In case of failure, `nil` and a Lua string which describes the error reason
will be given.

[Back to TOC](#table-of-contents)

### h2_frame.rst_stream.new

**syntax**: *local rf = h2_frame.rst_stream.new(error_code, sid)*

Creates a RST_STREAM frame with the error code `error_code`, which belongs to
the stream `sid`.

[Back to TOC](#table-of-contents)

### h2_frame.settings.pack

**syntax**: *h2_frame.settings.pack(sf, dst)*

Serializes a SETTINGS frame to the destination `dst`. The `dst` must be a array-like Lua table.

The `sf` must be a hash-like Lua table which contains:

* `header`, the frame header;
* `item`, the specific settings, which should be a array-like Lua table, each element should be a hash-like Lua table:
  * `id`, the setting identifier, can be:
    * SETTINGS_ENABLE_PUSH (0x2)
    * SETTINGS_MAX_CONCURRENT_STREAMS (0x3)
    * SETTINGS_INITIAL_WINDOW_SIZE (0x4)
    * SETTINGS_MAX_FRAME_SIZE (0x5)
  * `value`, the corresponding setting value;

[Back to TOC](#table-of-contents)

### h2_frame.settings.unpack

**syntax**: *local ok, err = h2_frame.settings.unpack(sf, src, stream)*

Deserializes a SETTINGS frame from a Lua string `src`. The length of `src` must be at least the size specified in the `sf.header.length`.

The `sf` should be a hash-like Lua table which already contains the current SETTINGS frame's header, i.e. `sf.header`.

The last parameter `stream` specifies the stream that current SETTINGS frame belongs (must be the root stream).

Corresponding actions will be taken automatically inside this method like updating the HTTP/2 session settings value.

In case of failure, `nil` and a Lua string which describes the error reason will be given.

[Back to TOC](#table-of-contents)

### h2_frame.settings.new

**syntax**: *local sf = h2_frame.settings.new(flags, payload)*

Creates a SETTINGS frame with the flags `flags` and payload item `payload`.

The `payload` should be a array-like Lua table, each element should be a hash-like Lua table:
  * `id`, the setting identifier, can be:
    * SETTINGS_ENABLE_PUSH (0x2)
    * SETTINGS_MAX_CONCURRENT_STREAMS (0x3)
    * SETTINGS_INITIAL_WINDOW_SIZE (0x4)
    * SETTINGS_MAX_FRAME_SIZE (0x5)
  * `value`, the corresponding setting value;

[Back to TOC](#table-of-contents)

### h2_frame.ping.pack

**syntax**: *h2_frame.ping.pack(pf, dst)*

Serializes a PING frame to the destination `dst`. The `dst` must be a array-like Lua table.

The `pf` must be a hash-like Lua table which contains:

* `header`, the frame header;
* `opaque_data_hi`, highest 32 bits value of the corresponding ping data;
* `opaque_data_lo`, lowest 32 bits value of the corresponding ping data;

[Back to TOC](#table-of-contents)

### h2_frame.ping.unpack

**syntax**: *local ok, err = h2_frame.ping.unpack(pf, src, stream)*

Deserializes a PING frame from a Lua string `src`. The length of `src` must be at least the size specified in the `sf.header.length`.

The `pf` should be a hash-like Lua table which already contains the current PING frame's header, i.e. `pf.header`.

The last parameter `stream` specifies the stream that current PING frame belongs (must be the root stream).

In case of failure, `nil` and a Lua string which describes the error reason will be given.

[Back to TOC](#table-of-contents)

### h2_frame.goaway.pack

**syntax**: *h2_frame.goaway.pack(gf, dst)*

Serializes a GOAWAY frame to the destination `dst`. The `dst` must be a array-like Lua table.

The `gf` must be hash-like Lua table which contains:

* `header`, the frame header;
* `last_stream_id`, the last peer-initialized stream identifier;
* `error_code`, the error code;
* `debug_data`, the debug data;

[Back to TOC](#table-of-contents)

### h2_frame.goaway.unpack

**syntax**: *local ok, err = h2_frame.goaway.unpack(gf, src, stream)*

Deserializes a GOAWAY frame from a Lua string `src`. The length of `src` must be at least the size specified in the `gf.header.length`.

The `gf` should be a hash-like Lua table which already contains the current GOAWAY frame's heaer, i.e. `gf.header`.

The last parameter `stream` specifies the stream that current GOAWAY frame belongs (must be the root stream).

In case of failure, `nil` and a Lua string which describes the error reason will be given.

[Back to TOC](#table-of-contents)

### h2_frame.goaway.new

**syntax**: *local gf = h2_frame.goaway.new(last_sid, error_code, debug_data)*

Creates a GOAWAY frame with the last peer-initialized stream identifier `last_sid`, and error code `error_code`. Optionally, with the debug data `debug_data`.

[Back to TOC](#table-of-contents)

### h2_frame.window_update.pack

**syntax**: *h2_frame.window_update.pack(wf, dst)*

Serializes a WINDOW_UPDATE frame to the destination `dst`. The `dst` must be a array-like Lua table.

The `wf` must be hash-like Lua table which contains:

* `header`, the frame header;
* `window_size_increment`, the window size increment;

[Back to TOC](#table-of-contents)

### h2_frame.window_update.unpack

**syntax**: *local ok, err = h2_frame.window_update.unpack(wf, src, stream)*

Deserializes a WINDOW_UPDATE frame from a Lua string `src`. The length of `src` must be at least the size specified in the `wf.header.length`.

The `wf` should be a hash-like Lua table which already contains the current WINDOW_UPDATE frame's heaer, i.e. `wf.header`.

The last parameter `stream` specifies the stream that current WINDOW_UPDATE frame belongs.

In case of failure, `nil` and a Lua string which describes the error reason will be given.

[Back to TOC](#table-of-contents)

### h2_frame.window_update.new

**syntax**: *local wf = h2_frame.window_update.new(sid, window)*

Creates a WINDOW_UPDATE frame with the stream identifier `sid`, and enlarges the window size specified by `window`.

[Back to TOC](#table-of-contents)

### h2_frame.headers.pack

**syntax**: *h2_frame.headers.pack(hf, dst)*

Serializes a HEADERS frame to the destination `dst`. The `dst` must be a array-like Lua table.

The `hf` must be hash-like Lua table which contains:

* `header`, the frame header;
* `pad`, the padding data;
* `depend`, the dependent stream identifier;
* `excl`, specifies whether the stream that current HEADERS frame belongs will become the sole child of the stream `depend`;
* `weight`, specifies the weight of the stream that current HEADERS frame belongs.
* `block_frags`, the plain HTTP headers (after the hpack compressing);

[Back to TOC](#table-of-contents)

### h2_frame.headers.unpack

**syntax**: *local ok,err = h2_frame.headers.unpack(hf, src, stream)*

Deserializes a HEADERS frame from the Lua string `src`, the length of `src` must be at least the size specified in the `hf.header.length`

The `hf` should be a hash-like Lua table which already contains the current HEADERS frame's heaer, i.e. `hf.header`.

The last parameter `stream` specifies the stream that current HEADER frame belongs.

The corresponding action will be taken, for example, stream state transition will happens.

In case of failure, `nil` and a Lua string which describes the error reason will be given.

[Back to TOC](#table-of-contents)

### h2_frame.headers.new

**syntax**: *local hf = h2_frame.headers.new(frags, pri?, pad?, end_stream, end_headers, sid)*

Creates a HEADERS frame which takes the block fragments `frags`.

The parameter `pri` can be taken to specify the stream dependencies, `pri` should be a hash-like Lua table, which contains:

* `sid`, the dependent stream identifier;
* `excl`, whether the stream `sid` will be the sole child of dependent stream;
* `weight`, defines the current stream's (specified by `sid`) weight
;

The `pad` specifies the padding data, which is optional.

When `end_stream` is true, current HEADERS frame will takes the END_STREAM flag, likewise, when `end_headers` is true, current HEADERS frame will takes the END_HEADERS flag.

One should take care that if current HEADERS frame doesn't contain the whole headers, then one or more CONTINUATION frames must be followed according to the HTTP/2 procotol.

[Back to TOC](#table-of-contents)

### h2_frame.continuation.pack

**syntax**: *h2_frame.continuation.pack(cf, dst)*

Serializes a CONTINUATION frame to the destination `dst`. The `dst` must be a array-like Lua table.

The `cf` must be hash-like Lua table which contains:

* `header`, the frame header;
* `block_frags`, the plain HTTP headers (after the hpack compressing);

[Back to TOC](#table-of-contents)

### h2_frame.continuation.unpack

**syntax**: *local ok, err = h2_frame.continuation.unpack(cf, src, stream)*

Deserializes a CONTINUATION frame from the Lua string `src`, the length of `src` must be at least the size specified in the `cf.header.length`

The `cf` should be a hash-like Lua table which already contains the current CONTINUATION frame's heaer, i.e. `cf.header`.

The last parameter `stream` specifies the stream that current CONTINUATION frame belongs.

The corresponding action will be taken, for example, stream state transition will happens.

In case of failure, `nil` and a Lua string which describes the error reason will be given.

[Back to TOC](#table-of-contents)

### h2_frame.continuation.new

**syntax**: *local cf = h2_frame.continuation.new(frags, end_headers, sid)*

Creates a CONTINUATION frame which takes the block fragments `frags`.

When `end_headers` is true, current CONTINUATION frame will takes the END_HEADERS flag.

One should take care that if current CONTINUATION frame doesn't contain the whole headers, then one or more CONTINUATION frames must be followed according to the HTTP/2 procotol.

The `sid` specifies the stream that current CONTINUATION frame belongs.

[Back to TOC](#table-of-contents)

### h2_frame.data.pack

**syntax**: *h2_frame.data.pack(df, dst)*

Serializes a DATA frame to the destination `dst`. The `dst` must be a array-like Lua table.

The `df` must be hash-like Lua table which contains:

* `header`, the frame header;
* `payload`, the HTTP request/response body;

[Back to TOC](#table-of-contents)

### h2_frame.data.unpack

**syntax**: *local ok, err = h2_frame.data.unpack(df, src, stream)*

Deserializes a DATA frame from the Lua string `src`, the length of `src` must be at least the size specified in the `df.header.length`

The `df` should be a hash-like Lua table which already contains the current DATA frame's heaer, i.e. `df.header`.

The last parameter `stream` specifies the stream that current DATA frame belongs.

The corresponding action will be taken, for example, stream state transition will happens.

In case of failure, `nil` and a Lua string which describes the error reason will be given.

[Back to TOC](#table-of-contents)

### h2_frame.data.new

**syntax**: *local df = h2_frame.data.new(payload, pad, last, sid)*

Creates a DATA frame which takes the payload `payload`.

The `pad` specifies the padding data, which is optional.

When `last` is true, current DATA frame will takes the END_STREAM flag.

The `sid` specifies the stream that current DATA frame belongs.

[Back to TOC](#table-of-contents)

### h2_frame.push_promise.unpack

**syntax**: *local df = h2_frame.data.new(payload, pad, last, sid)*

Currently any incoming PUSH_PROMISE frame will be rejected.

This method always returns `nil` and the error PROTOCOL_ERROR.

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
