-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Validation and application of the model's intents, and the answers to its
-- queries.
--
-- Every intent goes through the same pipeline (docs/design/director-design.md, "Actions"):
-- schema, scope, stop, budget, the framework's rules, the place, pacing,
-- apply with an undo record, audit. A refusal carries a machine readable
-- reason. A player who has opted out is never targeted, spoken to, placed
-- near or remembered.

return function(D)
	local logic = D.logic

	local function player_name(s)
		if type(s) ~= "string" then
			return nil
		end
		return (s:gsub("^player:", ""))
	end

	local function obj_by_guid(guid)
		local obj = guid and core.objects_by_guid[guid]
		if obj and obj:is_valid() and obj:get_pos() then
			return obj
		end
		return nil
	end
	D.obj_by_guid = obj_by_guid

	-- One random source per session, seeded from the world seed and the
	-- session, so a session's placements replay from its audit log.
	local seed = tonumber(core.get_mapgen_setting("seed")) or 0
	local rng = PcgRandom(math.floor(seed % 2147483647) + #D.session * 7919)
	local function random(n)
		return rng:next(1, math.max(1, math.floor(n)))
	end
	D.random = random

	local function result(msg, status, fields, audit_extra)
		local body = fields or {}
		body.id = msg.req
		body.type = msg.type
		body.status = status
		local entry = {kind = "intent", id = msg.req, type = msg.type, args = msg.args,
			reason = msg.reason, outcome = status, refusal = body.reason}
		for k, v in pairs(audit_extra or {}) do
			entry[k] = v
		end
		D.audit(entry)
		return body
	end

	local function refuse(msg, reason, fields)
		fields = fields or {}
		fields.reason = reason
		return result(msg, "refused", fields)
	end

	-- Places. A position is usable when its mapblock is loaded, the mob's
	-- height of nodes is clear, the node under it is walkable and not a
	-- liquid, nothing protects it, and it is clear of static spawn and of
	-- every player who opted out.
	local function walkable(node)
		local def = node and core.registered_nodes[node.name]
		return def and def.walkable and (def.liquidtype or "none") == "none"
	end

	local function clear(node)
		local def = node and core.registered_nodes[node.name]
		return def and not def.walkable and (def.liquidtype or "none") == "none"
			and (def.damage_per_second or 0) <= 0
	end

	local static_spawn = core.setting_get_pos and core.setting_get_pos("static_spawnpoint")

	local function excluded(pos)
		local r = D.cfg.exclusion
		if static_spawn and vector.distance(pos, static_spawn) < r then
			return "spawn"
		end
		for name, p in pairs(D.players) do
			if p.optout then
				local other = core.get_player_by_name(name)
				if other and vector.distance(other:get_pos(), pos) < math.max(r, 32) then
					return "opted_out_player_near"
				end
			end
		end
		return nil
	end

	D.excluded = excluded
	D.walkable = walkable

	local function ground_at(x, z, y0, height)
		x, z = math.floor(x + 0.5), math.floor(z + 0.5)
		for y = math.floor(y0 + 6), math.floor(y0 - 10), -1 do
			local below = core.get_node_or_nil({x = x, y = y - 1, z = z})
			if below and walkable(below) then
				local ok = true
				for h = 0, height - 1 do
					local n = core.get_node_or_nil({x = x, y = y + h, z = z})
					if not clear(n) then
						ok = false
						break
					end
				end
				if ok then
					return {x = x, y = y, z = z}
				end
			end
		end
		return nil
	end

	D.ground_at = ground_at

	-- Find a place for one mob. Returns the position, or nil and the last
	-- reason a candidate was turned down. hidden is true (out of the
	-- player's sight, for encounters) or false (in sight if any such place
	-- is found, else any usable place, for characters).
	local function find_place(player, mob, dmin, dmax, hidden, anchor)
		local pp = player:get_pos()
		local eye = vector.offset(pp, 0, 1.5, 0)
		local cb = D.mobs.collisionbox(mob)
		local height = math.max(1, math.ceil((cb[5] or 1.8) - (cb[2] or 0)))
		local why = "no_ground"
		local fallback
		for attempt = 1, 32 do
			local x, z
			if anchor and attempt <= 12 then
				x = anchor.x + random(7) - 4
				z = anchor.z + random(7) - 4
			else
				local angle = random(3600) / 3600 * 2 * math.pi
				local d = dmin + (dmax - dmin) * random(1000) / 1000
				x, z = pp.x + math.cos(angle) * d, pp.z + math.sin(angle) * d
			end
			local pos = ground_at(x, z, anchor and anchor.y or pp.y, height)
			if pos then
				local dist = vector.distance(pos, pp)
				if dist < dmin * 0.75 or dist > dmax * 1.25 then
					why = "distance"
				elseif core.is_protected(pos, "") then
					why = "protected"
				elseif excluded(pos) then
					why = excluded(pos)
				elseif hidden and core.line_of_sight(eye, vector.offset(pos, 0, 1, 0)) then
					why = "in_sight"
				elseif D.cfg.spawn_rules == "natural" and D.mobs.natural_spawn_ok(pos, mob) == false then
					why = "rules"
				elseif not hidden and not core.line_of_sight(eye, vector.offset(pos, 0, 1, 0)) then
					why = "out_of_sight"
					fallback = fallback or pos
				else
					return pos
				end
			end
		end
		if fallback then
			return fallback
		end
		return nil, why
	end

	local function remove_owned(guid)
		local rec = D.owned[guid]
		if not rec then
			return false
		end
		rec.removing = true
		local obj = obj_by_guid(guid)
		if obj then
			obj:remove()
		end
		rec.gone = rec.gone or "removed"
		return obj ~= nil
	end

	local function end_encounter(e, outcome)
		if e.state ~= "live" then
			return
		end
		local removed, died = 0, 0
		for _, guid in ipairs(e.guids) do
			local rec = D.owned[guid]
			if rec and rec.gone == "died" then
				died = died + 1
			elseif remove_owned(guid) then
				removed = removed + 1
			end
			D.owned[guid] = nil
		end
		e.state = "ended"
		e.outcome = outcome
		D.emit("encounter_ended", {"player:" .. e.player},
			{encounter = e.id, act = e.act, outcome = outcome, died = died, removed = removed})
		D.audit({kind = "effect", id = e.act, type = "encounter_ended", outcome = outcome,
			effects = {encounter = e.id, died = died, removed = removed}})
	end
	D.end_encounter = end_encounter

	-- Encounters -------------------------------------------------------------

	local function candidates(msg, player, name)
		local mobs, args = D.mobs, msg.args
		local list = {}
		if type(args.mobs) == "table" and #args.mobs > 0 then
			for _, m in ipairs(args.mobs) do
				if type(m) ~= "string" or not mobs.known(m) then
					return nil, "unknown_mob", {mob = tostring(m)}
				end
				if D.cfg.deny[m] then
					return nil, "denied", {mob = m}
				end
				list[#list + 1] = {name = m, weight = 1}
			end
		else
			local category = type(args.theme) == "string" and args.theme or "monster"
			local biome = mobs.biome_at(vector.round(player:get_pos()))
			for _, f in ipairs(mobs.fauna(biome, category)) do
				if not D.cfg.deny[f.name] and mobs.known(f.name) then
					list[#list + 1] = {name = f.name, weight = f.weight}
				end
			end
			if #list == 0 then
				return nil, "no_fauna", {biome = biome, theme = category}
			end
		end
		for _, c in ipairs(list) do
			c.cost = logic.mob_cost(mobs.cost_parts(c.name))
		end
		return list
	end

	local function stage_encounter(msg, from_queue)
		local args, now = msg.args, D.now()
		local name = player_name(args.near)
		if not name then
			return refuse(msg, "schema", {detail = "near must be a player name"})
		end
		if not D.mobs then
			return refuse(msg, "no_adapter")
		end
		local player = core.get_player_by_name(name)
		local p = D.players[name]
		if not player or not p then
			return refuse(msg, "not_online", {near = name})
		end
		if p.optout then
			return refuse(msg, "opted_out", {near = name})
		end
		if type(msg.based_on) == "number" and p.died_seq > msg.based_on then
			return result(msg, "stale", {reason = "player_changed", since = p.died_seq})
		end
		local ceiling, gear = D.encounter_ceiling(player)
		local budget = tonumber(args.budget) or ceiling
		local clamped = budget > ceiling
		budget = math.min(budget, ceiling)
		local left = D.cfg.points_per_hour - logic.window_sum(D.points, now)
		if budget > left then
			return refuse(msg, "budget", {asked = budget, points_left = left,
				points_per_hour = D.cfg.points_per_hour})
		end
		local slots = math.min(D.cfg.max_entities - D.live_owned(),
			D.cfg.max_entities_per_player - D.live_owned(name))
		if slots <= 0 then
			return refuse(msg, "entity_cap", {live = D.live_owned(), live_near = D.live_owned(name)})
		end
		local list, why, detail = candidates(msg, player, name)
		if not list then
			return refuse(msg, why, detail)
		end
		local names, cost = logic.compose(list, budget, slots, random)
		if #names == 0 then
			return refuse(msg, "budget_too_small", {budget = budget, gear_score = gear.score})
		end
		-- Pacing comes after the cheap checks, so a queued intent is one that
		-- would have been accepted, and is checked again when released.
		local when = args.when or "next_build_up"
		if not from_queue and p.pacing.phase ~= "build_up" then
			if when == "now" then
				return refuse(msg, "pacing", {phase = p.pacing.phase})
			end
			local valid = math.min(tonumber(args.valid_for_s) or D.cfg.queue_s, D.cfg.queue_s)
			D.queue[#D.queue + 1] = {msg = msg, id = msg.req, type = msg.type, args = args,
				until_t = now + valid, player = name}
			return result(msg, "queued", {phase = p.pacing.phase, valid_for_s = valid})
		end
		local dist = type(args.distance) == "table" and args.distance or {12, 24}
		local dmin = math.max(6, tonumber(dist[1]) or 12)
		local dmax = math.min(48, math.max(dmin + 2, tonumber(dist[2]) or 24))
		local hidden = args.hidden ~= false
		local leash = math.max(10, math.min(tonumber(args.leash_s) or D.cfg.leash, 600))
		D.encounter_counter = (D.encounter_counter or 0) + 1
		local eid = "e" .. D.encounter_counter
		local e = {id = eid, act = msg.req, player = name, guids = {}, state = "live",
			started = now, leash_until = now + leash, alive = 0}
		local spawned, anchor, last_why, spent = {}, nil, nil, 0
		for _, mob in ipairs(names) do
			local pos, why = find_place(player, mob, dmin, dmax, hidden, anchor)
			if pos then
				local obj, err = D.mobs.spawn(pos, mob)
				if obj then
					anchor = anchor or pos
					local guid = obj:get_guid()
					D.owned[guid] = {kind = "encounter", guid = guid, act = msg.req, encounter = eid,
						target = name, mob = mob, region = D.region_id(pos), spawned_at = now,
						may_target = D.may_target}
					D.mobs.apply_target(obj)
					e.guids[#e.guids + 1] = guid
					spawned[#spawned + 1] = {guid = guid, mob = mob, pos = D.vec(pos)}
					spent = spent + logic.mob_cost(D.mobs.cost_parts(mob))
				else
					last_why = err
				end
			else
				last_why = why
			end
		end
		if #spawned == 0 then
			return refuse(msg, "no_place", {last = last_why})
		end
		logic.window_add(D.points, now, spent)
		e.alive = #spawned
		D.encounters[eid] = e
		D.undo[msg.req] = {type = "encounter", encounter = eid}
		D.emit("encounter_started", {"player:" .. name},
			{encounter = eid, act = msg.req, mobs = spawned, cost = spent}, player:get_pos())
		return result(msg, from_queue and "completed" or "accepted", {
			encounter = eid, mobs = spawned, cost = spent, asked = tonumber(args.budget),
			ceiling = ceiling, clamped_to_gear = clamped or nil, gear_score = gear.score,
			points_left = left - spent, leash_s = leash,
			partial = #spawned < #names or nil, unplaced_reason = #spawned < #names and last_why or nil,
		}, {effects = {encounter = eid, mobs = spawned}, undo = D.undo[msg.req]})
	end

	-- Characters ---------------------------------------------------------------

	local function npc_obj(npc)
		return npc and obj_by_guid(npc.guid)
	end

	local function cast_npc(msg)
		local args, now = msg.args, D.now()
		local name = logic.clean_text(args.name)
		if not logic.valid_name(name) then
			return refuse(msg, "schema", {detail = "name: 2 to 24 letters, spaces, ' or -"})
		end
		-- A character must never pass for a player.
		if core.player_exists(name) or core.player_exists(name:lower()) then
			return refuse(msg, "name_taken")
		end
		if D.npcs[name:lower()] and npc_obj(D.npcs[name:lower()]) then
			return refuse(msg, "name_in_use")
		end
		local near = player_name(args.near)
		local player = near and core.get_player_by_name(near)
		local p = near and D.players[near]
		if not player or not p then
			return refuse(msg, "not_online", {near = near})
		end
		if p.optout then
			return refuse(msg, "opted_out", {near = near})
		end
		if not D.mobs then
			return refuse(msg, "no_adapter")
		end
		local npc = {name = name, act = msg.req, cast_at = now}
		if type(args.guid) == "string" then
			local obj = obj_by_guid(args.guid)
			local e = obj and obj:get_luaentity()
			if not obj or not D.mobs.is_mob(e) then
				return refuse(msg, "unknown_entity")
			end
			if vector.distance(obj:get_pos(), player:get_pos()) > D.cfg.earshot then
				return refuse(msg, "out_of_earshot")
			end
			for _, other in pairs(D.npcs) do
				if other.guid == args.guid then
					return refuse(msg, "already_cast", {as = other.name})
				end
			end
			npc.guid, npc.mob, npc.bound = args.guid, e.name, true
			npc.old_name = D.mobs.current_name(obj)
			D.mobs.set_name(obj, name)
			if args.hold == true then
				D.mobs.freeze(obj)
				npc.held = true
			end
		else
			local mob = type(args.mob) == "string" and args.mob or "mobs_mc:villager"
			if not D.mobs.known(mob) then
				return refuse(msg, "unknown_mob", {mob = mob})
			end
			if D.cfg.deny[mob] then
				return refuse(msg, "denied", {mob = mob})
			end
			-- A monster is never a character, except an armed one, which is
			-- an encounter by another name and is charged and paced as one:
			-- held until ordered to attack, and only then dangerous.
			local armed_cost
			if D.mobs.category(mob) == "monster" then
				if args.armed ~= true then
					return refuse(msg, "hostile_npc", {mob = mob})
				end
				if p.pacing.phase ~= "build_up" then
					return refuse(msg, "pacing", {phase = p.pacing.phase})
				end
				armed_cost = logic.mob_cost(D.mobs.cost_parts(mob))
				local ceiling = D.encounter_ceiling(player)
				if armed_cost > ceiling then
					return refuse(msg, "over_ceiling", {cost = armed_cost, ceiling = ceiling})
				end
				local left = D.cfg.points_per_hour - logic.window_sum(D.points, now)
				if armed_cost > left then
					return refuse(msg, "budget", {cost = armed_cost, points_left = left})
				end
			end
			if D.live_owned() >= D.cfg.max_entities
					or D.live_owned(near) >= D.cfg.max_entities_per_player then
				return refuse(msg, "entity_cap")
			end
			-- distance is [min, max] as everywhere else; a bare number is
			-- still taken as the near edge.
			local dist = type(args.distance) == "table" and args.distance or {args.distance}
			local d = math.max(2, math.min(tonumber(dist[1]) or 4, 12))
			local dmax = math.max(d + 1, math.min(tonumber(dist[2]) or d + 3, 16))
			local pos, why = find_place(player, mob, d, dmax, false, nil)
			if not pos then
				return refuse(msg, "no_place", {last = why})
			end
			local obj = D.mobs.spawn(pos, mob)
			if not obj then
				return refuse(msg, "spawn_failed")
			end
			npc.guid, npc.mob = obj:get_guid(), mob
			D.owned[npc.guid] = {kind = "npc", guid = npc.guid, act = msg.req, name = name, near = near,
				mob = mob, region = D.region_id(pos), spawned_at = now, may_target = D.may_target}
			if armed_cost then
				logic.window_add(D.points, now, armed_cost)
				npc.armed, npc.cost = true, armed_cost
			end
			D.mobs.set_name(obj, name)
			if args.hold ~= false or armed_cost then
				D.mobs.freeze(obj)
				local to = vector.subtract(player:get_pos(), pos)
				obj:set_yaw(math.atan2(-to.x, to.z))
				npc.held = true
			end
		end
		D.npcs[name:lower()] = npc
		D.undo[msg.req] = {type = "npc", key = name:lower()}
		local obj = npc_obj(npc)
		D.emit("npc_cast", {"npc:" .. name, "player:" .. near},
			{npc = name, guid = npc.guid, mob = npc.mob, bound = npc.bound or false},
			obj and obj:get_pos())
		return result(msg, "accepted", {npc = name, guid = npc.guid, mob = npc.mob,
			pos = obj and D.vec(obj:get_pos()), held = npc.held or false,
			armed = npc.armed or nil, cost = npc.cost},
			{effects = {npc = name, guid = npc.guid}})
	end

	local function uncast(key)
		local npc = D.npcs[key]
		if not npc then
			return false
		end
		if D.cancel_order then
			D.cancel_order(key)
		end
		local obj = npc_obj(npc)
		if npc.bound then
			if obj then
				D.mobs.set_name(obj, npc.old_name)
				if npc.held then
					D.mobs.release(obj)
				end
			end
		else
			remove_owned(npc.guid)
			D.owned[npc.guid] = nil
		end
		D.npcs[key] = nil
		return true
	end

	-- Speech ---------------------------------------------------------------

	local NARRATOR = "#a9c4ff"
	local SPEAKER = "#f0d070"

	local function speak(msg)
		local args, now = msg.args, D.now()
		local text = logic.clean_text(args.text)
		if not text or text == "" then
			return refuse(msg, "schema", {detail = "text is required"})
		end
		if #text > D.cfg.speech_chars then
			return refuse(msg, "too_long", {max = D.cfg.speech_chars})
		end
		local as = type(args.as) == "string" and args.as or "narrator"
		local to = type(args.to) == "string" and player_name(args.to) or nil
		if not to then
			return refuse(msg, "schema", {detail = "to: a player, \"near\" or \"all\""})
		end
		local listeners, line = {}, nil
		local npc, ruleset_sp
		local lines = {}  -- per listener, for a ruleset speaker near or far
		if as:lower() == "narrator" then
			line = core.colorize(NARRATOR, "[Narrator] " .. text)
			if to == "all" then
				for name, p in pairs(D.players) do
					if not p.optout then
						listeners[#listeners + 1] = name
					end
				end
			elseif to == "near" then
				return refuse(msg, "schema", {detail = "narration goes to a player or \"all\""})
			else
				local p = D.players[to]
				if not p then
					return refuse(msg, "not_online", {to = to})
				end
				if p.optout then
					return refuse(msg, "opted_out", {to = to})
				end
				listeners[1] = to
			end
		elseif not D.npcs[as:lower()] then
			-- Not a cast character: a ruleset's own character, if one
			-- knows the name (rulesets.lua). It reaches players within
			-- earshot of its body, as a cast character does, and from afar
			-- only the players its ruleset names in remote.
			local sp, why = D.ruleset_speaker(as)
			if not sp then
				return refuse(msg, why or "unknown_speaker", {as = as})
			end
			ruleset_sp = sp
			local near_line = core.colorize(SPEAKER, sp.name .. " (NPC):") .. " " .. text
			local far_line = core.colorize(SPEAKER, sp.label .. " (NPC):") .. " " .. text
			if to == "all" then
				to = "near"
			end
			for name, p in pairs(D.players) do
				local player = core.get_player_by_name(name)
				if player and not p.optout and (to == "near" or to == name) then
					if sp.pos and vector.distance(player:get_pos(), sp.pos) <= D.cfg.earshot then
						listeners[#listeners + 1] = name
						lines[name] = near_line
					elseif sp.remote[name] then
						listeners[#listeners + 1] = name
						lines[name] = far_line
					end
				end
			end
			if to ~= "near" then
				local p = D.players[to]
				if not p then
					return refuse(msg, "not_online", {to = to})
				elseif p.optout then
					return refuse(msg, "opted_out", {to = to})
				elseif #listeners == 0 then
					return refuse(msg, "out_of_earshot", {to = to, earshot = D.cfg.earshot})
				end
			end
			if #listeners > 0 then
				local ok, reason, detail = D.ruleset_speak_check(sp, text, listeners)
				if not ok then
					return refuse(msg, "rules", {rule = reason, detail = detail})
				end
			end
		else
			npc = D.npcs[as:lower()]
			local obj = npc_obj(npc)
			if not obj then
				return refuse(msg, "speaker_gone", {as = npc.name})
			end
			line = core.colorize(SPEAKER, npc.name .. " (NPC):") .. " " .. text
			local spos = obj:get_pos()
			-- "all" from a character means everyone within its earshot, the
			-- same word as the narrator's; "near" is kept as its old name.
			if to == "all" then
				to = "near"
			end
			for name, p in pairs(D.players) do
				local player = core.get_player_by_name(name)
				if player and not p.optout
						and vector.distance(player:get_pos(), spos) <= D.cfg.earshot
						and (to == "near" or to == name) then
					listeners[#listeners + 1] = name
				end
			end
			if to ~= "near" then
				local p = D.players[to]
				if not p then
					return refuse(msg, "not_online", {to = to})
				elseif p.optout then
					return refuse(msg, "opted_out", {to = to})
				elseif #listeners == 0 then
					return refuse(msg, "out_of_earshot", {to = to, earshot = D.cfg.earshot})
				end
			end
		end
		if #listeners == 0 then
			return refuse(msg, "no_listeners")
		end
		local speaker_key = npc and npc.name or ruleset_sp and ruleset_sp.name or "narrator"
		if not logic.rate_allow(D.speech_rate, speaker_key, now) then
			return refuse(msg, "rate", {per_minute = D.cfg.speech_per_minute, speaker = speaker_key})
		end
		local delivered, skipped = {}, {}
		for _, name in ipairs(listeners) do
			if logic.rate_allow(D.listener_rate, name, now) then
				core.chat_send_player(name, lines[name] or line)
				delivered[#delivered + 1] = name
				if npc then
					local rec = logic.memory_get(D.memory, npc.name, name, now)
					rec.spoken = rec.spoken + 1
					rec.last_seen = now
				end
			else
				skipped[#skipped + 1] = name
			end
		end
		if #delivered == 0 then
			return refuse(msg, "rate", {per_minute = D.cfg.listener_per_minute, listeners = skipped})
		end
		if ruleset_sp then
			D.ruleset_spoken(ruleset_sp, text, delivered)
		end
		return result(msg, "completed", {as = npc and npc.name or ruleset_sp and ruleset_sp.name
			or "narrator", ruleset = ruleset_sp and ruleset_sp.ruleset.name or nil,
			delivered = delivered, skipped_rate = #skipped > 0 and skipped or nil},
			{effects = {text = text, delivered = delivered}, players = delivered})
	end

	-- Memory -----------------------------------------------------------------

	local function memory_view(rec)
		if not rec then
			return {known = false}
		end
		local facts = {}
		for _, f in ipairs(rec.facts) do
			facts[#facts + 1] = {text = f.text, source = f.source,
				ago_s = math.floor(D.now() - f.t)}
		end
		return {known = true, met_s_ago = math.floor(D.now() - rec.first_met),
			last_seen_s_ago = math.floor(D.now() - rec.last_seen),
			spoken = rec.spoken, addressed = rec.addressed,
			disposition = rec.disposition, facts = facts}
	end
	D.memory_view = memory_view

	local limits = function()
		return {facts = 16, model_lines = D.cfg.memory_lines, model_chars = D.cfg.memory_chars}
	end

	local function remember(msg)
		local args, now = msg.args, D.now()
		local name = player_name(args.player)
		if not name then
			return refuse(msg, "schema", {detail = "player is required"})
		end
		if D.opted_out(name) then
			return refuse(msg, "opted_out", {player = name})
		end
		local npc = type(args.npc) == "string" and D.npcs[args.npc:lower()]
		if not npc then
			return refuse(msg, "unknown_speaker", {npc = args.npc})
		end
		local rec = logic.memory_get(D.memory, npc.name, name, now)
		local undo = {type = "memory", npc = npc.name, player = name,
			disposition = rec.disposition}
		if args.fact ~= nil then
			if not D.cfg.memory_text then
				return refuse(msg, "memory_text_off")
			end
			local fact = logic.clean_text(args.fact)
			if not fact or fact == "" then
				return refuse(msg, "schema", {detail = "fact must be text"})
			end
			local ok, why = logic.memory_fact(rec, fact, "model", now, limits())
			if not ok then
				return refuse(msg, why, {max = D.cfg.memory_chars})
			end
			undo.fact = fact
		end
		if args.disposition ~= nil then
			rec.disposition = logic.clamp_disposition(args.disposition)
		end
		D.undo[msg.req] = undo
		return result(msg, "completed", {npc = npc.name, player = name, memory = memory_view(rec)},
			{effects = {fact = undo.fact, disposition = rec.disposition}, players = {name}})
	end

	-- A cast character overhears a player kill something near it: a
	-- structured fact from an event, no model involved.
	function D.on_kill(mob, killer, pos, rec)
		local now = D.now()
		if rec and rec.kind == "npc" and killer and not D.opted_out(killer) then
			local m = logic.memory_get(D.memory, rec.name, killer, now)
			logic.memory_fact(m, "was killed by " .. killer, "event", now, limits())
		end
		if not killer or D.opted_out(killer) then
			return
		end
		for _, npc in pairs(D.npcs) do
			local obj = npc_obj(npc)
			if obj and obj:get_guid() ~= (rec and rec.guid) and
					vector.distance(obj:get_pos(), pos) <= D.cfg.earshot then
				local m = logic.memory_get(D.memory, npc.name, killer, now)
				logic.memory_fact(m, "saw " .. killer .. " kill a " .. mob:gsub("^.*:", ""),
					"event", now, limits())
				m.last_seen = now
			end
		end
	end

	-- Called by events.lua for every public chat line. Returns true when the
	-- line was addressed to a character within earshot.
	function D.npc_addressed(name, message)
		local player = core.get_player_by_name(name)
		if not player then
			return false
		end
		for _, npc in pairs(D.npcs) do
			local obj = npc_obj(npc)
			if obj and logic.addressed_to(message, npc.name)
					and vector.distance(obj:get_pos(), player:get_pos()) <= D.cfg.earshot then
				local now = D.now()
				local rec = logic.memory_get(D.memory, npc.name, name, now)
				rec.addressed = rec.addressed + 1
				rec.last_seen = now
				D.emit("npc_addressed", {"player:" .. name, "npc:" .. npc.name},
					{npc = npc.name, text = message:sub(1, 280), memory = memory_view(rec)},
					player:get_pos())
				return true
			end
		end
		return false
	end

	-- Undo and stop ------------------------------------------------------------

	local function undo(msg)
		local id = msg.args.id
		local u = type(id) == "string" and D.undo[id]
		if not u then
			return refuse(msg, "unknown_action", {target = id})
		end
		local fields = {target = id}
		if u.type == "encounter" then
			local e = D.encounters[u.encounter]
			if e and e.state == "live" then
				end_encounter(e, "undone")
			end
			fields.encounter = u.encounter
		elseif u.type == "npc" then
			fields.npc = u.key
			uncast(u.key)
		elseif u.type == "order" then
			fields.npc = u.key
			D.cancel_order(u.key)
		elseif u.type == "structure" then
			if u.npc then
				fields.npc = u.npc
				D.cancel_order(u.npc)
			end
			for k, v in pairs(D.undo_structure(u)) do
				fields[k] = v
			end
		elseif u.type == "reward" then
			for k, v in pairs(D.undo_reward(u)) do
				fields[k] = v
			end
		elseif u.type == "ruleset" then
			for k, v in pairs(D.ruleset_undo(u)) do
				fields[k] = v
			end
		elseif u.type == "memory" then
			local rec = logic.memory_get(D.memory, u.npc, u.player)
			if rec then
				if u.fact then
					for i = #rec.facts, 1, -1 do
						if rec.facts[i].source == "model" and rec.facts[i].text == u.fact then
							table.remove(rec.facts, i)
							break
						end
					end
				end
				rec.disposition = u.disposition
			end
		end
		D.undo[id] = nil
		return result(msg, "undone", fields, {effects = fields})
	end

	-- Stop: every director owned entity removed, every cast name taken back,
	-- the queue cancelled, and every intent refused until /director start.
	function D.stop(by, why)
		for _, e in pairs(D.encounters) do
			end_encounter(e, "stopped")
		end
		for key in pairs(D.npcs) do
			uncast(key)
		end
		for guid in pairs(D.owned) do
			remove_owned(guid)
		end
		D.owned = {}
		for _, q in ipairs(D.queue) do
			D.send_result(q.msg, {id = q.id, type = q.type, status = "interrupted",
				reason = "stopped"})
		end
		D.queue = {}
		-- A ruleset ends what it started for the director.
		D.rulesets_stop(by, why)
		D.stopped = by
		D.save_meta()
		D.audit({kind = "stop", by = by, reason = why})
		D.emit("director_stopped", {}, {by = by})
	end

	function D.start(by)
		D.stopped = nil
		D.save_meta()
		D.audit({kind = "start", by = by})
		D.emit("director_started", {}, {by = by})
	end

	-- Dispatch -----------------------------------------------------------------

	local INTENTS = {
		stage_encounter = stage_encounter,
		cast_npc = cast_npc,
		order = function(msg)
			return D.order_intent(msg, result, refuse)
		end,
		speak = speak,
		remember = remember,
		grant_reward = function(msg)
			return D.grant_reward_intent(msg, result, refuse)
		end,
		place_structure = function(msg)
			return D.place_structure_intent(msg, result, refuse, random)
		end,
		undo = undo,
		end_encounter = function(msg)
			local id = msg.args.id
			local e = D.encounters[id]
			if not e then
				for _, cand in pairs(D.encounters) do
					if cand.act == id then
						e = cand
					end
				end
			end
			if not e or e.state ~= "live" then
				return refuse(msg, "unknown_encounter", {target = id})
			end
			end_encounter(e, "ended_by_director")
			return result(msg, "completed", {encounter = e.id})
		end,
		stop = function(msg)
			if D.stopped then
				return result(msg, "completed", {already = true})
			end
			D.stop("director", msg.reason)
			return result(msg, "completed", {stopped = true})
		end,
	}

	local QUERIES = {
		capabilities = function() return D.capabilities() end,
		catalogue = function(args) return D.catalogue(args) end,
		status = function() return D.status() end,
		player = function(args)
			local name = player_name(args.name)
			local s = D.player_summary(name or "")
			if s.region and not s.opted_out then
				s.region_summary = D.region_summary(s.region)
			end
			return s
		end,
		players = function()
			local out = {}
			for name in pairs(D.players) do
				out[#out + 1] = D.player_summary(name)
			end
			return out
		end,
		region = function(args)
			if type(args.id) == "string" then
				return D.region_summary(args.id) or {error = "bad region id"}
			end
			return {error = "region wants id"}
		end,
		memory = function(args)
			local npc = type(args.npc) == "string" and D.npcs[args.npc:lower()]
			local name = player_name(args.player)
			if name and D.opted_out(name) then
				return {opted_out = true}
			end
			local npc_name = npc and npc.name or args.npc
			if not name then
				local out = {}
				for player, rec in pairs(D.memory[npc_name] or {}) do
					if not D.opted_out(player) then
						out[player] = memory_view(rec)
					end
				end
				return {npc = npc_name, players = out}
			end
			return {npc = npc_name, player = name,
				memory = memory_view(logic.memory_get(D.memory, npc_name or "", name))}
		end,
	}

	-- The names a ruleset may not take (rulesets.lua).
	D.builtin_intents, D.builtin_queries = {}, {}
	for k in pairs(INTENTS) do
		D.builtin_intents[k] = true
	end
	for k in pairs(QUERIES) do
		D.builtin_queries[k] = true
	end

	local function ruleset_intent(msg)
		return D.ruleset_act(msg, result, refuse)
	end

	-- msg: {id, kind = "act" | "query", req, type, args, based_on, reason}.
	-- Returns the body of the result or reply.
	function D.handle(msg)
		msg.args = type(msg.args) == "table" and msg.args or {}
		msg.req = tostring(msg.req or msg.id)
		if msg.kind == "query" then
			local q = QUERIES[msg.type]
			if not q and D.ruleset_queries[msg.type] then
				return D.ruleset_query(msg)
			end
			if not q then
				return {id = msg.req, type = msg.type, status = "error", reason = "unknown_query"}
			end
			return {id = msg.req, type = msg.type, status = "ok", body = q(msg.args)}
		end
		local intent = INTENTS[msg.type] or (D.ruleset_intents[msg.type] and ruleset_intent)
		if not intent then
			return refuse(msg, "unknown_intent")
		end
		if msg.scope and msg.scope ~= "gm" then
			return refuse(msg, "not_in_scope")
		end
		if D.stopped and msg.type ~= "undo" and msg.type ~= "stop" then
			return refuse(msg, "stopped", {by = D.stopped})
		end
		local ok, out = pcall(intent, msg)
		if not ok then
			core.log("warning", "[goanna director] " .. msg.type .. " failed: " .. tostring(out))
			return refuse(msg, "error", {detail = tostring(out):sub(1, 200)})
		end
		return out
	end

	-- Per player permissions for the targeting rule, refreshed once a second
	-- so the rule itself, which runs every step for every owned mob, is a
	-- table lookup. Never a player who opted out or stands in a protected
	-- area.
	function D.may_target(name)
		local p = D.players[name]
		return p ~= nil and p.target_ok == true and not D.stopped
	end

	D.tick_hooks[#D.tick_hooks + 1] = function(now)
		for name, p in pairs(D.players) do
			local player = core.get_player_by_name(name)
			p.target_ok = player ~= nil and not p.optout
				and not core.is_protected(vector.round(player:get_pos()), "")
		end
		for _, e in pairs(D.encounters) do
			if e.state == "live" then
				local alive = 0
				for _, guid in ipairs(e.guids) do
					local rec = D.owned[guid]
					local obj = rec and not rec.gone and obj_by_guid(guid)
					if obj then
						alive = alive + 1
						D.mobs.apply_target(obj)
					end
				end
				e.alive = alive
				local p = D.players[e.player]
				if alive == 0 then
					end_encounter(e, "defeated")
				elseif not p then
					end_encounter(e, "player_left")
				elseif p.optout then
					end_encounter(e, "opted_out")
				elseif now >= e.leash_until then
					end_encounter(e, "leash")
				end
			end
		end
		-- Owned characters that died or vanished stop being speakers.
		for key, npc in pairs(D.npcs) do
			local rec = D.owned[npc.guid]
			if rec and rec.gone then
				D.owned[npc.guid] = nil
				D.npcs[key] = nil
			end
		end
		-- Queued intents: released at a build up, expired after their time.
		local keep = {}
		for _, q in ipairs(D.queue) do
			local p = D.players[q.player]
			if now >= q.until_t then
				D.send_result(q.msg, {id = q.id, type = q.type, status = "expired"})
				D.audit({kind = "intent", id = q.id, type = q.type, outcome = "expired"})
			elseif not p then
				D.send_result(q.msg, {id = q.id, type = q.type, status = "expired",
					reason = "not_online"})
			elseif not D.stopped and (q.ready and q.ready()
					or not q.ready and p.pacing.phase == "build_up") then
				local out = (q.run or stage_encounter)(q.msg, true)
				D.send_result(q.msg, out)
			else
				keep[#keep + 1] = q
			end
		end
		D.queue = keep
	end

	function D.on_death(name)
		for _, e in pairs(D.encounters) do
			if e.state == "live" and e.player == name then
				end_encounter(e, "player_died")
			end
		end
	end

	function D.on_leave(name)
		for _, e in pairs(D.encounters) do
			if e.state == "live" and e.player == name then
				end_encounter(e, "player_left")
			end
		end
	end
end
