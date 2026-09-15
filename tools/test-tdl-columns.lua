-- Batched mapgen and point-sampled tree roots must agree, including shorelines.
-- Optional first argument: an earlier tdl_mapgen.lua for a before/after audit.
local ids,names={},{}
local function id(name)
 if not ids[name] then ids[name]=#names+1; names[#names+1]=name end
 return ids[name]
end
local callback
core={get_content_id=id,registered_nodes=setmetatable({}, {__index=function() return {} end}),
 settings={get_bool=function(_,name,default) if name=='tdl_place_decorations' then return false end; return default end,
 get=function() return '0' end},
 register_on_generated=function(fn) callback=fn end,log=function() end,
 generate_ores=function() end,generate_decorations=function() end}
local scene=0
local floor=math.floor
local function noise(p,seed) return math.sin(p.x*.13+seed)*math.cos(p.y*.09-seed)*.8 end
function ValueNoise(p) return {get_2d=function(_,at) return noise(at,p.seed) end} end
function ValueNoiseMap(p,size)
 return {get_2d_map_flat=function(_,at)
  local out={}
  for z=0,size.y-1 do for x=0,size.x-1 do out[#out+1]=noise({x=at.x+x,y=at.y+z},p.seed) end end
  return out
 end}
end
VoxelArea={new=function(_,v)
 local sx=v.MaxEdge.x-v.MinEdge.x+1
 local sy=v.MaxEdge.y-v.MinEdge.y+1
 return {ystride=sx,index=function(_,x,y,z)
  return (z-v.MinEdge.z)*sx*sy+(y-v.MinEdge.y)*sx+x-v.MinEdge.x+1
 end}
end}
tdl={available=true,nodes_per_pixel=30,metres_per_node=1,detail_metres=20,
 sea_level=0,min_drainage_km2=4,manifest={native_resolution=30},
 node_to_pixel=function(x,z) return z,x end,climate_pixel=function(x,z) return z,x end,
 elevation_at=function(z,x) return 10+math.sin(x*.03)*8+math.cos(z*.02)*6 end,
 surface_y=function(y) return floor(y) end,
 climate_at=function(z,x) return x*.1,3,80+z*.2,4 end,
 wetness_at=function() return 10,3 end,
 water_distance_at=function(z,x) return scene==0 and 1000 or math.abs(x+scene*3) end,
 water_surface_at=function() return 12 end,
 drainage_at=function() return scene==2 and 200 or 1 end,
 channel_segment_at=function(_,_,distance) return distance*.7,11 end}
local entries={}
for _,n in ipairs({'cold','warm'}) do
 entries[n]={name=n,top_name=n,filler_name='soil',top=id(n),filler=id('soil'),depth_top=1,depth_filler=3}
end
tdl_palette={load=function() return 2 end,heat=function(x) return x end,humidity=function(x) return x end,
 pick=function(t) return t<0 and entries.cold or entries.warm end}
tdl_classify={material=function() return 'forest' end,adjust=function(_,t,p) return t,p end,
 aridity=function(_,_,p) return p end}
dofile('project/vendor/terrain_diffusion/tdl_column.lua')
local function generate(path,minp,maxp)
 dofile(path)
 local data
 local vm={get_emerged_area=function() return minp,maxp end,get_data=function() return {} end,
  set_data=function(_,v) data=v end,
  calc_lighting=function() assert(data,"lighting ran before terrain was written") end}
 callback(vm,minp,maxp,123)
 return data
end
local count=0
for s=0,2 do
 scene=s
 for _,cx in ipairs({-32,0,32}) do
  local minp,maxp={x=cx,y=-16,z=-16},{x=cx+15,y=40,z=-1}
  local data=generate('project/vendor/terrain_diffusion/tdl_mapgen.lua',minp,maxp)
  local area=VoxelArea:new{MinEdge=minp,MaxEdge=maxp}
  for z=minp.z,maxp.z do for x=minp.x,maxp.x do
   local y,top,water=tdl_column.at(x,z)
   assert(data[area:index(x,y,z)]==id(top),'tree root differs from generated ground')
   local above=data[area:index(x,y+1,z)]
   assert(above==id(water and water>y and 'mcl_core:water_source' or 'air'),'water/ground boundary differs')
   count=count+1
  end end
  if arg[1] then
   local old=generate(arg[1],minp,maxp)
   assert(#old==#data)
   for i,v in ipairs(data) do assert(v==old[i],'shared column extraction changed generated terrain') end
  end
 end
end
print('TDL columns: '..count..' roots agree with batched mapgen; shore and channel cases PASS')
