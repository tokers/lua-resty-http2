-- Copyright Alex Zhang (tokers)

local h2_protocol = require "resty.http2.protocol"
local h2_frame = require "resty.http2.frame"
local h2_error = require "resty.http2.error"
local util = require "resty.http2.util"

local is_func = util.is_func
local debug_log = util.debug_log
local new_tab = util.new_tab
local new_buffer = util.new_buffer
local sub = string.sub
local min = math.min
local setmetatable = setmetatable

local _M = { _VERSION = "0.1" }
local mt = { __index = _M }
local session_pool = new_tab(0, 4)


local function get_data_wrapper(data)
    local pos = 1

    return function(max_frame_size)
        if is_func(data) then
            return data(max_frame_size)
        end

        local data_size = #data
        if data_size - pos + 1 <= max_frame_size then
            if pos == 1 then
                return data, true
            end

            return sub(data, pos), true
        end

        local part = sub(data, pos, pos + max_frame_size - 1)
        pos = pos + max_frame_size

        return part, false
    end
end


local function send_data(stream, session, part, last)
    local ok
    local err
    local flush_err

    ok, err = stream:submit_data(part, nil, last)
    if not ok then
        session:close(h2_error.INTERNAL_ERROR)
        ok, flush_err = session:flush_queue()
        if not ok then
            return nil, flush_err
        end

        return nil, err
    end

    -- we always flush the frame queue,
    -- since a single DATA frame maybe large enough

    ok, flush_err = session:flush_queue()
    if not ok then
        return nil, flush_err
    end

    return true
end


local function handle_frame(self, session, stream)
    local frame, err = session:recv_frame()
    if not frame then
        debug_log("failed to receive a frame: ", err)
        return nil, err
    end

    local typ = frame.header.type
    if typ == h2_frame.RST_STREAM_FRAME or typ == h2_frame.GOAWAY_FRAME then
        session:close()

        local ok, flush_err = session:flush_queue()
        if not ok then
            return nil, flush_err
        end

        if typ == h2_frame.RST_STREAM_FRAME then
            return nil, "stream reset"
        else
            if frame.error_code == h2_error.NO_ERROR then
                return true
            end

            return nil, "connection went away"
        end
    end

    if typ == h2_frame.SETTINGS_FRAME and not frame.header.flag_ack then
        -- response to the server's SETTINGS frame
        local settings_frame = h2_frame.settings.new(h2_frame.FLAG_ACK, nil)
        session.ack_peer_settings = true
        session:frame_queue(settings_frame)
        return session:flush_queue()
    end

    local end_stream = frame.header.flag_end_stream
    if end_stream and frame.header.id == stream.sid then
        stream.done = true
    end

    local headers = typ == h2_frame.HEADERS_FRAME or h2_frame.CONTINUATION_FRAME
    if headers and frame.header.flag_end_headers then
        self.cached_headers = frame.block_frags
        return true
    end

    if typ == h2_frame.DATA_FRAME then
        local buf = new_buffer(frame.payload)
        if not self.cached_body then
            self.last_body = buf
            self.cached_body = self.last_body
        else
            self.last_body.next = buf
            self.last_body = buf
        end

        if session.output_queue_size > 0 then
            -- flush the WINDOW_UPDATE frame as soon as possible
            local ok, flush_err = session:flush_queue()
            if not ok then
                debug_log("failed to flush frames: ", flush_err)
                return nil, err
            end
        end
    end

    return true
end


function _M.new(opts)
    local recv = opts.recv
    local send = opts.send
    local ctx = opts.ctx
    local preread_size = opts.preread_size
    local max_concurrent_stream = opts.max_concurrent_stream
    local max_frame_size = opts.max_frame_size
    local key = opts.key

    if max_frame_size and
       (max_frame_size > h2_frame.MAX_FRAME_SIZE or
        max_frame_size < h2_frame.DEFAULT_FRAME_SIZE)
    then
        return nil, "incorrect max_frame_size value"
    end

    local session
    local err
    local ok

    if key and session_pool[key] then
        session = session_pool[key]
        session_pool[key] = nil
        ok, err = session:attach(recv, send, ctx)
        if not ok then
            return nil, err
        end

    else
        session, err = h2_protocol.session(recv, send, ctx, preread_size,
                                           max_concurrent_stream,
                                           max_frame_size)
        if not session then
            return nil, err
        end
    end

    local client = {
        session = session,
        cached_headers = nil,
        cached_body = nil,
        last_body = nil,
    }

    return setmetatable(client, mt)
end


function _M:keepalive(key)
    local session = self.session

    if session.goaway_sent or session.goaway_received or session.fatal then
        return
    end

    session:detach()
    session_pool[key] = session
end


function _M:close(code)
    local session = self.session
    session:close(code)
    return session:flush_queue()
end


function _M:acknowledge_settings()
    local session = self.session
    while not session.ack_peer_settings do
        local ok, err = handle_frame(self, session)
        if not ok then
            return nil, err
        end
    end

    return true
end


function _M:send_request(headers, body)
    local session = self.session
    local stream, err = session:submit_request(headers, body == nil, nil, nil)
    if not stream then
        debug_log("failed to submit_request: ", err)
        return nil, err
    end

    local ok, flush_err = session:flush_queue()
    if not ok then
        debug_log("failed to flush frames: ", err)
        return nil, flush_err
    end

    if not body then
        return stream
    end

    local get_data = get_data_wrapper(body)

    while true do
        local size = min(session.send_window, stream.send_window)
        if size > session.max_frame_size then
            size = session.max_frame_size
        end

        if size > 0 then
            local part, last
            part, last, err = get_data(size)
            if not part then
                debug_log("connection will be closed since ",
                          "DATA frame cannot be generated correctly")

                session:close(h2_error.INTERNAL_ERROR)
                ok, flush_err = session:flush_queue()
                if not ok then
                    return nil, flush_err
                end

                return nil, err
            end

            ok, err = send_data(stream, session, part, last)
            if not ok then
                return nil, err
            end

            if last then
                break
            end
        else
            -- cannot continue sending body, waits the WINDOW_UPDATE firstly
            ok, err = handle_frame(self, session, stream)
            if not ok then
                return nil, err
            end
        end
    end

    return stream
end


function _M:read_headers(stream)
    local session = stream.session

    while not self.cached_headers do
        local ok, err = handle_frame(self, session, stream)
        if not ok then
            return nil, err
        end
    end

    local headers = self.cached_headers
    self.cached_headers = nil

    return headers
end


function _M:read_body(stream)
    if stream.done then
        return ""
    end

    local session = stream.session

    while not self.cached_body do
        local ok, err = handle_frame(self, session, stream)
        if not ok then
            return nil, err
        end
    end

    local body = self.cached_body.data
    self.cached_body = self.cached_body.next

    return body
end


function _M:request(headers, body, on_headers_reach, on_data_reach)
    local ack, err = self:acknowledge_settings()
    if not ack then
        return nil, err
    end

    if not headers then
        return nil, "empty headers"
    end

    if not is_func(on_headers_reach) then
        return nil, "invalid on_headers_reach callback"
    end

    if not is_func(on_data_reach) then
        return nil, "invalid on_data_reach callback"
    end

    local stream
    local resp_headers
    local data
    local session = self.session

    stream, err = self:send_request(headers, body)
    if not stream then
        return nil, err
    end

    resp_headers, err = self:read_headers(stream)
    if not resp_headers then
        return nil, err
    end

    local ctx = session.ctx

    if on_headers_reach(ctx, resp_headers) then
        -- abort the session
        return self:close(h2_error.INTERNAL_ERROR)
    end

    if stream.done then
        return true
    end

    while true do
        data, err = self:read_body(stream)
        if not data then
            return nil, err
        end

        if on_data_reach(ctx, data) then
            -- abort
            return self:close(h2_error.INTERNAL_ERROR)
        end

        if stream.done then
            break
        end
    end

    return true
end


return _M
