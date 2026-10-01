-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Player and region summaries, status and capabilities: what the model
-- reads instead of raw state.
--
-- How much of a player the game master sees is the operator's choice,
-- goanna_director_sees: "exact" (positions and gear, which the operator can
-- see anyway; the default, and testers are told in the join notice) or
-- "coarse" (region and gear score only). An opted out player is reported as
-- opted out and nothing else.

return function(D)
	local logic = D.logic

	function D.gear(player)
		local mobs = D.mobs
		local eq = mobs and mobs.equipment and mobs.equipment(player)
		if not eq then
			return {score = 0, armour = 0, weapon = nil}
		end
		local score = logic.gear_score(eq.armour, eq.weapon_damage, eq.armour_best, eq.weapon_best)
		return {score = score, armour = eq.armour, armour_best = eq.armour_best,
			weapon = eq.weapon, weapon_damage = eq.weapon_damage, pieces = eq.pieces}
	end

	function D.encounter_ceiling(player)
		local g = D.gear(player)
		return logic.encounter_ceiling(g.score, D.cfg.encounter_base, D.cfg.encounter_per_gear), g
	end

	local function depth(pos, light)
		if pos.y < -40 then
			return "deep"
		elseif pos.y < -8 then
			return "underground"
		end
		return "surface"
	end

	local function live_owned(name)
		local n = 0
		for _, rec in pairs(D.owned) do
			if not rec.gone and (not name or rec.target == name or rec.near == name) then
				n = n + 1
			end
		end
		return n
	end
	D.live_owned = live_owned

	function D.player_summary(name)
		local p = D.players[name]
		local player = core.get_player_by_name(name)
		if not p or not player then
			return {name = name, online = false}
		end
		if p.optout then
			return {name = name, online = true, opted_out = true}
		end
		local pos = player:get_pos()
		local last = {hurt = 0, kills = 0, deaths = 0, travelled = 0, underground_s = 0, dark_s = 0}
		for _, b in pairs(p.minutes) do
			for k, v in pairs(b) do
				last[k] = last[k] + v
			end
		end
		last.travelled = math.floor(last.travelled)
		last.underground_s = math.floor(last.underground_s)
		last.dark_s = math.floor(last.dark_s)
		local alone = true
		for other in pairs(D.players) do
			local o = other ~= name and core.get_player_by_name(other)
			if o and vector.distance(o:get_pos(), pos) < 64 then
				alone = false
			end
		end
		local ceiling, gear = D.encounter_ceiling(player)
		local s = {
			name = name, online = true,
			region = D.region_id(pos),
			depth = depth(pos),
			light = p.light,
			hp = player:get_hp(), hp_max = player:get_properties().hp_max or 20,
			breath = player:get_breath(),
			last_10_min = last,
			session_s = math.floor(D.now() - p.joined),
			alone = alone,
			hostiles_near = p.hostiles or 0,
			pacing = {phase = p.pacing.phase,
				intensity = math.floor(p.pacing.intensity * 100) / 100,
				phase_s = math.floor(D.now() - p.pacing.since)},
			director_mobs = live_owned(name),
			encounter_ceiling = ceiling,
		}
		if D.cfg.sees == "exact" then
			s.pos = D.vec(pos)
			s.biome = D.mobs and D.mobs.biome_at(vector.round(pos)) or nil
			s.gear = gear
			s.wielded = player:get_wielded_item():get_name()
		else
			s.gear = {score = gear.score}
		end
		return s
	end

	function D.region_summary(id)
		local ax, az = id:match("^r:(%-?%d+):(%-?%d+)$")
		if not ax then
			return nil
		end
		ax, az = tonumber(ax), tonumber(az)
		local r = D.regions[id] or {deaths = 0, kills = {}, placed = 0, dug = 0, visited = {}}
		local out = {id = id, x = {ax * 128, ax * 128 + 127}, z = {az * 128, az * 128 + 127},
			deaths = r.deaths, kills = r.kills, placed = r.placed, dug = r.dug}
		-- Visits, without the opted out.
		local visited = {}
		for name, s in pairs(r.visited) do
			if not D.opted_out(name) then
				visited[name] = math.floor(s)
			end
		end
		out.visited = visited
		-- Biomes from 16 samples at the height of a player in the region, or
		-- at sea level. The engine's opinion where no provider answers.
		local y, danger = 0, 0
		for name, p in pairs(D.players) do
			local player = core.get_player_by_name(name)
			if player and not p.optout and D.region_id(player:get_pos()) == id then
				y = player:get_pos().y
				danger = math.max(danger, p.pacing.intensity)
			end
		end
		out.danger = math.floor(danger * 100) / 100
		if D.mobs then
			local biomes = {}
			for i = 0, 3 do
				for j = 0, 3 do
					local b = D.mobs.biome_at({x = ax * 128 + 16 + i * 32, y = math.floor(y),
						z = az * 128 + 16 + j * 32})
					if b then
						biomes[b] = (biomes[b] or 0) + 1 / 16
					end
				end
			end
			out.biomes = biomes
		end
		local director = 0
		for _, rec in pairs(D.owned) do
			if not rec.gone and rec.region == id then
				director = director + 1
			end
		end
		out.director_mobs = director
		return out
	end

	function D.budget_status()
		local spent = logic.window_sum(D.points, D.now())
		return {
			points_per_hour = D.cfg.points_per_hour,
			points_spent_last_hour = spent,
			points_left = math.max(0, D.cfg.points_per_hour - spent),
			live_entities = live_owned(),
			max_entities = D.cfg.max_entities,
			max_entities_per_player = D.cfg.max_entities_per_player,
			speech_per_minute = D.cfg.speech_per_minute,
			listener_per_minute = D.cfg.listener_per_minute,
		}
	end

	function D.status()
		local phases, queued, encounters, npcs = {}, {}, {}, {}
		for name, p in pairs(D.players) do
			if not p.optout then
				phases[name] = {phase = p.pacing.phase,
					intensity = math.floor(p.pacing.intensity * 100) / 100}
			end
		end
		for _, q in ipairs(D.queue) do
			queued[#queued + 1] = {id = q.id, type = q.type, near = q.args.near}
		end
		for id, e in pairs(D.encounters) do
			if e.state == "live" then
				local player = core.get_player_by_name(e.player)
				local mobs = {}
				for _, guid in ipairs(e.guids) do
					local rec = D.owned[guid]
					local obj = rec and not rec.gone and D.obj_by_guid(guid)
					if obj then
						mobs[#mobs + 1] = {guid = guid, mob = rec.mob,
							target = D.mobs.target_of(obj),
							distance = player and math.floor(vector.distance(obj:get_pos(),
								player:get_pos()) * 10) / 10 or nil,
							health = D.mobs.health(obj)}
					end
				end
				encounters[#encounters + 1] = {id = id, act = e.act, near = e.player,
					alive = e.alive, mobs = mobs,
					leash_left_s = math.floor(e.leash_until - D.now())}
			end
		end
		for _, n in pairs(D.npcs) do
			npcs[#npcs + 1] = {name = n.name, guid = n.guid, mob = n.mob}
		end
		return {
			session = D.session,
			stopped = D.stopped and true or false,
			stopped_by = D.stopped,
			budgets = D.budget_status(),
			pacing = phases,
			queued = queued,
			encounters = encounters,
			npcs = npcs,
			adapter = D.mobs and D.mobs.name or "none",
		}
	end

	function D.capabilities()
		local game = core.get_game_info and core.get_game_info() or {}
		local version = core.get_version()
		return {
			protocol = 1,
			engine = version.project .. " " .. version.string,
			game = game.id,
			adapters = {mobs = D.mobs and D.mobs.name or "none"},
			scopes = {"gm"},
			intents = {"stage_encounter", "end_encounter", "cast_npc", "speak", "remember",
				"undo", "stop"},
			queries = {"capabilities", "status", "player", "players", "region", "memory"},
			sees = D.cfg.sees,
			chat = D.cfg.chat,
			memory_text = D.cfg.memory_text,
			budgets = D.budget_status(),
			deny = (function()
				local out = {}
				for k in pairs(D.cfg.deny) do
					out[#out + 1] = k
				end
				table.sort(out)
				return out
			end)(),
		}
	end
end
