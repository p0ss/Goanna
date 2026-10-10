-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Only for a disposable singlenode Mineclonia test world.
assert(core.settings:get("mg_name") == "singlenode", "Portal fixture needs singlenode")
local started = false
-- Mineclonia regenerates its initial spawn area asynchronously. Keep the
-- fixture a kilometre away so that work cannot erase a completed test.
local function position(x, y, z)
    return {x=1024+x, y=32+y, z=1024+z}
end
core.register_on_joinplayer(function(player)
    local name = player:get_player_name()
    core.set_player_privs(name, {interact=true, fly=true, fast=true})
    core.after(2, function()
        local current = core.get_player_by_name(name)
        if current then
            current:set_pos(position(0, 3, -7))
            current:set_physics_override({gravity=0})
        end
    end)
    if started then return end
    started = true
    core.emerge_area(position(-16, -16, -16), position(16, 16, 16), function(_, _, remaining)
        if remaining ~= 0 then return end
        for x=-8,8 do
            for z=-5,5 do
                core.swap_node(position(x, -1, z), {name="mcl_core:stonebrick"})
            end
        end
        for x=-5,-1 do
            for y=0,5 do
                local frame = x == -5 or x == -1 or y == 0 or y == 5
                core.swap_node(position(x, y, 0),
                    {name=frame and "mcl_core:obsidian" or "mcl_portals:portal"})
            end
        end
        for x=0,4 do
            for z=-2,2 do
                local frame = x == 0 or x == 4 or z == -2 or z == 2
                core.swap_node(position(x, 0, z),
                    {name=frame and "mcl_portals:end_portal_frame_eye" or "mcl_portals:portal_end"})
            end
        end
        core.set_timeofday(0.5)
        core.log("action", "PORTAL_FIXTURE_READY " .. core.get_node(position(-3, 2, 0)).name .. " " .. core.get_node(position(2, 0, 0)).name)
    end)
end)
