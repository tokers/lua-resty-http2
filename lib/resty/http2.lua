-- Copyright Alex Zhang (tokers)

local h2_protocol = require "resty.http2.protocol"
local util = require "resty.http2.util"

local is_func = util.is_func
local setmetatable = setmetatable

local _M = { _VERSION = "0.1" }
local mt = { __index = _M }


function _M.new(opts)
    local recv = opts.recv
    local send = opts.send
    local ctx = opts.ctx
    local preread_size = opts.preread_size
    local max_concurrent_stream = opts.max_concurrent_stream
    local submit_request = opts.submit_request
    local on_headers_reach = opts.on_headers_reach
    local on_data_reach = opts.on_data_reach

    if not is_func(submit_request) then
        return nil, "submit_request must be a Lua function"
    end

    if not is_func(on_headers_reach) then
        return nil, "on_headers_reach must be a Lua function"
    end

    local session, err = h2_protocol.session(recv, send, ctx, preread_size,
                                             max_concurrent_stream)
    if not session then
        return nil, err
    end

    local client = {
        session = session,
        submit_request = submit_request,
        on_headers_reach = on_headers_reach,
        on_data_reach = on_data_reach,
    }

    return setmetatable(client, mt)
end


function _M:cycle()
end


return _M
