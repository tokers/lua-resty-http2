-- Copyright Alex Zhang (tokers)

local util = require "resty.http2.util"
local h2_frame = require "resty.http2.frame"
local h2_stream = require "resty.http2.stream"
local hpack = require "resty.http2.hpack"

local new_tab = util.new_tab
local clear_tab = util.clear_tab

local MAX_STREAMS_SETTING = 0x3
local INIT_WINDOW_SIZE_SETTING = 0x4
local MAX_FRAME_SIZE_SETTING = 0x5
local MAX_STREAM_ID = 0x7fffffff
local DEFAULT_WINDOW_SIZE = 65535
local DEFAULT_MAX_STREAMS = 128
local DEFAULT_MAX_FRAME_SIZE = 0xffffff

local send_buffer
local send_buffer_size = 0
local _M = { _VERSION = "0.1" }
local mt = { __index = _M }


-- create a new http2 session
function _M.session(recv, send, ctx)
    if not recv then
        return nil, "empty read handler"
    end

    if not send then
        return nil, "empty write handler"
    end

    local root = h2_stream.new_root()

    local session = {
        send_window = DEFAULT_WINDOW_SIZE,
        recv_window = DEFAULT_WINDOW_SIZE,
        init_window = DEFAULT_WINDOW_SIZE,
        preread_size = DEFAULT_WINDOW_SIZE,

        recv = recv, -- handler for reading data
        send = send, -- handler for writing data
        ctx = ctx,

        last_stream_id = 0x0,
        next_stream_id = 0x3, -- 0x1 is used for the HTTP/1.1 upgrade
        enable_push = false,

        stream = new_tab(4, 0),

        goaway = false,

        output_queue = nil,
        output_queue_size = 0,
        last_frame = nil, -- last frame in the output queue

        root = root,
    }

    return setmetatable(session, mt)
end


-- send the default settings and advertise the window size
-- for the whole connection
function _M:init(preread_size)
    preread_size = preread_size or self.preread_size

    local payload = {
        { id = MAX_STREAMS_SETTING, value = DEFAULT_MAX_STREAMS },
        { id = INIT_WINDOW_SIZE_SETTING, value = preread_size },
        { id = MAX_FRAME_SIZE_SETTING, value = DEFAULT_MAX_FRAME_SIZE },
    }

    local sf, err = h2_frame.settings.new(0x0, h2_frame.FLAG_NONE, payload)

    if not sf then
        return nil, err
    end

    local incr = h2_frame.MAX_WINDOW - DEFAULT_WINDOW_SIZE

    local wf
    wf, err = h2_frame.window_update.new(0x0, incr)
    if not wf then
        return nil, err
    end

    self.recv_window = h2_frame.MAX_WINDOW

    self:frame_queue(sf)
    self:frame_queue(wf)

    return self:flush_queue()
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
        h2_frame.pack[frame.header.type](frame, send_buffer)
        frame = frame.next
    end

    self.output_queue_size = 0
    self.output_queue = nil

    local _, err = self.send(self.ctx, send_buffer)
    if err then
        return nil, err
    end

    return true
end


-- submit a request
function _M:submit_request(headers, no_body, priority, pad)
    if #headers == 0 then
        return nil, "empty headers"
    end

    local sid = self.next_stream_id
    if sid > MAX_STREAM_ID then
        return nil, "stream id overflow"
    end

    self.next_stream_id = sid + 2 -- odd number

    -- TODO custom stream weight
    local stream, err = h2_stream.new(sid, h2_stream.DEFAULT_WEIGHT, self)
    if not stream then
        return nil, err
    end

    local ok
    ok, err = stream:submit_headers(headers, no_body, priority, pad)
    if not ok then
        return nil, err
    end

    self.stream[sid] = stream

    return stream
end


function _M:close()
    if self.goaway then
        return
    end

    self.goaway = true
end


function _M:rst()
end
