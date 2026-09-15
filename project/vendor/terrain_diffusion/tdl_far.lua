-- Far surface for Goanna clients. Optional: does nothing unless the Goanna
-- server mod is loaded and has registered the hook.
--
-- Goanna draws terrain past the server's send distance from coarse summaries
-- the Goanna mod makes of generated blocks, which means a horizon has to be
-- generated before it can be seen, and on a world like this one, with dozens
-- of kilometres of land in the tile cache, generating it is the slow part.
-- But the far field only needs the ground height and the surface material
-- per column, and this mapgen can answer that for any (x, z) straight from
-- the tiles without generating anything. So it does: the Goanna mod asks for
-- one sample per 4 node cell of any block that is not generated, serves what
-- comes back as a summary, and replaces it with the real block's summary
-- when the block is generated. Nothing here writes to the world.
--
-- Ground samples are deliberately coarse. The tiled path also carries a
-- separate forest preview, using the decoration runtime and game schematics.
-- Cached/generated voxel meshes replace it where published coverage exists.

if not (tdl and tdl.available and tdl_classify) then
        return
end
if not goanna_register_far_surface then
        return
end

-- The same tables as tdl_mapgen.lua's, by name rather than content id since
-- this runs in the main environment and is asked for names.
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
local ROCK = {
        desert   = "mcl_core:sandstone",
        badlands = "mcl_core:redsandstone",
        default  = "mcl_core:stone",
}
local SCREE = "mcl_core:gravel"
local function first_node(...)
        for _, name in ipairs({...}) do
                if core.registered_nodes[name] then return name end
        end
        return "air"
end
local STONE = first_node("mcl_core:stone", "default:stone")
local WATER = first_node("mcl_core:water_source", "default:water_source")
SCREE = first_node(SCREE, "default:gravel", STONE)
local SAND = first_node("mcl_core:sand", "default:sand", STONE)
-- Include the provider code, bake manifest, coordinate settings and game
-- palette in the persistent tile namespace. Bake replacements must change
-- their manifest identity, as the world catalogue packages already do.
local function stable(value)
        if type(value) ~= "table" then return core.serialize(value) end
        local keys, parts = {}, {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, key in ipairs(keys) do
                parts[#parts + 1] = stable(key) .. "=" .. stable(value[key])
        end
        return "{" .. table.concat(parts, ";") .. "}"
end
local function surface_revision()
        local identity = {stable(tdl.manifest)}
        local keys = core.settings:get_names()
        table.sort(keys)
        for _, key in ipairs(keys) do
                if key:sub(1, 4) == "tdl_" then
                        identity[#identity + 1] = key .. "=" .. core.settings:get(key)
                end
        end
        identity[#identity + 1] = stable(core.registered_biomes)
        identity[#identity + 1] = stable(core.registered_decorations)
        -- A schematic can change without its registered filename changing.
        -- Include file contents as well as the decoration definitions.
        local schematics = {}
        for _, deco in pairs(core.registered_decorations) do
                if type(deco.schematic) == "string" then schematics[deco.schematic] = true end
        end
        local paths = {}
        for path in pairs(schematics) do paths[#paths + 1] = path end
        table.sort(paths)
        for _, path in ipairs(paths) do
                local file = io.open(path, "rb")
                if file then
                        identity[#identity + 1] = path .. "=" .. core.sha1(file:read("*a"))
                        file:close()
                end
        end

        identity[#identity + 1] = tostring(core.get_mapgen_setting("seed"))
        identity[#identity + 1] = tostring(core.get_mapgen_setting("chunksize"))
        -- tdl_biomes.lua, not "tdl_classify.lua": the classifier is defined in
        -- the former and there has never been a file by the latter name, so
        -- io.open returned nil and every change to how a climate is read
        -- left the persisted tiles looking current.
        for _, file in ipairs({"tdl_far.lua", "tdl_terrain.lua", "tdl_biomes.lua", "tdl_palette.lua", "tdl_decorate.lua", "tdl_forest.lua", "tdl_column.lua"}) do
                local source = io.open(core.get_modpath("terrain_diffusion") .. "/" .. file, "rb")
                if source then
                        identity[#identity + 1] = source:read("*a")
                        source:close()
                end
        end
        return table.concat(identity, "\n")
end

local sea_level = tdl.sea_level
local min_drainage_km2 = tdl.min_drainage_km2
local run = 2 * 30.0
local use_palette = core.settings:get_bool("tdl_use_game_biomes", true)

-- Same reasoning as tdl_mapgen.lua: past this depth below its own water
-- level, a column is the interior of a lake or the sea, not its edge, and
-- there is no channel bed left to invent for it.
local MAX_INVENTED_DEPTH = 24

-- How shallow standing water has to be before its floor counts as a beach,
-- rather than just the interior of whatever it is part of.
local SHORE_DEPTH = 4

local function coarse_surface(x, z)
        local fi, fj = tdl.node_to_pixel(x, z)
        local elevation = tdl.elevation_at(fi, fj)
        local east = tdl.elevation_at(fi, fj + 1)
        local west = tdl.elevation_at(fi, fj - 1)
        local south = tdl.elevation_at(fi + 1, fj)
        local north = tdl.elevation_at(fi - 1, fj)
        local slope = math.sqrt(((east - west) / run) ^ 2 + ((south - north) / run) ^ 2)
        local ci, cj = tdl.climate_pixel(x, z)
        local temp, t_season, precip, p_cv = tdl.climate_at(ci, cj)
        local drainage, hand = tdl.wetness_at(fi, fj)
        local material = tdl_classify.material(elevation, slope, temp, t_season, precip, p_cv,
                drainage, hand)
        -- Same palette the mapgen uses, so the horizon is made of the same
        -- nodes as the ground you reach when you walk to it. Falls back to the
        -- table above when the game registers no biomes.
        local top, side, biome
        if use_palette and tdl_palette then
                local at, ap = tdl_classify.adjust(elevation, temp, precip)
                local entry = tdl_palette.pick(tdl_palette.heat(at),
                        tdl_palette.humidity(tdl_classify.aridity(at, t_season, ap)),
                        tdl.surface_y(elevation))
                if entry then
                        top, side, biome = entry.top_name, entry.filler_name, entry
                end
        end
        if not top then
                local m = MATERIALS[material] or MATERIALS.stony
                top, side = first_node(m.top, STONE), first_node(m.filler, STONE)
        end
        local rock = first_node(ROCK[material] or ROCK.default, STONE)
        if slope > 0.84 then
                top, side = rock, rock
        elseif slope > 0.58 then
                top, side = SCREE, rock
        end
        -- The same channel the mapgen cuts, from the same distance field, so
        -- the horizon has water where the ground does. The bed profile is
        -- skipped: at four nodes a cell it is below what can be seen.
        local water_y = nil
        local shore = false
        local distance = tdl.water_distance_at(fi, fj)
        if distance < 400 then
                local level = tdl.water_surface_at(fi, fj)

                if distance <= tdl.manifest.native_resolution
                                and elevation < level - MAX_INVENTED_DEPTH then
                        -- The interior of a lake or the sea, not its edge:
                        -- "distance to water" cannot see past its own
                        -- surface, so it reads zero out here too. Flood it
                        -- and leave the ground and its material alone.
                        --
                        -- The distance test carries this, not the depth. The
                        -- water plane holds whatever level is nearest for
                        -- every cell, so depth alone asks "am I below
                        -- something wet nearby", which downhill ground always
                        -- is: see docs/fixes/perched-water.md, where it put
                        -- lakes hundreds of metres up a hillside. tdl_mapgen
                        -- carries the same guard and the two have to agree, or
                        -- the horizon holds water the ground does not and it
                        -- drains as you walk to it.
                        water_y = tdl.surface_y(level)
                else
                        local catchment = math.max(1, tdl.drainage_at(fi, fj))
                        local is_channel = catchment >= min_drainage_km2
                        local half = 0.7 * math.sqrt(catchment)
                        if half < 2 then half = 2 elseif half > 300 then half = 300 end
                        local deep = 0.35 * (catchment ^ 0.3)
                        if deep < 1 then deep = 1 elseif deep > 24 then deep = 24 end
                        if is_channel and distance < half then
                                local across = distance / half
                                local bed = level - deep * math.sqrt(math.max(0, 1 - across * across))
                                if bed < elevation then elevation = bed end
                                water_y = tdl.surface_y(level)
                                shore = true
                        elseif elevation < level - 0.5 and distance < half * 2.5 then
                                water_y = tdl.surface_y(level)
                                -- Shallow enough to be a rim, not just
                                -- anywhere on a lake's or the sea's own
                                -- floor: "distance to water" cannot tell the
                                -- difference once a column is already wet.
                                if elevation > level - SHORE_DEPTH then
                                        shore = true
                                end
                        end
                end
                if shore then
                        top = slope > 0.35 and SCREE or SAND
                        side = SAND
                end
        end
        local surface = tdl.surface_y(elevation)
        if water_y and water_y < surface then
                water_y = nil
        end
        if surface < sea_level and (not water_y or water_y < sea_level) then
                water_y = sea_level
        end
        return surface, top, water_y, side, biome
end

local function surface_provider(x, z, step)
        -- Nearby summaries and forest geometry need the mapgen's actual root
        -- height. Omitting its small-scale relief can bury an entire crown in
        -- the preview ground, even though tree placement itself is correct.
        if not step or step <= 16 then return tdl_column.at(x, z) end
        return coarse_surface(x, z)
end

core.register_on_mods_loaded(function()
        local forest = dofile(core.get_modpath("terrain_diffusion") .. "/tdl_forest.lua")(tdl_column.at, coarse_surface)
        goanna_register_far_surface(surface_provider, {water = WATER, revision = surface_revision(), forest = forest})
end)

core.log("action", "[terrain_diffusion] far surface registered with the Goanna server mod")
