-- Isolated regression fixture: two identical stone targets, one at the
-- +X/+Z mapblock corner and one in its interior. Brick belongs to neighbours.
minetest.override_item("", {tool_capabilities={full_punch_interval=1,
    groupcaps={cracky={times={[1]=4,[2]=4,[3]=4},uses=0,maxlevel=3}}}})
local function build()
    for _, base in ipairs({{x=7,y=8,z=7}, {x=15,y=8,z=15}}) do
        for z=base.z-2,base.z+2 do
            for y=base.y-2,base.y+3 do
                for x=base.x-2,base.x+2 do
                    minetest.set_node({x=x,y=y,z=z},
                        {name=y<=base.y and "default:brick" or "air"})
                end
            end
        end
        minetest.set_node(base,{name="default:stone"})
    end
end
minetest.register_on_joinplayer(function(player)
    minetest.set_player_privs(player:get_player_name(),{interact=true,fly=true,teleport=true})
    minetest.emerge_area({x=0,y=0,z=0},{x=31,y=15,z=31},function(_,_,remaining)
        if remaining==0 then
            minetest.after(0,function()
                build()
                if player and player:is_player() then
                    player:set_pos({x=15,y=10,z=12})
                    player:set_look_horizontal(0)
                end
            end)
        end
    end)
end)
