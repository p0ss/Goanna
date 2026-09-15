-- Detailed summaries preserve actual nodes, known air, param2 and lighting.
local message,ticks,dig,place
local sent,reads={},0
local mode='solid'
local now=0
core={CONTENT_IGNORE=127,
 register_on_modchannel_message=function(fn) message=fn end,
 register_globalstep=function(fn) ticks=ticks or {};ticks[#ticks+1]=fn end,
 register_on_dignode=function(fn) dig=fn end,register_on_placenode=function(fn) place=fn end,
 get_player_by_name=function(who) if who=='player' then return {get_pos=function() return {x=0,y=0,z=0} end} end end,
 get_us_time=function() now=now+100;return now end,
 get_name_from_content_id=function(id) return id==0 and 'air' or id==1 and 'wood' or 'leaves' end,
 compress=function(raw) return raw end, encode_base64=function(raw) return raw end,
 get_voxel_manip=function(lo,hi)
  reads=reads+1
  return {get_emerged_area=function() return lo,hi end,
   get_data=function() local data={} for i=1,4096 do data[i]=mode=='unknown' and 127 or mode=='air' and 0 or i<20 and 1 or 2 end return data end,
   get_light_data=function() return setmetatable({}, {__index=function() return 175 end}) end,
   get_param2_data=function() return setmetatable({}, {__index=function() return 7 end}) end}
 end}
VoxelArea={new=function(_,v) return {index=function(_,x,y,z)
 return (z-v.MinEdge.z)*256+(y-v.MinEdge.y)*16+x-v.MinEdge.x+1 end} end}
local offered
goanna_announce=function(k,v) offered=k..'='..v end
local channel={is_writeable=function() return true end,send_all=function(_,v) sent[#sent+1]=v end}
dofile('goanna_server_mod/fine.lua')(channel,true,512)
assert(offered=='far_fine=1')
local function ask(token,x) message('goanna:v1','player','farfine? 1 '..token..' '..(x or 0)..' 0 0') end
local function tick() for _,fn in ipairs(ticks) do fn(.1) end end
ask(1,100);ask(2,2147483647);ask(string.rep("9",65500));tick();assert(reads==0,'out-of-grant request read the map')
ask(3);ask(3);tick();assert(reads==1 and #sent==1,'duplicate read not bounded')
local payload=sent[1]:match('|(.*)$');assert(payload and #payload==12,'actual nodes were not run-length encoded')
assert(payload:byte(5)==175 and payload:byte(6)==7,'light or param2 discarded')
assert(payload:byte(1)*256+payload:byte(2)==19,'node run changed length')
mode='air';ask(4);tick();assert(sent[#sent]:find('air|',1,true),'known empty became unavailable')
mode='unknown';ask(5);tick();assert(sent[#sent]=='farfine player 1 5 0 0 0 -','ungenerated became authoritative empty')
dig({x=1,y=2,z=3});assert(sent[#sent]=='farfine_changed 0 0 0','dig did not invalidate watched block')
place({x=1,y=2,z=3});assert(sent[#sent]=='farfine_changed 0 0 0','placement did not invalidate watched block')
print('fine server: bounds, actual nodes, light, param2, empty, unknown and edits PASS')
