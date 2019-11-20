-- Copyright (C) Alex Zhang

package.path = "./lib/?.lua;;"

local http2 = require "resty.http2"

local arg = arg
local exit = os.exit
local error = error
local print = print
local pairs = pairs

local host = arg[1]
local port = tonumber(arg[2])

if not host or not port then
    error("invalid host or port")
end

local sock = ngx.socket.tcp()

local ok, err = sock:connect(host, port)
if not ok then
    print("failed to connect ", host, ":", port, ": ", err)
    exit(1)
end

local headers = {
    { name = ":authority", value = "tokers.com" },
    { name = ":method", value = "GET" },
    { name = ":path", value = "/index.html" },
    { name = ":scheme", value = "http" },
    { name = "accept-encoding", value = "gzip" },
    { name = "user-agent", value = "example/client" },
}


local on_headers_reach = function(ctx, headers)
    print("received HEADERS frame:")
    for k, v in pairs(headers) do
        print(k, ": ", v)
    end
end

local on_data_reach = function(ctx, data)
    print("received DATA frame:")
    print(data)
end

local on_trailers_reach = function(ctx, data)
    print("received HEADERS frame for trailer headers:")
    for k, v in pairs(headers) do
        print(k, ": ", v)
    end
end

local opts = {
    ctx = sock,
    recv = sock.receive,
    send = sock.send,
    preread_size = 1024,
    max_concurrent_stream = 100,
}

local client, err = http2.new(opts)
if not client then
    print("failed to create HTTP/2 client: ", err)
    exit(1)
end

local ok, err = client:request(headers, nil, on_headers_reach,
                               on_data_reach, on_trailers_reach)
if not ok then
    print("client:request() failed: ", err)
    exit(1)
end


sock:close()
