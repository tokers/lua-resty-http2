use Test::Nginx::Socket::Lua;

our $http_config = << 'EOC';
    lua_package_path "lib/?.lua;;";

    server {
        listen 8083 http2;
        http2_max_field_size 64k;
        http2_max_header_size 64k;
        location = /t1 {
            return 200;

            header_filter_by_lua_block {
                local cookie = {}
                local client, err

                for i = 1, 50000 do
                    cookie[i] = string.char(math.random(48, 97))
                end

                cookie = table.concat(cookie)

                ngx.header["Cookie"] = cookie
            }
        }

        location = /t2 {
            return 200;

            header_filter_by_lua_block {
                ngx.header["Cookie"] = ngx.var.http_cookie
            }
        }
    }
EOC


repeat_each(3);
plan tests => repeat_each() * blocks() * 3;
no_long_string();
run_tests();

__DATA__

=== TEST 1: CONTINUATION frame

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
                assert(#headers["cookie"] == 50000)
            end

            local on_data_reach = function(ctx, data)
                if #data > 0 then
                    error("unexpected DATA frame")
                end
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
                preread_size = 1024,
                on_headers_reach = on_headers_reach,
                on_data_reach = on_data_reach,
                max_frame_size = 16385,
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


=== TEST 2: client sent CONTINUATION frame

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

            local prepare_request = function()
                -- work-around way to force our library
                -- generates CONTINUATION frame
                client.session.max_frame_size = 16384
                return headers
            end

            local on_headers_reach = function(ctx, headers)
                assert(headers["cookie"] == cookie)
            end

            local on_data_reach = function(ctx, data)
                if #data > 0 then
                    error("unexpected DATA frame")
                end
            end

            local sock = ngx.socket.tcp()
            local ok, err = sock:connect("127.0.0.1", 8083)
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            client, err = http2.new {
                ctx = sock,
                recv = sock.receive,
                send = sock.send,
                prepare_request = prepare_request,
                preread_size = 1024,
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



=== TEST 3: request with PING frame

--- http_config eval: $::http_config
--- config
    location = /t {
        content_by_lua_block {
            local http2 = require "resty.http2"
            local h2_frame = require "resty.http2.frame"

            local prepare_request = function()
                return {
                    { name = ":authority", value = "test.com" },
                    { name = ":method", value = "GET" },
                    { name = ":path", value = "/t2" },
                    { name = ":scheme", value = "http" },
                }
            end

            local on_headers_reach = function()
            end

            local on_data_reach = function(ctx, data)
                if #data > 0 then
                    error("unexpected DATA frame")
                end
            end

            local sock = ngx.socket.tcp()
            local ok, err = sock:connect("127.0.0.1", 8083)
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            client, err = http2.new {
                ctx = sock,
                recv = sock.receive,
                send = sock.send,
                prepare_request = prepare_request,
                preread_size = 1024,
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

            local session = client.session
            local hd = h2_frame.header.new(8, h2_frame.PING_FRAME, 0, 0)

            local frame = {
                next = nil,
                header = hd,
                opaque_data_hi = 1234,
                opaque_data_lo = 5678,
            }

            session:frame_queue(frame)
            local ok, err = session:flush_queue()
            if not ok then
                ngx.log(ngx.ERR, err)
                return
            end

            local frame, err = session:recv_frame()
            if not frame then
                ngx.log(ngx.ERR, err)
                return
            end

            assert(frame.header.type == h2_frame.PING_FRAME)
            assert(frame.header.length == 8)
            assert(frame.header.flag_ack == true)
            assert(frame.opaque_data_hi == 1234)
            assert(frame.opaque_data_lo == 5678)

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
