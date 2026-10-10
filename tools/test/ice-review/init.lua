-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Copyright (C) 2026 the Goanna contributors
-- Isolated visual fixture. No production world uses this command.
core.register_chatcommand("ice_review", {
 privs = {server=true},
 func = function(name)
  local lo, hi = {x=-17,y=72,z=-17}, {x=17,y=89,z=17}
  local vm = core.get_voxel_manip()
  vm:read_from_map(lo,hi)
  for x=-17,17 do for z=-17,17 do for y=72,89 do
   local n="air"
   if y==72 or ((math.abs(x)==17 or math.abs(z)==17) and y<=80) then n="mcl_core:stonebrick"
   elseif y<=79 then n="mcl_core:water_source" end
   if y==79 and x<=0 and math.abs(x)<17 and math.abs(z)<17 then n="mcl_core:ice" end
   if x>=-7 and x<=-4 and z>=-3 and z<=2 and y>=77 and y<=83 then n="mcl_core:ice" end
   if x>=-12 and x<=-9 and z>=-7 and z<=-4 and y>=77 and y<=85 then n="mcl_core:packed_ice" end
   if x>=-6 and x<=-3 and z>=-12 and z<=-9 and y>=77 and y<=84 then n="mcl_core:blue_ice" end
   vm:set_node_at({x=x,y=y,z=z},{name=n})
  end end end
  vm:calc_lighting()
  vm:write_to_map()
  return true,"Ice review pool: x/z -17..17, water top 79.5, floor 72"
 end,
})
