use Test::Nginx::Socket::Lua;

our $http_config = << 'EOC';
    lua_package_path "lib/?.lua;;";

    server {
        listen 8083 http2;
        location = /t1 {
            return 200;
        }

        location = /t2 {
            return 200 "hello world";
        }
    }
EOC

repeat_each(3);
plan tests => repeat_each() * blocks() * 3;
no_long_string();
run_tests();

__DATA__

=== TEST 1: GET request and zero Content-Length 

--- http_config eval: $::http_config
--- config
    location = /t {
        content_by_lua_block {
            local http2 = require "resty.http2"
            local headers = {
                { name = ":authority", value = "test.com" },
                { name = ":method", value = "GET" },
                { name = ":path", value = "/t1" },
                { name = ":scheme", value = "http" },
                { name = "accept-encoding", value = "deflate, gzip" },
            }

            local prepare_request = function() return headers end
            local on_headers_reach = function(ctx, headers)
                assert(headers[":status"] == "200")
                local length = headers["content-length"]
                assert(not length or length == "0")

                return true
            end

            local on_data_reach = function(ctx, data)
                error("unexpected data")
            end

            local sock = ngx.socket.tcp()
            local ok, err = sock:connect("127.0.0.1", 8083)
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            local client, err = http2.new {
                ctx = sock,
                recv = sock.receive,
                send = sock.send,
                prepare_request = prepare_request,
                on_headers_reach = on_headers_reach,
                on_data_reach = on_data_reach,
            }

            if not client then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = client:process()
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = sock:close()
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.print("OK")
        }
    }

--- request
GET /t

--- response_body: OK
--- no_error_log
[error]



=== TEST 2: GET request with response body

--- http_config eval: $::http_config
--- config
    location = /t {
        content_by_lua_block {
            local http2 = require "resty.http2"
            local headers = {
                { name = ":authority", value = "test.com" },
                { name = ":method", value = "GET" },
                { name = ":path", value = "/t2" },
                { name = ":scheme", value = "http" },
                { name = "accept-encoding", value = "deflate, gzip" },
            }

            local prepare_request = function() return headers end
            local on_headers_reach = function(ctx, headers)
                assert(headers[":status"] == "200")
                local length = headers["content-length"]
                assert(not length or length == "11")

                return true
            end

            local on_data_reach = function(ctx, data)
                assert(data == "hello world")
            end

            local sock = ngx.socket.tcp()
            local ok, err = sock:connect("127.0.0.1", 8083)
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            local client, err = http2.new {
                ctx = sock,
                recv = sock.receive,
                send = sock.send,
                prepare_request = prepare_request,
                on_headers_reach = on_headers_reach,
                on_data_reach = on_data_reach,
            }

            if not client then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = client:process()
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = sock:close()
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.print("OK")
        }
    }

--- request
GET /t

--- response_body: OK
--- no_error_log
[error]



=== TEST 3: POST request with request body

--- http_config eval: $::http_config
--- config
    location = /t {
        content_by_lua_block {
            local http2 = require "resty.http2"
            local headers = {
                { name = ":authority", value = "test.com" },
                { name = ":method", value = "GET" },
                { name = ":path", value = "/t1" },
                { name = ":scheme", value = "http" },
                { name = "accept-encoding", value = "deflate, gzip" },
                { name = "content-length", value = "11" },
            }

            local prepare_request = function() return headers, "hello, world" end
            local on_headers_reach = function(ctx, headers)
                assert(headers[":status"] == "200")
                local length = headers["content-length"]
                assert(not length or length == "0")

                return true
            end

            local on_data_reach = function(ctx, data)
                error("unexpected DATA frame")
            end

            local sock = ngx.socket.tcp()
            local ok, err = sock:connect("127.0.0.1", 8083)
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            local client, err = http2.new {
                ctx = sock,
                recv = sock.receive,
                send = sock.send,
                prepare_request = prepare_request,
                on_headers_reach = on_headers_reach,
                on_data_reach = on_data_reach,
            }

            if not client then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = client:process()
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = sock:close()
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.print("OK")
        }
    }

--- request
GET /t

--- response_body: OK
--- no_error_log
[error]
