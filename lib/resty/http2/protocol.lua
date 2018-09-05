-- Copyright Alex Zhang (tokers)

local util = require "resty.http2.util"
local h2_frame = require "resty.http2.frame"
local h2_stream = require "resty.http2.stream"
local h2_error = require "resty.http2.error"
local h2_hpack = require "resty.http2.hpack"

local pairs = pairs
local new_tab = util.new_tab
local clear_tab = util.clear_tab
local debug_log = util.debug_log

local MAX_STREAMS_SETTING = h2_frame.SETTINGS_MAX_CONCURRENT_STREAMS
local INIT_WINDOW_SIZE_SETTING = h2_frame.SETTINGS_INITIAL_WINDOW_SIZE
local MAX_FRAME_SIZE_SETTING = h2_frame.SETTINGS_MAX_FRAME_SIZE
local ENABLE_PUSH_SETTING = h2_frame.SETTINGS_ENABLE_PUSH
local MAX_STREAM_ID = 0x7fffffff
local DEFAULT_WINDOW_SIZE = 65535
local DEFAULT_MAX_STREAMS = 128
local DEFAULT_MAX_FRAME_SIZE = h2_frame.MAX_FRAME_SIZE
local HTTP2_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

local send_buffer
local send_buffer_size = 0
local _M = { _VERSION = "0.1" }
local mt = { __index = _M }


local function handle_error(self, stream, error_code)
    if h2_error.is_stream_error(error_code) then
        stream:rst(error_code)
    else
        self:close(error_code)
    end

    -- we flush the frame queue actively,
    -- since callers cannot distinguish protocol error and network error
    local ok, err = self:flush_queue()
    if not ok then
        debug_log("failed to flush frame queue: ", err)
    end

    return nil, h2_error.strerror(error_code)
end


-- send the default settings and advertise the window size
-- for the whole connection
local function init(self, preread_size, max_concurrent_stream)
    preread_size = preread_size or self.preread_size
    max_concurrent_stream = max_concurrent_stream or DEFAULT_MAX_STREAMS

    local payload = {
        { id = MAX_STREAMS_SETTING, value = max_concurrent_stream },
        { id = INIT_WINDOW_SIZE_SETTING, value = preread_size },
        { id = MAX_FRAME_SIZE_SETTING, value = DEFAULT_MAX_FRAME_SIZE },
        { id = ENABLE_PUSH_SETTING, value = 0 },
    }

    local sf, err = h2_frame.settings.new(h2_frame.FLAG_NONE, payload)

    if not sf then
        return nil, err
    end

    local incr = h2_stream.MAX_WINDOW - DEFAULT_WINDOW_SIZE

    local wf
    wf, err = h2_frame.window_update.new(0x0, incr)
    if not wf then
        return nil, err
    end

    self.recv_window = h2_stream.MAX_WINDOW
    self.preread_size = preread_size

    self:frame_queue(sf)
    self:frame_queue(wf)

    return self:flush_queue()
end


-- create a new http2 session
function _M.session(recv, send, ctx, preread_size, max_concurrent_stream)
    if not recv then
        return nil, "empty read handler"
    end

    if not send then
        return nil, "empty write handler"
    end

    local _, err = send(ctx, HTTP2_PREFACE)
    if err then
        return nil, err
    end

    local session = {
        send_window = DEFAULT_WINDOW_SIZE,
        recv_window = DEFAULT_WINDOW_SIZE,
        init_window = DEFAULT_WINDOW_SIZE,
        preread_size = DEFAULT_WINDOW_SIZE,
        max_stream = DEFAULT_MAX_STREAMS,
        max_frame_size = DEFAULT_MAX_FRAME_SIZE,

        recv = recv, -- handler for reading data
        send = send, -- handler for writing data
        ctx = ctx,

        last_stream_id = 0x0,
        next_stream_id = 0x3, -- 0x1 is used for the HTTP/1.1 upgrade

        stream_map = new_tab(4, 1),
        total_streams = 0,
        idle_streams = 0,
        closed_streams = 0,

        goaway_sent = false,
        goaway_received = false,
        incomplete_headers = false,

        current_sid = nil,

        ack_peer_settings = false,

        output_queue = nil,
        output_queue_size = 0,
        last_frame = nil, -- last frame in the output queue

        root = nil,

        hpack = h2_hpack.new(),
    }

    session = setmetatable(session, mt)

    session.root = h2_stream.new_root(session)
    session.stream_map[0] = session.root

    local ok
    ok, err = init(session, preread_size, max_concurrent_stream)
    if not ok then
        debug_log("failed to send SETTINGS frame: ", err)
        return nil, err
    end

    return session
end


function _M:adjust_window(delta)
    local max_window = h2_stream.MAX_WINDOW
    for sid, stream in pairs(self.stream_map) do
        if sid ~= 0x0 then
            local send_window = stream.send_window
            if delta > 0 and send_window > max_window - delta then
                stream:rst(h2_error.FLOW_CONTROL_ERROR)
                return
            end

            stream.send_window = send_window + delta
            if stream.send_window > 0 and stream.exhausted then
                stream.exhausted = false

            elseif stream.send_window < 0 then
                stream.exhausted = true
            end
        end
    end

    return true
end


function _M:frame_queue(frame)
    local output_queue = self.output_queue
    local last_frame = self.last_frame
    local queue_size = self.output_queue_size

    if not output_queue then
        self.output_queue = frame
        self.last_frame = frame
        self.output_queue_size = 1
        return
    end

    last_frame.next = frame
    self.last_frame = frame
    self.output_queue_size = queue_size + 1
end


function _M:flush_queue()
    local frame = self.output_queue
    if not frame then
        return true
    end

    local size = self.output_queue_size
    if send_buffer_size < size then
        send_buffer_size = size
        send_buffer = new_tab(size, 0)
    else
        clear_tab(send_buffer)
    end

    while frame do
        local frame_type = frame.header.type
        h2_frame.pack[frame_type](frame, send_buffer)
        frame = frame.next
    end

    self.output_queue_size = size
    self.output_queue = frame

    local _, err = self.send(self.ctx, send_buffer)
    if err then
        return nil, err
    end

    return true
end


-- submit a request
function _M:submit_request(headers, priority, pad)
    if not self.ack_peer_settings then
        return nil, "peer's settings aren't acknowledged yet"
    end

    if #headers == 0 then
        return nil, "empty headers"
    end

    local sid = self.next_stream_id
    if sid > MAX_STREAM_ID then
        return nil, "stream id overflow"
    end

    local total = self.total_streams
    if total == self.max_streams then
        return nil, h2_error.STRERAM_OVERFLOW
    end

    if self.goaway_sent or self.goaway_received then
        return nil, "goaway frame was received or sent"
    end

    self.next_stream_id = sid + 2 -- odd number

    -- TODO custom stream weight
    local stream, err = h2_stream.new(sid, h2_stream.DEFAULT_WEIGHT, self)
    if not stream then
        return nil, err
    end

    local ok
    ok, err = stream:submit_headers(headers, false, priority, pad)
    if not ok then
        return nil, err
    end

    self.total_streams = total + 1
    self.idle_streams = self.idle_streams + 1

    return stream
end


function _M:submit_window_update(incr)
    return self.root:submit_window_update(incr)
end


-- all the frame payload will be read, thereby a proper preread_size is needed .
-- note WINDOW_UPDATE, RST_STREAM or GOAWAY frame will be sent automatically
-- (if necessary).
function _M:recv_frame()
    local ctx = self.ctx
    local recv = self.recv

    local incomplete_headers = self.incomplete_headers
    local frame
    local ok

    while true do
        local bytes, err = recv(ctx, h2_frame.HEADER_SIZE)
        if err then
            return nil, err
        end

        local hd = h2_frame.header.unpack(bytes)
        local typ = hd.type

        bytes, err = recv(ctx, hd.length) -- read the payload
        if err then
            return nil, err
        end

        if typ <= h2_frame.MAX_FRAME_ID then
            local sid = hd.id
            local stream = self.stream_map[sid]
            if sid > 0x0 and not stream then
                -- idle stream
                if typ ~= h2_frame.HEADERS_FRAME and
                   typ ~= h2_frame.PUSH_PROMISE_FREAM
                then
                    return handle_error(self, nil, h2_error.PROTOCOL_ERROR)
                end

                stream = h2_stream.new(sid, h2_stream.DEFAULT_WEIGHT, self)
            end

            if incomplete_headers then
                local current_sid = self.current_sid
                if typ ~= h2_frame.CONTINUATION_FRAME or current_sid ~= sid then
                    return handle_error(self, stream, h2_error.PROTOCOL_ERROR)
                end
            end

            frame = new_tab(0, h2_frame.sizeof[typ])
            frame.header = hd

            ok, err = h2_frame.unpack[typ](frame, bytes, stream)
            if not ok then
                return handle_error(self, stream, err)
            end

            return frame

        elseif incomplete_headers then
            return handle_error(self, nil, h2_error.PROTOCOL_ERROR)
        end
    end
end


function _M:close(code, debug_data)
    if self.goaway_sent then
        return
    end

    code = code or h2_error.NO_ERROR

    debug_log("GOAWAY frame with code ", code, " and last_stream_id: ",
              MAX_STREAM_ID, " will be sent")

    local frame = h2_frame.goaway.new(MAX_STREAM_ID, code, debug_data)
    self:frame_queue(frame)

    self.goaway_sent = true
end


return _M
