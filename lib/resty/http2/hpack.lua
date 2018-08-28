-- Copyright Alex Zhang (tokers)

local bit = require "bit"
local util = require "resty.http2.util"
local huffenc = require "resty.http2.huff_encode"

local bor = bit.bor
local brshift = bit.rshift
local band = bit.band
local char = string.char
local concat = table.concat
local setmetatable = setmetatable
local new_tab = util.new_tab
local _M = { _VERSION = "0.1" }
local mt = { __index = _M }

-- (127 + (1 << (4 - 1) * 7) - 1)
local MAX_FIELD = 182
local MAX_TABLE_SIZE = 4096
local ENTRY_SLOTS = 64
local ENCODE_HUFF = 0x80
local ENCODE_RAW = 0x0

local HPACK_AGAIN = 0
local HPACK_ERROR = 1
local HPACK_DONE = 2

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
        return false
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
end


function _M:decode(src, pos, dst)
    local len = #src

    while pos <= len do
        local b = band(byte(src, pos, pos), 0xff)
        pos = pos + 1
    end
end


function _M:get_indexed_header(raw_index)
    if raw_index <= 0 then
        return nil, "invalid hpack table index " .. raw_index
    end

    local static = self.static
    if raw_index <= #static then
        return static[raw_index]
    end

    local dynamic = self.dynamic
    local front = dynamic.front
    local back = dynamic.back

    if back == 0 then
        return nil, "invalid hpack table index " .. raw_index
    end

    local index = raw_index - #self.static

    if back >= front then
        if back - front + 1 < index then
            return nil, "invalid hpack table index " .. raw_index
        end

        return dynamic.entries[back - index + 1]
    end

    local count = back + dynamic.slots - front + 1
    if count < index then
        return nil, "invalid hpack table index " .. raw_index
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

_M.COMMON_REQUESTS_HEADER_INDEX = {
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
