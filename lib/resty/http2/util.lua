-- Copyright Alex Zhang (tokers)

local bit = require "bit"

local pairs = pairs
local bor = bit.bor
local band = bit.band
local bnot = bit.bnot
local blshift = bit.lshift
local brshift = bit.rshift
local char = string.char
local type = type
local ngx_log = ngx.log
local DEBUG = ngx.DEBUG
local debug_log

local _M = { _VERSION = "0.1" }


if ngx.config.debug then
    debug_log = function(...) ngx_log(DEBUG, ...) end
else
    debug_log = function() end
end
_M.debug_log = debug_log


local ok, new_tab = pcall(require, "table.new")
if not ok then
    new_tab = function() return {} end
end
_M.new_tab = new_tab

local clear_tab
ok, clear_tab = pcall(require, "table.clear")
if not ok then
    clear_tab = function(tab)
        for k, _ in pairs(tab) do
            tab[k] = nil
        end
    end
end
_M.clear_tab = clear_tab


function _M.align(value, base)
    return band(value + base - 1, bnot(base - 1))
end


function _M.pack_u16(u, dst)
    dst[#dst + 1] = char(band(brshift(u, 8), 0xff))
    dst[#dst + 1] = char(band(u, 0xff))
end


function _M.unpack_u16(b1, b2)
    return bor(blshift(b1, 8), b2)
end


function _M.pack_u32(u, dst)
    dst[#dst + 1] = char(band(brshift(u, 24), 0xff))
    dst[#dst + 1] = char(band(brshift(u, 16), 0xff))
    dst[#dst + 1] = char(band(brshift(u, 8), 0xff))
    dst[#dst + 1] = char(band(u, 0xff))
end


function _M.unpack_u32(b1, b2, b3, b4)
    local mid1 = bor(blshift(b1, 8), b2)
    local mid2 = bor(blshift(b3, 8), b4)
    return bor(blshift(mid1, 16), mid2)
end


function _M.is_num(num)
    return type(num) == "number"
end


function _M.is_tab(tab)
    return type(tab) == "table"
end


-- TODO recycle the buffer struct if necessary
function _M.new_buffer(data, pos, last)
    return {
        data = data,
        pos = pos,
        last = last,
        next = nil,
    }
end


return _M
