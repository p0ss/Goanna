-- Shared exterior column calculation for map generation and forest prediction.
-- The mapgen supplies batched noise; read-only previews evaluate the same
-- fields at individual roots. No map access, generation or node writes.
tdl_column = {}
local min,max,floor=math.min,math.max,math.floor
local nodes_per_pixel,metres_per_node=tdl.nodes_per_pixel,tdl.metres_per_node
local detail_metres,min_drainage_km2=tdl.detail_metres,tdl.min_drainage_km2
local MAX_INVENTED_DEPTH,SHORE_DEPTH=24,4

tdl_column.detail_params = {
        offset = 0,
        scale = 1,
        spread = {x = 8 * nodes_per_pixel, y = 8 * nodes_per_pixel, z = 8 * nodes_per_pixel},
        seed = 71249,
        octaves = 4,
        persistence = 0.55,
        lacunarity = 2.0,
}
tdl_column.rock_params = {
        offset = 0,
        scale = 1,
        spread = {x = 3 * nodes_per_pixel, y = 3 * nodes_per_pixel, z = 3 * nodes_per_pixel},
        seed = 20261,
        octaves = 2,
        persistence = 0.5,
        lacunarity = 2.0,
}
tdl_column.dither_params = {
        offset = 0,
        scale = 1,
        spread = {x = 3, y = 3, z = 3},
        seed = 40507,
        octaves = 2,
        persistence = 0.5,
        lacunarity = 2.0,
}
local MATERIALS = {
        ocean_warm    = {top = "mcl_core:sand",            filler = "mcl_core:sand"},
        ocean         = {top = "mcl_core:gravel",          filler = "mcl_core:gravel"},
        ocean_cold    = {top = "mcl_core:gravel",          filler = "mcl_core:clay"},
        ocean_frozen  = {top = "mcl_core:gravel",          filler = "mcl_core:clay"},
        desert        = {top = "mcl_core:sand",            filler = "mcl_core:sandstone"},
        badlands      = {top = "mcl_core:redsand",         filler = "mcl_core:redsandstone"},
        savanna       = {top = "mcl_core:dirt_with_grass", filler = "mcl_core:dirt"},
        plains        = {top = "mcl_core:dirt_with_grass", filler = "mcl_core:dirt"},
        forest        = {top = "mcl_core:dirt_with_grass", filler = "mcl_core:dirt"},
        jungle        = {top = "mcl_core:dirt_with_grass", filler = "mcl_core:dirt"},
        swamp         = {top = "mcl_core:dirt_with_grass", filler = "mcl_core:dirt"},
        taiga         = {top = "mcl_core:podzol",          filler = "mcl_core:dirt"},
        snowy_taiga   = {top = "mcl_core:snowblock",       filler = "mcl_core:dirt"},
        snowy_plains  = {top = "mcl_core:snowblock",       filler = "mcl_core:dirt"},
        snowy_slopes  = {top = "mcl_core:snowblock",       filler = "mcl_core:stone"},
        grove         = {top = "mcl_core:coarse_dirt",     filler = "mcl_core:dirt"},
        stony         = {top = "mcl_core:stone",           filler = "mcl_core:stone"},
        frozen_peaks  = {top = "mcl_core:snowblock",       filler = "mcl_core:stone"},
}

-- Exposed rock, used where the ground is too steep to hold soil. Which one
-- appears is a matter of what the surrounding material is made of.
local ROCK = {
        desert   = "mcl_core:sandstone",
        badlands = "mcl_core:redsandstone",
        default  = "mcl_core:stone",
}
local SCREE = "mcl_core:gravel"


function tdl_column.evaluate(elevation,slope,detail,dither,climate,drainage,hand,fi,fj,use_palette)
    local roughness = detail_metres * (0.08 + 1.2 * min(1, slope * 2.0))
    local dither_nodes = 0.1 + 0.8 * min(1, slope * 4.0)
    local detailed = elevation + detail * roughness
            + dither * dither_nodes * metres_per_node

    local water_y = nil
    local shore = false
    local distance = tdl.water_distance_at(fi, fj)
    if distance < 800 then
            local level = tdl.water_surface_at(fi, fj)
            local catchment = max(1, tdl.drainage_at(fi, fj))
            local is_channel = catchment >= min_drainage_km2
            local half = 0.7 * math.sqrt(catchment)
            if half < 2 then half = 2 elseif half > 300 then half = 300 end
            if is_channel and distance >= half
                    and distance <= tdl.manifest.native_resolution then
                    local segment_distance, segment_level =
                            tdl.channel_segment_at(fi, fj, distance)
                    if segment_distance < distance then
                            distance = segment_distance
                            if segment_level then level = segment_level end
                    end
            end

            if distance <= tdl.manifest.native_resolution
                    and elevation < level - MAX_INVENTED_DEPTH then
                    water_y = tdl.surface_y(level)
            else
                    local deep = 0.35 * (catchment ^ 0.3)
                    if deep < 1 then deep = 1 elseif deep > 24 then deep = 24 end

                    local reach = half * 2.5
                    local near = 1 - min(1, distance / reach)
                    if near > 0 then
                            near = near * near * (3 - 2 * near)
                            detailed = detailed + (elevation - detailed) * near
                    end

                    if is_channel and distance < half then
                            local across = distance / half
                            local bed = level - deep * math.sqrt(max(0, 1 - across * across))
                            if bed < detailed then detailed = bed end
                            water_y = tdl.surface_y(level)
                            shore = true
                    elseif distance < reach then
                            local t = (distance - half) / (reach - half)
                            if t < 0 then t = 0 elseif t > 1 then t = 1 end
                            t = t * t * (3 - 2 * t)
                            local bank = level + 0.5
                            if bank < detailed then
                                    detailed = bank + (detailed - bank) * t
                            end
                    end

                    if not water_y and distance < reach
                            and elevation < level - 0.5 then
                            water_y = tdl.surface_y(level)
                            if detailed > level then detailed = elevation end
                            if elevation > level - SHORE_DEPTH then
                                    shore = true
                            end
                    end
            end
    end

    local surface = tdl.surface_y(detailed)
    if water_y and water_y < surface then
            water_y = nil
            shore = false
    end
    local material = tdl_classify.material(detailed, slope,
            climate[1], climate[2], climate[3], climate[4], drainage, hand)

    local entry
    if use_palette then
            local temp, precip = tdl_classify.adjust(detailed,
                    climate[1], climate[3])
            entry = tdl_palette.pick(
                    tdl_palette.heat(temp),
                    tdl_palette.humidity(tdl_classify.aridity(
                            temp, climate[2], precip)), surface)
    end
    return surface, water_y, shore, material, entry
end

local detail_noise,rock_noise,dither_noise
local function first(...)
    for _,name in ipairs({...}) do if core.registered_nodes[name] then return name end end
    return "air"
end
function tdl_column.at(x,z)
    if not detail_noise then
        detail_noise=ValueNoise(tdl_column.detail_params)
        rock_noise=ValueNoise(tdl_column.rock_params)
        dither_noise=ValueNoise(tdl_column.dither_params)
    end
    local fi,fj=tdl.node_to_pixel(x,z)
    local function elevation(dx,dz)
        local i,j=tdl.node_to_pixel(x+dx,z+dz)
        return tdl.elevation_at(i,j)
    end
    local dx=(elevation(1,0)-elevation(-1,0))/(2*metres_per_node)
    local dz=(elevation(0,1)-elevation(0,-1))/(2*metres_per_node)
    local slope=math.sqrt(dx*dx+dz*dz)
    -- The mapgen caches climate in eight-node squares starting on chunk edges.
    local ci,cj=tdl.climate_pixel(floor(x/8)*8,floor(z/8)*8)
    local climate={tdl.climate_at(ci,cj)}
    local drainage,hand=tdl.wetness_at(fi,fj)
    local pos={x=x,y=z}
    local y,water,shore,material,entry=tdl_column.evaluate(elevation(0,0),slope,
        detail_noise:get_2d(pos),dither_noise:get_2d(pos),climate,drainage,hand,fi,fj,
        core.settings:get_bool("tdl_use_game_biomes",true))
    local pair=MATERIALS[material] or MATERIALS.stony
    local stone=first("mcl_core:stone","default:stone")
    local top=entry and entry.top_name or first(pair.top,stone)
    local side=entry and entry.filler_name or first(pair.filler,stone)
    local rock=first(ROCK[material] or ROCK.default,stone)
    local bare=slope+rock_noise:get_2d(pos)*0.18
    if bare>0.84 then top,side=rock,rock
    elseif bare>0.58 then top,side=first(SCREE,"default:gravel",stone),rock end
    if water and shore then
        top=slope>0.35 and first("mcl_core:gravel","default:gravel",stone) or first("mcl_core:sand","default:sand",stone)
        side=first("mcl_core:sand","default:sand",stone)
    end
    if y<tdl.sea_level then water=math.max(water or tdl.sea_level,tdl.sea_level) end
    return y,top,water,side,entry
end
