-- Copyright Alex Zhang (tokers)

local bit = require "bit"
local util = require "resty.http2.util"
local huffenc = require "resty.http2.huff_encode"
local huffdec = require "resty.http2.huff_decode"
local h2_error = require "resty.http2.error"

local bor = bit.bor
local brshift = bit.rshift
local blshift = bit.lshift
local band = bit.band
local char = string.char
local sub = string.sub
local byte = string.byte
local concat = table.concat
local setmetatable = setmetatable
local new_tab = util.new_tab
local clear_tab = util.clear_tab
local debug_log = util.debug_log

local _M = { _VERSION = "0.1" }
local mt = { __index = _M }

local MAX_TABLE_SIZE = 4096
local ENTRY_SLOTS = 64
local ENCODE_HUFF = 0x80
local ENCODE_RAW = 0x0

local HPACK_INDEXED = 0
local HPACK_INCR_INDEXING = 1
local HPACK_WITHOUT_INDEXING = 2
local HPACK_NEVER_INDEXED = 3

local huff_data
local huff_data_len = 0

local hpack_static_table = {
    { name = ":authority", value = "" },
    { name = ":method", value = "GET" },
    { name = ":method", value = "POST" },
    { name = ":path", value = "/" },
    { name = ":path", value = "/index.html" },
    { name = ":scheme", value = "http" },
    { name = ":scheme", value = "https" },
    { name = ":status", value = "200" },
    { name = ":status", value = "204" },
    { name = ":status", value = "206" },
    { name = ":status", value = "304" },
    { name = ":status", value = "400" },
    { name = ":status", value = "404" },
    { name = ":status", value = "500" },
    { name = "accept-charset", value = "" },
    { name = "accept-encoding", value = "gzip, deflate" },
    { name = "accept-language", value = "" },
    { name = "accept-ranges", value = "" },
    { name = "accept", value = "" },
    { name = "access-control-allow-origin", value = "" },
    { name = "age", value = "" },
    { name = "allow", value = "" },
    { name = "authorization",  value = "" },
    { name = "cache-control",  value = "" },
    { name = "content-disposition", value = "" },
    { name = "content-encoding", value = "" },
    { name = "content-language", value = "" },
    { name = "content-length", value = "" },
    { name = "content-location", value = "" },
    { name = "content-range", value = "" },
    { name = "content-type", value = "" },
    { name = "cookie", value = "" },
    { name = "date", value = "" },
    { name = "etag", value = "" },
    { name = "expect", value = "" },
    { name = "expires", value = "" },
    { name = "from", value = "" },
    { name = "host", value = "" },
    { name = "if-match", value = "" },
    { name = "if-modified-since", value = "" },
    { name = "if-none-match", value = "" },
    { name = "if-range", value = "" },
    { name =  "if-unmodified-since", value = ""  },
    { name = "last-modified", value = "" },
    { name = "link", value = "" },
    { name = "location", value = "" },
    { name = "max-forwards", value = "" },
    { name = "proxy-authenticate", value = "" },
    { name = "proxy-authorization", value = "" },
    { name = "range", value = "" },
    { name = "referer", value = "" },
    { name = "refresh", value = "" },
    { name = "retry-after", value = "" },
    { name = "server", value = "" },
    { name = "set-cookie", value = "" },
    { name = "strict-transport-security", value = "" },
    { name = "transfer-encoding", value = "" },
    { name = "user-agent", value = "" },
    { name = "vary", value = "" },
    { name = "via", value = "" },
    { name = "www-authenticate", value = "" },
}

-- use two pointers mimic the dynamic table's borders,
-- back is the insert point and front is always the drop point.
--
-- case 1 (back >= front) :
--
-- ....^--------------------^.....
-- front                   back
--
-- number of entries = back - front + 1
--
-- ith entry = entries[back - i + 1]
--
-- case 2 (back < front) :
--
-- ----^....................^-----
--    back                front
--
-- number of entries = slots - (front - back - 1)
--
-- ith entry =
--  * entries[back - i + 1] (when i <= back)
--  * entries[slots - (i - back) + 1] (when i > back)
--
-- when all the slots are occupied, a larger slots table will be
-- allocated, all the current data will be moved to there.


local function table_account(hpack, size)
    size = size + 32
    local dynamic = hpack.dynamic
    local free = dynamic.free

    if free >= size then
        dynamic.free = free - size
        return true
    end

    if size > dynamic.size then
        dynamic.front = 1
        dynamic.back = 0
        dynamic.free = dynamic.size
        return false
    end

    local front = dynamic.front
    local slots = dynamic.slots

    while size > free do
        -- evict this entry
        local entry = dynamic.entries[front]

        front = front + 1
        if front > slots then
            front = front - slots
        end

        free = free + 32 + entry.len
    end

    dynamic.free = free - size

    -- all entries are evicted
    dynamic.front = front

    return true
end


local function parse_int(buffer, current, prefix)
    local value = band(current, prefix)
    if value ~= prefix then
        return value
    end

    local count = 0

    value = 0

    while true do
        if buffer.pos == buffer.last then
            buffer = buffer.next
            if not buffer then
                debug_log("server sent header block with incorrect length")
                return
            end
        end

        local pos = buffer.pos
        local b = band(byte(buffer.data, pos, pos), 0xff)
        buffer.pos = pos + 1

        value = blshift(value, 7) + band(b, 0x7f)

        if b < 128 then
            return value
        end

        count = count + 1

        -- length is too large
        if count > 4 then
            debug_log("server sent header block with too long length")
            return
        end
    end
end


local function parse_raw(buffer, length)
    local data = new_tab(2, 0)
    while length > 0 do
        if not buffer then
            break
        end

        local pos = buffer.pos
        local last = buffer.last
        local size = last - pos
        if size >= length then
            data[#data + 1] = sub(buffer.data, pos, pos + length - 1)
            buffer.pos = pos + length
            length = 0
            break
        end

        -- size < length
        if pos == 1 then
            data[#data + 1] = buffer.data
        else
            data[#data + 1] = sub(buffer.data, pos, last - 1)
        end

        length = length - size
        buffer = buffer.next
    end

    if length > 0 then
        debug_log("server sent incomplet header block")
        return
    end

    return concat(data)
end


local function parse_huff(hpack, buffer, length)
    if huff_data_len < length then
        huff_data = new_tab(length, 0)
        huff_data_len = length
    else
        clear_tab(huff_data)
    end

    while true do
        if not buffer then
            break
        end

        local pos = buffer.pos
        local last = buffer.last
        local size = last - pos
        if size >= length then
            local src = sub(buffer.data, pos, pos + length - 1)
            buffer.pos = pos + length

            local ok, err = hpack.decode_state:decode(src, huff_data, true)
            if not ok then
                debug_log("hpack huffman decoding error: ", err)
                return
            end

            hpack.decode_state:reset()

            return concat(huff_data)
        end

        local src
        if pos == 1 then
            src = buffer.data
        else
            src = sub(buffer.data, pos, pos + size - 1)
        end

        buffer = buffer.next

        local ok, err = hpack.decode_state:decode(src, huff_data, false)
        if not ok then
            debug_log("hpack huffman decoding error: ", err)
            return
        end
    end

    if length > 0 then
        debug_log("server sent incomplet header block")
        return
    end

    return concat(huff_data)
end


local function parse_value(hpack, buffer)
    if buffer.pos == buffer.last then
        buffer = buffer.next
        if not buffer then
            debug_log("server sent incomplete header block")
            return
        end
    end

    local pos = buffer.pos
    local ch = band(byte(buffer.data, pos, pos), 0xff)
    buffer.pos = pos + 1

    local huff = ch >= 128
    local value = parse_int(buffer, ch, 127)
    if not value then
        return
    end

    debug_log("string length: ", value, " huff: ", huff)

    if not huff then
        return parse_raw(buffer, value)
    end

    return parse_huff(hpack, buffer, value)
end


local function write_length(preface, prefix, value, dst)
    if value < prefix then
        dst[#dst + 1] = char(bor(preface, value))
        return
    end

    dst[#dst + 1] = char(bor(prefix, prefix))
    while value >= 128 do
        dst[#dst + 1] = char(band(value, 0x7f) + 128)
        value = brshift(value, 7)
    end

    dst[#dst + 1] = char(value)
end


function _M.new(size)
    size = size or MAX_TABLE_SIZE

    -- linked list cannot be indexed fastly.
    -- We use two pointers to index a solidify table.
    local dynamic = {
        free = size,
        size = size,
        entries = new_tab(ENTRY_SLOTS, 0),
        slots = ENTRY_SLOTS,
        front = 1, -- pop from the front
        back = 0, -- push from the back
    }

    return setmetatable({
        static = hpack_static_table,
        dynamic = dynamic,
        cached = nil,
        last_cache = nil,
        decode_state = huffdec.new_state(),
    }, mt)
end


function _M:insert_entry(header_name, header_value)
    local dynamic = self.dynamic

    local cost = #header_name + #header_value

    if not table_account(self, cost) then
        return false
    end

    -- TODO reuse these entries to reduce the GC overheads.
    local entry = {
        name = header_name,
        value = header_value,
        len = cost,
    }

    local back = dynamic.back
    local front = dynamic.front
    local slots = dynamic.slots

    if back == 0 then
        goto insert
    end

    if (back == slots and front == 1) or back == front - 1 then
        -- enlarge the capacity
        -- TODO use luatablepool to recycle this tables.
        local entries = dynamic.entries
        local new_entries = new_tab(slots + 64, 0)

        -- the first case
        if back == slots and front == 1 then
            for i = 1, slots do
                new_entries[i] = entries[i]
            end

        else
            for i = front, slots do
                new_entries[i - front + 1] = entries[i]
            end

            -- back == front - 1
            for i = 1, back do
                new_entries[slots - front + 1 + i] = entries[i]
            end

            dynamic.back = slots
            dynamic.front = 1
        end

        dynamic.entries = new_entries
        dynamic.slots = slots + 64
    end

::insert::

    back = back + 1
    if back > dynamic.slots then
        back = back - dynamic.slots
    end

    dynamic.back = back
    dynamic.entries[back] = entry

    return true
end


function _M:resize(new_size)
    if new_size > MAX_TABLE_SIZE then
        debug_log("server sent header block with too long size update value")
        return
    end

    local dynamic = self.dynamic
    local front = dynamic.front
    local slots = dynamic.slots
    local cost = dynamic.size - dynamic.free

    while cost > new_size do
        local entry = dynamic.entries[front]
        front = front + 1
        if front > slots then
            front = front - slots
        end

        cost = cost - entry.len - 32
    end

    dynamic.front = front
    dynamic.size = new_size
    dynamic.free = new_size - cost

    return true
end


function _M:decode(dst)
    local buffer = self.cached
    if not buffer then
        return true
    end

    self.cached = nil

    local index_type
    local size_update = false
    local prefix

    while true do
        local pos = buffer.pos
        if pos == buffer.last then
            break
        end

        local ch = band(byte(buffer.data, pos), 0xff)
        buffer.pos = pos + 1

        if ch >= 128 then -- indexed header field
            prefix = 127
            index_type = HPACK_INDEXED

        elseif ch >= 64 then -- literal header field with incremental indexing
            prefix = 63
            index_type = HPACK_INCR_INDEXING

        elseif ch >= 32 then -- dynamic table size update
            prefix = 31
            size_update = true

        elseif ch >= 16 then -- literal header field never indexed
            prefix = 15
            index_type = HPACK_NEVER_INDEXED

        else
            prefix = 15
            index_type = HPACK_WITHOUT_INDEXING
        end

        local value = parse_int(buffer, ch, prefix)
        if not value then
            return nil, h2_error.COMPRESSION_ERROR
        end

        if index_type == HPACK_INDEXED then
            local entry = self:get_indexed_header(value)
            if not entry then
                return nil, h2_error.COMPRESSION_ERROR
            end

            dst[entry.name] = entry.value

        elseif size_update then
            size_update = false

            if not self:resize(value) then
                return nil, h2_error.COMPRESSION_ERROR
            end

        else
            local header_name
            local header_value

            if value > 0 then
                local entry = self:get_indexed_header(value)
                if not entry then
                    return nil, h2_error.COMPRESSION_ERROR
                end

                header_name = entry.name

            else
                header_name = parse_value(self, buffer)
                if not header_name then
                    return nil, h2_error.COMPRESSION_ERROR
                end
            end

            header_value = parse_value(self, buffer)
            if not header_value then
                return nil, h2_error.COMPRESSION_ERROR
            end

            dst[header_name] = header_value

            if index_type == HPACK_INCR_INDEXING then
                self:insert_entry(header_name, header_value)
            end
        end
    end

    return true
end


function _M:get_indexed_header(raw_index)
    if raw_index <= 0 then
        debug_log("server sent invalid hpack table index ", raw_index)
        return
    end

    local static = self.static
    if raw_index <= #static then
        return static[raw_index]
    end

    local dynamic = self.dynamic
    local front = dynamic.front
    local back = dynamic.back

    if back == 0 then
        debug_log("server sent invalid hpack table index ", raw_index)
        return
    end

    local index = raw_index - #self.static

    if back >= front then
        if back - front + 1 < index then
            debug_log("server sent invalid hpack table index ", raw_index)
            return
        end

        return dynamic.entries[back - index + 1]
    end

    local count = back + dynamic.slots - front + 1
    if count < index then
        debug_log("server sent invalid hpack table index ", raw_index)
        return
    end

    if index <= back then
        return dynamic.entries[back - index + 1]
    end

    local slots = dynamic.slots
    return dynamic.entries[slots - (index - back) + 1]
end


-- literal header field with incremental indexing
function _M.encode(src, dst, lower)
    local tmp = huffenc.encode(src, lower)

    if tmp then -- encode to huffman codes is a better idea
        write_length(ENCODE_HUFF, 127, #tmp, dst)
        dst[#dst + 1] = concat(tmp)
        return
    end

    write_length(ENCODE_RAW, 127, #src, dst)
    if lower then
        dst[#dst + 1] = src:lower()
    else
        dst[#dst + 1] = src
    end
end


function _M.indexed(index)
    return char(128 + index)
end


function _M.incr_indexed(index)
    return char(64 + index)
end


_M.MAX_TABLE_SIZE = MAX_TABLE_SIZE

_M.COMMON_REQUEST_HEADERS_INDEX = {
    [":authority"]          = 1,
    ["accept-charset"]      = 15,
    ["accept-language"]     = 17,
    ["accept-ranges"]       = 18,
    ["accept"]              = 19,
    ["authorization"]       = 23,
    ["cache-control"]       = 24,
    ["cookie"]              = 32,
    ["expect"]              = 35,
    ["host"]                = 38,
    ["if-match"]            = 39,
    ["if-modified-since"]   = 40,
    ["if-none-match"]       = 41,
    ["if-range"]            = 42,
    ["if-unmodified-since"] = 43,
    ["range"]               = 50,
    ["referer"]             = 51,
    ["user-agent"]          = 58,
    ["via"]                 = 60,

    [":method"]             = { ["GET"] = 2, ["POST"] = 3 },
    [":path"]               = { ["/"] = 4, ["/index.html"] = 5 },
    [":scheme"]             = { ["http"] = 6, ["https"] = 7 },
    ["accept-encoding"]     = { ["gzip, deflate"] = 16 },
}


return _M
