-- Copyright Alex Zhang (tokers)

local bit = require "bit"
local util = require "resty.http2.util"

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

local WINDOW_UPDATE_PAYLOAD_SIZE = 4
local MAX_WINDOW = 0x7fffffff -- 2^31 - 1
local HEADER_SIZE = 9

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
local rst_stream = {} -- rst_stream frame
local data = {} -- data frame


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
        depend = bor(depend, 0x7fffffff)
    end

    pack_u32(depend, dst)

    dst[#dst + 1] = char(weight)
end


function priority.unpack(pf, src)
    local b1, b2, b3, b4, b5 = byte(src, 1, 5)

    if b1 > 127 then
        b1 = b1 - 127
        pf.excl = 1

    else
        pf.excl = 0
    end

    pf.depend = unpack_u32(b1, b2, b3, b4)
    pf.weight = b5
end


function rst.pack(rf, dst)
    header.pack(rf.header, dst)
    pack_u32(rf.error_code, dst)
end


function rst.unpack(rf, src)
    rf.error_code = unpack_u32(byte(src, 1, 4))
end


function settings.pack(sf, dst)
    header.pack(sf.header, dst)

    for i = 1, #sf.item do
        pack_u16(sf.item[i].id, dst)
        pack_u32(sf.item[i].value, dst)
    end
end


function settings.unpack(sf, src, count)
    sf.item = new_tab(count, 0)
    local offset = 0

    for i = 1, count do
        local id = unpack_u16(byte(src, offset + 1, offset + 2))
        local value = unpack_u32(byte(src, offset + 3, offset + 6))

        sf.item[i] = { id = id, value = value }

        offset = offset + 6
    end
end


function settings.new(sid, flags, payload)
    local count = #payload

    if band(flags, FLAG_ACK) and count > 0 then
        return nil, "settings frame with ACK flag cannot take payloads"
    end

    local hd = header.new(6 * count, SETTINGS_FRAME, flags, sid)

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


function ping.unpack(pf, src)
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


function goaway.unpack(gf, src)
    local payload_length = gf.header.length
    gf.last_stream_id = unpack_u32(byte(src, 1, 4))
    gf.error_code = unpack_u32(byte(src, 5, 8))

    if payload_length > 8 then
        gf.debug_data = sub(src, 9, payload_length - 8)
    end
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
    if window < 1 or window > MAX_WINDOW then
        return nil, "invalid window size"
    end

    local hd = header.new(WINDOW_UPDATE_PAYLOAD_SIZE, WINDOW_UPDATE_FRAME,
                          FLAG_NONE, sid)
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


function headers.unpack(hf, src)
end


function headers.new(frags, pri, pad, end_stream, sid)
    local payload_length = #frags
    local flags = FLAG_NONE

    if end_stream then
        flags = bor(flags, FLAG_END_STREAM)
    end

    if pri then
        if sid == pri.sid then
            return nil, "stream cannont be self dependency"
        end

        flags = bor(flags, FLAG_PRIORITY)
    end

    -- basically we don't use this but still we should respect it
    if pad then
        if #pad > 255 then
            return nil, "invalid pad length"
        end

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


function data.unpack(df, src)
end


function data.new(payload, pad, last, sid)
    if sid == 0x0 then
        return nil, "invalid stream id"
    end

    local flags = FLAG_NONE
    if last then
        flags = bor(flags, FLAG_END_STREAM)
    end

    if pad then
        if #pad > 255 then
            return nil, "invalid pad length"
        end

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


_M.header = header
_M.priority = priority
_M.rst = rst
_M.settings = settings
_M.ping = ping
_M.goaway = goaway
_M.window_update = window_update
_M.headers = headers
_M.rst_stream = rst_stream
_M.data = data

_M.FRAME_NONE = FLAG_NONE
_M.FRAME_ACK = FLAG_ACK
_M.FRAME_END_STREAM = FLAG_END_STREAM
_M.FRAME_END_HEADERS = FLAG_END_HEADERS
_M.FRAME_PADDED = FLAG_PADDED
_M.FRAME_PRIORITY = FLAG_PRIORITY

_M.MAX_WINDOW = MAX_WINDOW
_M.HEADER_SIZE = HEADER_SIZE

_M.DATA_FRAME = DATA_FRAME

_M.pack = {
    [DATA_FRAME] = data.pack,
    [HEADERS_FRAME] = headers.pack,
    [PRIORITY_FRAME] = priority.pack,
    [RST_STREAM_FRAME] = rst_stream.pack,
    [SETTINGS_FRAME] = settings.pack,
    [PING_FRAME] = ping.pack,
    [GOAWAY_FRAME] = goaway.pack,
    [WINDOW_UPDATE_FRAME] = window_update.pack,
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
}


return _M
