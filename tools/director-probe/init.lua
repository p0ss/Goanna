-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Director probe: a throwaway worldmod that checks, on a real server, the
-- engine and framework calls docs/director.md builds on. It needs no client
-- and no player. It emerges a few columns near the origin, forceloads a small
-- area, spawns and steers a couple of mobs, and writes what the engine
-- actually answered to <world>/director_probe.json, then shuts the server
-- down. Never install it on a world anyone plays: it spawns and kills mobs.
--
-- Settings (in the --config file, not goanna_* because those are broadcast):
--   director_probe_url   base URL of a local HTTP sink, for the HTTP transport
--                        check (needs secure.http_mods = director_probe)
--   director_probe_keep  true to leave the server running afterwards

local modname = core.get_current_modname()
local worldpath = core.get_worldpath()
local http = core.request_http_api and core.request_http_api()
local storage = core.get_mod_storage()
local entity_phase
local R = {probes = {}, errors = {}, events = {}}
local T0 = core.get_us_time()

local function note(k, v) R.probes[k] = v end
local function err(where, e)
	R.errors[#R.errors + 1] = where .. ": " .. tostring(e)
	core.log("error", "[director_probe] " .. where .. ": " .. tostring(e))
end
local function count(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end
local function us() return core.get_us_time() end
local function vstr(p) return p and string.format("%.1f,%.1f,%.1f", p.x, p.y, p.z) or "nil" end
local function try(where, fn, ...)
	local ok, e = pcall(fn, ...)
	if not ok then err(where, e) end
	return ok
end

-- Death and removal events, for every Lua entity, without a framework: the
-- engine calls on_deactivate(self, removal) with removal = true when an
-- object is removed for good. Wrapped once every mod has registered.
core.register_on_mods_loaded(function()
	local wrapped = 0
	for name, def in pairs(core.registered_entities) do
		local old = def.on_deactivate
		def.on_deactivate = function(self, removal)
			if #R.events < 200 and (removal or self._director_probe_watched) then
				local o = self.object
				R.events[#R.events + 1] = {
					kind = removal and "entity_removed" or "entity_deactivated", name = name,
					guid = o and o.get_guid and o:get_guid() or nil,
					hp = o and o:get_hp() or nil,
					mob_health = self.health,
					t_ms = math.floor((us() - T0) / 1000),
				}
			end
			if old then return old(self, removal) end
		end
		wrapped = wrapped + 1
	end
	note("entity_hooks_wrapped", wrapped)
end)

-- 1. Registries: what a director can list without any framework.
local function probe_registries()
	local r = {
		items = count(core.registered_items), nodes = count(core.registered_nodes),
		craftitems = count(core.registered_craftitems), tools = count(core.registered_tools),
		entities = count(core.registered_entities), biomes = count(core.registered_biomes),
		decorations = count(core.registered_decorations), ores = count(core.registered_ores),
		abms = #core.registered_abms, lbms = #core.registered_lbms,
		privileges = count(core.registered_privileges), aliases = count(core.registered_aliases),
	}
	-- The whole item catalogue as a model would receive it, to measure size.
	local list, creative = {}, 0
	for name, def in pairs(core.registered_items) do
		if name ~= "" then
			local groups = def.groups or {}
			if (groups.not_in_creative_inventory or 0) == 0 then creative = creative + 1 end
			local desc = def.description or ""
			if core.get_translated_string then desc = core.get_translated_string("en", desc) end
			desc = core.strip_colors(desc):gsub("\n.*", "")
			list[#list + 1] = {n = name, d = desc, t = def.type, g = groups}
		end
	end
	local t = us()
	local json = core.write_json(list)
	r.item_json_bytes = #json
	r.item_json_us = us() - t
	r.items_in_creative = creative
	local sample = {}
	for _, want in ipairs({"mcl_core:diamond", "mcl_tools:sword_iron", "default:diamond",
			"default:sword_steel", "mcl_farming:bread", "farming:bread"}) do
		local def = core.registered_items[want]
		if def then
			sample[want] = {type = def.type, groups = def.groups,
				tool_capabilities = def.tool_capabilities and true or false}
		end
	end
	r.sample = sample
	return r
end

-- 2 and 3. Biome at a position, and the decorations registered for it.
local deco_by_biome, deco_anywhere
local function index_decorations()
	deco_by_biome, deco_anywhere = {}, {}
	local function what(d)
		if d.deco_type == "simple" then
			local dn = d.decoration
			if type(dn) == "table" then return table.concat(dn, "|") end
			return tostring(dn)
		end
		return "schematic:" .. tostring(d.name or (type(d.schematic) == "string"
				and d.schematic:match("[^/]+$") or "table"))
	end
	for key, d in pairs(core.registered_decorations) do
		local entry = {name = d.name or tostring(key), what = what(d), type = d.deco_type}
		local biomes = d.biomes
		if biomes == nil or (type(biomes) == "table" and #biomes == 0) then
			deco_anywhere[#deco_anywhere + 1] = entry
		else
			if type(biomes) ~= "table" then biomes = {biomes} end
			for _, b in ipairs(biomes) do
				local bn = type(b) == "number" and core.get_biome_name(b) or tostring(b)
				deco_by_biome[bn] = deco_by_biome[bn] or {}
				table.insert(deco_by_biome[bn], entry)
			end
		end
	end
end

local function surface_at(x, z, ytop, ybot)
	for y = ytop, ybot, -1 do
		local n = core.get_node_or_nil({x = x, y = y, z = z})
		if n and n.name ~= "air" and n.name ~= "ignore" then
			local def = core.registered_nodes[n.name]
			if def and (def.walkable or (def.liquidtype or "none") ~= "none") then
				local above = core.get_node_or_nil({x = x, y = y + 1, z = z})
				return y, n.name, above and above.name
			end
		end
	end
end

local function biome_name_at(pos)
	local d = core.get_biome_data(pos)
	return d and core.get_biome_name(d.biome), d
end

-- Under a liquid surface, the ground the mapgen chose the biome from.
local function floor_under(x, y, z, ybot)
	for yy = y - 1, ybot, -1 do
		local n = core.get_node_or_nil({x = x, y = yy, z = z})
		local def = n and core.registered_nodes[n.name]
		if def and def.walkable then return yy, n.name end
	end
end

-- Every node standing on the ground in a 17 by 17 patch, and whether the
-- decorations registered for the column's biome account for it.
local function patch_plants(c, biome, ytop, ybot)
	local found = {}
	for x = c.x - 8, c.x + 8 do
		for z = c.z - 8, c.z + 8 do
			local _, _, above = surface_at(x, z, ytop, ybot)
			if above and above ~= "air" and above ~= "ignore" then
				found[above] = (found[above] or 0) + 1
			end
		end
	end
	local listed, unlisted = {}, {}
	for name, n in pairs(found) do
		local hit
		for _, list in ipairs({deco_by_biome[biome] or {}, deco_anywhere or {}}) do
			for _, d in ipairs(list) do
				for part in d.what:gmatch("[^|]+") do
					if part == name then hit = d.name end
				end
			end
		end
		if hit then listed[name] = n else unlisted[name] = n end
	end
	return listed, unlisted
end

-- 4 and 6. Entities in an area, and steering one.
local function describe_obj(o)
	local e = o:get_luaentity()
	local d = {guid = o:get_guid(), pos = vstr(o:get_pos()), hp = o:get_hp(),
		player = o:is_player() or nil}
	if e then
		d.name = e.name
		d.is_mob = e.is_mob
		d.mob_type = e.type
		d.health = e.health
		d.state = e.state
		d.persistent = e.persistent
		if e._active_target then
			d.active_target = e._active_target:is_valid() and e._active_target:get_guid() or "invalid"
		end
		if e.attack and type(e.attack) == "userdata" then
			d.attack = e.attack:is_valid() and e.attack:get_guid() or "invalid"
		end
	end
	return d
end

local function objects_near(center, radius)
	local out = {}
	for o in core.objects_inside_radius(center, radius) do
		out[#out + 1] = describe_obj(o)
	end
	return out
end

local function finish()
	R.total_ms = math.floor((us() - T0) / 1000)
	local path = worldpath .. "/director_probe.json"
	local f = io.open(path, "w")
	if f then
		f:write(core.write_json(R, true))
		f:close()
	end
	core.log("action", "[director_probe] wrote " .. path .. " with " .. #R.errors .. " errors")
	if not core.settings:get_bool("director_probe_keep", false) then
		core.request_shutdown("director probe done", false, 1)
	end
end

-- The HTTP transport check: POST one event, GET one action.
local function probe_http(done)
	local url = core.settings:get("director_probe_url")
	local h = {available = http ~= nil, url = url}
	if not http or not url then
		note("http", h)
		return done()
	end
	local body = core.write_json({v = 1, kind = "event", seq = 1, type = "probe_hello",
		game = core.get_game_info and core.get_game_info().id})
	local t = us()
	http.fetch({url = url .. "/events", method = "POST", data = body, timeout = 5,
			extra_headers = {"Content-Type: application/json"}}, function(res)
		h.post = {succeeded = res.succeeded, code = res.code, ms = math.floor((us() - t) / 1000)}
		local t2 = us()
		http.fetch({url = url .. "/actions?after=0", timeout = 5}, function(res2)
			h.get = {succeeded = res2.succeeded, code = res2.code,
				ms = math.floor((us() - t2) / 1000), body = res2.data}
			local parsed = res2.data and core.parse_json(res2.data)
			h.get_parsed = parsed ~= nil
			note("http", h)
			done()
		end)
	end)
end

-- Off-thread cost: what handing a large table to the async environment costs
-- the server thread, against encoding it on the server thread directly.
local function probe_async(done)
	local big = {}
	for i = 1, 20000 do
		big[i] = {name = "item" .. i, groups = {a = i, b = 2}, pos = {x = i, y = -i, z = i * 2}}
	end
	local a = {}
	local t = us()
	local json = core.write_json(big)
	a.write_json_main_us = us() - t
	a.json_bytes = #json
	t = us()
	storage:set_string("big", json)
	a.mod_storage_set_us = us() - t
	storage:set_string("big", "")
	t = us()
	a.ipc_available = core.ipc_set ~= nil
	if core.ipc_set then
		core.ipc_set("director_probe:big", big)
		a.ipc_set_us = us() - t
	end
	local started = us()
	local ok, e = pcall(core.handle_async, function(tbl)
		local t1 = core.get_us_time()
		local s = core.write_json(tbl)
		return #s, core.get_us_time() - t1, core.ipc_get ~= nil
	end, function(n, inner_us, has_ipc)
		a.async_bytes = n
		a.async_inner_us = inner_us
		a.async_roundtrip_us = us() - started
		a.async_has_ipc = has_ipc
		note("async", a)
		done()
	end, big)
	a.handle_async_dispatch_us = us() - started
	if not ok then
		a.error = tostring(e)
		note("async", a)
		done()
	end
end

-- mcl_mobs: spawn definitions as the framework holds them after load.
local function probe_mcl_spawners(biomes_seen)
	if not (rawget(_G, "mcl_mobs") and mcl_mobs.registered_spawners) then return nil end
	local s = {registered_mobs = count(mcl_mobs.registered_mobs),
		categories = {}, biomes_with_spawners = count(mcl_mobs.registered_spawners),
		per_seen_biome = {}}
	for cat, data in pairs(mcl_mobs.spawn_categories or {}) do
		s.categories[cat] = {chunk_mob_cap = data.chunk_mob_cap, is_animal = data.is_animal}
	end
	for bn in pairs(biomes_seen) do
		local by_cat = mcl_mobs.registered_spawners[bn]
		if by_cat then
			local t = {}
			for cat, list in pairs(by_cat) do
				local names = {}
				for _, sp in ipairs(list) do
					names[#names + 1] = sp.name .. "(w" .. tostring(sp.weight) .. ",p" ..
							tostring(sp.pack_min) .. "-" .. tostring(sp.pack_max) .. ")"
				end
				t[cat] = names
			end
			s.per_seen_biome[bn] = t
		else
			s.per_seen_biome[bn] = "none"
		end
	end
	if mcl_mobs.describe_spawning then
		s.describe_zombie = mcl_mobs.describe_spawning("mobs_mc:zombie")
	end
	return s
end

-- mobs_redo: spawn rules are ABMs labelled "<mob> spawning".
local function probe_redo_spawners()
	if not (rawget(_G, "mobs") and mobs.spawning_mobs) then return nil end
	local s = {spawning_mobs = {}, abms = {}}
	for name, v in pairs(mobs.spawning_mobs) do s.spawning_mobs[name] = v end
	for _, abm in ipairs(core.registered_abms) do
		if abm.label and abm.label:find(" spawning$") then
			s.abms[#s.abms + 1] = {label = abm.label, nodenames = abm.nodenames,
				neighbors = abm.neighbors, interval = abm.interval, chance = abm.chance,
				min_y = abm.min_y, max_y = abm.max_y}
		end
	end
	return s
end

-- A test mob for mobs_redo, which ships no mobs of its own.
if rawget(_G, "mobs") and mobs.register_mob and core.registered_nodes["default:stone"] then
	local cube = {"default_stone.png", "default_stone.png", "default_stone.png",
		"default_stone.png", "default_stone.png", "default_stone.png"}
	mobs:register_mob(modname .. ":raider", {
		type = "monster", passive = false, attack_type = "dogfight", damage = 1,
		hp_min = 10, hp_max = 10, armor = 100, collisionbox = {-0.4, 0, -0.4, 0.4, 1, 0.4},
		visual = "cube", textures = {cube}, walk_velocity = 1, run_velocity = 2,
		view_range = 12, jump = true, fear_height = 4, reach = 2,
		attack_animals = false, attack_players = false, lifetimer = 600,
	})
	mobs:register_mob(modname .. ":sheep", {
		type = "animal", passive = true, hp_min = 5, hp_max = 5, armor = 100,
		collisionbox = {-0.4, 0, -0.4, 0.4, 1, 0.4}, visual = "cube", textures = {cube},
		walk_velocity = 0.5, run_velocity = 1, view_range = 6, jump = true,
	})
	mobs:spawn({name = modname .. ":sheep", nodes = {"default:dirt_with_grass"},
		neighbors = {"air"}, min_light = 10, interval = 60, chance = 8000,
		active_object_count = 2, min_height = 0, max_height = 200})
end

-- The main sequence. Timers rather than one long function, because entities
-- only act between server steps.
local function run()
	local mg = core.get_mapgen_setting("mg_name")
	R.engine = core.get_version()
	R.game = core.get_game_info and core.get_game_info() or nil
	R.mapgen = {mg_name = mg, water_level = core.get_mapgen_setting("water_level"),
		mcl_singlenode_mapgen = core.get_mapgen_setting("mcl_singlenode_mapgen"),
		mcl_levelgen = rawget(_G, "mcl_levelgen") and mcl_levelgen.levelgen_enabled or nil,
		tdl = rawget(_G, "tdl_column") ~= nil}
	try("registries", function() note("registries", probe_registries()) end)
	try("decoration index", index_decorations)
	note("decorations_with_no_biome_filter", #(deco_anywhere or {}))

	-- Biome for a wide grid without generating anything, for timing and range.
	try("biome grid", function()
		local t, n, seen, misses = us(), 0, {}, 0
		for x = -1024, 1024, 64 do
			for z = -1024, 1024, 64 do
				local bn = biome_name_at({x = x, y = 8, z = z})
				n = n + 1
				if bn then seen[bn] = (seen[bn] or 0) + 1 else misses = misses + 1 end
			end
		end
		note("biome_grid", {calls = n, us_per_call = (us() - t) / n, distinct = count(seen),
			nil_results = misses, names = seen})
	end)

	-- Columns to emerge and compare against what was really generated.
	local cols = {}
	local tdl = rawget(_G, "tdl_column")
	for _, dx in ipairs({-192, 0, 192}) do
		for _, dz in ipairs({-192, 0, 192}) do
			local c = {x = dx + 3, z = dz + 5, ytop = 128, ybot = -48}
			if tdl then
				local ok, y = pcall(tdl.at, c.x, c.z)
				if ok and y then c.ytop, c.ybot = math.floor(y) + 40, math.floor(y) - 40 end
			end
			cols[#cols + 1] = c
		end
	end
	local pending = #cols
	local t_emerge = us()
	for _, c in ipairs(cols) do
		core.emerge_area({x = c.x - 8, y = c.ybot, z = c.z - 8}, {x = c.x + 8, y = c.ytop, z = c.z + 8},
			function(_, _, remaining)
				if remaining == 0 then
					pending = pending - 1
					if pending == 0 then
						note("emerge_ms", math.floor((us() - t_emerge) / 1000))
						core.after(0.5, function() try("columns", function()
							local out, seen = {}, {}
							for _, cc in ipairs(cols) do
								local y, top, above = surface_at(cc.x, cc.z, cc.ytop, cc.ybot)
								local row = {x = cc.x, z = cc.z, surface_y = y, surface = top, above = above}
								if y then
									local pos = {x = cc.x, y = y, z = cc.z}
									local bn, bd = biome_name_at(pos)
									row.engine_biome = bn
									row.heat = bd and bd.heat
									row.humidity = bd and bd.humidity
									local def = bn and core.registered_biomes[bn]
									if def then
										row.biome_top = def.node_top
										row.biome_dust = def.node_dust
										row.top_matches = (def.node_top == top or def.node_dust == top
												or def.node_water == top or def.node_riverbed == top)
									end
									if rawget(_G, "mcl_biome_dispatch") then
										row.mcl_dispatch_biome = mcl_biome_dispatch.get_biome_name(pos)
									end
									if tdl then
										local ok, ty, ttop, _, _, entry = pcall(tdl.at, cc.x, cc.z)
										if ok then
											row.tdl_biome = entry and entry.name
											row.tdl_top = ttop
											row.tdl_y = ty
										end
									end
									local key = row.tdl_biome or row.mcl_dispatch_biome or bn
									if key then seen[key] = true end
									if bn then seen[bn] = true end
									-- Under water, the biome of the ground the mapgen used.
									local tdef = core.registered_nodes[top]
									if tdef and (tdef.liquidtype or "none") ~= "none" then
										local fy, fname = floor_under(cc.x, y, cc.z, cc.ybot)
										row.floor_y, row.floor = fy, fname
										if fy then
											row.floor_engine_biome = biome_name_at({x = cc.x, y = fy, z = cc.z})
											if rawget(_G, "mcl_biome_dispatch") then
												row.floor_mcl_dispatch_biome = mcl_biome_dispatch.get_biome_name(
														{x = cc.x, y = fy, z = cc.z})
											end
										end
									end
									-- What stands on the ground round the column, and whether
									-- the biome's registered decorations account for it.
									row.plants_listed_engine, row.plants_unlisted_engine =
											patch_plants(cc, bn, cc.ytop, cc.ybot)
									if key ~= bn then
										row.plants_listed_game, row.plants_unlisted_game =
												patch_plants(cc, key, cc.ytop, cc.ybot)
									end
									row.decorations_for_game_biome = key and #(deco_by_biome[key] or {}) or 0
								end
								out[#out + 1] = row
							end
							note("columns", out)
							note("mcl_spawners", probe_mcl_spawners(seen))
							note("redo_spawners", probe_redo_spawners())
						end)
						core.after(0.5, function() try("entities", function()
							-- Dry ground for the mobs: the centre column, or the
							-- first column whose surface is not a liquid.
							local pick = cols[5]
							for _, i in ipairs({5, 1, 2, 3, 4, 6, 7, 8, 9}) do
								local _, top = surface_at(cols[i].x, cols[i].z, cols[i].ytop, cols[i].ybot)
								local def = top and core.registered_nodes[top]
								if def and def.walkable then pick = cols[i] break end
							end
							entity_phase(pick)
						end) end)
						end)
					end
				end
			end)
	end
end

-- Entity phase: forceload a small area round the centre column and steer
-- mobs in it with nobody connected.
entity_phase = function(c)
	local y = surface_at(c.x, c.z, c.ytop, c.ybot)
	if not y then
		err("entities", "no surface at the centre column")
		return probe_http(function() probe_async(finish) end)
	end
	local center = {x = c.x, y = y + 1, z = c.z}
	local fl = 0
	for bx = -1, 1 do for bz = -1, 1 do for by = -1, 1 do
		if core.forceload_block({x = c.x + bx * 16, y = y + by * 16, z = c.z + bz * 16}, true, -1) then
			fl = fl + 1
		end
	end end end
	local E = {center = vstr(center), forceloaded = fl, steps = {}}
	note("entities", E)
	-- Standing room on real ground, or nil. An earlier version fell back to
	-- the centre's height when a column had no ground within 12 nodes, and
	-- teleported a zombie into the air over a ravine: it fell out of the
	-- forceloaded blocks and was deactivated, not killed.
	local function ground(dx, dz)
		local gy = surface_at(c.x + dx, c.z + dz, y + 12, y - 12)
		if not gy then return nil end
		return {x = c.x + dx, y = gy + 1, z = c.z + dz}
	end

	local hunter_name, prey_name
	if core.registered_entities["mobs_mc:zombie"] then
		hunter_name, prey_name = "mobs_mc:zombie", "mobs_mc:cow"
	elseif core.registered_entities[modname .. ":raider"] then
		hunter_name, prey_name = modname .. ":raider", modname .. ":sheep"
	end
	E.framework = hunter_name and (hunter_name:find("^mobs_mc") and "mcl_mobs" or "mobs_redo") or "none"

	-- Framework spawn validation, before forcing anything.
	if rawget(_G, "mcl_mobs") and mcl_mobs.spawning_possible then
		local p = ground(2, 2) or center
		E.spawning_possible = {pos = vstr(p),
			zombie = tostring(mcl_mobs.spawning_possible(vector.new(p), "mobs_mc:zombie")),
			cow = tostring(mcl_mobs.spawning_possible(vector.new(p), "mobs_mc:cow")),
			light = core.get_node_light(p), timeofday = core.get_timeofday()}
	end

	local hunter, prey
	if hunter_name then
		hunter = core.add_entity(ground(4, 0) or center, hunter_name)
		prey = core.add_entity(ground(-4, 0) or center, prey_name)
	else
		-- No framework: a dropped item is the one entity every game has.
		for name, def in pairs(core.registered_craftitems) do
			prey = core.add_item(ground(-4, 0) or center, name)
			break
		end
	end
	-- A mob with no player near it despawns on its first step in mcl_mobs
	-- unless it is persistent or named: record whether that happened.
	for _, o in ipairs({hunter, prey}) do
		local e = o and o:get_luaentity()
		if e then e.persistent = true; e._director_probe_watched = true end
	end
	E.spawned = {hunter = hunter and describe_obj(hunter), prey = prey and describe_obj(prey)}

	local function step(label)
		E.steps[#E.steps + 1] = {label = label, t_ms = math.floor((us() - T0) / 1000),
			hunter = hunter and hunter:is_valid() and describe_obj(hunter) or "gone",
			prey = prey and prey:is_valid() and describe_obj(prey) or "gone",
			nearby = #objects_near(center, 32)}
	end
	step("spawned")

	-- Watch the hunter every server step, so that if it stops being valid the
	-- record says where, when and whether the engine still knows its GUID.
	local watch = {guid = hunter and hunter:get_guid()}
	E.hunter_watch = watch
	local watching = hunter ~= nil
	core.register_globalstep(function()
		if not watching then return end
		if hunter:is_valid() then
			local e = hunter:get_luaentity()
			watch.last_pos = hunter:get_pos()
			watch.last_health = e and e.health
			watch.last_t_ms = math.floor((us() - T0) / 1000)
			return
		end
		watching = false
		local p = watch.last_pos
		watch.gone_t_ms = math.floor((us() - T0) / 1000)
		watch.last_pos = vstr(p)
		watch.by_guid = core.objects_by_guid and core.objects_by_guid[watch.guid] ~= nil
		watch.block_active = p and core.compare_block_status(p, "active")
		watch.block_loaded = p and core.compare_block_status(p, "loaded")
		watch.near_last_pos = p and objects_near(p, 6) or nil
		watch.node_at_last_pos = p and core.get_node(vector.round(p)).name
	end)

	core.after(1.0, function() try("puppet", function()
		step("after 1 s")
		if hunter and hunter:is_valid() then
			local to = ground(4, 6) or ground(4, 0)
			local t = us()
			hunter:set_pos(to)
			E.set_pos = {to = vstr(to), immediately = vstr(hunter:get_pos()), us = us() - t}
			hunter:set_yaw(math.pi / 2)
			E.set_yaw_read = hunter:get_yaw()
			local e = hunter:get_luaentity()
			-- Speaking as a mob: a nametag through the framework when it has one.
			if e and e.set_nametag then
				e:set_nametag("Grimbold")
			elseif e and e.update_tag then
				e:update_tag("Grimbold")
			else
				hunter:set_nametag_attributes({text = "Grimbold"})
			end
			local nt = hunter:get_nametag_attributes()
			E.nametag = {text = nt and nt.text, prop = hunter:get_properties().nametag}
			core.chat_send_all("<Grimbold> The director probe says hello.")
		end
	end) end)

	core.after(2.0, function() try("target", function()
		step("after set_pos, 1 s")
		if not (hunter and hunter:is_valid() and prey and prey:is_valid()) then return end
		local e = hunter:get_luaentity()
		E.target_method = "none"
		if e and e._targeting_rules and mcl_mobs.build_target_rule then
			-- mcl_mobs recomputes _active_target from its rule list every
			-- step, so writing the field is overwritten. Put a rule first.
			local rule = mcl_mobs.build_target_rule({fn = function(self)
				local t = self._director_target
				if t and t:is_valid() then return t end
			end})
			local rules = {rule}
			for _, f in ipairs(e._targeting_rules) do rules[#rules + 1] = f end
			e._targeting_rules = rules
			e._director_target = prey
			E.target_method = "mcl_mobs targeting rule prepended"
		elseif e and e.do_attack then
			e:do_attack(prey, true)
			E.target_method = "mobs_redo do_attack(obj, true)"
		end
		E.distance_at_target_set = vector.distance(hunter:get_pos(), prey:get_pos())
	end) end)

	for i, s in ipairs({4, 6, 8, 10}) do
		core.after(s, function() try("track " .. i, function()
			step("target +" .. (s - 2) .. " s")
			if hunter and hunter:is_valid() and prey and prey:is_valid() then
				E["distance_" .. (s - 2) .. "s"] = vector.distance(hunter:get_pos(), prey:get_pos())
			end
		end) end)
	end

	-- Puppeting with the framework's AI suspended: shadow on_step on this one
	-- instance, so the prototype and every other mob are untouched. Frozen
	-- from +4 s to +6 s after the target was set, then released.
	E.freeze = {}
	core.after(6.05, function() try("freeze", function()
		if not (hunter and hunter:is_valid()) then return end
		local e = hunter:get_luaentity()
		e.on_step = function() end
		hunter:set_velocity(vector.zero())
		E.freeze.at = vstr(hunter:get_pos())
		E.freeze.frozen_at_us = us()
	end) end)
	core.after(8.05, function() try("release", function()
		if not (hunter and hunter:is_valid()) then return end
		local e = hunter:get_luaentity()
		local p = hunter:get_pos()
		E.freeze.after_2s = vstr(p)
		E.freeze.prey_after_2s = prey and prey:is_valid() and vstr(prey:get_pos()) or "gone"
		e.on_step = nil
		E.freeze.released = rawget(e, "on_step") == nil
	end) end)

	-- A kill, to see what the generic removal hook reports.
	core.after(11, function() try("kill", function()
		if prey and prey:is_valid() then
			E.punch_prey = true
			prey:punch(hunter and hunter:is_valid() and hunter or nil, 1.0,
				{full_punch_interval = 1.0, damage_groups = {fleshy = 200}}, nil)
			local e = prey:get_luaentity()
			E.after_punch = {hp = prey:is_valid() and prey:get_hp() or nil, health = e and e.health}
		end
	end) end)

	core.after(15, function() try("cleanup", function()
		step("after kill 4 s")
		E.area_objects = objects_near(center, 32)
		for o in core.objects_inside_radius(center, 32) do
			if not o:is_player() then o:remove() end
		end
		for bx = -1, 1 do for bz = -1, 1 do for by = -1, 1 do
			core.forceload_free_block({x = c.x + bx * 16, y = y + by * 16, z = c.z + bz * 16}, true)
		end end end
		if rawget(_G, "mcl_weather") and mcl_weather.change_weather then
			E.weather_before = mcl_weather.state
			E.weather_change = tostring(mcl_weather.change_weather("rain", nil, "director_probe"))
			E.weather_after = mcl_weather.state
		end
	end)
	probe_http(function() probe_async(finish) end)
	end)
end

core.after(2, function()
	try("run", run)
end)
core.log("action", "[director_probe] loaded; http api " .. (http and "granted" or "not granted"))
