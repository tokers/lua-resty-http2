-- Copyright Alex Zhang (tokers)

local _M = { _VERSION = "0.1" }

local NO_ERROR = 0x0
local PROTOCOL_ERROR = 0x1
local INTERNAL_ERROR = 0x2
local FLOW_CONTROL_ERROR = 0x3
local SETTINGS_TIMEOUT = 0x4
local STREAM_CLOSED = 0x5
local FRAME_SIZE_ERROR = 0x6
local REFUSED_STREAM = 0x7
local CANCEL = 0x8
local COMPRESSION_ERROR = 0x9
local CONNECT_ERROR = 0xa
local ENHANCE_YOUR_CALM = 0xb
local INADEQUATE_SECURITY = 0xc
local HTTP_1_1_REQUIRED = 0xd

-- we use negative codes to represent the some stream-level errors
local STREAM_PROTOCOL_ERROR = -PROTOCOL_ERROR
local STREAM_FLOW_CONTROL_ERROR = -FLOW_CONTROL_ERROR
local STREAM_FRAME_SIZE_ERROR = -FRAME_SIZE_ERROR

local error_map = {
    [NO_ERROR] = "no error",
    [PROTOCOL_ERROR] = "protocol error",
    [INTERNAL_ERROR] = "internal error",
    [FLOW_CONTROL_ERROR] = "flow control error",
    [SETTINGS_TIMEOUT] = "settings timeout",
    [STREAM_CLOSED] = "stream closed",
    [FRAME_SIZE_ERROR] = "frame size error",
    [REFUSED_STREAM] = "refused stream",
    [CANCEL] = "cancel",
    [COMPRESSION_ERROR] = "compression error",
    [CONNECT_ERROR] = "connect error",
    [ENHANCE_YOUR_CALM] = "enhanced your calm",
    [INADEQUATE_SECURITY] = "inadequate security",
    [HTTP_1_1_REQUIRED] = "http/1.1 required",

    [STREAM_FRAME_SIZE_ERROR] = "frame size error (stream level)",
    [STREAM_PROTOCOL_ERROR] = "protocol error (stream level)",
    [STREAM_FLOW_CONTROL_ERROR] = "flow control error (stream level)",
}


function _M.strerror(code)
    return error_map[code] or "unknown error"
end


function _M.is_stream_error(code)
    return code < 0 or code == REFUSED_STREAM or code == STREAM_CLOSED
end


_M.NO_ERROR = NO_ERROR
_M.PROTOCOL_ERROR = PROTOCOL_ERROR
_M.INTERNAL_ERROR = INTERNAL_ERROR
_M.FLOW_CONTROL_ERROR = FLOW_CONTROL_ERROR
_M.SETTINGS_TIMEOUT = SETTINGS_TIMEOUT
_M.STREAM_CLOSED = STREAM_CLOSED
_M.FRAME_SIZE_ERROR = FRAME_SIZE_ERROR
_M.REFUSED_STREAM = REFUSED_STREAM
_M.CANCEL = CANCEL
_M.COMPRESSION_ERROR = COMPRESSION_ERROR
_M.CONNECT_ERROR = CONNECT_ERROR
_M.ENHANCE_YOUR_CALM = ENHANCE_YOUR_CALM
_M.INADEQUATE_SECURITY = INADEQUATE_SECURITY
_M.HTTP_1_1_REQUIRED = HTTP_1_1_REQUIRED

_M.STREAM_PROTOCOL = STREAM_PROTOCOL_ERROR
_M.STREAM_FLOW_CONTROL_ERROR = STREAM_FLOW_CONTROL_ERROR


return _M
