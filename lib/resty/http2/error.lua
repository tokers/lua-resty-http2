-- Copyright Alex Zhang (tokers)

local _M = { _VERSION = "0.1" }

_M.NO_ERROR = 0x0
_M.PROTOCOL_ERROR = 0x1
_M.INTERNAL_ERROR = 0x2
_M.FLOW_CONTROL_ERROR = 0x3
_M.SETTINGS_TIMEOUT = 0x4
_M.STREAM_CLOSED = 0x5
_M.FRAME_SIZE_ERROR = 0x6
_M.REFUSED_STREAM = 0x7
_M.CANCEL = 0x8
_M.COMPRESSION_ERROR = 0x9
_M.CONNECT_ERROR = 0xa
_M.ENHANCE_YOUR_CALM = 0xb
_M.INADEQUATE_SECURITY = 0xc
_M.HTTP_1_1_REQUIRED = 0xd

_M.INVALID_STREAM_STATE = 1
_M.FLOW_EXHAUSTED = 2
_M.STREAM_OVERFLOW = 3


-- we use negative codes to represent the some stream-level errors
_M.STREAM_PROTOCOL_ERROR = -_M.PROTOCOL_ERROR

local error_map = {
    [_M.INVALID_STREAM_STATE] = "invalid stream state",
    [_M.FLOW_EXHAUSTED] = "flow window is exhausted",
    [_M.STREAM_OVERFLOW] = "concurrent streams exceeds",
}


function _M.strerror(code)
    return error_map[code]
end


function _M.is_stream_error(code)
    return code < 0 or code == _M.REFUSED_STREAM
end


return _M
