-- Copyright Alex Zhang (tokers)

local util = require "resty.http2.util"

local char = string.char
local setmetatable = setmetatable
local new_tab = util.new_tab

local _M = { _VERSION = "0.1" }
local mt = { __index = _M }

-- (127 + (1 << (4 - 1) * 7) - 1)
local MAX_FIELD = 182
local MAX_TABLE_SIZE = 4096
local ENTRY_SLOTS = 64

local hpack_static_table = {
    { ":authority", "" },
    { ":method", "GET" },
    { ":method", "POST" },
    { ":path", "/" },
    { ":path", "/index.html" },
    { ":scheme", "http" },
    { ":scheme", "https" },
    { ":status", "200" },
    { ":status", "204" },
    { ":status", "206" },
    { ":status", "304" },
    { ":status", "400" },
    { ":status", "404" },
    { ":status", "500" },
    { "accept-charset", "" },
    { "accept-encoding", "gzip, deflate" },
    { "accept-language", "" },
    { "accept-ranges", "" },
    { "accept", "" },
    { "access-control-allow-origin", "" },
    { "age", "" },
    { "allow", "" },
    { "authorization", "" },
    { "cache-control", "" },
    { "content-disposition", "" },
    { "content-encoding", "" },
    { "content-language", "" },
    { "content-length", "" },
    { "content-location", "" },
    { "content-range", "" },
    { "content-type", "" },
    { "cookie", "" },
    { "date", "" },
    { "etag", "" },
    { "expect", "" },
    { "expires", "" },
    { "from", "" },
    { "host", "" },
    { "if-match", "" },
    { "if-modified-since", "" },
    { "if-none-match", "" },
    { "if-range", "" },
    {  "if-unmodified-since", ""  },
    { "last-modified", "" },
    { "link", "" },
    { "location", "" },
    { "max-forwards", "" },
    { "proxy-authenticate", "" },
    { "proxy-authorization", "" },
    { "range", "" },
    { "referer", "" },
    { "refresh", "" },
    { "retry-after", "" },
    { "server", "" },
    { "set-cookie", "" },
    { "strict-transport-security", "" },
    { "transfer-encoding", "" },
    { "user-agent", "" },
    { "vary", "" },
    { "via", "" },
    { "www-authenticate", "" },
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
--


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

    local back = dynamic.back
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


function _M.indexed(index)
    return char(128 + index)
end


function _M.incr_indexed(index)
    return char(64 + index)
end


_M.MAX_TABLE_SIZE = MAX_TABLE_SIZE


return _M
