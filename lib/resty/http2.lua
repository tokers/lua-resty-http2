-- Copyright Alex Zhang (tokers)

local h2_protocol = require "resty.http2.protocol"
local h2_frame = require "resty.http2.frame"
local h2_error = require "resty.http2.error"
local util = require "resty.http2.util"

local is_func = util.is_func
local debug_log = util.debug_log
local new_tab = util.new_tab
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


local function handle_frame(self, session)
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
    local abort = false

    local headers = typ == h2_frame.HEADERS_FRAME or h2_frame.CONTINUATION_FRAME
    if headers and frame.header.flag_end_headers then
        if self.on_headers_reach(session.ctx, frame.block_frags) then
            abort = true
        end
    end

    if typ == h2_frame.DATA_FRAME then
        if self.on_data_reach(session.ctx, frame.payload) then
            abort = true
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

    if not abort then
        if end_stream and frame.header.id > 0x0 then
            session.done = true
        end

        return true
    end

    -- caller asks for aborting the connection
    session:close(h2_error.NO_ERROR)

    return session:flush_queue()
end


function _M.new(opts)
    local recv = opts.recv
    local send = opts.send
    local ctx = opts.ctx
    local preread_size = opts.preread_size
    local max_concurrent_stream = opts.max_concurrent_stream
    local prepare_request = opts.prepare_request
    local max_frame_size = opts.max_frame_size
    local on_headers_reach = opts.on_headers_reach
    local on_data_reach = opts.on_data_reach
    local key = opts.key

    if not is_func(prepare_request) then
        return nil, "prepare_request must be a Lua function"
    end

    if not is_func(on_headers_reach) then
        return nil, "on_headers_reach must be a Lua function"
    end

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
        prepare_request = prepare_request,
        on_headers_reach = on_headers_reach,
        on_data_reach = on_data_reach,
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


function _M:process()
    local session = self.session

    while not session.ack_peer_settings do
        local ok, err = handle_frame(self, session)
        if not ok then
            return nil, err
        end
    end

    local prepare_request = self.prepare_request

    local headers, data = prepare_request(session.ctx)
    if not headers then
        return nil, "empty headers"
    end

    local stream, err = session:submit_request(headers, data == nil, nil, nil)
    if not stream then
        debug_log("failed to submit_request: ", err)
        return nil, err
    end

    local ok, flush_err = session:flush_queue()
    if not ok then
        debug_log("failed to flush frames: ", err)
        return nil, flush_err
    end

    if not stream then
        return nil, err
    end

    local get_data
    if data then
        get_data = get_data_wrapper(data)
    end

    while true do
        if data then
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
                    data = nil
                end
            end
        end

        ok, err = handle_frame(self, session)
        if not ok then
            return nil, err
        end

        if session.done then
            break
        end

        if session.goaway_sent or session.goaway_received then
            break
        end
    end

    -- connection closed normally
    return true
end


return _M
