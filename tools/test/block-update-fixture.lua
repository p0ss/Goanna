-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Disposable world: cut a dark room across a mapblock boundary.
local function build()
 core.load_area({x=-16,y=0,z=-16},{x=31,y=31,z=31})
 for x=0,5 do for z=0,5 do for y=13,20 do
  core.set_node({x=x,y=y,z=z},{name="mcl_core:stone"})
 end end end
end
core.register_on_joinplayer(function(p)
 core.emerge_area({x=-16,y=0,z=-16},{x=31,y=31,z=31},function(_,_,remaining)
  if remaining~=0 then return end
  core.after(0,function()
   build()
   p:set_pos({x=2,y=16,z=-3})
   p:set_physics_override({gravity=0})
   core.chat_send_player(p:get_player_name(),"MESH READY")
  end)
 end)
end)
core.register_chatcommand("mesh_cut",{func=function()
 local vm=VoxelManip()
 local a,b=vm:read_from_map({x=0,y=16,z=0},{x=5,y=17,z=5})
 local area=VoxelArea:new({MinEdge=a,MaxEdge=b})
 local data=vm:get_data()
 for x=1,4 do for z=1,4 do for y=16,17 do
  data[area:index(x,y,z)]=core.CONTENT_AIR
 end end end
 vm:set_data(data);vm:write_to_map(false)
 return true,"MESH CUT"
end})
core.after(240,function() core.request_shutdown("fixture timeout",false,0) end)
