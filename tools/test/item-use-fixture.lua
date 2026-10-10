-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Disposable world only. Wrap real DorfCraft callbacks to count delivery.
local counts = {}
local items = {"overseer:document", "labour:designator", "rooms:planner", "dorfcraft_runes:chisel", "mcl_tools:pick_stone"}
core.register_on_mods_loaded(function()
 for i=1,4 do
  local name=items[i]
  local original=assert(core.registered_items[name].on_use)
  core.override_item(name, {on_use=function(stack,player,pointed)
   counts[name]=(counts[name] or 0)+1
   core.chat_send_player(player:get_player_name(), "PROBE USE "..name.." "..counts[name].." "..pointed.type)
   return original(stack,player,pointed)
  end})
 end
end)
core.register_on_joinplayer(function(p)
 core.emerge_area({x=-16,y=-16,z=-16},{x=16,y=16,z=16},function(_,_,remaining)
  if remaining~=0 then return end
  core.after(0,function()
   core.load_area({x=-16,y=-16,z=-16},{x=16,y=16,z=16})
   for x=-6,6 do for z=-6,6 do core.set_node({x=x,y=-1,z=z},{name="mcl_core:stone"}) end end
   core.set_node({x=0,y=1,z=3},{name="mcl_core:stone"})
   if not labour.fortress_at({x=0,y=0,z=0}) then
    assert(labour.found(p:get_player_name(),"Tool fixture",{x=0,y=0,z=0},0))
   end
   p:set_pos({x=0,y=-0.49,z=0})
   p:set_look_horizontal(0);p:set_look_vertical(0)
   core.set_player_privs(p:get_player_name(),{interact=true,shout=true})
   p:get_inventory():set_list("main",items)
   core.chat_send_player(p:get_player_name(),"PROBE READY")
  end)
 end)
end)
core.register_chatcommand("probe", {func=function(name)
 local p=core.get_player_by_name(name)
 return true,"PROBE STATE "..core.write_json({counts=counts,overseer=overseer.sessions[name]~=nil,node=core.get_node({x=0,y=1,z=3}).name,interact=core.get_player_privs(name).interact==true})
end})
core.after(300,function() core.request_shutdown("test timeout",false,0) end)
