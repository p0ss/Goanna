-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Engine callbacks into the event ring, per player state, and the pacing
-- layer's tick.
--
-- A callback appends a small table and updates counters; it never encodes
-- and never scans. The ring is read by http.lua once a second.
--
-- A player who has opted out is left out of the stream entirely: nothing
-- about them is recorded as an event, so nothing about them reaches the
-- model.

return function(D)
	local logic = D.logic

	local function minute()
		return math.floor(D.now() / 60)
	end

	-- The last ten minutes, per player, as one bucket per minute.
	local function bucket(p)
		local m = minute()
		local b = p.minutes[m]
		if not b then
			b = {hurt = 0, kills = 0, deaths = 0, travelled = 0, underground_s = 0, dark_s = 0}
			p.minutes[m] = b
			for k in pairs(p.minutes) do
				if k < m - 10 then
					p.minutes[k] = nil
				end
			end
		end
		return b
	end
	D.bucket = bucket

	function D.region(id)
		local r = D.regions[id]
		if not r then
			r = {deaths = 0, kills = {}, placed = 0, dug = 0, visited = {}}
			D.regions[id] = r
		end
		return r
	end

	function D.player_state(name)
		return D.players[name]
	end

	local function excluded(who)
		for _, s in ipairs(who or {}) do
			local name = type(s) == "string" and s:match("^player:(.+)$")
			if name and D.opted_out(name) then
				return true
			end
		end
		return false
	end

	-- type, subjects, data, position. Returns the sequence number, or nil
	-- when the event was dropped because it concerns an opted out player.
	function D.emit(etype, who, data, pos)
		if excluded(who) then
			return nil
		end
		local ev = {type = etype, t = core.get_gametime(), who = who or {}, data = data or {}}
		if pos then
			local where = {region = D.region_id(pos)}
			if D.cfg.sees == "exact" then
				where.pos = D.vec(pos)
			end
			ev.where = where
		end
		return logic.ring_push(D.ring, ev)
	end

	local function new_player(player)
		local name = player:get_player_name()
		local p = {
			name = name,
			joined = D.now(),
			optout = player:get_meta():get_string("goanna_director_optout") == "1",
			pacing = logic.pacing_new(D.now(), D.pacing_cfg),
			minutes = {},
			hurt_pending = 0,
			last_pos = player:get_pos(),
			died_seq = 0,
		}
		D.players[name] = p
		D.optout_seen[name] = p.optout
		return p
	end

	core.register_on_joinplayer(function(player, last_login)
		local p = new_player(player)
		local seq = D.emit("player_join", {"player:" .. p.name},
			{first_join = last_login == nil}, player:get_pos())
		p.died_seq = seq or 0
		if D.on_join then
			D.on_join(player, p)
		end
	end)

	core.register_on_leaveplayer(function(player, timed_out)
		local name = player:get_player_name()
		local seq = D.emit("player_leave", {"player:" .. name}, {timed_out = timed_out == true},
			player:get_pos())
		if D.on_leave then
			D.on_leave(name)
		end
		local p = D.players[name]
		if p then
			p.died_seq = seq or p.died_seq
		end
		D.players[name] = nil
	end)

	core.register_on_player_hpchange(function(player, hp_change, reason)
		if hp_change >= 0 then
			return
		end
		local p = D.players[player:get_player_name()]
		if not p then
			return
		end
		local amount = -hp_change
		p.hurt_pending = p.hurt_pending + amount
		p.hurt_cause = reason and reason.type or p.hurt_cause
		local obj = reason and reason.object
		local e = obj and obj:get_luaentity()
		if e and e.name then
			p.hurt_by = e.name
			p.hurt_by_guid = obj:get_guid()
		end
		local hp_max = player:get_properties().hp_max or 20
		logic.pacing_damage(p.pacing, amount / hp_max, D.now())
		bucket(p).hurt = bucket(p).hurt + amount
	end, false)

	core.register_on_dieplayer(function(player, reason)
		local name = player:get_player_name()
		local p = D.players[name]
		local pos = player:get_pos()
		D.region(D.region_id(pos)).deaths = D.region(D.region_id(pos)).deaths + 1
		if not p then
			return
		end
		bucket(p).deaths = bucket(p).deaths + 1
		local phase = logic.pacing_death(p.pacing, D.pacing_cfg, D.now())
		local by
		local obj = reason and reason.object
		local e = obj and obj:get_luaentity()
		if e and e.name then
			by = e.name
		end
		local seq = D.emit("player_death", {"player:" .. name},
			{cause = reason and reason.type, by = by}, pos)
		p.died_seq = seq or p.died_seq
		D.emit("pacing", {"player:" .. name}, {phase = phase, intensity = 1, why = "death"})
		if D.on_death then
			D.on_death(name)
		end
	end)

	core.register_on_respawnplayer(function(player)
		D.emit("player_respawn", {"player:" .. player:get_player_name()}, {}, player:get_pos())
	end)

	core.register_on_placenode(function(pos, newnode, placer)
		local r = D.region(D.region_id(pos))
		r.placed = r.placed + 1
	end)

	core.register_on_dignode(function(pos, oldnode, digger)
		local r = D.region(D.region_id(pos))
		r.dug = r.dug + 1
	end)

	-- Kills and removals, for every mob, from a wrapped on_deactivate. A
	-- removal is not proof of death (docs/agents/director.md, "Deactivation is not
	-- death"), so the adapter decides from the framework's own state.
	core.register_on_mods_loaded(function()
		for name, def in pairs(core.registered_entities) do
			local old = def.on_deactivate
			def.on_deactivate = function(self, removal)
				local ok, err = pcall(D.entity_gone, self, name, removal)
				if not ok then
					core.log("warning", "[goanna director] removal hook: " .. tostring(err))
				end
				if old then
					return old(self, removal)
				end
			end
		end
	end)

	function D.entity_gone(self, name, removal)
		local obj = self.object
		if not obj or not obj:get_pos() then
			return
		end
		local guid = obj:get_guid()
		local rec = guid and D.owned[guid]
		local mobs = D.mobs
		if not removal then
			if rec then
				D.emit("entity_deactivated", {"entity:" .. guid}, {mob = name}, obj:get_pos())
			end
			return
		end
		local died, killer = false, nil
		if mobs and mobs.is_mob(self) then
			died, killer = mobs.death(self)
		end
		if not died and not rec then
			return
		end
		local pos = obj:get_pos()
		local category = mobs and mobs.category(name) or "unknown"
		if died then
			local r = D.region(D.region_id(pos))
			r.kills[category] = (r.kills[category] or 0) + 1
			local p = killer and D.players[killer]
			if p then
				bucket(p).kills = bucket(p).kills + 1
				if category == "monster" then
					logic.pacing_kill(p.pacing, D.pacing_cfg, D.now())
				end
			end
			if D.on_kill then
				D.on_kill(name, killer, pos, rec)
			end
		end
		-- Every death of a director owned mob is reported, and every death a
		-- player caused. Other mobs dying of other things are not news.
		if rec or killer then
			local who = {"entity:" .. guid}
			if killer then
				who[#who + 1] = "player:" .. killer
			end
			D.emit(died and "entity_died" or "entity_removed", who,
				{mob = name, category = category, killer = killer,
					director = rec ~= nil, encounter = rec and rec.encounter,
					npc = rec and rec.name}, pos)
		end
		if rec then
			rec.gone = died and "died" or "removed"
		end
	end

	-- Chat. builtin's handler returns true for every "/" command before any
	-- mod's callback runs, so /msg never arrives here (docs/agents/director.md,
	-- "Public chat only"). By default every public line is read, as the
	-- operator can read it; goanna_director_chat narrows that.
	core.register_on_chat_message(function(name, message)
		if D.cfg.chat == "none" or D.opted_out(name) or not D.players[name] then
			return false
		end
		if message:sub(1, 1) == "/" then
			return false
		end
		-- The director's cast characters first, then each ruleset's own.
		local addressed = D.npc_addressed and D.npc_addressed(name, message)
			or D.ruleset_addressed(name, message)
		if not addressed and D.cfg.chat == "all" then
			local player = core.get_player_by_name(name)
			D.emit("player_chat", {"player:" .. name}, {text = message:sub(1, 280)},
				player and player:get_pos())
		end
		return false
	end)

	-- Once a second: coalesced hurt events, movement and light, pacing, and
	-- whatever the other modules hang on the tick.
	D.tick_hooks = {}
	local timer = 0
	core.register_globalstep(function(dtime)
		timer = timer + dtime
		if timer < 1 then
			return
		end
		local dt = timer
		timer = 0
		local now = D.now()
		for name, p in pairs(D.players) do
			local player = core.get_player_by_name(name)
			if player then
				local pos = player:get_pos()
				local b = bucket(p)
				b.travelled = b.travelled + vector.distance(pos, p.last_pos)
				p.last_pos = pos
				local light = core.get_node_light(vector.offset(pos, 0, 1, 0)) or 0
				p.light = light
				if pos.y < -8 then
					b.underground_s = b.underground_s + dt
				end
				if light < 7 then
					b.dark_s = b.dark_s + dt
				end
				local rv = D.region(D.region_id(pos)).visited
				rv[name] = (rv[name] or 0) + dt
				if p.hurt_pending > 0 then
					D.emit("player_hurt", {"player:" .. name},
						{amount = p.hurt_pending, hp = player:get_hp(), cause = p.hurt_cause,
							mob = p.hurt_by}, pos)
					p.hurt_pending, p.hurt_cause, p.hurt_by = 0, nil, nil
				end
				local hostiles = 0
				if D.mobs then
					for obj in core.objects_inside_radius(pos, 16) do
						if D.mobs.hostile(obj:get_luaentity()) then
							hostiles = hostiles + 1
						end
					end
				end
				p.hostiles = hostiles
				local changed = logic.pacing_tick(p.pacing, D.pacing_cfg, now, dt, hostiles)
				if changed then
					D.emit("pacing", {"player:" .. name},
						{phase = changed, intensity = math.floor(p.pacing.intensity * 100) / 100})
				end
			end
		end
		for _, hook in ipairs(D.tick_hooks) do
			local ok, err = pcall(hook, now, dt)
			if not ok then
				core.log("warning", "[goanna director] tick: " .. tostring(err))
			end
		end
	end)
end
