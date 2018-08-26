-- Copyright Alex Zhang (tokers)

local util = require "resty.http2.util"
local h2_frame = require "resty.http2.frame"
local h2_stream = require "resty.http2.stream"
local hpack = require "resty.http2.hpack"

local new_tab = util.new_tab
local clear_tab = util.clear_tab
local is_num = util.is_num
local is_tab = util.is_tab
local concat = table.concat
local lower = string.lower
local pairs = pairs

local MAX_STREAMS_SETTING = 0x3
local INIT_WINDOW_SIZE_SETTING = 0x4
local MAX_FRAME_SIZE_SETTING = 0x5
local MAX_STREAM_ID = 0x7fffffff
local DEFAULT_WINDOW_SIZE = 65535
local DEFAULT_MAX_STREAMS = 128
local DEFAULT_MAX_FRAME_SIZE = 0xffffff

local INITIAL_SETTINGS_PAYLOAD = {
    { id = MAX_STREAMS_SETTING, value = DEFAULT_MAX_STREAMS },
    { id = INIT_WINDOW_SIZE_SETTING, value = DEFAULT_WINDOW_SIZE },
    { id = MAX_FRAME_SIZE_SETTING, value = DEFAULT_MAX_FRAME_SIZE },
}

local IS_CONNECTION_SPEC_HEADERS = {
    ["connection"] = true,
    ["keep-alive"] = true,
    ["proxy-connection"] = true,
    ["upgrade"] = true,
    ["transfer-encoding"] = true,
}

local frag
local frag_len = 0
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
        send_window = nil,
        recv_window = nil,

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
function _M:init()
    self.send_window = DEFAULT_WINDOW_SIZE
    self.recv_window = DEFAULT_WINDOW_SIZE

    local payload = INITIAL_SETTINGS_PAYLOAD
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
    local output_queue = self.output_queue
    if not output_queue then
        return true
    end
end


-- serialize headers and create a headers frame,
-- note this function does not check the HTTP protocol semantics,
-- callers should check this in the higher land.
function _M:submit_headers(headers, end_stream, priority, pad, sid)
    local headers_count = #headers
    if frag_len < headers_count then
        frag = new_tab(headers_count, 0)
        frag_len = headers_count
    else
        clear_tab(frag)
    end

    for name, value in pairs(headers) do
        name = lower(name)
        if IS_CONNECTION_SPEC_HEADERS[name] then
            goto continue
        end

        local index = hpack.COMMON_REQUEST_HEADERS_INDEX[name]
        if is_num(index) then
            frag[#frag + 1] = hpack.incr_indexed(index)
            hpack.encode(value, frag, false)
            goto continue
        end

        if is_tab(index) then
            for v_name, v_index in pairs(index) do
                if value == v_name then
                    frag[#frag + 1] = hpack.indexed(v_index)
                    goto continue
                end
            end
        end

        hpack.encode(name, frag, true)
        hpack.encode(value, frag, true)

        ::continue::
    end

    frag = concat(frag)
    local frame, err = h2_frame.headers.new(frag, priority, pad, end_stream,
                                            sid)
    if not frame then
        return nil, err
    end

    self:frame_queue(frame)
end


-- submit a request
function _M:submit_request(headers, body, priority, pad)
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
    ok, err = self:submit_headers(headers, not body, priority, pad)
    if not ok then
        return nil, err
    end

    self.stream[sid] = sid

    return true
end


function _M:close()
    if self.goaway then
        return
    end

    self.goaway = true
end


function _M:rst()
end
