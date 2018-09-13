use Test::Nginx::Socket::Lua;

our $http_config = << 'EOC';
    lua_package_path "lib/?.lua;;";

    server {
        listen 8083 http2;
        http2_body_preread_size 256;
        http2_max_header_size 19k;

        location = /t1 {
            lua_need_request_body on;
            content_by_lua_block {
                ngx.status = 200
                return ngx.exit(200)
            }
        }
    }
EOC


repeat_each(3);
plan tests => repeat_each() * (blocks() * 3 + 1);
no_long_string();
run_tests();

__DATA__

=== TEST 1: abnormal request headers

--- http_config eval: $::http_config
--- config
    location = /t {
        content_by_lua_block {
            local http2 = require "resty.http2"
            local headers = {
                { name = ":authority", value = "test.com" },
                { name = ":method", value = "get" },
                { name = ":path", value = "/t1" },
                { name = ":scheme", value = "http" },
                { name = "accept-encoding", value = "deflate, gzip" },
                { name = "content-length", value = "2048" },
            }

            local t = {}
            for i = 1, 2048 do
                t[i] = string.char(math.random(48, 120))
            end

            local data = table.concat(t)

            local on_headers_reach = function(ctx, headers)
            end

            local on_data_reach = function(ctx, data)
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
                preread_size = 1024,
            }

            if not client then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = client:request(headers, data, on_headers_reach,
                                           on_data_reach)
            assert(ok == nil)
            ngx.print(err)

            local ok, err = sock:close()
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end
        }
    }

--- request
GET /t

--- response_body: stream reset
--- grep_error_log: client sent invalid method: "get"
--- grep_error_log_out
client sent invalid method: "get"
--- no_error_log
[error]



=== TEST 2: client sent too large headers

--- http_config eval: $::http_config
--- config
    location = /t {
        content_by_lua_block {
            local http2 = require "resty.http2"

            local cookie = {}
            local client, err

            for i = 1, 20000 do
                cookie[i] = string.char(math.random(48, 97))
            end

            cookie = table.concat(cookie)

            local headers = {
                { name = ":authority", value = "test.com" },
                { name = ":method", value = "GET" },
                { name = ":path", value = "/t2" },
                { name = ":scheme", value = "http" },
                { name = "accept-encoding", value = "deflate, gzip" },
                { name = "cookie", value = cookie },
            }

            local on_headers_reach = function(ctx, headers)
                error("unexpected HEADERS frame")
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
            }

            if not client then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = client:request(headers, nil, on_headers_reach,
                                           on_data_reach)
            assert(ok == nil)
            assert(err == "connection went away")
            ngx.print("OK")
        }
    }

--- request
GET /t

--- response_body: OK
--- no_error_log
[error]
