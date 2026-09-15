-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Actual node data for the detailed LOD rungs. Read-only VoxelManip reads do
-- not generate terrain; ignore is an unavailable reply, never invented air.
return function(channel, enabled, distance)
 local queue,pending,watch={}, {}, {}
 local function key(x,y,z) return x..':'..y..':'..z end
 local function u16(v) return string.char(math.floor(v/256),v%256) end
 core.register_on_modchannel_message(function(name,who,msg)
  if name~='goanna:v1' or not enabled then return end
  local token,x,y,z=msg:match('^farfine%? 1 (%d+) (%-?%d+) (%-?%d+) (%-?%d+)$')
  if not token or #token>20 then return end
  x,y,z=tonumber(x),tonumber(y),tonumber(z)
  if math.abs(x)>1936 or math.abs(y)>1936 or math.abs(z)>1936 then return end
  local player=core.get_player_by_name(who)
  if not player then return end
  local p=player:get_pos()
  local dx,dz=math.max(math.abs(x*16+8-p.x)-8,0),math.max(math.abs(z*16+8-p.z)-8,0)
  if dx*dx+dz*dz>distance*distance or math.abs(y*16+8-p.y)>distance+16 then return end
  local k=who..':'..key(x,y,z)
  if pending[k] or #queue>=64 then return end
  local count=0
  for _,j in ipairs(queue) do if j.who==who then count=count+1 end end
  if count>=16 then return end
  pending[k]=true
  queue[#queue+1]={who=who,token=token,x=x,y=y,z=z,key=k}
 end)
 local function read(job)
  local lo={x=job.x*16,y=job.y*16,z=job.z*16}
  local hi={x=lo.x+15,y=lo.y+15,z=lo.z+15}
  local vm=core.get_voxel_manip(lo,hi)
  local emin,emax=vm:get_emerged_area()
  local area=VoxelArea:new{MinEdge=emin,MaxEdge=emax}
  local data,light,param2=vm:get_data(),vm:get_light_data(),vm:get_param2_data()
  local names,indices,runs={}, {}, {}
  local last,count
  local function flush() if last then runs[#runs+1]=u16(count)..last end end
  for z=lo.z,hi.z do for y=lo.y,hi.y do for x=lo.x,hi.x do
   local i=area:index(x,y,z)
   local cid=data[i]
   if cid==core.CONTENT_IGNORE then return '-' end
   local index=indices[cid]
   if not index then
    names[#names+1]=core.get_name_from_content_id(cid)
    index=#names;indices[cid]=index
   end
   local record=u16(index)..string.char(light[i] or 0,param2[i] or 0)
   if record==last and count<4096 then count=count+1
   else flush();last,count=record,1 end
  end end end
  flush()
  local body=table.concat(names,',')..'|'..core.encode_base64(core.compress(table.concat(runs),'deflate',1))
  -- Unusually varied blocks can exceed one packet. A bounded unavailable
  -- reply lets the normal live-block path supply those without truncation.
  if #body>60000 then return '-' end
  return body
 end
 core.register_globalstep(function()
  if not channel or not channel:is_writeable() then return end
  local start=core.get_us_time()
  for _=1,4 do
   local job=table.remove(queue,1)
   if not job then break end
   pending[job.key]=nil
   if core.get_player_by_name(job.who) then
    local body=read(job)
    channel:send_all(string.format('farfine %s 1 %s %d %d %d %s',job.who,job.token,job.x,job.y,job.z,body))
    local k=key(job.x,job.y,job.z)
    watch[k]=core.get_us_time()
   end
   if core.get_us_time()-start>=2000 then break end
  end
 end)
 local function changed(pos)
  local x,y,z=math.floor(pos.x/16),math.floor(pos.y/16),math.floor(pos.z/16)
  local k=key(x,y,z)
  if watch[k] and channel and channel:is_writeable() then
   channel:send_all(string.format('farfine_changed %d %d %d',x,y,z))
  end
 end
 core.register_on_dignode(changed)
 core.register_on_placenode(changed)
 local timer=0
 core.register_globalstep(function(dt)
  timer=timer+dt
  if timer<30 then return end
  timer=0
  local now=core.get_us_time()
  for k,t in pairs(watch) do if now-t>60000000 then watch[k]=nil end end
 end)
 if enabled then goanna_announce('far_fine','1') end
end
