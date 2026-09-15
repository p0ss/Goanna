-- Flat-world parity, biome exclusion, read-only sampling and schematic outlines.
local ids={air=0,ignore=1,soil=2,wood=3,leaves=4,water=5}
core={
 registered_nodes={air={walkable=false},ignore={walkable=false},soil={groups={}},wood={groups={tree=1}},leaves={groups={leaves=1}},water={walkable=false}},
 registered_decorations={},
 get_content_id=function(n) return assert(ids[n],n) end,
 get_mapgen_setting=function(k) return k=='seed' and '123' or '5' end,
 settings={get_bool=function(_,_,default) return default end},
 log=function() end,
}
function PcgRandom(seed)
 local state=seed%2147483647
 return {next=function(_,a,b) state=(state*16807)%2147483647; return a+state%(b-a+1) end}
end
function ValueNoise() return {get_2d=function() return 0.04 end} end
local data={}
for z=0,2 do for y=0,5 do for x=0,4 do
 local name=(x==2 and z==1 and y<4) and 'wood' or (y==4 and not(x==0 and z==0)) and 'leaves' or 'air'
 data[#data+1]={name=name,prob=255,param2=0}
end end end
core.registered_decorations.oak={deco_type='schematic',name='oak',place_on={'soil'},biomes={'forest'},sidelen=8,
 fill_ratio=0.04,rotation='random',flags='place_center_x,place_center_z',schematic={size={x=5,y=6,z=3},data=data}}
dofile('project/vendor/terrain_diffusion/tdl_decorate.lua')
local minp,maxp={x=-32,y=-32,z=-32},{x=47,y=47,z=47}
local area={index=function(_,x,y,z) return x..':'..y..':'..z end}
local nodes=setmetatable({}, {__index=function(_,k) local y=tonumber(k:match('^[^:]+:([^:]+):')); return y<=0 and ids.soil or ids.air end})
local cols={margin=0,wide_x=80,heights={},water_levels={},grounds={},present={forest=true}}
for i=1,6400 do cols.heights[i]=0; cols.grounds[i]={name='forest'} end
local placed=tdl_decorate.place(nodes,area,minp,maxp,0,cols).deferred
local function sample() return {y=0,top='soil',side='soil',biome={name='forest'}} end
local preview=tdl_decorate.preview(minp,maxp,{forest=true},sample,function() return true end,function() end)
assert(#placed>0 and #placed==#preview, 'placement count differs')
for i,p in ipairs(placed) do
 local q=preview[i]
 assert(p.x==q.x and p.y==q.y and p.z==q.z and p.rotation==q.rotation,'placement stream drift')
end
local wrong=tdl_decorate.preview(minp,maxp,{desert=true},sample,function() return true end,function() end)
assert(#wrong==0,'trees leaked into a biome without decorations')
local preview_runtime=tdl_decorate.preview
tdl_decorate.preview=function(minp)
 if minp.x==-32 and minp.z==-32 and minp.y==-32 then
  return {{deco=placed[1].deco,x=1,y=0,z=1,rotation='90'}}
 end
 return {}
end
local forest=dofile('project/vendor/terrain_diffusion/tdl_forest.lua')(function() return 0,'soil',nil,'soil',{name='forest'} end)
local spans=forest(2,2,4)
local spans2=forest(2,2,4)
assert(#spans>0 and #spans==#spans2,'cold/warm forest changed')
local wood,leaf=false,false
for i,s in ipairs(spans) do
 assert(s.size==1 and s.bottom>=1 and s.top>s.bottom,'bad voxel run')
 assert(s.x>=0 and s.x<4 and s.z>=0 and s.z<4,'overhang escaped requested cell')
 assert(s.x==spans2[i].x and s.z==spans2[i].z and s.bottom==spans2[i].bottom,'unstable cache')
 wood=wood or s.name=='wood'; leaf=leaf or s.name=='leaves'
end
assert(wood and leaf,'lost trunks or canopy')
for _,s in ipairs(spans) do
 assert(not(s.x==0 and s.z==3 and s.bottom<=4 and s.top>4),'rotation filled the asymmetric crown opening')
end
for _,step in ipairs({8,16}) do
 local reduced=forest(step/2,step/2,step)
 assert(#reduced>0,"intermediate tree LOD missing")
 for _,s in ipairs(reduced) do
  local cell=step/4
  assert(s.size==cell and s.x%cell==0 and s.z%cell==0 and s.bottom%cell==0,
   "intermediate tree LOD is not aligned to its voxel grid")
 end
end
tdl_decorate.preview=preview_runtime
local coarse=forest(32,32,64)
assert(#coarse==1 and coarse[1].name=='leaves' and coarse[1].bottom>0,'coarse canopy became wood or ground')
assert(coarse[1].coverage>0 and coarse[1].coverage<255,'sparse forest became full coverage')
print('forest preview: placement parity, biomes, trunks, crowns and density PASS')
