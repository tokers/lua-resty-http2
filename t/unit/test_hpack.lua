-- Copyright Alex Zhang (tokers)

package.path = "./lib/?.lua;;"

local hpack = require "resty.http2.hpack"

local assert = assert
local char = string.char
local rep = string.rep

local hstate = hpack.new(hpack.MAX_TABLE_SIZE)

assert(char(128 + 55) == hpack.indexed(55), "bad indexed value")
assert(char(64 + 13) == hpack.incr_indexed(13), "bad incr indexed value")

local headers = {
    { name = "header_A", value = "value_A" },
    { name = "header_B", value = "value_B" },
    { name = "header_C", value = "value_C" },
    { name = "header_D", value = "value_D" },
    { name = "header_E", value = "value_E" },
    { name = "header_F", value = "value_F" },
}

for i = 1, #headers do
    local name = headers[i].name
    local value = headers[i].value

    assert(hstate:insert_entry(name, value), "failed to insert entry")
end

local dynamic = hstate.dynamic

assert(dynamic.front == 1, "bad front value " .. dynamic.front)
assert(dynamic.back == 6, "bad back value " .. dynamic.back)
assert(dynamic.free == 4096 - 47 * 6, "bad free value " .. dynamic.free)

assert(hstate:get_indexed_header(0) == nil)
local entry = hstate:get_indexed_header(2)
assert(entry.name == ":method")
assert(entry.value == "GET")

entry = hstate:get_indexed_header(63)
assert(entry.name == "header_E")
assert(entry.value == "value_E")

assert(hstate:get_indexed_header(70) == nil)

-- resize the dynamic table, only two entries can be retained
hstate:resize(100)

assert(dynamic.front == 5, "bad front value " .. dynamic.front)
assert(dynamic.back == 6, "bad back value " .. dynamic.back)
assert(dynamic.size == 100, "bad size value " .. dynamic.size)

local name = "header_G"
local value = "value_G"

-- evict a entry
assert(hstate:insert_entry(name, value), "failed to insert entry")
assert(dynamic.front == 6, "bad front value " .. dynamic.front)
assert(dynamic.back == 7, "bad back value " .. dynamic.back)

-- more evictions
for i = 1, 57 do
    local name = "header_" .. i
    local value = "value_" .. i
    assert(hstate:insert_entry(name, value), "failed to insert entry")
end

assert(dynamic.front == 63, "bad front value " .. dynamic.front)
assert(dynamic.back == 64, "bad back value " .. dynamic.back)

local name = "header_H"
local value = "value_H"

-- pointers go back
assert(hstate:insert_entry(name, value), "failed to insert entry")
assert(dynamic.front == 64, "bad front value " .. dynamic.front)
assert(dynamic.back == 1, "bad back value " .. dynamic.back)

entry = hstate:get_indexed_header(63)
assert(entry.name == "header_57")
assert(entry.value == "value_57")

entry = hstate:get_indexed_header(62)
assert(entry.name == "header_H")
assert(entry.value == "value_H")
assert(hstate:get_indexed_header(64) == nil)

local name = rep("HEADER_I", 5)
local value = rep("HEADER_I", 5)

-- too large, all items should be evicted
assert(hstate:insert_entry(name, value) == false, "should be failed!")
assert(dynamic.front == 1, "bad front value " .. dynamic.front)
assert(dynamic.back == 0, "bad back value " .. dynamic.back)

local name = rep("HEADER_I", 4)
local value = rep("HEADER_I", 4)

assert(hstate:insert_entry(name, value), "failed to insert entry")
assert(dynamic.front == 1, "bad front value " .. dynamic.front)
assert(dynamic.back == 1, "bad back value " .. dynamic.back)

hstate:resize(3400)
assert(dynamic.front == 1, "bad front value " .. dynamic.front)
assert(dynamic.back == 1, "bad back value " .. dynamic.back)
assert(dynamic.free == 3400 - #name - #value - 32, "incorrect free size")

local free = dynamic.free
for i = 1, 63 do
    local name = "header_" .. i
    local value = "value_" .. i
    free = free - #name - #value - 32
    assert(hstate:insert_entry(name, value), "failed to insert entry")
end

assert(dynamic.front == 1, "bad front value " .. dynamic.front)
assert(dynamic.back == 64, "bad back value " .. dynamic.back)
assert(dynamic.free == free, "incorrect free size")

local name = "header_" .. 64
local value = "value_" .. 64
assert(hstate:insert_entry(name, value), "failed to insert entry")

assert(dynamic.front == 1, "bad front value " .. dynamic.front)
assert(dynamic.back == 65, "bad back value " .. dynamic.back)
