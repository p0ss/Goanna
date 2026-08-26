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
-- What the sample leaves out, against the generated terrain: the detail
-- noise (a few metres on a slope, nothing on a plain), the dither, the rock
-- noise that makes the soil line ragged, caves, and the trees. At four nodes
-- a cell and hundreds of nodes away, none of that is visible; the trees
-- arrive when the blocks do.

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
local WATER = "mcl_core:water_source"

local sea_level = tdl.sea_level
local run = 2 * 30.0
local use_palette = core.settings:get_bool("tdl_use_game_biomes", true)

goanna_register_far_surface(function(x, z)
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
        local top, side
        if use_palette and tdl_palette then
                local at, ap = tdl_classify.adjust(elevation, temp, precip)
                local entry = tdl_palette.pick(tdl_palette.heat(at),
                        tdl_palette.humidity(ap), tdl.surface_y(elevation))
                if entry then
                        top, side = entry.top_name, entry.filler_name
                end
        end
        if not top then
                local m = MATERIALS[material] or MATERIALS.stony
                top, side = m.top, m.filler
        end
        local rock = ROCK[material] or ROCK.default
        if slope > 0.84 then
                top, side = rock, rock
        elseif slope > 0.58 then
                top, side = SCREE, rock
        end
        -- The same channel the mapgen cuts, from the same distance field, so
        -- the horizon has water where the ground does. The bed profile is
        -- skipped: at four nodes a cell it is below what can be seen.
        local water_y = nil
        local distance = tdl.water_distance_at(fi, fj)
        if distance < 400 then
                local level = tdl.water_surface_at(fi, fj)
                local catchment = math.max(1, tdl.drainage_at(fi, fj))
                local half = 0.7 * math.sqrt(catchment)
                if half < 2 then half = 2 elseif half > 300 then half = 300 end
                local deep = 0.35 * (catchment ^ 0.3)
                if deep < 1 then deep = 1 elseif deep > 24 then deep = 24 end
                if distance < half then
                        local across = distance / half
                        local bed = level - deep * math.sqrt(math.max(0, 1 - across * across))
                        if bed < elevation then elevation = bed end
                        water_y = tdl.surface_y(level)
                elseif elevation < level - 0.5 and distance < half * 2.5 then
                        water_y = tdl.surface_y(level)
                end
                if water_y then
                        top = slope > 0.35 and "mcl_core:gravel" or "mcl_core:sand"
                        side = "mcl_core:sand"
                end
        end
        local surface = tdl.surface_y(elevation)
        if water_y and water_y < surface then
                water_y = nil
        end
        if surface < sea_level and (not water_y or water_y < sea_level) then
                water_y = sea_level
        end
        return surface, top, water_y, side
end, {water = WATER})

core.log("action", "[terrain_diffusion] far surface registered with the Goanna server mod")
