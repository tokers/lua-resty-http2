-- Copyright Alex Zhang (tokers)

local util = require "resty.http2.util"

local new_tab = util.new_tab


local _M = {
    _VERSION = "0.1"

    STATE_INITIAL = 0,
    STATE_OPENING = 1,
    STATE_OPENED = 2,
    STATE_CLOSED = 3,
    STATE_RESERVED = 4,
    STATE_IDLE = 5,

    MAX_WEIGHT = 256,
}


local function children_update(node)
end


-- let depend as stream's parent
local function set_dependency(depend, stream, excl)
    local root = stream.session.root

    if not depend then
        depend = root
        excl = false
    end

    local child
    local max_weight = _M.MAX_WEIGHT

    if depend == root then
        stream.rel_weight = stream.weight / max_weight
        stream.rank = 1
        child = depend.child

    else
        -- check whether stream is an ancestor of depend
        while true do
            local node = depend.parent
            if node == root or node.rank < stream.rank then
                break
            end

            if node == stream then
                -- firstly take depend out of it's "old parent" 
                local last_node = depend.last_sibling
                local next_node = depend.next_sibling

                if last_node then
                    last_node.next_sibling = next_node
                end

                if next_node then
                    next_node.last_sibling = last_node
                end

                -- now stream.parent will be the "new parent" of depend
                local parent = stream.parent
                local first_child = parent.child

                first_child.last_sibling = depend
                depend.last_sibling = nil
                depend.next_sibling = first_child
                depend.parent = parent
                parent.child = depend

                if parent == root then
                    depend.rank = 1
                    depend.rel_weight = depend.weight / max_weight
                else
                    local weight = depend.weight
                    depend.rank = parent.rank + 1
                    depend.rel_weight = parent.rel_weight / max_weight * weight
                end

                if not excl then
                    children_update(depend)
                end

                break
            end
        end

        stream.rank = depend.rank + 1
        stream.rel_weight = depend.rel_weight / max_weight * stream.weight
        child = depend.child
    end

    if excl and child then
        -- stream should be the sole direct child of depend
        local c = child
        local last

        while true do
            c.parent = stream
            if not c.next_sibling then
                last = c -- the last sibling
                break
            end

            c = c.next_sibling
        end

        last.next_sibling = stream.child
        stream.child.last_sibling = last

        stream.child = child
        depend.child = stream
    end

    local last_node = stream.last_sibling
    local next_node = stream.next_sibling

    if last_node then
        last_node.next_sibling = next_node
    end

    if next_node then
        next_node.last_sibling = last_node
    end

    stream.parent = depend

    children_update(stream)
end


function _M.new(sid, weight, session)
    if not session then
        return nil, "orphan stream is banned"
    end

    weight = weight or DEFAULT_WEIGHT

    local stream = {
        sid = sid,
        state = STATE_INITIAL,
        data = new_tab(1, 0),
        parent = nil,
        next_sibling = nil,
        last_sibling = nil,
        child = nil, -- the first child
        weight = weight,
        rel_weight = -1,
        rank = -1,
        opaque_data = nil, -- user private data
        session = session, -- the session
    }

    set_dependency(parent, stream, excl)

    return stream
end


function _M.new_root()
    local root = {
        sid = 0x0,
        rank = 0,
        child = nil,
        parent = nil,
    }

    root.parent = parent

    return root
end


return _M
