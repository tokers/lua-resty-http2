-- Copyright Alex Zhang (tokers)

local _M = { _VERSION = "0.1" }

_M.protocol = {
    NO_ERROR = 0x0,
    PROTOCOL_ERROR = 0x1,
    INTERNAL_ERROR = 0x2,
    FLOW_CONTROL_ERROR = 0x3,
    SETTINGS_TIMEOUT = 0x4,
    STREAM_CLOSED = 0x5,
    FRAME_SIZE_ERROR = 0x6,
    REFUSED_STREAM = 0x7,
    CANCEL = 0x8,
    COMPRESSION_ERROR = 0x9,
    CONNECT_ERROR = 0xa,
    ENHANCE_YOUR_CALM = 0xb,
    INADEQUATE_SECURITY = 0xc,
    HTTP_1_1_REQUIRED = 0xd,
}

_M.INVALID_STREAM_STATE = 1
_M.FLOW_EXHAUSTED = 2


local error_map = {
    [_M.INVALID_STREAM_STATE] = "invalid stream state",
    [_M.FLOW_EXHAUSTED] = "flow window is exhausted"
}


function _M.strerror(code)
    return error_str[code]
end


_M.protocol = protocol_error


return _M
