-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Disposable Minetest Game fixture: identical sealed stone caves, one torch
-- and one naturally spreading lava source. No skylight reaches either floor.
local made = false
minetest.register_on_joinplayer(function(player)
    minetest.set_player_privs(player:get_player_name(), {fly=true,fast=true,noclip=true,teleport=true,server=true})
    player:set_physics_override({gravity=0})
    player:set_pos({x=20,y=4,z=11})
    if made then return end
    made = true
    minetest.emerge_area({x=-48,y=-16,z=-32},{x=48,y=16,z=32},function(_,_,left)
        if left ~= 0 then return end
        for _,cx in ipairs({-20,20}) do
            for x=cx-14,cx+14 do for z=-14,14 do for y=0,8 do
                local boundary = x==cx-14 or x==cx+14 or z==-14 or z==14 or y==0 or y==8
                minetest.set_node({x=x,y=y,z=z},{name=boundary and "default:stone" or "air"})
            end end end
            -- A low bank beside the far end of the flow; both floor and a
            -- vertical receiver remain in the same view.
            for x=cx-2,cx+2 do for y=1,3 do
                minetest.set_node({x=x,y=y,z=-10},{name="default:stone"})
            end end
        end
        minetest.set_node({x=-20,y=1,z=0},{name="default:torch",param2=1})
        minetest.set_node({x=20,y=1,z=0},{name="default:lava_source"})
        minetest.set_timeofday(0)
    end)
end)
