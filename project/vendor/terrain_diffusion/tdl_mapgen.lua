-- Runs in the mapgen environment, one copy per emerge thread. This is off the
-- main thread, which is why the tile reads and the per column work here do not
-- show up as lag to players.

if not tdl or not tdl.available then
        return
end

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

-- The game's trees, plants and ground cover. Off leaves bare terrain, which
-- is what this mod produced before tdl_decorate.lua existed.
local place_decorations = core.settings:get_bool("tdl_place_decorations", true)

local use_palette = core.settings:get_bool("tdl_use_game_biomes", true)
local palette_count = 0
if use_palette and tdl_palette then
        palette_count = tdl_palette.load()
        if palette_count == 0 then
                core.log("warning", "[terrain_diffusion] the game registered no usable " ..
                        "biomes, falling back to this mod's own node names")
                use_palette = false
        end
end

-- Node names differ between games, and a mapgen that refuses to load because
-- one is missing is no use to anyone. Everything below takes a list of
-- candidates and settles for the first that exists.
local function first_content(...)
        for _, name in ipairs({...}) do
                local ok, id = pcall(core.get_content_id, name)
                if ok then
                        return id
                end
        end
        return nil
end

local c_air = core.get_content_id("air")
local c_stone = first_content("mcl_core:stone", "default:stone", "air")
local c_water = first_content("mcl_core:water_source", "default:water_source", "air")
local c_scree = first_content(SCREE, "default:gravel") or c_stone
local c_sand = first_content("mcl_core:sand", "default:sand") or c_stone
local c_gravel = first_content("mcl_core:gravel", "default:gravel") or c_stone

local top_id, filler_id, rock_id = {}, {}, {}
for name, pair in pairs(MATERIALS) do
        top_id[name] = first_content(pair.top) or c_stone
        filler_id[name] = first_content(pair.filler) or c_stone
        rock_id[name] = first_content(ROCK[name] or ROCK.default) or c_stone
end

local sea_level = tdl.sea_level
local nodes_per_pixel = tdl.nodes_per_pixel
local metres_per_node = tdl.metres_per_node
local detail_metres = tdl.detail_metres
local min_drainage_km2 = tdl.min_drainage_km2

-- Deeper than this below its own water level, a column is the interior of a
-- lake or the sea rather than its edge, so there is nothing left to invent:
-- the deepest bed this mapgen ever carves for a real channel is 24 m, so
-- past that depth the ground already explains itself.
local MAX_INVENTED_DEPTH = 24

-- How shallow standing water has to be before its floor counts as a beach.
-- "Distance to water" cannot tell a true shoreline from the middle of a lake
-- once a column is already wet, since both read zero, so a shallow pond a
-- kilometre across would otherwise sand its entire bed rather than just the
-- rim. Depth can tell the difference: a rim is shallow, a middle usually
-- is not.
local SHORE_DEPTH = 4

-- Everything the model knows about is 30 m across or larger. Below that the
-- terrain has to be invented, and the amplitude of what gets invented has to
-- follow the ground: mountainsides in the real world are rough at every scale,
-- floodplains are not. Slope is the cheapest proxy for that, and it is already
-- being computed for the biome classifier.
--
-- Four octaves starting at eight nodes puts the wavelengths at roughly 60, 30,
-- 15 and 7 m, which fills in below the model and stops short of arguing with it.
local detail_params = {
        offset = 0,
        scale = 1,
        spread = {x = 8 * nodes_per_pixel, y = 8 * nodes_per_pixel, z = 8 * nodes_per_pixel},
        seed = 71249,
        octaves = 4,
        persistence = 0.55,
        lacunarity = 2.0,
}

-- A second, finer field decides where soil gives way to bare rock, so the
-- boundary is ragged instead of a clean contour line.
local rock_params = {
        offset = 0,
        scale = 1,
        spread = {x = 3 * nodes_per_pixel, y = 3 * nodes_per_pixel, z = 3 * nodes_per_pixel},
        seed = 20261,
        octaves = 2,
        persistence = 0.5,
        lacunarity = 2.0,
}

-- A one node dither. Rounding a smooth height field to whole nodes puts every
-- contour line in exactly the same place for hundreds of nodes, which reads as
-- corduroy stripes across the landscape. Breaking the rounding up with noise at
-- roughly node scale scatters those boundaries instead. It is applied
-- everywhere, including flat ground, because perfectly flat ground is what
-- makes the banding visible in the first place.
-- Quantisation lives at node scale, so this stays at node scale: a few nodes
-- across, whatever a node happens to mean. What has to follow the ground is the
-- amplitude. Contour banding only appears where there is a gradient to band,
-- and a flat field has none, so dithering it just scatters rubble over
-- otherwise good farmland. Amplitude therefore follows slope, and flat ground
-- is left flat.
local dither_params = {
        offset = 0,
        scale = 1,
        spread = {x = 3, y = 3, z = 3},
        seed = 40507,
        octaves = 2,
        persistence = 0.5,
        lacunarity = 2.0,
}

-- Caves. Two fields intersected, which gives tunnels rather than the blobs a
-- single field produces, and both are sized in metres rather than nodes so a
-- cave stays the same size in the world whatever the node scale is set to. A
-- real cave passage is a few metres across, which is why this only starts
-- producing something worth crawling through once nodes are about a metre.
local cave_metres = tonumber(core.settings:get("tdl_cave_size")) or 45
local cave_threshold = tonumber(core.settings:get("tdl_cave_amount")) or 0.075
local cave_nodes = math.max(4, cave_metres / metres_per_node)

local cave_params_a = {
        offset = 0, scale = 1,
        spread = {x = cave_nodes, y = cave_nodes * 0.6, z = cave_nodes},
        seed = 55031, octaves = 2, persistence = 0.5, lacunarity = 2.0,
}
local cave_params_b = {
        offset = 0, scale = 1,
        spread = {x = cave_nodes, y = cave_nodes * 0.6, z = cave_nodes},
        seed = 90211, octaves = 2, persistence = 0.5, lacunarity = 2.0,
}

local detail_map, rock_map, dither_map
local cave_map_a, cave_map_b
local detail_buffer, rock_buffer, dither_buffer = {}, {}, {}
local cave_buffer_a, cave_buffer_b = {}, {}
local data_buffer = {}

-- Heights, slopes and materials for the chunk, kept across calls. The height
-- grid carries a one node margin so slope can be taken from it rather than from
-- four more tile lookups per column, which was most of the cost.

-- What grows where is the game's to say. Every game publishes it through
-- core.register_decoration, and tdl_decorate.lua places what it finds against
-- the biome tdl_palette chose for the column.
--
-- What used to be here was a table of nine species with Mineclonia's node
-- names written into it, which is why a world in any other game came up bare:
-- not one of those names resolved, so not one plant was placed, while the
-- hundreds the game itself had registered were never asked for.


-- Heights and materials were worked out four columns outside the chunk so a
-- tree rooted just beyond it still got its canopy drawn inside. Decorations
-- are the game's now and are placed only within the chunk, the same as the
-- engine places them, so the widened area costs work and buys nothing.
local COLUMN_MARGIN = 0

local raw_height = {}
local heights = {}
local present = {}
local slopes = {}
local materials = {}
local grounds = {}
local water_levels = {}
local shore_columns = {}

local floor = math.floor
local sqrt = math.sqrt
local min = math.min
local max = math.max


core.register_on_generated(function(vmanip, minp, maxp, blockseed)
        local side_x = maxp.x - minp.x + 1
        local side_y = maxp.y - minp.y + 1
        local side_z = maxp.z - minp.z + 1

        local m = COLUMN_MARGIN
        local wide_x = side_x + 2 * m
        local wide_z = side_z + 2 * m
        local raw_x = wide_x + 2

        if not detail_map then
                local size = {x = wide_x, y = wide_z}
                detail_map = ValueNoiseMap(detail_params, size)
                rock_map = ValueNoiseMap(rock_params, size)
                dither_map = ValueNoiseMap(dither_params, size)
        end
        local noise_at = {x = minp.x - m, y = minp.z - m}
        local detail = detail_map:get_2d_map_flat(noise_at, detail_buffer)
        local rock_noise = rock_map:get_2d_map_flat(noise_at, rock_buffer)
        local dither = dither_map:get_2d_map_flat(noise_at, dither_buffer)

        -- Pass one: raw elevation over the wide area plus one, for slope.
        for name in pairs(present) do present[name] = nil end

        local at = 1
        for z = minp.z - m - 1, maxp.z + m + 1 do
                for x = minp.x - m - 1, maxp.x + m + 1 do
                        local fi, fj = tdl.node_to_pixel(x, z)
                        raw_height[at] = tdl.elevation_at(fi, fj)
                        at = at + 1
                end
        end

        -- Pass two: slope, detail, water and material over the wide area.
        local run = 2 * metres_per_node
        local climate_cache = {}
        for iz = 1, wide_z do
                for ix = 1, wide_x do
                        local index = (iz - 1) * wide_x + ix
                        local centre = iz * raw_x + ix + 1
                        local elevation = raw_height[centre]
                        local dx = (raw_height[centre + 1] - raw_height[centre - 1]) / run
                        local dz = (raw_height[centre + raw_x] - raw_height[centre - raw_x]) / run
                        local slope = sqrt(dx * dx + dz * dz)

                        local roughness = detail_metres * (0.08 + 1.2 * min(1, slope * 2.0))
                        local dither_nodes = 0.1 + 0.8 * min(1, slope * 4.0)
                        local detailed = elevation + detail[index] * roughness
                                + dither[index] * dither_nodes * metres_per_node

                        local x = minp.x - m + ix - 1
                        local z = minp.z - m + iz - 1
                        local fi_here, fj_here = tdl.node_to_pixel(x, z)

                        local key = floor((z - minp.z) / 8) * 32 + floor((x - minp.x) / 8)
                        local climate = climate_cache[key]
                        if not climate then
                                local ci, cj = tdl.climate_pixel(x, z)
                                local temp, t_season, precip, p_cv = tdl.climate_at(ci, cj)
                                climate = {temp, t_season, precip, p_cv}
                                climate_cache[key] = climate
                        end
                        local drainage, hand = tdl.wetness_at(fi_here, fj_here)

                        -- Cut the channel here rather than in the bake, at node
                        -- resolution, from a distance field that interpolates
                        -- smoothly. Half width comes from the catchment: a river
                        -- widens with the square root of the country behind it,
                        -- so a headwater stream is a few metres across and a
                        -- trunk river is hundreds, and neither is tied to the
                        -- thirty metre pixel the model works in.
                        local water_y = nil
                        local shore = false
                        local distance = tdl.water_distance_at(fi_here, fj_here)
                        if distance < 800 then
                                local level = tdl.water_surface_at(fi_here, fj_here)
                                local catchment = max(1, tdl.drainage_at(fi_here, fj_here))
                                local is_channel = catchment >= min_drainage_km2
                                local half = 0.7 * math.sqrt(catchment)
                                if half < 2 then half = 2 elseif half > 300 then half = 300 end
                                if is_channel and distance >= half
                                        and distance <= tdl.manifest.native_resolution then
                                        local segment_distance, segment_level =
                                                tdl.channel_segment_at(fi_here, fj_here, distance)
                                        if segment_distance < distance then
                                                distance = segment_distance
                                                if segment_level then level = segment_level end
                                        end
                                end

                                if distance <= tdl.manifest.native_resolution
                                        and elevation < level - MAX_INVENTED_DEPTH then
                                        -- Well below the water's own level and
                                        -- actually at it: this is the interior
                                        -- of a lake or the sea, not its edge.
                                        -- The distance test is the whole of it.
                                        -- The water plane is a field over every
                                        -- cell holding whatever level is
                                        -- nearest, so depth on its own only
                                        -- asks "am I below something wet within
                                        -- 800 m", and downhill is the ordinary
                                        -- state of ground. A lake on a shoulder
                                        -- poured its level into every valley
                                        -- under it: 92 per cent of flooded
                                        -- cells were not at water, a median
                                        -- 379 m from it, and one column stood
                                        -- 437 m tall. Being far below the level
                                        -- argues against being in the water,
                                        -- not for it. "Distance to
                                        -- water" reads zero out here just as
                                        -- it does right at the shoreline,
                                        -- since it cannot see past its own
                                        -- surface, so depth is what tells
                                        -- the two apart. Flood it and leave
                                        -- the bed and material alone: the
                                        -- heightmap is already the basin,
                                        -- and the biome classifier already
                                        -- knows what a sea floor is made of.
                                        water_y = tdl.surface_y(level)
                                else
                                        -- A real channel is worth inventing a
                                        -- bed for, the same catchment the
                                        -- bake needed before it would call
                                        -- something a river. Below that this
                                        -- is the edge of a pond, a lake or
                                        -- the sea, all of which are wide
                                        -- enough that the model already
                                        -- resolved their bed: the basin in
                                        -- the heightmap is the bed, not a
                                        -- profile invented from how much
                                        -- land drains to it.
                                        local deep = 0.35 * (catchment ^ 0.3)
                                        if deep < 1 then deep = 1 elseif deep > 24 then deep = 24 end

                                        -- Put the invented relief away as the
                                        -- water is approached. A floodplain
                                        -- is flat, and twenty metres of noise
                                        -- beside a river is what stands
                                        -- isolated cubes of water up on the
                                        -- bank: every column the noise
                                        -- happens to dip below the river's
                                        -- level floods on its own.
                                        local reach = half * 2.5
                                        local near = 1 - min(1, distance / reach)
                                        if near > 0 then
                                                near = near * near * (3 - 2 * near)
                                                detailed = detailed + (elevation - detailed) * near
                                        end

                                        if is_channel and distance < half then
                                                -- Inside a real channel: a
                                                -- rounded bed, so the bottom
                                                -- is deepest mid stream and
                                                -- rises to meet the banks.
                                                local across = distance / half
                                                local bed = level - deep * math.sqrt(max(0, 1 - across * across))
                                                if bed < detailed then detailed = bed end
                                                water_y = tdl.surface_y(level)
                                                shore = true
                                        elseif distance < reach then
                                                -- Just outside a channel, or
                                                -- anywhere near the edge of a
                                                -- standing body: ease the
                                                -- ground towards the
                                                -- shoreline instead of
                                                -- leaving a vertical wall. t
                                                -- can start below zero here
                                                -- (a standing body has no
                                                -- "inside half" to have
                                                -- already excluded), so
                                                -- clamp it.
                                                local t = (distance - half) / (reach - half)
                                                if t < 0 then t = 0 elseif t > 1 then t = 1 end
                                                t = t * t * (3 - 2 * t)
                                                local bank = level + 0.5
                                                if bank < detailed then
                                                        detailed = bank + (detailed - bank) * t
                                                end
                                        end

                                        -- Standing water is decided by the
                                        -- baked ground, never by the noise
                                        -- laid on top of it: this is what
                                        -- floods a basin to the level the
                                        -- heightmap actually holds it at,
                                        -- rather than every dip becoming its
                                        -- own pond.
                                        if not water_y and distance < reach
                                                and elevation < level - 0.5 then
                                                water_y = tdl.surface_y(level)
                                                if detailed > level then detailed = elevation end
                                                -- Shallow enough to be a rim,
                                                -- not just anywhere on a
                                                -- lake's or the sea's own
                                                -- floor.
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
                        water_levels[index] = water_y
                        shore_columns[index] = shore

                        heights[index] = surface
                        slopes[index] = slope
                        materials[index] = tdl_classify.material(detailed, slope,
                                climate[1], climate[2], climate[3], climate[4], drainage, hand)

                        -- The classifier decides what the climate is here, from
                        -- terrain the game cannot see. The game decides what
                        -- that climate is made of. Both need the same figures,
                        -- adjusted for height, which is why this is per column
                        -- rather than per eight node block: the lapse rate is
                        -- what separates a peak from the valley below it.
                        if use_palette then
                                local temp, precip = tdl_classify.adjust(detailed,
                                        climate[1], climate[3])
                                local entry = tdl_palette.pick(
                                        tdl_palette.heat(temp),
                                        tdl_palette.humidity(tdl_classify.aridity(
                                                temp, climate[2], precip)), surface)
                                grounds[index] = entry
                                -- Which biomes the chunk actually holds, so the
                                -- decoration pass can ignore the hundreds that
                                -- were never going to match here.
                                if entry then present[entry.name] = true end
                        end
                end
        end

        -- Caves are only worth computing where there is rock to put them in.
        local highest = heights[1]
        for k = 2, wide_x * wide_z do
                if heights[k] > highest then highest = heights[k] end
        end
        local carve_caves = cave_threshold > 0 and minp.y <= highest

        local cave_a, cave_b
        if carve_caves then
                if not cave_map_a then
                        local size = {x = side_x, y = side_y, z = side_z}
                        cave_map_a = ValueNoiseMap(cave_params_a, size)
                        cave_map_b = ValueNoiseMap(cave_params_b, size)
                end
                cave_a = cave_map_a:get_3d_map_flat(minp, cave_buffer_a)
                cave_b = cave_map_b:get_3d_map_flat(minp, cave_buffer_b)
        end

        -- Pass three: fill the columns.
        local emin, emax = vmanip:get_emerged_area()
        local area = VoxelArea:new{MinEdge = emin, MaxEdge = emax}
        local data = vmanip:get_data(data_buffer)

        for z = minp.z, maxp.z do
                for x = minp.x, maxp.x do
                        local index = (z - minp.z + m) * wide_x + (x - minp.x + m) + 1
                        local surface = heights[index]
                        local material = materials[index]
                        local slope = slopes[index]

                        local entry = grounds[index]
                        local top, filler
                        local depth_top, depth_filler = 1, 3
                        if entry then
                                top, filler = entry.top, entry.filler
                                depth_top, depth_filler = entry.depth_top, entry.depth_filler
                        else
                                top, filler = top_id[material], filler_id[material]
                        end

                        local bare = slope + rock_noise[index] * 0.18
                        if bare > 0.84 then
                                top = rock_id[material]
                                filler = rock_id[material]
                        elseif bare > 0.58 then
                                top = c_scree
                                filler = rock_id[material]
                        end

                        local water_y = water_levels[index]
                        if water_y and shore_columns[index] then
                                -- Only right at the edge: the interior of a
                                -- lake or the sea is deep enough that this
                                -- column was never marked a shore, and keeps
                                -- whatever the biome classifier decided a
                                -- floor that deep is made of.
                                top = (slope > 0.35) and c_gravel or c_sand
                                filler = c_sand
                        end

                        local vi = area:index(x, minp.y, z)
                        local cave_base = (z - minp.z) * side_y * side_x + (x - minp.x) + 1
                        for y = minp.y, maxp.y do
                                local content
                                if y < surface - depth_top + 1 - depth_filler then
                                        content = c_stone
                                elseif y < surface then
                                        content = filler
                                elseif y == surface then
                                        content = top
                                elseif water_y and y <= water_y then
                                        content = c_water
                                elseif y <= sea_level then
                                        content = c_water
                                else
                                        content = c_air
                                end

                                if carve_caves and y < surface and content ~= c_water then
                                        local cat = cave_base + (y - minp.y) * side_x
                                        local a = cave_a[cat]
                                        local b = cave_b[cat]
                                        if a > -cave_threshold and a < cave_threshold
                                                and b > -cave_threshold and b < cave_threshold then
                                                content = c_air
                                        end
                                end

                                data[vi] = content
                                vi = vi + area.ystride
                        end
                end
        end

        -- Pass four: the game's own decorations, against the biome this mod
        -- chose for each column. tdl_decorate.lua carries the why.
        local decorated = nil
        if place_decorations and use_palette and not tdl_decorate.unkeyed_only() then
                decorated = tdl_decorate.place(data, area, minp, maxp, blockseed, {
                        margin = m,
                        wide_x = wide_x,
                        heights = heights,
                        water_levels = water_levels,
                        grounds = grounds,
                        present = present,
                })
        end

        vmanip:set_data(data)

        -- Ores come from whatever the game registered. Mineclonia's are keyed on
        -- the node they sit in and a height range, not on the biome map, which a
        -- singlenode mapgen never fills in, so they land correctly without this
        -- mod knowing anything about them.
        core.generate_ores(vmanip, minp, maxp)

        if decorated then
                -- Schematics and L-system trees, which the engine writes
                -- through the VoxelManip and so could not run while the node
                -- buffer was out on loan.
                tdl_decorate.flush(vmanip, decorated)
        elseif place_decorations then
                -- Nothing this mod can improve on: either the game keys none of
                -- its decorations to a biome, or it registered no biomes for
                -- the ground either, so the engine's own pass is both correct
                -- and faster. It skips the biome test when there is no biome
                -- map, which is exactly right when no decoration asked for one.
                core.generate_decorations(vmanip, minp, maxp)
        end
end)

core.log("action", "[terrain_diffusion] mapgen ready, " ..
        string.format("%.2f", metres_per_node) .. " m per node, detail " ..
        string.format("%.0f", detail_metres) .. " m")
