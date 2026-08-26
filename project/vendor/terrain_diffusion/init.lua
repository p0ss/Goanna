-- Terrain Diffusion for Luanti.
--
-- Terrain comes from a tile cache baked into the world directory by
-- server/bake.py, not from anything this mod generates. See README.md.

local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)

-- Two mapgen settings have to be right before this mod loads, and neither can
-- be fixed from here. Mods load after the engine has chosen a mapgen and, in
-- Mineclonia's case, after mcl_init has read them.
--
-- mg_name must be singlenode so the engine generates nothing. But singlenode is
-- also the switch that turns Mineclonia's own Lua level generator on, and that
-- one writes a full Minecraft style world over the top of this one, so
-- mcl_singlenode_mapgen must be false as well. Both belong in the world's
-- map_meta.txt, which tools/prepare-world.sh writes.
local mg_name = core.get_mapgen_setting("mg_name")
if mg_name ~= "singlenode" then
        core.log("error", "[terrain_diffusion] mg_name is '" .. tostring(mg_name) ..
                "', expected 'singlenode'. The engine mapgen will fight this mod. " ..
                "Run tools/prepare-world.sh against this world.")
end
if core.get_mapgen_setting("mcl_singlenode_mapgen") ~= "false" then
        core.log("error", "[terrain_diffusion] mcl_singlenode_mapgen is not false, so " ..
                "Mineclonia's own level generator will overwrite this terrain. " ..
                "Run tools/prepare-world.sh against this world.")
end

dofile(modpath .. "/tdl_terrain.lua")
dofile(modpath .. "/tdl_biomes.lua")
dofile(modpath .. "/tdl_palette.lua")

-- These run in the mapgen environment, one copy per emerge thread, in order.
core.register_mapgen_script(modpath .. "/tdl_terrain.lua")
core.register_mapgen_script(modpath .. "/tdl_biomes.lua")
core.register_mapgen_script(modpath .. "/tdl_palette.lua")
core.register_mapgen_script(modpath .. "/tdl_mapgen.lua")

-- Goanna clients draw terrain past the send distance from summaries; on this
-- world the ground can be answered from the tiles without generating it. See
-- tdl_far.lua. Needs goanna_server_mod loaded first, hence optional_depends.
dofile(modpath .. "/tdl_far.lua")

if not tdl.available then
        core.log("error", "[terrain_diffusion] no baked terrain, the world will be empty")
        return
end

local manifest = tdl.manifest
local span_km = manifest.tiles * manifest.tile_px * manifest.native_resolution / 1000
local span_nodes = manifest.tiles * manifest.tile_px * tdl.nodes_per_pixel

core.log("action", string.format(
        "[terrain_diffusion] %dx%d tiles, %.1f km across, %.2f m per node, %d nodes across",
        manifest.tiles, manifest.tiles, span_km, tdl.metres_per_node, span_nodes))

-- Spawn. The baker picks a land pixel near the middle of the region and Luanti's
-- origin is mapped onto it. The baked elevation is only a starting estimate:
-- tdl_mapgen adds sub-pixel relief, rivers and caves, so placing a player at the
-- estimate can leave them underground. Emerge the area and inspect the finished
-- nodes before choosing a position.
local function surface_at(x, z)
        local fi, fj = tdl.node_to_pixel(x, z)
        return tdl.surface_y(tdl.elevation_at(fi, fj))
end

local spawn_generation = {}

local function is_open_node(pos)
        local node = core.get_node_or_nil(pos)
        local def = node and core.registered_nodes[node.name]
        return def ~= nil and not def.walkable and def.liquidtype == "none"
end

local function is_spawn_ground(pos)
        local node = core.get_node_or_nil(pos)
        local def = node and core.registered_nodes[node.name]
        if not def or not def.walkable or def.liquidtype ~= "none" then
                return false
        end

        -- Canopies and trunks are technically walkable but make poor spawn
        -- surfaces. Search outward for actual ground instead.
        return core.get_item_group(node.name, "leaves") == 0 and
                core.get_item_group(node.name, "tree") == 0 and
                core.get_item_group(node.name, "flora") == 0
end

local function spawn_offsets(radius, step)
        local offsets = {}
        for z = -radius, radius, step do
                for x = -radius, radius, step do
                        offsets[#offsets + 1] = {x = x, z = z, d2 = x * x + z * z}
                end
        end
        table.sort(offsets, function(a, b) return a.d2 < b.d2 end)
        return offsets
end

local spawn_search = spawn_offsets(32, 4)

local function finish_spawn(name, generation, estimated_y)
        if spawn_generation[name] ~= generation then
                return
        end
        local player = core.get_player_by_name(name)
        if not player then
                return
        end

        for _, offset in ipairs(spawn_search) do
                for y = estimated_y + 64, estimated_y - 96, -1 do
                        local ground = {x = offset.x, y = y, z = offset.z}
                        if is_spawn_ground(ground) and
                                        is_open_node({x = offset.x, y = y + 1, z = offset.z}) and
                                        is_open_node({x = offset.x, y = y + 2, z = offset.z}) then
                                player:set_pos({x = offset.x, y = y + 1, z = offset.z})
                                core.log("action", string.format(
                                        "[terrain_diffusion] placed %s on surface at %d,%d,%d",
                                        name, offset.x, y + 1, offset.z))
                                return
                        end
                end
        end

        -- This should only be reachable for a damaged or incomplete tile cache.
        core.log("error", "[terrain_diffusion] no safe surface spawn found for " .. name)
        player:set_pos({x = 0, y = estimated_y + 65, z = 0})
end

local function place(player)
        local name = player:get_player_name()
        local estimated_y = math.max(surface_at(0, 0), tdl.sea_level)
        local generation = (spawn_generation[name] or 0) + 1
        spawn_generation[name] = generation

        -- Keep the player clear of the estimated terrain while the spawn column
        -- is generated. The final placement happens only after every requested
        -- mapblock has emerged.
        player:set_pos({x = 0, y = estimated_y + 65, z = 0})
        core.emerge_area(
                {x = -32, y = estimated_y - 96, z = -32},
                {x = 32, y = estimated_y + 64, z = 32},
                function(_, _, calls_remaining)
                        if calls_remaining == 0 then
                                core.after(0, finish_spawn, name, generation, estimated_y)
                        end
                end)
end

core.register_on_newplayer(place)
core.register_on_respawnplayer(function(player)
        place(player)
        return true
end)

-- Repair worlds created with the old coarse-height spawn calculation. Do not
-- move legitimate underground players: this only fires when the saved player
-- body is embedded in a walkable node.
core.register_on_joinplayer(function(player)
        local name = player:get_player_name()
        core.after(1, function()
                local joined = core.get_player_by_name(name)
                if not joined then
                        return
                end
                local pos = joined:get_pos()
                local x = math.floor(pos.x + 0.5)
                local y = math.floor(pos.y + 0.5)
                local z = math.floor(pos.z + 0.5)
                local feet = core.get_node_or_nil({x = x, y = y, z = z})
                local head = core.get_node_or_nil({x = x, y = y + 1, z = z})
                local feet_def = feet and core.registered_nodes[feet.name]
                local head_def = head and core.registered_nodes[head.name]
                if (feet_def and feet_def.walkable) or (head_def and head_def.walkable) then
                        core.log("warning", "[terrain_diffusion] recovering embedded player " .. name)
                        place(joined)
                end
        end)
end)

core.register_chatcommand("tdl", {
        description = "Report terrain diffusion scale and the terrain under you",
        func = function(name)
                local player = core.get_player_by_name(name)
                if not player then
                        return false, "no player"
                end
                local pos = player:get_pos()
                local fi, fj = tdl.node_to_pixel(pos.x, pos.z)
                local elevation = tdl.elevation_at(fi, fj)
                local temp, t_season, precip, p_cv = tdl.climate_at(fi, fj)
                local drainage, hand = tdl.wetness_at(fi, fj)
                local distance = tdl.water_distance_at(fi, fj)
                local water = distance < 400 and tdl.water_surface_at(fi, fj) or nil

                local east = tdl.elevation_at(fi, fj + 1)
                local west = tdl.elevation_at(fi, fj - 1)
                local south = tdl.elevation_at(fi + 1, fj)
                local north = tdl.elevation_at(fi - 1, fj)
                local run = 2 * 30.0
                local slope = math.sqrt(((east - west) / run) ^ 2 +
                        ((south - north) / run) ^ 2)

                local material = tdl_classify.material(elevation, slope, temp,
                        t_season, precip, p_cv, drainage, hand)

                return true, string.format(
                        "pixel %.0f,%.0f  %.0f m (y=%d)  slope %.2f  %s\n" ..
                        "%.1f C, %.0f mm/year, seasonality %.0f/%.0f\n" ..
                        "drainage %.1f km2, %.0f m above it, water %s at %.0f m away",
                        fi, fj, elevation, tdl.surface_y(elevation), slope, material,
                        temp, precip, t_season, p_cv,
                        drainage, hand, water and string.format("%.0f m", water) or "none",
                        distance)
        end,
})




core.register_chatcommand("tdlbiomes", {
        description = "Sample the whole world and report which biomes it holds",
        func = function()
                local counts, total = {}, 0
                local reach = 31000
                for z = -reach, reach, 400 do
                        for x = -reach, reach, 400 do
                                local fi, fj = tdl.node_to_pixel(x, z)
                                local ci, cj = tdl.climate_pixel(x, z)
                                local elevation = tdl.elevation_at(fi, fj)
                                local temp, t_season, precip, p_cv = tdl.climate_at(ci, cj)
                                local drainage, hand = tdl.wetness_at(fi, fj)
                                local east = tdl.elevation_at(fi, fj + 1)
                                local west = tdl.elevation_at(fi, fj - 1)
                                local south = tdl.elevation_at(fi + 1, fj)
                                local north = tdl.elevation_at(fi - 1, fj)
                                local slope = math.sqrt(((east - west) / 60) ^ 2 +
                                        ((south - north) / 60) ^ 2)
                                local material = tdl_classify.material(elevation, slope,
                                        temp, t_season, precip, p_cv, drainage, hand)
                                counts[material] = (counts[material] or 0) + 1
                                total = total + 1
                        end
                end
                local names = {}
                for name in pairs(counts) do names[#names + 1] = name end
                table.sort(names, function(a, b) return counts[a] > counts[b] end)
                local parts = {}
                for _, name in ipairs(names) do
                        parts[#parts + 1] = string.format("%s %.1f%%",
                                name, 100 * counts[name] / total)
                end
                return true, total .. " samples: " .. table.concat(parts, ", ")
        end,
})
