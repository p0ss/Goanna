-- Placing the game's own decorations.
--
-- Every Luanti game publishes its trees, plants and ground cover through
-- core.register_decoration, keyed to the biomes they belong to. The engine
-- places them from the mapgen, and a singlenode mapgen places none, so under
-- this mod every one of them was inert. What stood in for them was a table of
-- nine species written into this mod with Mineclonia's node names spelled into
-- it, which in Mineclonia was a thin forest and in any other game was nothing
-- at all: Asuna logged "no node mcl_trees:tree_oak, skipping it" and eleven
-- more like it, and generated a landscape with no plant on it.
--
-- core.generate_decorations() is what exists for this, but it matches a
-- decoration's `biomes` against the mapgen's biome map, and a singlenode
-- mapgen fills no biome map. mg_decoration.cpp tests the biome only
-- `if (mg->biomemap && !biomes.empty())`, so with no map the test is skipped
-- rather than failed, and every decoration lands wherever its place_on
-- matches: spruce, jungle and acacia together on one field of grass. A biome
-- restriction is the point of a biome, not a refinement of it.
--
-- So the placement happens here, against the biome tdl_palette already chose
-- for the column out of climate this mod worked out. That is the same division
-- as the ground: the climate is ours, and every species, density and node name
-- is the game's.
--
-- This runs in the mapgen environment. core.registered_decorations reaches it
-- through core.get_globals_to_transfer(), and place_schematic_on_vmanip,
-- spawn_tree_on_vmanip and read_schematic are all in
-- ModApiMapgen::InitializeEmerge.

tdl_decorate = {}

local floor = math.floor
local max = math.max

local prepared = nil
local by_biome = nil
local anywhere = nil

local c_air = core.get_content_id("air")
local c_ignore = core.get_content_id("ignore")

local ROTATIONS = {"0", "90", "180", "270"}

-- walkable per content id, for the column scan that finds cave floors and
-- ceilings. Asked per node of a column, so it is a table rather than a lookup
-- through the node definitions each time.
local walkable = {}

local function build_node_tables()
        for name, def in pairs(core.registered_nodes) do
                local ok, id = pcall(core.get_content_id, name)
                if ok then
                        walkable[id] = def.walkable ~= false
                end
        end
        walkable[c_air] = false
        walkable[c_ignore] = false
end

-- place_on, spawn_by and decoration take node names, group names, or a bare
-- string instead of a list. Returns a set of content ids, or nil when nothing
-- named exists in this game, which is the signal to drop the decoration rather
-- than place it on everything.
local function id_set(names)
        if type(names) == "string" then names = {names} end
        if type(names) ~= "table" then return nil end
        local ids, found = {}, false
        for _, name in ipairs(names) do
                if type(name) ~= "string" then
                        -- a malformed entry is skipped, not fatal
                elseif name:sub(1, 6) == "group:" then
                        local group = name:sub(7)
                        for node_name, def in pairs(core.registered_nodes) do
                                local groups = def.groups
                                if groups and (groups[group] or 0) ~= 0 then
                                        local ok, id = pcall(core.get_content_id, node_name)
                                        if ok then
                                                ids[id] = true
                                                found = true
                                        end
                                end
                        end
                else
                        local ok, id = pcall(core.get_content_id, name)
                        if ok then
                                ids[id] = true
                                found = true
                        end
                end
        end
        if not found then return nil end
        return ids
end

-- Decoration flags are one comma separated string, and any may be negated with
-- a "no" prefix. Only the ones that decide where a decoration goes are read.
local function flag_set(flags)
        local set = {}
        if type(flags) == "string" then
                for token in flags:gmatch("[^,%s]+") do
                        if token:sub(1, 2) == "no" and #token > 2 then
                                set[token:sub(3)] = false
                        else
                                set[token] = true
                        end
                end
        end
        return set
end

-- The centring flags are handed back to place_schematic_on_vmanip unchanged,
-- so the engine does that arithmetic against the schematic's real size rather
-- than this file guessing at it.
local function centre_flags(set)
        local parts = {}
        for _, name in ipairs({"place_center_x", "place_center_y", "place_center_z"}) do
                if set[name] then parts[#parts + 1] = name end
        end
        return table.concat(parts, ",")
end

local function prepare(def, order)
        local place_on = id_set(def.place_on)
        if not place_on then
                return nil
        end

        local flags = flag_set(def.flags)
        local deco = {
                order = order,
                name = def.name or ("decoration " .. order),
                place_on = place_on,
                sidelen = max(1, floor(tonumber(def.sidelen) or 16)),
                fill_ratio = tonumber(def.fill_ratio) or 0,
                noise_params = def.noise_params,
                y_min = floor(tonumber(def.y_min) or -31000),
                y_max = floor(tonumber(def.y_max) or 31000),
                place_offset_y = floor(tonumber(def.place_offset_y) or 0),
                force = flags.force_placement or false,
                liquid_surface = flags.liquid_surface or false,
                all_floors = flags.all_floors or false,
                all_ceilings = flags.all_ceilings or false,
        }

        if def.spawn_by and def.num_spawn_by then
                local spawn_by = id_set(def.spawn_by)
                if spawn_by then
                        deco.spawn_by = spawn_by
                        deco.num_spawn_by = floor(tonumber(def.num_spawn_by) or 0)
                        deco.check_offset = floor(tonumber(def.check_offset) or 0)
                end
        end

        if type(def.biomes) == "table" and #def.biomes > 0 then
                deco.biomes = {}
                for _, name in ipairs(def.biomes) do
                        deco.biomes[name] = true
                end
        end

        local kind = def.deco_type or "simple"
        if kind == "simple" then
                local nodes = id_set(def.decoration)
                if not nodes then return nil end
                deco.kind = "simple"
                deco.nodes = {}
                for id in pairs(nodes) do deco.nodes[#deco.nodes + 1] = id end
                table.sort(deco.nodes)
                deco.height = max(1, floor(tonumber(def.height) or 1))
                deco.height_max = floor(tonumber(def.height_max) or 0)
                deco.param2 = floor(tonumber(def.param2) or 0)
                deco.param2_max = floor(tonumber(def.param2_max) or 0)
        elseif kind == "schematic" then
                if not def.schematic then return nil end
                deco.kind = "schematic"
                deco.tree = true
                deco.schematic = def.schematic
                deco.rotation = def.rotation or "0"
                deco.replacements = def.replacements
                deco.centre = centre_flags(flags)
                deco.centre_y = flags.place_center_y or false
        elseif kind == "lsystem" then
                if not def.treedef then return nil end
                deco.kind = "lsystem"
                deco.tree = true
                deco.treedef = def.treedef
        else
                return nil
        end

        return deco
end

-- Built on first use rather than at load: the emerge environment receives the
-- registration tables as they stood when every mod had finished loading, and
-- this file is run before that point on the main thread.
function tdl_decorate.load()
        if prepared then
                return #prepared > 0
        end
        prepared, by_biome, anywhere = {}, {}, {}
        build_node_tables()

        -- Registration order has to be the same in every Lua state, and a
        -- pairs() walk is not: core.registered_decorations is keyed by the
        -- decoration's name where it has one and by its numeric handle where
        -- it does not, so the walk is hash order and differs between the main
        -- environment and each emerge thread.
        --
        -- That order seeds the placement. Left as it was, two emerge threads
        -- generating neighbouring chunks would each seed the same decoration
        -- differently and grow different trees, and the far field could not
        -- predict either. Sorting the keys costs nothing and makes the order
        -- a property of the game rather than of a hash table.
        local keys = {}
        for k in pairs(core.registered_decorations or {}) do
                keys[#keys + 1] = k
        end
        table.sort(keys, function(a, b)
                local ta, tb = type(a), type(b)
                if ta ~= tb then return ta < tb end
                return a < b
        end)

        local order, dropped = 0, 0
        for _, key in ipairs(keys) do
                local def = core.registered_decorations[key]
                order = order + 1
                local deco = prepare(def, order)
                if deco then
                        prepared[#prepared + 1] = deco
                        if deco.biomes then
                                for name in pairs(deco.biomes) do
                                        local list = by_biome[name]
                                        if not list then
                                                list = {}
                                                by_biome[name] = list
                                        end
                                        list[#list + 1] = deco
                                end
                        else
                                anywhere[#anywhere + 1] = deco
                        end
                else
                        dropped = dropped + 1
                end
        end

        core.log("action", string.format("[terrain_diffusion] %d decorations ready, " ..
                "%d unusable, %d not keyed to any biome",
                #prepared, dropped, #anywhere))
        return #prepared > 0
end

function tdl_decorate.count()
        return prepared and #prepared or 0
end

-- A game that keys none of its decorations to a biome gains nothing from the
-- filtering below, and the engine can place them faster than Lua can.
function tdl_decorate.unkeyed_only()
        if not tdl_decorate.load() then
                -- Nothing to place either way; let the engine's pass decide.
                return true
        end
        return #anywhere == #prepared
end

local function noise_for(deco)
        if deco.noise == nil then
                deco.noise = deco.noise_params and ValueNoise(deco.noise_params) or false
        end
        return deco.noise
end

-- Height of a schematic, needed only to hang one from a ceiling. Read once and
-- kept; a decoration whose schematic cannot be read loses its ceiling
-- placements rather than being positioned by a guess.
local function schematic_size(deco)
        if deco.size_of == nil then
                local size = type(deco.schematic) == "table" and deco.schematic.size
                if not size and type(deco.schematic) == "string" then
                        local ok, read = pcall(core.read_schematic, deco.schematic, {})
                        if ok and type(read) == "table" then size = read.size end
                end
                deco.size_of = size and {
                        x = tonumber(size.x) or 1,
                        y = tonumber(size.y) or 1,
                        z = tonumber(size.z) or 1,
                } or false
        end
        return deco.size_of
end

local function schematic_height(deco)
        local size = schematic_size(deco)
        return size and size.y or false
end

-- Decoration::canPlaceDecoration, against the chunk as this mod generated it.
-- `y` is the node the decoration stands on, not the decoration itself.
local function can_place(deco, data, area, x, y, z, ctx)
        if ctx and ctx.top_at then
                -- Deriving rather than generating: the only thing known about
                -- the column is the node the palette would put on top of it,
                -- which is exactly what place_on is tested against anyway.
                -- spawn_by needs neighbours that do not exist yet and is
                -- skipped, so a derived tree may stand where a generated one
                -- would have been refused for want of company.
                return deco.place_on[ctx.top_at(x, z)] or false
        end
        local vi = area:index(x, y, z)
        if not deco.place_on[data[vi]] then
                return false
        end
        if not deco.spawn_by then
                return true
        end
        local found = 0
        for dz = -1, 1 do
                for dx = -1, 1 do
                        if dx ~= 0 or dz ~= 0 then
                                local at = area:index(x + dx, y + 1, z + dz)
                                if deco.spawn_by[data[at]] then
                                        found = found + 1
                                end
                                if deco.check_offset ~= 0 then
                                        local off = area:index(x + dx,
                                                y + 1 + deco.check_offset, z + dz)
                                        if deco.spawn_by[data[off]] then
                                                found = found + 1
                                        end
                                end
                        end
                end
        end
        return found >= deco.num_spawn_by
end

-- Every floor and ceiling in a column, for the all_floors and all_ceilings
-- decorations that line caves. Without it they would fall through to the
-- heightmap branch and put cave moss on a mountain top.
local function surfaces_in_column(data, area, x, z, ymin, ymax, floors, ceilings)
        local above = walkable[data[area:index(x, ymax, z)]]
        for y = ymax - 1, ymin, -1 do
                local here = walkable[data[area:index(x, y, z)]]
                if here and not above then
                        floors[#floors + 1] = y
                elseif not here and above then
                        ceilings[#ceilings + 1] = y + 1
                end
                above = here
        end
end

local function place_simple(deco, ps, ctx, x, y, z, ceiling)
        local data, area = ctx.data, ctx.area
        if not can_place(deco, data, area, x, y, z, ctx) then
                return
        end
        local content = deco.nodes[ps:next(1, #deco.nodes)]
        local height = deco.height
        if deco.height_max > 0 then
                height = ps:next(deco.height, deco.height_max)
        end
        local param2 = deco.param2
        if deco.param2_max > 0 then
                param2 = ps:next(deco.param2, deco.param2_max)
        end

        -- For a ceiling the offset is inverted and the column is walked down.
        local step = ceiling and -1 or 1
        local at = y + step * deco.place_offset_y
        for _ = 1, height do
                at = at + step
                if at < ctx.minp.y or at > ctx.maxp.y then
                        return
                end
                local vi = area:index(x, at, z)
                local was = data[vi]
                if was ~= c_air and was ~= c_ignore and not deco.force then
                        return
                end
                data[vi] = content
                if param2 ~= 0 then
                        local writes = ctx.param2
                        writes[#writes + 1] = vi
                        writes[#writes + 1] = param2
                end
        end
end

-- Schematics and L-system trees are written by the engine through the
-- VoxelManip, which cannot be done while the node buffer is still out on loan,
-- so their positions are collected here and run in flush() once it has gone
-- back. The ground test still reads the terrain as generated, which means a
-- tree does not see one placed beside it a moment earlier; the engine has the
-- same blind spot within a single decoration.
local function defer_structure(deco, ps, ctx, x, y, z, ceiling)
        if not can_place(deco, ctx.data, ctx.area, x, y, z, ctx) then
                return
        end
        local at = y
        if deco.kind == "schematic" then
                if ceiling then
                        local height = schematic_height(deco)
                        if not height then return end
                        at = y - (deco.place_offset_y + height - 1)
                elseif not deco.centre_y then
                        at = y + deco.place_offset_y
                end
        else
                at = y + deco.place_offset_y
        end

        local rotation = deco.rotation
        if rotation == "random" then
                rotation = ROTATIONS[ps:next(1, 4)]
        end

        local list = ctx.deferred
        list[#list + 1] = {deco = deco, x = x, y = at, z = z, rotation = rotation}
end

local function emit(deco, ps, ctx, x, y, z, ceiling)
        if ctx.sink then
                ctx.sink(deco, ps, x, y, z, ceiling)
        elseif deco.kind == "simple" then
                place_simple(deco, ps, ctx, x, y, z, ceiling)
        else
                defer_structure(deco, ps, ctx, x, y, z, ceiling)
        end
end

local function try_column(deco, ps, ctx, x, z)
        local index = (z - ctx.minp.z + ctx.margin) * ctx.wide_x
                + (x - ctx.minp.x + ctx.margin) + 1

        local tally = ctx.tally
        if tally then tally.drawn = tally.drawn + 1 end
        if deco.biomes then
                local entry = ctx.grounds[index]
                if not entry or not deco.biomes[entry.name] then
                        if tally then tally.biome = tally.biome + 1 end
                        return
                end
        end

        -- all_floors is not only a cave flag. Games put it on ordinary trees so
        -- they also grow on overhangs and floating islands, and the ground is
        -- simply one of the floors: 445 of Asuna's schematic decorations carry
        -- it, which is nearly all of them. Treating it as "cave decoration,
        -- skip when deriving" threw away every tree in the chunk.
        --
        -- So a derived run takes the one floor it knows, the terrain surface,
        -- and falls through to the heightmap path below. A decoration that
        -- wants ceilings only has none at the surface and is dropped.
        local derived_floor = ctx.top_at and (deco.all_floors or deco.all_ceilings)
        if derived_floor and not deco.all_floors then
                if tally then tally.caves = (tally.caves or 0) + 1 end
                return
        end

        if (deco.all_floors or deco.all_ceilings) and not derived_floor then
                local floors, ceilings = {}, {}
                surfaces_in_column(ctx.data, ctx.area, x, z,
                        ctx.minp.y, ctx.maxp.y, floors, ceilings)
                if deco.all_floors then
                        for _, y in ipairs(floors) do
                                if y >= deco.y_min and y <= deco.y_max then
                                        emit(deco, ps, ctx, x, y, z, false)
                                end
                        end
                end
                if deco.all_ceilings then
                        for _, y in ipairs(ceilings) do
                                if y >= deco.y_min and y <= deco.y_max then
                                        emit(deco, ps, ctx, x, y, z, true)
                                end
                        end
                end
                return
        end

        local y
        if deco.liquid_surface then
                y = ctx.water_levels[index]
                if not y then
                        if tally then tally.dry = (tally.dry or 0) + 1 end
                        return
                end
        else
                y = ctx.heights[index]
        end
        if y < deco.y_min or y > deco.y_max or y < ctx.minp.y or y > ctx.maxp.y then
                if tally then tally.range = tally.range + 1 end
                return
        end
        if ctx.sink and not can_place(deco, ctx.data, ctx.area, x, y, z, ctx) then
                -- The sink does not test the ground itself, so it is tested
                -- here. The generating path tests inside place_simple and
                -- defer_structure instead, where the node data is to hand.
                if tally then tally.ground = tally.ground + 1 end
                return
        end
        emit(deco, ps, ctx, x, y, z, false)
end

-- Decoration::placeDeco: the chunk is cut into sidelen squares and each gets a
-- count from the density, then that many positions at random inside it.
-- The seed for a chunk's decorations, computed from where the chunk is and the
-- world's own seed rather than taken from the blockseed the engine hands to
-- on_generated.
--
-- That is on purpose. The far field has to work out which trees stand in a
-- chunk it is not going to generate, so it needs the same stream the mapgen
-- will use when it eventually does. The engine's blockseed comes out of
-- Mapgen::getBlockSeed2, which is not reachable from Lua and would have to be
-- reimplemented exactly or every derived tree would land somewhere else. This
-- is reachable from both sides by construction.
local world_seed = tonumber(core.get_mapgen_setting("seed")) or 0

function tdl_decorate.chunk_seed(minp)
        local x = math.floor(minp.x / 16)
        local y = math.floor(minp.y / 16)
        local z = math.floor(minp.z / 16)
        local h = (world_seed % 16777216) + x * 23 + y * 42123 + z * 38134234
        h = h % 4294967296
        if h < 0 then h = h + 4294967296 end
        return h
end

local function place_one(deco, ctx, blockseed, carea)
        local sidelen = deco.sidelen
        if carea % sidelen ~= 0 then
                sidelen = carea
        end
        local cells = sidelen * sidelen
        local noise = noise_for(deco)

        -- The engine seeds every decoration in a chunk with blockseed + 53, so
        -- two of the same density draw the same positions until their streams
        -- happen to diverge. The order is mixed in here so they never start
        -- correlated, which is the difference between a mixed wood and every
        -- species of it stacked in one spot.
        local ps = PcgRandom(blockseed + 53 + deco.order * 7919)
        if ctx.trees_only and not deco.tree then
                return
        end

        for z0 = 0, carea - 1, sidelen do
                for x0 = 0, carea - 1, sidelen do
                        local xmin = ctx.minp.x + x0
                        local zmin = ctx.minp.z + z0
                        local xmax = xmin + sidelen - 1
                        local zmax = zmin + sidelen - 1

                        local nval = deco.fill_ratio
                        if noise then
                                nval = noise:get_2d({x = xmin + sidelen / 2,
                                        y = zmin + sidelen / 2})
                        end

                        local cover, count = false, 0
                        if nval >= 10 then
                                -- Complete coverage: walk the square instead of
                                -- drawing the same position twice.
                                cover = true
                                count = cells
                        else
                                local wanted = cells * nval
                                if wanted >= 1 then
                                        count = floor(wanted)
                                elseif wanted > 0 then
                                        if ps:next(1, 1000000) <= wanted * 1000000 then
                                                count = 1
                                        end
                                end
                        end

                        local x, z = xmin - 1, zmin
                        for _ = 1, count do
                                if cover then
                                        x = x + 1
                                        if x > xmax then
                                                z = z + 1
                                                x = xmin
                                        end
                                else
                                        x = ps:next(xmin, xmax)
                                        z = ps:next(zmin, zmax)
                                end
                                if z <= zmax then
                                        try_column(deco, ps, ctx, x, z)
                                end
                        end
                end
        end
end

-- Which decorations can appear in this chunk at all. Every game registers far
-- more than any one chunk can hold, and most of the cost is in the ones that
-- were never going to match, so the biomes actually present decide the list.
local function candidates_for(present)
        local seen, list = {}, {}
        for name in pairs(present) do
                local keyed = by_biome[name]
                if keyed then
                        for i = 1, #keyed do
                                local deco = keyed[i]
                                if not seen[deco] then
                                        seen[deco] = true
                                        list[#list + 1] = deco
                                end
                        end
                end
        end
        for i = 1, #anywhere do
                local deco = anywhere[i]
                if not seen[deco] then
                        seen[deco] = true
                        list[#list + 1] = deco
                end
        end
        -- Registration order, so a chunk does not depend on the order a hash
        -- table happened to be walked in.
        table.sort(list, function(a, b) return a.order < b.order end)
        return list
end

-- columns carries what the mapgen already worked out for this chunk: the
-- surface height, the water level and the chosen biome per column, indexed
-- over the chunk widened by `margin` on each side.
--
-- Returns the deferred structure list, to be passed to flush() once the node
-- buffer has gone back to the VoxelManip.
function tdl_decorate.place(data, area, minp, maxp, blockseed, columns)
        if not tdl_decorate.load() then
                return nil
        end

        local ctx = {
                data = data,
                area = area,
                minp = minp,
                maxp = maxp,
                margin = columns.margin,
                wide_x = columns.wide_x,
                heights = columns.heights,
                water_levels = columns.water_levels,
                grounds = columns.grounds,
                deferred = {},
                param2 = {},
        }

        local carea = maxp.x - minp.x + 1
        if maxp.z - minp.z + 1 ~= carea then
                -- placeDeco needs a square chunk in x and z, and so does this.
                return nil
        end

        local list = candidates_for(columns.present)
        for i = 1, #list do
                local deco = list[i]
                if maxp.y >= deco.y_min and deco.y_max >= minp.y then
                        place_one(deco, ctx, tdl_decorate.chunk_seed(minp), carea)
                end
        end

        return ctx
end

-- Which trees this mod will put in a box, worked out without generating it.
--
-- This is the far field's whole reason for existing: a horizon nobody has
-- visited has no blocks to read, and the impostors need to know where the
-- trees are anyway. It runs the same selection the mapgen runs, over the same
-- seed, so a tree derived here is the tree that will be there when the chunk
-- is eventually generated.
--
-- `columns` is the same shape tdl_decorate.place takes, plus `top_at(x, z)`
-- giving the content id the palette would lay on that column. Returns a list
-- of {x, y, z, trunk, leaves, height, radius}.
function tdl_decorate.trees_in(minp, maxp, columns)
        if not tdl_decorate.load() then
                return {}
        end
        local carea = maxp.x - minp.x + 1
        if maxp.z - minp.z + 1 ~= carea then
                return {}
        end

        local out = {}
        local ctx = {
                minp = minp,
                maxp = maxp,
                margin = columns.margin,
                wide_x = columns.wide_x,
                heights = columns.heights,
                water_levels = columns.water_levels,
                grounds = columns.grounds,
                top_at = columns.top_at,
                trees_only = true,
                tally = {drawn = 0, biome = 0, range = 0, ground = 0, cands = 0},
                sink = function(deco, ps, x, y, z, ceiling)
                        if ceiling then return end
                        local size = deco.kind == "schematic" and schematic_size(deco)
                        -- An L-system tree has no schematic to measure, and a
                        -- schematic that would not read gets the same default:
                        -- something tree shaped rather than nothing, because
                        -- the position is the part that has to be right.
                        local height = size and size.y or 8
                        local width = size and math.max(size.x, size.z) or 5
                        out[#out + 1] = {
                                x = x,
                                y = y + (deco.place_offset_y or 0),
                                z = z,
                                trunk = deco.trunk_name or "",
                                leaves = deco.leaves_name or "",
                                height = height,
                                radius = width / 2,
                        }
                end,
        }

        local list = candidates_for(columns.present)
        local trees = 0
        for i = 1, #list do
                if list[i].tree then trees = trees + 1 end
        end
        ctx.tally.cands = trees
        for i = 1, #list do
                local deco = list[i]
                if maxp.y >= deco.y_min and deco.y_max >= minp.y then
                        place_one(deco, ctx, tdl_decorate.chunk_seed(minp), carea)
                end
        end
        tdl_decorate.last_tally = ctx.tally
        return out
end

-- Everything that had to wait for the node buffer to go back.
function tdl_decorate.flush(vmanip, ctx)
        if not ctx then
                return
        end

        local writes = ctx.param2
        if #writes > 0 then
                local param2 = vmanip:get_param2_data()
                for i = 1, #writes, 2 do
                        param2[writes[i]] = writes[i + 1]
                end
                vmanip:set_param2_data(param2)
        end

        local deferred = ctx.deferred
        for i = 1, #deferred do
                local item = deferred[i]
                local deco = item.deco
                local pos = {x = item.x, y = item.y, z = item.z}
                if deco.kind == "schematic" then
                        pcall(core.place_schematic_on_vmanip, vmanip, pos, deco.schematic,
                                item.rotation, deco.replacements, deco.force, deco.centre)
                else
                        pcall(core.spawn_tree_on_vmanip, vmanip, pos, deco.treedef)
                end
        end
end
