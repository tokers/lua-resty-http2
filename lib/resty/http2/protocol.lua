-- Copyright Alex Zhang (tokers)

local bit = require "bit"
local util = require "resty.http2.util"
local h2_frame = require "resty.http2.frame"
local h2_stream = require "resty.http2.stream"

local new_tab = util.new_tab
local band = bit.band
local bor = bit.bor
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


local _M = {
    _VERSION = "0.1",
}

local mt = { __index = _M }


local function submit_headers()
end


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

        stream = new_tab(0, 0),

        wco = nil,
        rco = nil,

        goaway = false,

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

    -- send the SETTINGS the WINDOW_UPDATE frames
    local size = 2 * h2_frame.HEADER_SIZE + sf.header.length + wf.header.length

    local data = new_tab(size, 0)

    h2_frame.settings.pack(sf, data)
    h2_frame.window_update.pack(wf, data)

    _, err = self.send(self.ctx, data)
    if err then
        return nil, err
    end

    return true
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

    local payload_length = 0
    local pad_length = 0

    local flags = h2_frame.FLAG_NONE
    if not body then
        flags = bor(flags, h2_frame.FLAG_END_STREAM)
    end

    if priority then
        flags = bor(flags, h2_frame.PRIORITY)
        if priority.sid == sid then -- self dependency
            return nil, "stream cannot be self dependency"
        end
    end

    -- basically we don't use this but still we should respect it
    if pad then
        flags = bor(flags, h2_frame.FLAG_PADDED)
        pad_length = pad.length
    end

    return true
end


function _M:flush()
end


function _M:close()
    if self.goaway then
        return
    end

    self.goaway = true
end
