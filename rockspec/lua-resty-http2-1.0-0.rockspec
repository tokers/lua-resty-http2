package = "lua-resty-http2"
version = "1.0-0"

source = {
    url = "git://github.com/tokers/lua-resty-http2",
    tag = "v1.0",
}

description = {
    summary = "The HTTP/2 Protocol (Client Side) Implementation for OpenResty.",
    homepage = "https://github.com/tokers/lua-resty-http2",
    license = "2-clause BSD",
    maintainer = "Alex Zhang <zchao1995@gmail.com>",
}

dependencies = {
    "lua >= 5.1",
}

build = {
    type = "builtin",
    modules = {
        ["resty.http2"] = "lib/resty/http2.lua",
        ["resty.http2.error"] = "lib/resty/http2/error.lua",
        ["resty.http2.frame"] = "lib/resty/http2/frame.lua",
        ["resty.http2.hpack"] = "lib/resty/http2/hpack.lua",
        ["resty.http2.huff_decode"] = "lib/resty/http2/huff_decode.lua",
        ["resty.http2.huff_encode"] = "lib/resty/http2/huff_encode.lua",
        ["resty.http2.protocol"] = "lib/resty/http2/protocol.lua",
        ["resty.http2.stream"] = "lib/resty/http2/stream.lua",
        ["resty.http2.util"] = "lib/resty/http2/util.lua",
    }
}
