-- SPDX-License-Identifier: LGPL-2.1-or-later
-- PBR census: a throwaway worldmod that measures which nodes a player can
-- actually see, so the texture pack is authored in the order it is looked
-- at. It needs no client and no player. It emerges a seeded sample of
-- mapchunks (overworld columns, the Nether, the End), counts every node face
-- that borders something see through, builds a handful of villages with
-- Mineclonia's own village code and counts what they added, dumps each
-- node's tiles, groups and recipe evidence, writes <world>/pbr_census.json
-- and shuts the server down.
--
-- Never install it on a world anyone plays: it generates a great deal of map
-- and it builds villages into it. tools/pbr_census/README.md says how to run
-- it and tools/pbr_census/rank.py turns the JSON into a ranking.
--
-- Settings, read from the server's --config file:
--   pbr_census_seed      sample seed (default 20260925)
--   pbr_census_regions   overworld mapchunk columns (default 300)
--   pbr_census_span      half width in nodes of the overworld sample (6000)
--   pbr_census_nether    Nether mapchunk columns (default 40)
--   pbr_census_end       End mapchunk columns (default 8)
--   pbr_census_villages  villages to build and count (default 12)
--   pbr_census_keep      true to leave the server running afterwards

local settings = core.settings
local function num(key, default)
	return tonumber(settings:get(key)) or default
end

local SEED = num("pbr_census_seed", 20260925)
local N_OVER = num("pbr_census_regions", 300)
local SPAN = num("pbr_census_span", 6000)
local N_NETHER = num("pbr_census_nether", 40)
local N_END = num("pbr_census_end", 8)
local N_VILLAGES = num("pbr_census_villages", 12)
local KEEP = settings:get_bool("pbr_census_keep", false)
local CONCURRENT = 2

local worldpath = core.get_worldpath()
local T0 = core.get_us_time()
local function ms() return math.floor((core.get_us_time() - T0) / 1000) end
local function log(msg) core.log("action", "[pbr_census] " .. msg) end

-- Contexts a face is counted in. Overworld faces are split by what the see
-- through node in front of them is: a liquid, a place the sun reaches (day
-- light 10 or more), or a place it does not (caves, tunnels, the underside
-- of overhangs). The other dimensions and the villages are their own.
local CTX = {"surface", "cave", "liquid", "nether", "end", "village"}
local SURFACE, CAVE, LIQUID, NETHER, END, VILLAGE = 1, 2, 3, 4, 5, 6
-- Buckets per node: top face, bottom face, side faces, faces of a node
-- turned off its upright axis (facedir with an axis other than +Y, and all
-- wallmounted nodes, which rank.py spreads over every tile), and nodes drawn
-- as billboards (plantlike, torchlike and the like), counted once each.
local TOP, BOTTOM, SIDE, ROT, BILL = 0, 1, 2, 3, 4

-- Node categories, by drawtype.
local IGN, AIR, CUBE, SEE, LIQ, BB = 0, 1, 2, 3, 4, 5
local CAT, ROTK = {}, {}
local counts = {}
for i = 1, #CTX do counts[i] = {} end

local drawcat = {
	normal = CUBE,
	airlike = AIR,
	liquid = LIQ, flowingliquid = LIQ,
	plantlike = BB, firelike = BB, torchlike = BB, signlike = BB, raillike = BB,
	-- see through but face shaped: counted per face like a cube
	allfaces = SEE, allfaces_optional = SEE, glasslike = SEE,
	glasslike_framed = SEE, glasslike_framed_optional = SEE,
	nodebox = SEE, mesh = SEE, plantlike_rooted = SEE,
}

local function classify()
	for name, def in pairs(core.registered_nodes) do
		local id = core.get_content_id(name)
		CAT[id] = drawcat[def.drawtype or "normal"] or SEE
		local p2 = def.paramtype2 or "none"
		if p2 == "facedir" or p2 == "colorfacedir" then
			ROTK[id] = 1
		elseif p2 == "wallmounted" or p2 == "colorwallmounted" then
			ROTK[id] = 2
		else
			ROTK[id] = 0
		end
	end
	CAT[core.CONTENT_AIR] = AIR
	CAT[core.CONTENT_IGNORE] = IGN
end

local data, light, param2 = {}, {}, {}
local before = nil

local function bump(ctx, id, bucket)
	local t = counts[ctx]
	local k = id * 8 + bucket
	t[k] = (t[k] or 0) + 1
end

-- Copy of a box's content ids, taken before a village is built, so the
-- count after it can skip every node the village did not change.
local function snapshot_box(pmin, pmax)
	local vm = VoxelManip()
	vm:read_from_map(pmin, pmax)
	local snap = {}
	vm:get_data(snap)
	return snap
end

-- Count one box. dim is NETHER or END for those dimensions, nil for the
-- overworld (context from the see through node), VILLAGE with `before` set
-- to count only what changed since the snapshot.
local function count_box(pmin, pmax, dim)
	local vm = VoxelManip()
	local emin, emax = vm:read_from_map(pmin, pmax)
	local area = VoxelArea(emin, emax)
	vm:get_data(data)
	vm:get_light_data(light)
	vm:get_param2_data(param2)
	local ys, zs = area.ystride, area.zstride
	local x0, x1, y0, y1, z0, z1 = pmin.x, pmax.x, pmin.y, pmax.y, pmin.z, pmax.z
	local diff = dim == VILLAGE and before or nil
	local faces, seen_bb = 0, 0

	local function face(ctx, c, j, bucket)
		local n = data[j]
		local nk = CAT[n]
		if nk == CUBE or ((nk == SEE or nk == LIQ) and n ~= c) then
			if diff and diff[j] == n then return end
			local r = ROTK[n]
			if r == 2 or (r == 1 and param2[j] % 32 >= 4) then
				bucket = ROT
			end
			bump(ctx, n, bucket)
			faces = faces + 1
		end
	end

	for z = z0, z1 do
		for y = y0, y1 do
			local i = area:index(x0, y, z)
			for x = x0, x1 do
				local c = data[i]
				local k = CAT[c]
				if k ~= CUBE and k ~= IGN then
					local ctx = dim
					if not ctx then
						if k == LIQ then
							ctx = LIQUID
						elseif light[i] % 16 >= 10 then
							ctx = SURFACE
						else
							ctx = CAVE
						end
					end
					if k == BB and not (diff and diff[i] == c) then
						bump(ctx, c, BILL)
						seen_bb = seen_bb + 1
					end
					if y > y0 then face(ctx, c, i - ys, TOP) end
					if y < y1 then face(ctx, c, i + ys, BOTTOM) end
					if x > x0 then face(ctx, c, i - 1, SIDE) end
					if x < x1 then face(ctx, c, i + 1, SIDE) end
					if z > z0 then face(ctx, c, i - zs, SIDE) end
					if z < z1 then face(ctx, c, i + zs, SIDE) end
				end
				i = i + 1
			end
		end
	end

	-- The ground at the middle of the box, for the region log.
	local cx, cz = math.floor((x0 + x1) / 2), math.floor((z0 + z1) / 2)
	local top_y
	for y = y1, y0, -1 do
		local k = CAT[data[area:index(cx, y, cz)]]
		if k == CUBE or k == LIQ then top_y = y break end
	end
	return faces, seen_bb, top_y
end

-- Sample layout -----------------------------------------------------------

local chunksize = tonumber(core.get_mapgen_setting("chunksize")) or 5
local CH = chunksize * 16
local OFF = -32 -- mapchunk origin offset: chunks start at -32 + k * CH
local function chunk_base(v) return OFF + math.floor((v - OFF) / CH) * CH end

local over_min = mcl_vars and mcl_vars.mg_overworld_min or -128
local nether_min = mcl_vars and mcl_vars.mg_nether_min or -29067
-- Stop at the underside of the Nether's bedrock roof: the rough top of the
-- roof borders the void above it, which no player stands in.
local nether_max = mcl_vars and mcl_vars.mg_bedrock_nether_top_min or (nether_min + 124)
local end_min = mcl_vars and mcl_vars.mg_end_min or -27073
local OVER_TOP = 191

local jobs = {}
local pr = PcgRandom(SEED)
local used = {}
local function pick_column(span)
	local n = math.floor(span / CH)
	for _ = 1, 100 do
		local i, j = pr:next(-n, n), pr:next(-n, n)
		local key = i .. "," .. j
		if not used[key] then
			used[key] = true
			return OFF + i * CH, OFF + j * CH
		end
	end
end

for _ = 1, N_OVER do
	local x, z = pick_column(SPAN)
	if x then
		jobs[#jobs + 1] = {kind = "overworld",
			pmin = {x = x, y = over_min, z = z},
			pmax = {x = x + CH - 1, y = OVER_TOP, z = z + CH - 1}}
	end
end
used = {}
for _ = 1, N_NETHER do
	-- the Nether is an eighth of the overworld's scale; players travel less
	local x, z = pick_column(math.max(SPAN / 8, 4 * CH))
	if x then
		jobs[#jobs + 1] = {kind = "nether", dim = NETHER,
			pmin = {x = x, y = nether_min, z = z},
			pmax = {x = x + CH - 1, y = nether_max, z = z + CH - 1}}
	end
end
used = {}
for n = 1, N_END do
	-- the main island first, then whatever the sampler lands on
	local x, z
	if n <= 4 then
		x, z = OFF + ((n - 1) % 2 - 1) * CH, OFF + (math.floor((n - 1) / 2) - 1) * CH
		x, z = chunk_base(x + 32), chunk_base(z + 32)
		used[x .. "," .. z] = true
	else
		x, z = pick_column(1500)
	end
	if x then
		jobs[#jobs + 1] = {kind = "end", dim = END,
			pmin = {x = x, y = end_min, z = z},
			pmax = {x = x + CH - 1, y = end_min + 239, z = z + CH - 1}}
	end
end
-- Village sites: a mapchunk with its eight neighbours emerged, surface band
-- only, so buildings near the chunk edge land on generated ground.
local village_sites = {}
used = {}
for _ = 1, N_VILLAGES * 8 do
	local x, z = pick_column(math.min(SPAN, 3000))
	if x then
		village_sites[#village_sites + 1] = {kind = "village_site",
			centre = {x = x, z = z},
			pmin = {x = x - CH, y = -32, z = z - CH},
			pmax = {x = x + 2 * CH - 1, y = 127, z = z + 2 * CH - 1}}
	end
end

-- Output ------------------------------------------------------------------

local regions = {}
local villages_built = 0
local village_log = {}

local function item_dump()
	local out = {}
	local item_uses, group_uses = {}, {}
	for iname in pairs(core.registered_items) do
		for _, r in ipairs(core.get_all_craft_recipes(iname) or {}) do
			local once = {}
			for _, it in pairs(r.items or {}) do
				local s = type(it) == "string" and it:match("^(%S+)") or nil
				if s and s ~= "" and not once[s] then
					once[s] = true
					if s:sub(1, 6) == "group:" then
						for g in s:sub(7):gmatch("[^,]+") do
							group_uses[g] = (group_uses[g] or 0) + 1
						end
					else
						item_uses[s] = (item_uses[s] or 0) + 1
					end
				end
			end
		end
	end
	local function tname(t)
		if type(t) == "string" then return t end
		if type(t) == "table" then return t.name or t.image end
	end
	local function tlist(ts)
		if not ts then return nil end
		local r = {}
		for i, t in ipairs(ts) do r[i] = tname(t) or "" end
		return r
	end
	-- Every item, not only nodes: a door or a bed is crafted as an item that
	-- places nodes of another name, and rank.py links the two by name.
	for name, def in pairs(core.registered_items) do
		if name ~= "" then
			local methods = {}
			for _, r in ipairs(core.get_all_craft_recipes(name) or {}) do
				local m = r.method or r.type or "normal"
				methods[m] = (methods[m] or 0) + 1
			end
			local cutter = def._mcl_stonecutter_recipes and #def._mcl_stonecutter_recipes or 0
			if cutter > 0 then methods.stonecutter = cutter end
			local e = {
				type = def.type,
				groups = def.groups or {},
				recipes = methods,
				used_in = item_uses[name] or 0,
				drop = type(def.drop) == "string" and def.drop or nil,
			}
			if def.type == "node" then
				e.drawtype = def.drawtype or "normal"
				e.paramtype2 = def.paramtype2 or "none"
				e.tiles = tlist(def.tiles)
				e.overlay_tiles = tlist(def.overlay_tiles)
				e.special_tiles = tlist(def.special_tiles)
				e.light_source = def.light_source or 0
			end
			out[name] = e
		end
	end
	return out, group_uses
end

local finished = false
local function finish()
	if finished then return end
	finished = true
	local c_out = {}
	for ci, cname in ipairs(CTX) do
		local t = {}
		for k, v in pairs(counts[ci]) do
			local id, bucket = math.floor(k / 8), k % 8
			local name = core.get_name_from_content_id(id)
			t[name] = t[name] or {0, 0, 0, 0, 0}
			t[name][bucket + 1] = v
		end
		c_out[cname] = t
	end
	local items, group_uses = item_dump()
	local out = {
		schema = "goanna-pbr-census/1",
		game = core.get_game_info and core.get_game_info().id or "?",
		engine = core.get_version().string,
		mg_name = core.get_mapgen_setting("mg_name"),
		map_seed = core.get_mapgen_setting("seed"),
		sample_seed = SEED,
		chunk_nodes = CH,
		buckets = {"top", "bottom", "side", "rotated", "billboard"},
		elapsed_ms = ms(),
		regions = regions,
		villages = village_log,
		counts = c_out,
		items = items,
		group_uses = group_uses,
	}
	local path = worldpath .. "/pbr_census.json"
	local ok = core.safe_file_write(path, core.write_json(out))
	log("wrote " .. path .. (ok and "" or " (write FAILED)") .. " after " .. ms() .. " ms")
	if not KEEP then
		core.request_shutdown("pbr_census done", false, 1)
	end
end

-- Villages ----------------------------------------------------------------

local function try_village(site)
	if villages_built >= N_VILLAGES or not mcl_villages
			or not mcl_villages.create_site_plan_new then
		return
	end
	-- find the ground at the centre chunk's middle
	local cx, cz = site.centre.x + CH / 2, site.centre.z + CH / 2
	local ground
	for y = 127, -32, -1 do
		local nd = core.get_node({x = cx, y = y, z = cz}).name
		local def = core.registered_nodes[nd]
		if def and def.walkable and (def.drawtype or "normal") == "normal" then
			ground = y break
		elseif def and (def.drawtype == "liquid") then
			break
		end
	end
	if not ground then
		village_log[#village_log + 1] = {centre = site.centre, result = "no dry ground"}
		return
	end
	local by = chunk_base(ground)
	local minp = {x = site.centre.x, y = by, z = site.centre.z}
	local maxp = {x = site.centre.x + CH - 1, y = by + CH - 1, z = site.centre.z + CH - 1}
	local box_min = {x = site.pmin.x, y = math.max(-32, by - 16), z = site.pmin.z}
	local box_max = {x = site.pmax.x, y = math.min(127, by + CH + 15), z = site.pmax.z}
	before = snapshot_box(box_min, box_max)
	local blockseed = pr:next(0, 2147483647)
	local vpr = PcgRandom(blockseed)
	local ok, err = pcall(function()
		local info, grid = mcl_villages.create_site_plan_new(minp, maxp, vpr)
		if not info then error("no site plan") end
		site.buildings = #info
		mcl_villages.terraform_new(info, grid)
		mcl_villages.place_schematics_new(info, vpr, blockseed)
	end)
	-- a failure after placement (a plan with no bell tower errors at the
	-- very end) still leaves the buildings standing, so count those too
	if ok or site.buildings then
		local f, b = count_box(box_min, box_max, VILLAGE)
		villages_built = villages_built + 1
		village_log[#village_log + 1] = {centre = site.centre, ground = ground,
			buildings = site.buildings, faces = f, billboards = b,
			error = (not ok) and tostring(err) or nil,
			biome = core.get_biome_name(core.get_biome_data({x = cx, y = ground, z = cz}).biome)}
		log(("village %d at %d,%d: %d buildings, %d faces"):format(villages_built,
			cx, cz, site.buildings or 0, f))
	else
		village_log[#village_log + 1] = {centre = site.centre, ground = ground, result = tostring(err)}
	end
	before = nil
end

-- Queue -------------------------------------------------------------------

local queue, qi, inflight = {}, 0, 0
local start_next

local function process(job)
	if job.kind == "village_site" then
		local ok, err = pcall(try_village, job)
		if not ok then log("village error: " .. tostring(err)) end
		return
	end
	local t = core.get_us_time()
	local f, b, top_y = count_box(job.pmin, job.pmax, job.dim)
	local biome
	if top_y then
		local cx, cz = job.pmin.x + CH / 2, job.pmin.z + CH / 2
		local bd = core.get_biome_data({x = cx, y = top_y, z = cz})
		biome = bd and core.get_biome_name(bd.biome) or nil
	end
	regions[#regions + 1] = {kind = job.kind, minp = job.pmin, maxp = job.pmax,
		faces = f, billboards = b, ground_y = top_y, biome = biome,
		count_ms = math.floor((core.get_us_time() - t) / 1000)}
end

start_next = function()
	while inflight < CONCURRENT and qi < #queue do
		qi = qi + 1
		local job = queue[qi]
		-- enough villages: skip the remaining sites without emerging them
		while job.kind == "village_site" and villages_built >= N_VILLAGES and qi < #queue do
			qi = qi + 1
			job = queue[qi]
		end
		if job.kind == "village_site" and villages_built >= N_VILLAGES then
			if inflight == 0 then finish() end
			return
		end
		inflight = inflight + 1
		core.emerge_area(job.pmin, job.pmax, function(_, action, remaining)
			if remaining > 0 then return end
			-- let mapgen callbacks queued by the last block settle first
			core.after(0.5, function()
				local ok, err = pcall(process, job)
				if not ok then log("error in " .. job.kind .. ": " .. tostring(err)) end
				inflight = inflight - 1
				if qi % 10 == 0 then
					log(("%d/%d done, %d ms"):format(qi, #queue, ms()))
				end
				if qi >= #queue and inflight == 0 then
					finish()
				else
					start_next()
				end
			end)
		end)
	end
end

core.register_on_mods_loaded(function()
	classify()
	for _, j in ipairs(jobs) do queue[#queue + 1] = j end
	for _, j in ipairs(village_sites) do queue[#queue + 1] = j end
	log(("queued %d regions and %d village sites"):format(#jobs, #village_sites))
	core.after(2, start_next)
end)
