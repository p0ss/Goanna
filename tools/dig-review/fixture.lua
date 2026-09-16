-- Stand the player in front of the carve demo row.
--
-- The row is not placed here: the demo draws whatever NDT_NORMAL nodes already
-- sit at the row's coordinates, and mgflat's surface is already there. All this
-- does is put the camera where the row can be seen.
local Y = 8   -- mgflat ground level, and the demo row
local Z = 3   -- the row's z

minetest.register_on_joinplayer(function(player)
    local function place()
        if not (player and player:is_player()) then return end
        player:set_pos({ x = 3.5, y = Y + 1.5, z = Z - 4 })
        player:set_look_horizontal(0)
    end
    place()
    for _, at in ipairs({ 0.3, 0.8, 1.4, 2.0, 2.6, 3.2 }) do
        minetest.after(at, place)
    end
end)
