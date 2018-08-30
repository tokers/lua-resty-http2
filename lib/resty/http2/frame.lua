-- Copyright Alex Zhang (tokers)

local bit = require "bit"
local util = require "resty.http2.util"
local h2_stream = require "resty.http2.stream"
local h2_error = require "resty.http2.h2_error"

local bor = bit.bor
local band = bit.band
local blshift = bit.lshift
local brshift = bit.rshift
local char = string.char
local byte = string.byte
local sub = string.sub
local new_tab = util.new_tab
local pack_u16 = util.pack_u16
local unpack_u16 = util.unpack_u16
local pack_u32 = util.pack_u32
local unpack_u32 = util.unpack_u32
local new_buffer = util.new_buffer
local debug_log = util.debug_log

local MAX_WINDOW = h2_stream.MAX_WINDOW
local HEADER_SIZE = 9
local DEFAULT_FRAME_SIZE = 16384
local MAX_FRAME_SIZE = 16777215

local FLAG_NONE = 0x0
local FLAG_ACK = 0x1
local FLAG_END_STREAM = 0x1
local FLAG_END_HEADERS = 0x4
local FLAG_PADDED = 0x8
local FLAG_PRIORITY = 0x20

local DATA_FRAME = 0x0
local HEADERS_FRAME = 0x1
local PRIORITY_FRAME = 0x2
local RST_STREAM_FRAME = 0x3
local SETTINGS_FRAME = 0x4
local PUSH_PROMISE_FRAME = 0x5
local PING_FRAME = 0x6
local GOAWAY_FRAME = 0x7
local WINDOW_UPDATE_FRAME = 0x8
local CONTINUATION_FRAME = 0x9

local SETTINGS_ENABLE_PUSH = 0x2
local SETTINGS_MAX_CONCURRENT_STREAMS = 0x3
local SETTINGS_INITIAL_WINDOW_SIZE = 0x4
local SETTINGS_MAX_FRAME_SIZE = 0x5


local _M = {
    _VERSION = "0.1",
}

local header = {} -- frame header
local priority = {} -- priority frame
local rst = {} -- rst frame
local settings = {} -- settings frame
local ping = {} -- ping frame
local goaway = {} -- goaway frame
local window_update = {} -- window_update frame
local headers = {} -- headers frame
local continuation = {} -- continuation frame
local rst_stream = {} -- rst_stream frame
local data = {} -- data frame
local push_promise = {} -- push_promise frame


function header.new(length, typ, flags, id)
    local flag_ack = band(flags, FLAG_ACK) ~= 0
    local flag_end_stream = band(flags, FLAG_END_STREAM) ~= 0
    local flag_end_headers = band(flags, FLAG_END_HEADERS) ~= 0
    local flag_padded = band(flags, FLAG_PADDED) ~= 0
    local flag_priority = band(flags, FLAG_PRIORITY) ~= 0

    return {
        length = length,
        type = typ,
        flags = flags,
        id = id,
        flag_ack = flag_ack,
        flag_end_stream = flag_end_stream,
        flag_end_headers = flag_end_headers,
        flag_padded = flag_padded,
        flag_priority = flag_priority,
    }
end


function header.pack(hd, dst)
    -- length (24)
    local length = hd.length
    for i = 16, 0, -8 do
        dst[#dst + 1] = char(band(brshift(length, i), 0xff))
    end

    dst[#dst + 1] = char(band(hd.type, 0xff))
    dst[#dst + 1] = char(band(hd.flags, 0xff))

    pack_u32(hd.id, dst)
end


function header.unpack(src)
    local b1, b2, b3 = byte(src, 1, 3)
    local length = bor(bor(blshift(b1, 16), blshift(b2, 8)), b3)

    local typ = byte(src, 4)
    local flags = byte(src, 5)

    local id = unpack_u32(byte(src, 6, 9))

    return header.new(length, typ, flags, id)
end


function priority.pack(pf, dst)
    header.pack(pf.header, dst)

    local depend = pf.depend
    local excl = pf.excl
    local weight = pf.weight

    if excl then
        depend = bor(depend, blshift(1, 31))
    end

    pack_u32(depend, dst)

    dst[#dst + 1] = char(weight)
end


function priority.unpack(pf, src, stream)
    local sid = stream.sid
    if sid == 0x0 then
        debug_log("server sent PRIORITY frame with incorrect ",
                  "stream idenitifier: 0x0")
        return nil, h2_error.PROTOCOL_ERROR
    end

    local payload_length = pf.header.length
    if payload_length ~= 5 then
        debug_log("server sent PRIORITY frame with incorrect payload length: ",
                  payload_length)
        return nil, h2_error.STREAM_FRAME_SIZE_ERROR
    end

    local b1, b2, b3, b4, b5 = byte(src, 1, 5)

    if b1 > 127 then
        b1 = b1 - 127
        pf.excl = 1

    else
        pf.excl = 0
    end

    local depend = unpack_u32(b1, b2, b3, b4)
    local weight = b5

    if depend == sid then
        debug_log("server sent PRIORITY frame with incorrect dependent stream: ",
                  depend)
        return nil, h2_error.PROTOCOL_ERROR
    end

    local session = stream.session

    local depend_stream = session.stream_map[depend]
    if not depend_stream then -- not in the dependency tree
        depend_stream = h2_stream.new(sid, h2_stream.DEFAULT_WEIGHT, session)
    end

    pf.weight = weight
    pf.depend = depend

    stream:set_dependency(depend_stream, pf.excl)

    return true
end


function rst.pack(rf, dst)
    header.pack(rf.header, dst)
    pack_u32(rf.error_code, dst)
end


function rst.unpack(rf, src, stream)
    local sid = rf.header.sid
    if sid == 0x0 then
        debug_log("server sent RST_STREAM frame with ",
                  "incorrect stream identifier: 0x0")
        return nil, h2_error.PROTOCOL_ERROR
    end

    local state = stream.state
    if state == h2_stream.STATE_IDLE then
        debug_log("server sent RST_STREAM frame for stream: ", sid,
                  " with invalid state")
        return nil, h2_error.PROTOCOL_ERROR
    end

    local length = rf.header.length
    if length ~= 4 then
        debug_log("server sent RST_STREAM frame with incorrect payload length ",
                  length)
        return nil, h2_error.PROTOCOL_ERROR
    end

    rf.error_code = unpack_u32(byte(src, 1, 4))

    return true
end


function rst.new(error_code, sid)
    local hd = header.new(4, RST_STREAM_FRAME, FLAG_NONE, sid)

    return {
        header = hd,
        error_code = error_code,
        next = nil,
    }
end


function settings.pack(sf, dst)
    header.pack(sf.header, dst)

    for i = 1, #sf.item do
        pack_u16(sf.item[i].id, dst)
        pack_u32(sf.item[i].value, dst)
    end
end


function settings.unpack(sf, src, stream)
    local ack = sf.header.flag_ack
    local payload_length = sf.header.length

    if ack and payload_length > 0 then
        debug_log("server sent SETTINGS frame with ACK flag ",
                  "and non-empty payloads")
        return nil, h2_error.FRAME_SIZE_ERROR
    end

    local sid = sf.header.sid
    if sid ~= 0x0 then
        debug_log("server sent SETTINGS frame with incorrect ",
                   "stream identifier: ", sid)
        return nil, h2_error.PROTOCOL_ERROR
    end

    if payload_length % 6 ~= 0 then
        debug_log("server sent SETTINGS frame with incorrect payload length: ",
                   payload_length)
        return nil, h2_error.FRAME_SIZE_ERROR
    end

    local session = stream.session
    local count = payload_length / 6
    sf.item = new_tab(count, 0)
    local offset = 0

    for i = 1, count do
        local id = unpack_u16(byte(src, offset + 1, offset + 2))
        local value = unpack_u32(byte(src, offset + 3, offset + 6))

        sf.item[i] = { id = id, value = value }

        offset = offset + 6

        -- TODO handle SETTINGS_HEADER_TABLE_SIZE
        -- and SETTINGS_MAX_HEADER_LIST_SIZE

        if id == SETTINGS_INITIAL_WINDOW_SIZE then
            if value > MAX_WINDOW then
                debug_log("server sent SETTINGS frame with improper ",
                          "SETTINGS_INITIAL_WINDOW_SIZE value: ", value)
                return nil, h2_error.FRAME_SIZE_ERROR
            end

            session.init_window = value

        elseif id == SETTINGS_MAX_CONCURRENT_STREAMS then
            session.max_stream = value

        elseif id == SETTINGS_ENABLE_PUSH then
            -- this setting makes no sense for client side,
            -- we just check the value
            if value > 1 then
                debug_log("server sent SETTINGS frame with improper ",
                          "SETTINGS_MAX_CONCURRENT_STREAMS value: ", value)
                return nil, h2_error.PROTOCOL_ERROR
            end

        elseif id == SETTINGS_MAX_FRAME_SIZE then
            if value > MAX_FRAME_SIZE or value < DEFAULT_FRAME_SIZE then
                debug_log("server sent SETTINGS frame with improper ",
                          "SETTINGS_MAX_FRAME_SIZE value: ", value)
                return nil, h2_error.PROTOCOL_ERROR
            end

            session.max_frame_size = value
        end
    end

    return true
end


function settings.new(sid, flags, payload)
    local hd = header.new(6 * #payload, SETTINGS_FRAME, flags, sid)

    return {
        header = hd,
        item = payload,
        next = nil,
    }
end


function ping.pack(pf, dst)
    header.pack(pf.header, dst)
    pack_u32(pf.opaque_data_hi, dst)
    pack_u32(pf.opaque_data_lo, dst)
end


function ping.unpack(pf, src, stream)
    local sid = stream.sid
    if sid ~= 0x0 then
        debug_log("server sent PING frame with incorrect stream identifier: ",
                  sid)
        return nil, h2_error.PROTOCOL_ERROR
    end

    local payload_length = pf.header.length
    if payload_length ~= 8 then
        debug_log("server sent PING frame with incorrect payload length: ",
                  payload_length)
        return nil ,h2_error.FRAME_SIZE_ERROR
    end

    pf.opaque_data_hi = unpack_u32(byte(src, 1, 4))
    pf.opaque_data_lo = unpack_u32(byte(src, 5, 8))
end


function goaway.pack(gf, dst)
    header.pack(gf.header, dst)
    pack_u32(gf.last_stream_id)
    pack_u32(gf.error_code)

    if gf.debug_data then
        dst[#dst + 1] = gf.debug_data
    end
end


function goaway.unpack(gf, src, stream)
    local payload_length = gf.header.length
    if payload_length < 4 then
        debug_log("server sent GOAWAY frame with incorrect payload length: ",
                  payload_length)
        return nil, h2_error.FRAME_SIZE_ERROR
    end

    local sid = stream.sid
    if sid ~= 0x0 then
        debug_log("server sent GOAWAY frame with incorrect stream identifier: ",
                  sid)
        return nil, h2_error.PROTOCOL_ERROR
    end

    local session = stream.session
    local last_stream_id = unpack_u32(byte(src, 1, 4))
    local error_code = unpack_u32(byte(src, 5, 8))

    session.goaway_received = true
    session.last_stream_id = last_stream_id
    gf.last_stream_id = last_stream_id
    gf.error_code = error_code

    debug_log("server sent GOAWAY frame with last stream id: ", last_stream_id,
              ", error_code: ", error_code)

    if payload_length > 8 then
        gf.debug_data = sub(src, 9, payload_length - 8)
    end

    return true
end


function goaway.new(last_sid, error_code, debug_data)
    local debug_data_len = debug_data and #debug_data or 0
    local hd = header.new(8 + debug_data_len, GOAWAY_FRAME, FLAG_NONE, 0)

    return {
        header = hd,
        last_stream_id = last_sid,
        error_code = error_code,
        debug_data = debug_data,
        next = nil,
    }
end


function window_update.pack(wf, dst)
    header.pack(wf.header, dst)
    pack_u32(wf.window_size_increment, dst)
end


function window_update.unpack(wf, src)
    wf.window_size_increment = band(unpack_u32(byte(src, 1, 4)), 0x7fffffff)
end


function window_update.new(sid, window)
    local hd = header.new(4, WINDOW_UPDATE_FRAME, FLAG_NONE, sid)
    return {
        header = hd,
        window_size_increment = window,
        next = nil,
    }
end


function headers.pack(hf, dst)
    header.pack(hf, dst)

    local flag_padded = hf.header.flag_padded
    local flag_priority = hf.header.flag_priority

    if flag_padded then
        local pad_length = #hf.pad
        dst[#dst + 1] = char(pad_length)
    end

    if flag_priority then
        local depend = hf.depend
        local excl = hf.excl

        if excl then
            depend = bor(depend, 0x7fffffff)
        end

        pack_u32(depend, dst)
        dst[#dst + 1] = char(hf.weight)
    end

    dst[#dst + 1] = hf.block_frags

    if flag_padded then
        dst[#dst + 1] = hf.pad
    end
end


function headers.unpack(hf, src, stream)
    local hd = hf.header

    local flag_padded = hd.FLAG_PADDED
    local flag_priority = hd.FLAG_PRIORITY

    local length = hd.length
    local offset = 0
    local size = 0
    local depend
    local weight
    local excl = false

    local sid = stream.sid
    local session = stream.session
    local next_stream_id = session.next_stream_id

    if sid % 2 == 1 or sid >= next_stream_id then
        debug_log("server sent HEADERS frame with incorrect identifier", sid)
        return nil, h2_error.PROTOCOL_ERROR
    end

    local state = stream.state
    if state ~= h2_stream.STATE_OPEN and
       state ~= h2_stream.STATE_IDLE and
       state ~= h2_stream.STATE_REVERSED_LOCAL and
       state ~= h2_stream.STATE_HALF_CLOSED_REMOTE
    then
        debug_log("server sent HEADERS frame for stream ", sid,
                  " with invalid state")
        return nil, h2_error.PROTOCOL_ERROR
    end

    if flag_padded then
        size = 1
    end

    if flag_priority then
        -- stream dependency (32) + weight (8)
        size = size + 5
    end

    if size <= length then
        debug_log("server sent HEADERS frame with incorrect length ", length)
        return nil, h2_error.FRAME_SIZE_ERROR
    end

    length = length - size

    if flag_padded then
        local pad_length = band(byte(src, 1, 1), 0xff)
        if length < pad_length then
            debug_log("server sent padded HEADERS frame with ",
                      "incorrect length: ", length, ", padding: ", pad_length)
            return nil, h2_error.FRAME_SIZE_ERROR
        end

        offset = 1
        length = length - pad_length
    end

    if flag_priority then
        depend = unpack_u32(byte(src, offset + 1, offset + 4))
        if band(brshift(depend, 31), 1) then
            excl = true
        end

        depend = band(depend, 0x7fffffff)

        weight = band(byte(src, offset + 5, offset + 5), 0xff)
        offset = offset + 5

        debug_log("HEADERS frame sid: ", sid, " depends on ", depend,
                  " excl: ", excl, "weight: ", weight)

        if depend == sid then
            debug_log("server sent HEADERS frame for stream ", sid,
                      " with incorrect dependency")
            return nil, h2_error.STREAM_PROTOCOL_ERROR
        end

        stream.weight = weight

        local depend_stream = session.stream_map[depend]
        if not depend_stream then
            -- not in the dependency tree
            depend_stream = h2_stream.new(depend, h2_stream.DEFAULT_WEIGHT,
                                          session)
        end

        stream:set_dependency(depend_stream, excl)
    end

    if hd.FLAG_END_STREAM then
        if state == h2_stream.STATE_OPEN then
            stream.state = h2_stream.STATE_HALF_CLOSED_REMOTE
        elseif state == h2_stream.STATE_IDLE then
            stream.state = h2_stream.STATE_OPEN
        else
            stream.state = h2_stream.STATE_CLOSED
        end
    end

    if length > 0 then
        local buffer = new_buffer(src, offset, offset + length)
        local cached = session.hpack.cached
        if not cached then
            session.hpack.cached = buffer
            session.hpack.last_cache = buffer
        else
            session.hpack.last_cache.next = buffer
            session.hpack.last_cache = buffer
        end
    end

    -- just skip the incompleting decode operation
    -- if we don't receive the whole headers (it's rare),
    -- that makes the hpack codes simple. :)
    if hd.flag_end_headers then
        -- XXX don't have a good way to estimate a proper size
        hf.block_frags = new_tab(0, 8)
        return session.hpack:decode(hf.block_frags)
    end

    debug_log("server sent large headers which cannot be ",
              "fitted in a single HEADERS frame")

    session.incomplete_headers = true
    session.current_sid = sid
    return true
end


function headers.new(frags, pri, pad, end_stream, sid)
    local payload_length = #frags
    local flags = FLAG_NONE

    if end_stream then
        flags = bor(flags, FLAG_END_STREAM)
    end

    if pri then
        flags = bor(flags, FLAG_PRIORITY)
    end

    -- basically we don't use this but still we should respect it
    if pad then
        flags = bor(flags, FLAG_PADDED)
        payload_length = payload_length + #pad
    end

    local hd = header.new(payload_length, HEADERS_FRAME, flags, sid)

    return {
        header = hd,
        depend = pri.sid,
        weight = pri.weight,
        excl = pri.excl,
        block_frags = frags,
        pad = pad,
        next = nil,
    }
end


function continuation.pack(cf, dst)
    header.pack(cf, dst)
    dst[#dst + 1] = cf.block_frags
end


function continuation.unpack(cf, src, stream)
    local session = stream.session

    if not session.incomplete_headers then
        debug_log("server sent unexpected CONTINUATION frame")
        return nil, h2_error.PROTOCOL_ERROR
    end

    if #src > 0 then
        local buffer = new_buffer(src, 1, #src + 1)
        session.hpack.last_cache.next = buffer
        session.hpack.last_cache = buffer
    end

    if cf.header.flag_end_headers then
        session.incomplete_headers = false
        session.current_sid = -1

        -- XXX don't have a good way to estimate a proper size
        cf.block_frags = new_tab(0, 4)
        return session.hpack:decode(cf.block_frags)
    end

    return true
end


function continuation.new(frags, end_headers, sid)
    local payload_length = #frags
    local flags = FLAG_NONE

    if end_headers then
        flags = bor(flags, FLAG_END_HEADERS)
    end

    local hd = header.new(payload_length, CONTINUATION_FRAME, flags, sid)

    return {
        header = hd,
        block_frags = frags,
        next = nil,
    }
end


function rst_stream.pack(rf, dst)
    header.pack(rf, dst)
    pack_u32(rf.error_code, dst)
end


function rst_stream.unpack(rf, src)
    rf.error_code = unpack_u32(byte(src, 1, 4))
end


function data.pack(df, dst)
    header.pack(df, dst)

    local flag_padded = df.header.FLAG_PADDED
    if flag_padded then
        local length = #df.pad
        dst[#dst + 1] = char(length)
    end

    dst[#dst + 1] = df.payload

    if flag_padded then
        dst[#dst + 1] = df.pad
    end
end


function data.unpack(df, src, stream)
    local sid = stream.sid

    if sid == 0x0 then
        debug_log("server sent DATA frame with incorrect identifier ", sid)
        return nil, h2_error.PROTOCOL_ERROR
    end

    local state = stream.state
    if state ~= h2_stream.STATE_OPEN and
       state ~= h2_stream.STATE_HALF_CLOSED_LOCAL
    then
        debug_log("server sent DATA frame for stream ", sid,
                  " with invalid state")
        return nil, h2_error.STREAM_CLOSED
    end

    local hd = df.header
    local flag_padded = hd.FLAG_PADDED
    local length = hd.length

    if flag_padded then
        if length == 0 then
            debug_log("server sent padded DATA frame with incorrect length: 0")
            return nil, h2_error.FRAME_SIZE_ERROR
        end

        local pad_length = band(byte(src, 1, 1), 0xff)

        if pad_length >= length then
            debug_log("server sent padded DATA frame with incorrect length: ",
                      length, ", padding: ", pad_length)
            return nil, h2_error.PROTOCOL_ERROR
        end

        df.payload = sub(src, 2, 1 + length - pad_length)
    else
        df.payload = src
    end

    if state == h2_stream.STATE_OPEN then
        stream.state = h2_stream.STATE_HALF_CLOSED_REMOTE
    else
        stream.state = h2_stream.STATE_CLOSED
    end

    local session = stream.session
    local recv_window = session.recv_window
    if length > recv_window then
        return nil, h2_error.FLOW_CONTROL_ERROR
    end

    recv_window = recv_window - length
    if recv_window * 4 < MAX_WINDOW then
        if not session:submit_window_update(MAX_WINDOW - recv_window) then
            return nil, h2_error.INTERNAL_ERROR
        end

        recv_window = MAX_WINDOW
    end

    session.recv_window = recv_window

    local init_window = stream.init_window
    recv_window = stream.recv_window
    if length > recv_window then
        return nil, h2_error.STREAM_FLOW_CONTROL_ERROR
    end

    recv_window = recv_window - length
    if recv_window * 4 < init_window then
        if not session:submit_window_update(MAX_WINDOW - recv_window) then
            return nil, h2_error.INTERNAL_ERROR
        end

        recv_window = init_window
    end

    stream.recv_window = recv_window

    return true
end


function data.new(payload, pad, last, sid)
    local flags = FLAG_NONE
    if last then
        flags = bor(flags, FLAG_END_STREAM)
    end

    if pad then
        flags = bor(flags, FLAG_PADDED)
    end

    local pad_length = pad and #pad or 0

    local hd = header.new(#payload + pad_length, DATA_FRAME, flags, sid)

    return {
        header = hd,
        pad = pad,
        payload = payload,
        next = nil,
    }
end


-- XXX just prohibits the PUSH_PROMISE frame,
-- maybe it will be supported in the future
function push_promise.unpack()
    debug_log("server sent PUSH_PROMISE frame with ",
              "ignoring SETTINGS_ENABLE_PUSH setting")
    return h2_error.PROTOCOL_ERROR
end


_M.header = header
_M.priority = priority
_M.rst = rst
_M.settings = settings
_M.ping = ping
_M.goaway = goaway
_M.window_update = window_update
_M.headers = headers
_M.continuation = continuation
_M.rst_stream = rst_stream
_M.data = data
_M.push_promise = push_promise

_M.FLAG_NONE = FLAG_NONE
_M.FLAG_ACK = FLAG_ACK
_M.FLAG_END_STREAM = FLAG_END_STREAM
_M.FLAG_END_HEADERS = FLAG_END_HEADERS
_M.FLAG_PADDED = FLAG_PADDED
_M.FLAG_PRIORITY = FLAG_PRIORITY

_M.HEADER_SIZE = HEADER_SIZE

_M.DATA_FRAME = DATA_FRAME
_M.HEADERS_FRAME = HEADERS_FRAME
_M.PRIORITY_FRAME = PRIORITY_FRAME
_M.RST_STREAM_FRAME = RST_STREAM_FRAME
_M.SETTINGS_FRAME = SETTINGS_FRAME
_M.PUSH_PROMISE_FRAME = PUSH_PROMISE_FRAME
_M.PING_FRAME = PING_FRAME
_M.GOAWAY_FRAME = GOAWAY_FRAME
_M.WINDOW_UPDATE_FRAME = WINDOW_UPDATE_FRAME
_M.CONTINUATION_FRAME = CONTINUATION_FRAME

_M.MAX_FRAME_SIZE = MAX_FRAME_SIZE
_M.DEFAULT_FRAME_SIZE = DEFAULT_FRAME_SIZE
_M.MAX_FRAME_ID = 0x9

_M.SETTINGS_ENABLE_PUSH = SETTINGS_ENABLE_PUSH
_M.SETTINGS_MAX_CONCURRENT_STREAMS = SETTINGS_MAX_CONCURRENT_STREAMS
_M.SETTINGS_INITIAL_WINDOW_SIZE = SETTINGS_INITIAL_WINDOW_SIZE
_M.SETTINGS_MAX_FRAME_SIZE = SETTINGS_MAX_FRAME_SIZE

_M.pack = {
    [DATA_FRAME] = data.pack,
    [HEADERS_FRAME] = headers.pack,
    [PRIORITY_FRAME] = priority.pack,
    [RST_STREAM_FRAME] = rst_stream.pack,
    [SETTINGS_FRAME] = settings.pack,
    [PING_FRAME] = ping.pack,
    [GOAWAY_FRAME] = goaway.pack,
    [WINDOW_UPDATE_FRAME] = window_update.pack,
    [CONTINUATION_FRAME] = continuation.pack,
}

_M.unpack = {
    [DATA_FRAME] = data.unpack,
    [HEADERS_FRAME] = headers.unpack,
    [PRIORITY_FRAME] = priority.unpack,
    [RST_STREAM_FRAME] = rst_stream.unpack,
    [SETTINGS_FRAME] = settings.unpack,
    [PING_FRAME] = ping.unpack,
    [GOAWAY_FRAME] = goaway.unpack,
    [WINDOW_UPDATE_FRAME] = window_update.unpack,
    [CONTINUATION_FRAME] = continuation.pack,
    [PUSH_PROMISE_FRAME] = push_promise.unpack,
}

_M.sizeof = {
    [DATA_FRAME] = 4,
    [HEADERS_FRAME] = 7,
    [PRIORITY_FRAME] = 5,
    [RST_STREAM_FRAME] = 3,
    [SETTINGS_FRAME] = 4,
    [PING_FRAME] = 4,
    [GOAWAY_FRAME] = 5,
    [WINDOW_UPDATE_FRAME] = 3,
    [CONTINUATION_FRAME] = 3,
    [PUSH_PROMISE_FRAME] = 1,
}


return _M
