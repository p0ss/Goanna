-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Structures: the director puts a building in the world, and can take it
-- away again (docs/director.md, "Structures").
--
-- The core works on the engine alone: it checks a site, snapshots it with a
-- VoxelManip before anything changes, places a schematic the director
-- authored with core.place_schematic, and restores the snapshot on undo.
-- The game's own structures come from the structures adapter, which places
-- them with the game's loot and setup and says what box they can touch.
--
-- Nothing a player built is overwritten or taken back. The director keeps,
-- in mod storage, the set of mapblocks players have dug or built in since
-- it was first switched on in the world, and refuses a site that overlaps
-- one. While a snapshot is held it also notes every node a player changes
-- inside it, and undo leaves those as the player left them.

return function(D)
	local logic = D.logic

	-- Mapblocks players have changed --------------------------------------

	local TOUCHED_KEY = "dir1:touched"
	local touched = core.parse_json(D.storage:get_string(TOUCHED_KEY) ~= ""
		and D.storage:get_string(TOUCHED_KEY) or "{}") or {}
	local touched_dirty, touched_saved = false, 0

	local function block_key(x, y, z)
		return ("%d,%d,%d"):format(math.floor(x / 16), math.floor(y / 16), math.floor(z / 16))
	end

	D.snapshots = {}      -- id -> snapshot, while undo is possible

	local function inside(p, a, b)
		return p.x >= a.x and p.x <= b.x and p.y >= a.y and p.y <= b.y
			and p.z >= a.z and p.z <= b.z
	end

	local function player_changed(pos, actor)
		if not (actor and actor.is_player and actor:is_player()) then
			return
		end
		local key = block_key(pos.x, pos.y, pos.z)
		if not touched[key] then
			touched[key] = true
			touched_dirty = true
		end
		local h = core.hash_node_position(pos)
		for _, snap in pairs(D.snapshots) do
			if inside(pos, snap.p1, snap.p2) then
				snap.changed[h] = true
			end
		end
	end

	core.register_on_placenode(function(pos, _, placer)
		player_changed(pos, placer)
	end)
	core.register_on_dignode(function(pos, _, digger)
		player_changed(pos, digger)
	end)

	D.tick_hooks[#D.tick_hooks + 1] = function(now)
		if touched_dirty and now - touched_saved >= 10 then
			D.storage:set_string(TOUCHED_KEY, core.write_json(touched))
			touched_dirty, touched_saved = false, now
		end
	end
	core.register_on_shutdown(function()
		if touched_dirty then
			D.storage:set_string(TOUCHED_KEY, core.write_json(touched))
		end
	end)

	-- Sites ---------------------------------------------------------------

	local static_spawn = core.setting_get_pos and core.setting_get_pos("static_spawnpoint")

	local function nearest_in_box(p, a, b)
		return {x = math.max(a.x, math.min(p.x, b.x)), y = math.max(a.y, math.min(p.y, b.y)),
			z = math.max(a.z, math.min(p.z, b.z))}
	end

	local function objects_in(a, b)
		return ipairs(core.get_objects_in_area(a, b))
	end

	-- Why the box p1..p2 may not be built in, or nil. Generated and loaded,
	-- wholly unprotected, no mapblock a player has changed, nobody standing
	-- in it, clear of static spawn and of players who opted out.
	function D.box_problem(p1, p2)
		for x = math.floor(p1.x / 16), math.floor(p2.x / 16) do
			for y = math.floor(p1.y / 16), math.floor(p2.y / 16) do
				for z = math.floor(p1.z / 16), math.floor(p2.z / 16) do
					if touched[("%d,%d,%d"):format(x, y, z)] then
						return "player_built", {block = {x, y, z}}
					end
				end
			end
		end
		local prot = core.is_area_protected(p1, p2, "", 4)
		if prot then
			return "protected", {at = D.vec(prot)}
		end
		local wide1, wide2 = vector.offset(p1, -2, -2, -2), vector.offset(p2, 2, 3, 2)
		for _, player in ipairs(core.get_connected_players()) do
			if inside(vector.round(player:get_pos()), wide1, wide2) then
				return "player_in_area", {player = player:get_player_name()}
			end
		end
		local r = D.cfg.exclusion
		if static_spawn and vector.distance(nearest_in_box(static_spawn, p1, p2), static_spawn) < r then
			return "spawn"
		end
		for name, p in pairs(D.players) do
			local other = p.optout and core.get_player_by_name(name)
			if other then
				local op = other:get_pos()
				if vector.distance(nearest_in_box(op, p1, p2), op) < math.max(r, 32) then
					return "opted_out_player_near"
				end
			end
		end
		return nil
	end

	-- Snapshots -----------------------------------------------------------

	-- Read the box's nodes, param2 and metadata, and which objects are in
	-- it. nil and "not_loaded" when part of it has not been generated or is
	-- not loaded; the area is then queued for emerging so a retry can work.
	function D.snapshot(p1, p2)
		local vm = VoxelManip()
		local e1, e2 = vm:read_from_map(p1, p2)
		local area = VoxelArea(e1, e2)
		local data, p2d = vm:get_data(), vm:get_param2_data()
		local nodes, param2, i = {}, {}, 0
		local ignore = core.CONTENT_IGNORE
		for z = p1.z, p2.z do
			for y = p1.y, p2.y do
				for x = p1.x, p2.x do
					local vi = area:index(x, y, z)
					i = i + 1
					if data[vi] == ignore then
						core.emerge_area(p1, p2)
						return nil, "not_loaded"
					end
					nodes[i], param2[i] = data[vi], p2d[vi]
				end
			end
		end
		local metas = {}
		for _, p in ipairs(core.find_nodes_with_meta(p1, p2)) do
			metas[core.hash_node_position(p)] = core.get_meta(p):to_table()
		end
		local objects = {}
		for _, obj in objects_in(p1, p2) do
			if obj.get_guid then
				objects[obj:get_guid()] = true
			end
		end
		return {p1 = vector.new(p1), p2 = vector.new(p2), nodes = nodes, param2 = param2,
			metas = metas, objects = objects, changed = {}, t = D.now()}
	end

	-- How many nodes in the box differ from the snapshot.
	function D.snapshot_diff(snap)
		local vm = VoxelManip()
		local e1, e2 = vm:read_from_map(snap.p1, snap.p2)
		local area = VoxelArea(e1, e2)
		local data = vm:get_data()
		local i, n = 0, 0
		for z = snap.p1.z, snap.p2.z do
			for y = snap.p1.y, snap.p2.y do
				for x = snap.p1.x, snap.p2.x do
					i = i + 1
					if data[area:index(x, y, z)] ~= snap.nodes[i] then
						n = n + 1
					end
				end
			end
		end
		return n
	end

	local function drop_inventory(pos)
		local inv = core.get_meta(pos):get_inventory()
		for list in pairs(inv:get_lists()) do
			for _, stack in ipairs(inv:get_list(list)) do
				if not stack:is_empty() then
					core.add_item(vector.offset(pos, 0, 0.5, 0), stack)
				end
			end
		end
	end

	-- Put the box back as the snapshot had it, except nodes a player
	-- changed since. Anything stored in a container that was not there
	-- before is dropped on the ground rather than deleted, and objects that
	-- appeared in the box, other than players, dropped items and the
	-- director's own characters, are removed. Returns the number of nodes
	-- restored and the number left as players made them.
	function D.restore(snap)
		local vm = VoxelManip()
		local e1, e2 = vm:read_from_map(snap.p1, snap.p2)
		local area = VoxelArea(e1, e2)
		local data, p2d = vm:get_data(), vm:get_param2_data()
		local kept = 0
		local reapply = {}
		for _, p in ipairs(core.find_nodes_with_meta(snap.p1, snap.p2)) do
			local h = core.hash_node_position(p)
			if not snap.changed[h] then
				local i = (p.z - snap.p1.z) * (snap.p2.y - snap.p1.y + 1) * (snap.p2.x - snap.p1.x + 1)
					+ (p.y - snap.p1.y) * (snap.p2.x - snap.p1.x + 1) + (p.x - snap.p1.x) + 1
				local same = snap.metas[h] and data[area:indexp(p)] == snap.nodes[i]
				if not same then
					drop_inventory(p)
					core.get_meta(p):from_table(nil)
				end
			end
		end
		for h, t in pairs(snap.metas) do
			if not snap.changed[h] then
				reapply[h] = t
			end
		end
		local i, restored = 0, 0
		for z = snap.p1.z, snap.p2.z do
			for y = snap.p1.y, snap.p2.y do
				for x = snap.p1.x, snap.p2.x do
					i = i + 1
					local vi = area:index(x, y, z)
					if snap.changed[core.hash_node_position({x = x, y = y, z = z})] then
						kept = kept + 1
					elseif data[vi] ~= snap.nodes[i] or p2d[vi] ~= snap.param2[i] then
						data[vi], p2d[vi] = snap.nodes[i], snap.param2[i]
						restored = restored + 1
					end
				end
			end
		end
		vm:set_data(data)
		vm:set_param2_data(p2d)
		vm:write_to_map(true)
		for h, t in pairs(reapply) do
			local p = core.get_position_from_hash(h)
			local m = core.get_meta(p)
			if not next(m:to_table().fields or {}) then
				m:from_table(t)
			end
		end
		for _, obj in objects_in(snap.p1, snap.p2) do
			local guid = obj.get_guid and obj:get_guid()
			local e = obj:get_luaentity()
			if guid and not obj:is_player() and not snap.objects[guid] and not D.owned[guid]
					and not (e and e.name == "__builtin:item") then
				obj:remove()
			end
		end
		return restored, kept
	end

	-- Schematics ------------------------------------------------------------

	local function node_ok(name)
		local def = core.registered_nodes[name]
		if not def then
			return false, "unknown_node"
		end
		local g = def.groups or {}
		if (def.damage_per_second or 0) > 0 or (g.tnt or 0) > 0 then
			return false, "harmful_node"
		end
		if (g.not_in_creative_inventory or 0) > 0 then
			return false, "hidden_node"
		end
		return true
	end

	local function limits()
		local max_volume = D.cfg.structure_max_volume
		return {max_side = 64, max_volume = max_volume}
	end

	-- A director's palette and layers, or a game structure's schematic for
	-- a character to build, as logic.parse_schematic's shape.
	function D.parse_authored(args)
		return logic.parse_schematic(args.palette, args.layers, node_ok, limits())
	end

	function D.from_read_schematic(s)
		local sx, sy, sz = s.size.x, s.size.y, s.size.z
		local nodes, count = {}, 0
		local i = 0
		for z = 0, sz - 1 do
			for y = 0, sy - 1 do
				for x = 0, sx - 1 do
					i = i + 1
					local d = s.data[i]
					if d and (d.prob or 255) > 0 and core.registered_nodes[d.name] then
						nodes[#nodes + 1] = {x, y, z, d.name, d.param2 or 0}
						if d.name ~= "air" then
							count = count + 1
						end
					end
				end
			end
		end
		return {size = {sx, sy, sz}, nodes = nodes, count = count}
	end

	local function to_engine_schematic(parsed)
		local sx, sy, sz = parsed.size[1], parsed.size[2], parsed.size[3]
		local data = {}
		for i = 1, sx * sy * sz do
			data[i] = {name = "air", prob = 0}
		end
		for _, n in ipairs(parsed.nodes) do
			data[(n[3] * sy + n[2]) * sx + n[1] + 1] = {name = n[4], prob = 255,
				param2 = n[5] or 0, force_place = true}
		end
		return {size = {x = sx, y = sy, z = sz}, data = data}
	end

	-- The box a parsed schematic occupies with its footprint centred on at
	-- and its bottom layer at at.y.
	function D.authored_box(parsed, at)
		local sx, sy, sz = parsed.size[1], parsed.size[2], parsed.size[3]
		local p1 = {x = at.x - math.floor(sx / 2), y = at.y, z = at.z - math.floor(sz / 2)}
		return p1, {x = p1.x + sx - 1, y = p1.y + sy - 1, z = p1.z + sz - 1}
	end

	-- Sites near a player ---------------------------------------------------

	-- The ground near a player for a footprint of side w by d: the centre on
	-- walkable ground, and the four corners within two nodes of its height,
	-- so a building neither floats nor buries itself. box(at) gives the box
	-- to check for a candidate centre. Returns at, p1, p2, or nil and the
	-- last reason a candidate was refused.
	function D.find_site(player, dmin, dmax, w, d, box, rng)
		local pp = player:get_pos()
		local why = "no_place"
		for _ = 1, 32 do
			local angle = rng(3600) / 3600 * 2 * math.pi
			local dist = dmin + (dmax - dmin) * rng(1000) / 1000
			local cx, cz = pp.x + math.cos(angle) * dist, pp.z + math.sin(angle) * dist
			local at = D.ground_at(cx, cz, pp.y + 4, 2)
			if at then
				local flat = true
				for _, c in ipairs({{-1, -1}, {1, -1}, {-1, 1}, {1, 1}}) do
					local g = D.ground_at(at.x + c[1] * math.floor(w / 2),
						at.z + c[2] * math.floor(d / 2), at.y + 2, 1)
					if not g or math.abs(g.y - at.y) > 2 then
						flat = false
						break
					end
				end
				if flat then
					local p1, p2 = box(at)
					local problem = D.box_problem(p1, p2)
					if not problem then
						return at, p1, p2
					end
					why = problem
				else
					why = "not_flat"
				end
			end
		end
		return nil, why
	end

	-- The intent --------------------------------------------------------------

	local function nodes_left()
		return D.cfg.build_nodes_per_hour - logic.window_sum(D.build_points, D.now())
	end
	D.build_nodes_left = nodes_left

	local function player_name(s)
		return type(s) == "string" and (s:gsub("^player:", "")) or nil
	end

	local function vec_arg(a)
		if type(a) == "table" and tonumber(a[1]) and tonumber(a[2]) and tonumber(a[3]) then
			return {x = math.floor(a[1] + 0.5), y = math.floor(a[2] + 0.5),
				z = math.floor(a[3] + 0.5)}
		end
		return nil
	end
	D.vec_arg = vec_arg

	-- Shared by place_structure and the build order: what to build, where,
	-- what it costs. Returns a plan {source, parsed or structure, at, p1,
	-- p2, nodes, seed}, or nil, a reason and detail fields.
	function D.plan_structure(args, rng, for_build)
		if not D.cfg.structures then
			return nil, "structures_off", {setting = "goanna_director_structures"}
		end
		local plan = {seed = rng(2147483646)}
		local w, d, h, box
		if type(args.structure) == "string" then
			if not D.structures then
				return nil, "no_adapter", {kind = "structures"}
			end
			local entry = D.catalogue_entry("structure", args.structure)
			if not entry then
				return nil, "unknown_structure", {structure = args.structure}
			end
			plan.source, plan.structure = "game", args.structure
			w, h, d = entry.size[1], entry.size[2], entry.size[3]
			if for_build then
				local s = D.structures.schematic(args.structure, plan.seed)
				if not s then
					return nil, "no_schematic", {structure = args.structure}
				end
				plan.parsed = D.from_read_schematic(s)
				box = function(at)
					return D.authored_box(plan.parsed, at)
				end
			else
				if not D.structures.plan(args.structure, {x = 0, y = 0, z = 0}, plan.seed) then
					return nil, "unknown_structure", {structure = args.structure}
				end
				box = function(at)
					local b = D.structures.plan(args.structure, at, plan.seed)
					return b.p1, b.p2
				end
			end
		elseif args.palette or args.layers then
			local parsed, why, detail = D.parse_authored(args)
			if not parsed then
				return nil, why, {detail = detail}
			end
			plan.source, plan.parsed = "authored", parsed
			w, h, d = parsed.size[1], parsed.size[2], parsed.size[3]
			box = function(at)
				return D.authored_box(parsed, at)
			end
		else
			return nil, "schema", {detail = "structure, or palette and layers"}
		end
		if w * h * d > D.cfg.structure_max_volume then
			return nil, "too_large", {max_volume = D.cfg.structure_max_volume,
				size = {w, h, d}}
		end
		plan.nodes = plan.parsed and #plan.parsed.nodes
			or (D.structures.plan(args.structure, {x = 0, y = 0, z = 0}, plan.seed) or {}).nodes
			or w * h * d
		if plan.nodes > nodes_left() then
			return nil, "budget", {nodes = plan.nodes, nodes_left = nodes_left()}
		end
		local at = vec_arg(args.at)
		if at then
			plan.at = at
			plan.p1, plan.p2 = box(at)
			local problem, detail = D.box_problem(plan.p1, plan.p2)
			if problem then
				return nil, problem, detail
			end
		else
			local name = player_name(args.near)
			local player = name and core.get_player_by_name(name)
			if not player then
				return nil, name and "not_online" or "schema",
					name and {near = name} or {detail = "at [x,y,z] or near a player"}
			end
			if D.opted_out(name) then
				return nil, "opted_out", {near = name}
			end
			local dist = type(args.distance) == "table" and args.distance or {}
			local reach = math.ceil(math.max(w, d) / 2) + 4
			local dmin = math.max(tonumber(dist[1]) or reach, reach)
			local dmax = math.max(tonumber(dist[2]) or dmin + 16, dmin + 1)
			local where, p1, p2 = D.find_site(player, dmin, dmax, w, d, box, rng)
			if not where then
				return nil, "no_place", {last = p1}
			end
			plan.at, plan.p1, plan.p2 = where, p1, p2
		end
		return plan
	end

	local function place_game(plan, snap_id, act)
		if not D.structures.place(plan.structure, plan.at, plan.seed) then
			return false
		end
		-- The game emerges the area and places the structure some steps
		-- later; report when it has landed.
		local tries = 0
		local function check()
			local snap = D.snapshots[snap_id]
			if not snap then
				return
			end
			tries = tries + 1
			local changed = D.snapshot_diff(snap)
			if changed > 0 then
				D.emit("structure_placed", {}, {act = act, structure = plan.structure,
					changed = changed}, plan.at)
			elseif tries < 5 then
				core.after(2, check)
			else
				D.snapshots[snap_id] = nil
				D.emit("structure_failed", {}, {act = act, structure = plan.structure,
					reason = "game_declined"}, plan.at)
			end
		end
		core.after(1, check)
		return true
	end

	function D.place_structure_intent(msg, result, refuse, rng)
		local plan, why, detail = D.plan_structure(msg.args, rng, false)
		if not plan then
			return refuse(msg, why, detail)
		end
		local snap, err = D.snapshot(plan.p1, plan.p2)
		if not snap then
			return refuse(msg, err, {hint = "the area is being loaded; try again in a few seconds"})
		end
		local id = msg.req
		D.snapshots[id] = snap
		if plan.source == "game" then
			if not place_game(plan, id, msg.req) then
				D.snapshots[id] = nil
				return refuse(msg, "game_declined", {structure = plan.structure})
			end
		else
			local p1 = D.authored_box(plan.parsed, plan.at)
			core.place_schematic(p1, to_engine_schematic(plan.parsed), "0", nil, true)
		end
		logic.window_add(D.build_points, D.now(), plan.nodes)
		D.undo[msg.req] = {type = "structure", snap = id}
		local fields = {source = plan.source, structure = plan.structure, at = D.vec(plan.at),
			box = {D.vec(plan.p1), D.vec(plan.p2)}, nodes = plan.nodes,
			nodes_left = nodes_left()}
		if plan.source == "authored" then
			D.emit("structure_placed", {}, {act = msg.req, source = "authored",
				changed = D.snapshot_diff(snap)}, plan.at)
		end
		return result(msg, plan.source == "game" and "accepted" or "completed", fields,
			{effects = {at = D.vec(plan.at), box = fields.box, source = plan.source,
				structure = plan.structure, nodes = plan.nodes}})
	end

	-- Undo for a structure or a build: the snapshot written back.
	function D.undo_structure(u)
		local snap = D.snapshots[u.snap]
		if not snap then
			return {restored = 0, note = "nothing was placed"}
		end
		local restored, kept = D.restore(snap)
		D.snapshots[u.snap] = nil
		return {restored = restored, kept_player_changes = kept}
	end

	-- Exposed for the build order.
	D.to_engine_schematic = to_engine_schematic
	D.node_ok = node_ok
end
