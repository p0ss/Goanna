-- Read-only forest previews. Reuses decoration placement streams and the game's
-- schematic voxels; never emerges or writes a mapblock. All work can yield to
-- the bounded surface-tile queue between columns and decorations.
local floor = math.floor
local chunks, order, prototypes = {}, {}, {}
local enabled = core.settings:get_bool("tdl_place_decorations", true)
local edge = 16 * (tonumber(core.get_mapgen_setting("chunksize")) or 5)
local offset = 16 * floor((tonumber(core.get_mapgen_setting("chunksize")) or 5) / 2)
local function origin(n) return floor((n + offset) / edge) * edge - offset end
local function pause() if coroutine.isyieldable and coroutine.isyieldable() then coroutine.yield() end end
-- LuaJIT's coroutine.running returns nil on the main thread.
if not coroutine.isyieldable then
    pause = function() if coroutine.running() then coroutine.yield() end end
end
local function foliage(name)
    local d = core.registered_nodes[name]
    local g = d and d.groups or {}
    return (g.leaves or 0) > 0 or (g.leafdecay or 0) > 0
end
local function woody(name)
    local d = core.registered_nodes[name]
    return d and d.groups and (d.groups.tree or 0) > 0
end
local function prototype(deco)
    if prototypes[deco] ~= nil then return prototypes[deco] end
    prototypes[deco] = false
    if deco.kind ~= "schematic" then return false end
    local s = deco.schematic
    if type(s) == "string" or type(s) == "number" then
        local ok, read = pcall(core.read_schematic, s, {})
        if not ok then return false end
        s = read
    end
    if type(s) ~= "table" or not s.size or not s.data then return false end
    -- Oversized structures are not tree prototypes. Bound both CPU and payload.
    if s.size.x > 64 or s.size.z > 64 or s.size.y > 128 then return false end
    local replacements = {}
    for k, v in pairs(deco.replacements or {}) do
        if type(v) == "table" then replacements[v[1]] = v[2] else replacements[k] = v end
    end
    local voxels, leaves = {}, false
    local i = 0
    for z = 0, s.size.z-1 do for y = 0, s.size.y-1 do for x = 0, s.size.x-1 do
        i = i+1
        if i%256==0 then pause() end
        local n = s.data[i]
        local name = n and (replacements[n.name] or n.name)
        for _=1,16 do
            local alias=core.registered_aliases and core.registered_aliases[name]
            if not alias or alias==name then break end
            name=alias
        end
        if name and (foliage(name) or woody(name)) and (n.prob or 255) > 0 then
            local leaf = foliage(name)
            leaves = leaves or leaf
            voxels[#voxels+1] = {x=x,y=y,z=z,name=name,param2=n.param2 or 0,
                prob=n.prob or 255,leaf=leaf}
        end
    end end end
    if not leaves then return false end
    local slices = {}
    for _, row in ipairs(s.yslice_prob or {}) do slices[row.ypos] = row.prob end
    local p = {size=s.size,voxels=voxels,slices=slices}
    prototypes[deco] = p
    return p
end

return function(sample, coarse_sample)
    local function chunk(cx, cz)
        local key = cx .. ":" .. cz
        if chunks[key] then return chunks[key] end
        local columns, present = {}, {}
        local low, high = 31000, -31000
        local function column(x,z)
            local k = x .. ":" .. z
            if not columns[k] then
                local y, top, wy, side, biome = sample(x,z)
                columns[k] = {y=y,top=top,water=wy,side=side,biome=biome}
            end
            return columns[k]
        end
        -- Bounds and candidate biomes. An extra vertical chunk handles relief
        -- between probes; the actual placement still tests each sampled root.
        for z=cz,cz+edge-1,8 do for x=cx,cx+edge-1,8 do
            local c=column(x,z)
            low,high=math.min(low,c.y),math.max(high,c.y)
            if c.biome then present[c.biome.name]=true end
            pause()
        end end
        local result = {[1]={},[2]={},[4]={}}
        for cy=origin(low)-edge,origin(high)+edge,edge do
            local placed=tdl_decorate.preview({x=cx,y=cy,z=cz},
                {x=cx+edge-1,y=cy+edge-1,z=cz+edge-1},present,column,prototype,pause)
            for _, item in ipairs(placed) do
                local p=prototype(item.deco)
                local rot=tonumber(item.rotation) or 0
                local sx,sz=p.size.x,p.size.z
                if rot==90 or rot==270 then sx,sz=sz,sx end
                local x0,y0,z0=item.x,item.y,item.z
                local flags=item.deco.centre or ""
                if flags:find("place_center_x",1,true) then x0=x0-floor((sx-1)/2) end
                if flags:find("place_center_y",1,true) then y0=y0-floor((p.size.y-1)/2) end
                if flags:find("place_center_z",1,true) then z0=z0-floor((sz-1)/2) end
                local rng=PcgRandom(tdl_decorate.chunk_seed({x=item.x,y=item.y,z=item.z})+item.deco.order)
                local keep={}
                local compressed_y=0
                for y=0,p.size.y-1 do
                    local prob=p.slices[y] or 255
                    if prob>=254 or prob>=rng:next(1,255) then keep[y]=compressed_y; compressed_y=compressed_y+1 end
                end
                for vi,v in ipairs(p.voxels) do
                    if vi%64==0 then pause() end
                    if keep[v.y] ~= nil and (v.prob>=254 or v.prob>=rng:next(1,255)) then
                        local x,z=v.x,v.z
                        if rot==90 then x,z=z,p.size.x-1-x
                        elseif rot==180 then x,z=p.size.x-1-x,p.size.z-1-z
                        elseif rot==270 then x,z=p.size.z-1-z,x end
                        x,z=x+x0,z+z0
                        local y=keep[v.y]+y0
                        local ground=column(x,z)
                        if y>ground.y and (not ground.water or y>ground.water) then
                            -- A visible leaf wins over a coincident trunk, as in
                            -- the canopy material reducer used for visited LODs.
                            for _,cell in ipairs({1,2,4}) do
                                local k=floor(x/cell)*cell..":"..floor(z/cell)*cell
                                local yy=floor(y/cell)*cell
                                local level=result[cell]
                                level[k]=level[k] or {}
                                local old=level[k][yy]
                                if not old or v.leaf then level[k][yy]=v end
                            end
                        end
                    end
                end
                pause()
            end
        end
        chunks[key]=result
        order[#order+1]=key
        if #order>96 then chunks[table.remove(order,1)]=nil end
        return result
    end
    local function at(x,z,cell)
        local result={}
        -- Schematics may overhang a neighbouring mapgen chunk by up to 64 nodes.
        for cz=origin(z-64),origin(z+64),edge do
            for cx=origin(x-64),origin(x+64),edge do
                local col=chunk(cx,cz)[cell][x..":"..z]
                if col then for y,v in pairs(col) do
                    if not result[y] or v.leaf then result[y]=v end
                end end
            end
        end
        return result
    end
    return function(x,z,step)
        if not enabled or not tdl_decorate.load() then return {} end
        local x0,z0=x-step/2,z-step/2
        local spans={}
        if step<=16 then
            -- Four samples per axis at every geometric rung: retain crowns
            -- at 1, 2 and 4 nodes before reducing to a statistical canopy.
            local cell=step/4
            for dz=0,step-cell,cell do for dx=0,step-cell,cell do
                local col=at(x0+dx,z0+dz,cell)
                local ys={}
                for y in pairs(col) do ys[#ys+1]=y end
                table.sort(ys)
                local last
                for _,y in ipairs(ys) do
                    local v=col[y]
                    if last and last.top==y and last.name==v.name and last.param2==v.param2 then
                        last.top=y+cell
                    else
                        last={x=x0+dx,z=z0+dz,bottom=y,top=y+cell,name=v.name,
                            param2=v.param2,size=cell,coverage=255}
                        spans[#spans+1]=last
                    end
                end
                pause()
            end end
        else
            local y,top,wy,side,biome=(coarse_sample or sample)(x,z)
            local c={y=y,top=top,water=wy,side=side,biome=biome}
            local rows=tdl_decorate.canopy(x,z,function() return c end,prototype)
            local weight,lo,hi,names=0,0,0,{}
            for _,row in ipairs(rows) do
                local p=row.prototype
                if not p.profile then
                    local cols,bottom,upper,material={},128,0,{}
                    for _,v in ipairs(p.voxels) do if v.leaf then
                        cols[v.x..":"..v.z]=true
                        bottom=math.min(bottom,v.y); upper=math.max(upper,v.y+1)
                        material[v.name]=(material[v.name] or 0)+1
                    end end
                    local area=0
                    for _ in pairs(cols) do area=area+1 end
                    local name,best=nil,0
                    for n,count in pairs(material) do
                        if count>best or (count==best and n<(name or n)) then name,best=n,count end
                    end
                    p.profile={area=area,bottom=bottom,top=upper,name=name}
                end
                local a=p.profile
                local w=math.min(row.density,1)*a.area
                local base=y+(row.deco.place_offset_y or 0)
                if row.deco.centre_y then base=y-floor((p.size.y-1)/2) end
                weight=weight+w; lo=lo+(base+a.bottom)*w; hi=hi+(base+a.top)*w
                names[a.name]=(names[a.name] or 0)+w
                pause()
            end
            if weight>0 then
                local name,best=nil,0
                for n,w in pairs(names) do
                    if w>best or (w==best and n<(name or n)) then name,best=n,w end
                end
                spans[1]={x=x0,z=z0,bottom=floor(lo/weight),top=math.max(floor(lo/weight)+1,floor(hi/weight)),
                    name=name,param2=0,size=step,coverage=math.max(1,floor((1-math.exp(-weight))*255))}
            end
        end
        return spans
    end
end
