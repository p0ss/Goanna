-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Orders for cast characters: high level goals a character carries out by
-- itself, so the model says what and the character works out how.
--
--   hold         stand still (optionally facing a target)
--   watch        stand, turning to face a target as it moves
--   go_to        walk to a point or a target, then stay there
--   stay         keep to a point, walking back when pushed or lured away
--   patrol       walk a loop of points, pausing at each
--   follow       keep within a distance range of a target ("hang back" is
--                the same with a larger range)
--   attack       fight a target until it dies, is lost, or the leash ends
--   hold_item    show an item in hand (mobs that can wield)
--   offer_trade  open the character's trades for a player (villagers)
--   build        put up a schematic node by node (structures.lua checks
--                the site, charges the budget and keeps the undo snapshot)
--   deliver      carry a reward to a player and drop it in front of them
--                (given by grant_reward, not ordered directly)
--
-- Movement uses mcl_mobs' own pathfinder through the adapter, with the
-- character's AI still off (held), so it never wanders off an order. An
-- attack lets the AI run with the director's rule as its only target source:
-- it fights whom it was ordered to and nobody else. Attacking a player is an
-- encounter by another name, so it passes the encounter's checks: the
-- player's gear ceiling, the hourly points, the build up phase and opt out.
--
-- Each order ends with an npc_order event (arrived, done, failed, lost,
-- leash, replaced) so the model hears how it went without polling.

return function(D)
	local logic = D.logic
	local STEP = 0.25
	local REPATH = 2.0          -- seconds between path refreshes on a moving target
	local STUCK = 20            -- seconds without progress before go_to fails
	-- Opening a trade puts a window on a player's screen, so it is rare.
	local trade_rate = logic.rate(3)

	local function obj_of(npc)
		return npc and D.obj_by_guid(npc.guid)
	end

	-- A target is a player name ("player:" optional), a cast character's
	-- name, or an entity guid. Returns the object and a label.
	local function resolve(target)
		if type(target) ~= "string" or target == "" then
			return nil
		end
		local name = target:gsub("^player:", "")
		local player = core.get_player_by_name(name)
		if player then
			return player, "player:" .. name, name
		end
		local npc = D.npcs[name:lower()]
		if npc then
			local obj = obj_of(npc)
			return obj, "npc:" .. npc.name
		end
		local obj = core.objects_by_guid[target]
		if obj and obj:is_valid() and obj:get_pos() then
			return obj, "entity:" .. target
		end
		return nil
	end

	local function point(v)
		if type(v) == "table" and tonumber(v[1]) and tonumber(v[2]) and tonumber(v[3]) then
			return vector.new(tonumber(v[1]), tonumber(v[2]), tonumber(v[3]))
		end
		return nil
	end

	local function finish(npc, outcome, extra)
		local o = npc.order
		if not o then
			return
		end
		local body = {npc = npc.name, order = o.kind, act = o.act, outcome = outcome}
		for k, v in pairs(extra or {}) do
			body[k] = v
		end
		local obj = obj_of(npc)
		D.emit("npc_order", {"npc:" .. npc.name}, body, obj and obj:get_pos())
	end

	local function end_attack(npc)
		local obj = obj_of(npc)
		local rec = D.owned[npc.guid]
		if rec then
			rec.target, rec.target_guid = nil, nil
		end
		if obj then
			D.mobs.attack_mode(obj, false)
		end
	end

	local function put_down(npc)
		local obj = obj_of(npc)
		if obj and D.mobs.can_wield(obj) then
			D.mobs.wield(obj, "")
		end
	end

	-- After an order ends by itself: stay where it stands, with no
	-- "replaced" event, since nothing replaced it.
	local function settle(npc, obj, act, now)
		npc.order = {kind = "stay", act = act, at = vector.round(obj:get_pos()), started = now,
			last_progress = now, best = 0}
	end

	-- Replace whatever the character is doing.
	local function set_order(npc, order)
		if npc.order and npc.order.kind == "attack" then
			end_attack(npc)
		end
		if npc.order and (npc.order.kind == "build" or npc.order.kind == "deliver") then
			put_down(npc)
		end
		if npc.order then
			finish(npc, "replaced", {by = order and order.kind})
		end
		local obj = obj_of(npc)
		if obj then
			D.mobs.halt(obj)
			if order and order.kind ~= "attack" then
				D.mobs.freeze(obj)
				npc.held = true
			end
		end
		npc.order = order
	end

	-- Checks for attacking a player, as stage_encounter makes them.
	local function may_attack_player(msg, npc, name)
		local player = core.get_player_by_name(name)
		local p = D.players[name]
		if not player or not p then
			return false, "not_online"
		end
		if p.optout or not D.may_target(name) then
			return false, "opted_out"
		end
		if p.pacing.phase ~= "build_up" then
			return false, "pacing", {phase = p.pacing.phase}
		end
		local cost = logic.mob_cost(D.mobs.cost_parts(npc.mob))
		local ceiling = D.encounter_ceiling(player)
		if cost > ceiling then
			return false, "over_ceiling", {cost = cost, ceiling = ceiling}
		end
		local left = D.cfg.points_per_hour - logic.window_sum(D.points, D.now())
		if cost > left then
			return false, "budget", {cost = cost, points_left = left}
		end
		return true, nil, {cost = cost}
	end

	-- The intent: {npc, order, target, at, points, distance, pause_s, item,
	-- profession, leash_s}.
	function D.order_intent(msg, result, refuse)
		local args = msg.args
		local npc = type(args.npc) == "string" and D.npcs[args.npc:lower()]
		if not npc then
			return refuse(msg, "unknown_speaker", {npc = args.npc})
		end
		local obj = obj_of(npc)
		if not obj then
			return refuse(msg, "speaker_gone", {npc = npc.name})
		end
		local kind = args.order
		local now = D.now()
		local o = {kind = kind, act = msg.req, started = now}

		if kind == "hold" or kind == "watch" then
			if args.target then
				local t = resolve(args.target)
				if not t then
					return refuse(msg, "unknown_target", {target = args.target})
				end
				o.target = args.target
			elseif kind == "watch" then
				return refuse(msg, "schema", {detail = "watch needs a target"})
			end
		elseif kind == "go_to" or kind == "stay" then
			o.at = point(args.at)
			if not o.at and args.target then
				local t = resolve(args.target)
				if not t then
					return refuse(msg, "unknown_target", {target = args.target})
				end
				o.at = vector.round(t:get_pos())
			end
			if not o.at then
				if kind == "go_to" then
					return refuse(msg, "schema", {detail = "go_to needs at [x,y,z] or a target"})
				end
				o.at = vector.round(obj:get_pos())
			end
			o.last_progress, o.best = now, math.huge
		elseif kind == "patrol" then
			o.points = {}
			for _, v in ipairs(type(args.points) == "table" and args.points or {}) do
				local p = point(v)
				if p then
					o.points[#o.points + 1] = p
				end
			end
			if #o.points == 0 then
				return refuse(msg, "schema", {detail = "patrol needs points [[x,y,z], ...]"})
			end
			if #o.points > 12 then
				return refuse(msg, "schema", {detail = "at most 12 patrol points"})
			end
			o.i, o.pause = 1, math.max(0, math.min(tonumber(args.pause_s) or 3, 60))
			o.last_progress, o.best = now, math.huge
		elseif kind == "follow" then
			local t = resolve(args.target)
			if not t then
				return refuse(msg, "unknown_target", {target = args.target})
			end
			local d = type(args.distance) == "table" and args.distance or {2, 5}
			o.target = args.target
			o.min = math.max(1, tonumber(d[1]) or 2)
			o.max = math.max(o.min + 1, math.min(tonumber(d[2]) or 5, 32))
		elseif kind == "attack" then
			if not D.mobs.can_attack(npc.mob) then
				return refuse(msg, "cannot_attack", {mob = npc.mob})
			end
			local t, label, pname = resolve(args.target)
			if not t then
				return refuse(msg, "unknown_target", {target = args.target})
			end
			local rec = D.owned[npc.guid]
			if not rec then
				return refuse(msg, "not_owned", {detail = "a bound mob cannot be ordered to attack"})
			end
			o.target = args.target
			o.leash_until = now + math.max(10, math.min(tonumber(args.leash_s) or 60, 300))
			if pname then
				local ok, why, detail = may_attack_player(msg, npc, pname)
				if not ok then
					return refuse(msg, why, detail)
				end
				logic.window_add(D.points, now, detail.cost)
				o.cost = detail.cost
				o.player = pname
			end
			set_order(npc, o)
			rec.target = pname
			rec.target_guid = not pname and t:get_guid() or nil
			rec.may_target = D.may_target
			D.mobs.attack_mode(obj, true)
			npc.held = false
			D.undo[msg.req] = {type = "order", key = npc.name:lower()}
			return result(msg, "accepted", {npc = npc.name, order = kind, target = label,
				cost = o.cost, leash_s = math.floor(o.leash_until - now)})
		elseif kind == "hold_item" then
			if not D.mobs.can_wield(obj) then
				return refuse(msg, "cannot_wield", {mob = npc.mob})
			end
			local item = type(args.item) == "string" and args.item or ""
			if item ~= "" and not core.registered_items[item] then
				return refuse(msg, "unknown_item", {item = item})
			end
			D.mobs.wield(obj, item)
			return result(msg, "completed", {npc = npc.name, item = item})
		elseif kind == "offer_trade" then
			if not D.mobs.can_trade(obj) then
				return refuse(msg, "cannot_trade", {mob = npc.mob})
			end
			local name = type(args.target) == "string" and args.target:gsub("^player:", "")
			local player = name and core.get_player_by_name(name)
			local p = name and D.players[name]
			if not player or not p then
				return refuse(msg, "not_online", {target = args.target})
			end
			if p.optout then
				return refuse(msg, "opted_out")
			end
			if vector.distance(obj:get_pos(), player:get_pos()) > D.cfg.earshot then
				return refuse(msg, "out_of_earshot")
			end
			local prof = args.profession
			if prof ~= nil then
				local known = false
				for _, v in ipairs(D.mobs.professions) do
					known = known or v == prof
				end
				if not known then
					return refuse(msg, "bad_profession", {professions = D.mobs.professions})
				end
			end
			if not logic.rate_allow(trade_rate, name, now) then
				return refuse(msg, "rate")
			end
			D.mobs.face(obj, player:get_pos())
			local ok, what = D.mobs.open_trade(obj, player, prof)
			if not ok then
				return refuse(msg, what)
			end
			return result(msg, "completed", {npc = npc.name, to = name, profession = what})
		elseif kind == "build" then
			local build_args = {}
			for k, v in pairs(args) do
				build_args[k] = v
			end
			build_args.near = args.near or args.target
			local plan, why, detail = D.plan_structure(build_args, D.random, true)
			if not plan then
				return refuse(msg, why, detail)
			end
			local snap, err = D.snapshot(plan.p1, plan.p2)
			if not snap then
				return refuse(msg, err, {hint = "the area is being loaded; try again in a few seconds"})
			end
			D.snapshots[msg.req] = snap
			logic.window_add(D.build_points, now, plan.nodes)
			o.queue, o.i, o.p1, o.snap = logic.build_order(plan.parsed.nodes), 1, plan.p1, msg.req
			o.at, o.credit, o.placed = plan.at, 0, 0
			o.rate = math.max(0.5, math.min(D.cfg.build_rate, 20))
			o.last_progress, o.best = now, math.huge
			set_order(npc, o)
			D.undo[msg.req] = {type = "structure", snap = msg.req, npc = npc.name:lower()}
			return result(msg, "accepted", {npc = npc.name, order = kind, source = plan.source,
				structure = plan.structure, at = D.vec(plan.at),
				box = {D.vec(plan.p1), D.vec(plan.p2)}, nodes = #o.queue,
				nodes_left = D.build_nodes_left(),
				eta_s = math.ceil(#o.queue / o.rate)},
				{effects = {at = D.vec(plan.at), source = plan.source, nodes = #o.queue}})
		else
			return refuse(msg, "schema", {detail = "order: hold, watch, go_to, stay, patrol, "
				.. "follow, attack, hold_item, offer_trade or build"})
		end
		set_order(npc, o)
		D.undo[msg.req] = {type = "order", key = npc.name:lower()}
		return result(msg, "accepted", {npc = npc.name, order = kind})
	end

	-- A reward carried to a player (rewards.lua). The character holds it
	-- on the way where its body can.
	function D.order_deliver(npc, player, stack, act)
		local obj = obj_of(npc)
		set_order(npc, {kind = "deliver", act = act, target = player, stack = stack:to_string(),
			started = D.now(), last_progress = D.now(), best = math.huge})
		if obj and D.mobs.can_wield(obj) then
			D.mobs.wield(obj, stack:get_name())
		end
	end

	-- Undo of an order: the character stops where it is.
	function D.cancel_order(key)
		local npc = D.npcs[key]
		if npc then
			set_order(npc, nil)
		end
	end

	-- One step of every character's order.
	local function walk(obj, o, goal, now, tol)
		local here = obj:get_pos()
		local d = vector.distance(here, goal)
		if d < (o.best or math.huge) - 0.5 then
			o.best, o.last_progress = d, now
		end
		if d <= (tol or 1.5) then
			D.mobs.halt(obj)
			return true, d
		end
		if not D.mobs.moving(obj) or now - (o.pathed or 0) > REPATH * 3 then
			D.mobs.walk_to(obj, goal, 1)
			o.pathed = now
		end
		D.mobs.pump_path(obj, STEP)
		return false, d
	end

	local function step(npc, now)
		local o = npc.order
		local obj = obj_of(npc)
		if not o or not obj then
			return
		end
		local kind = o.kind
		if kind == "hold" or kind == "watch" then
			if o.target then
				local t = resolve(o.target)
				if t then
					D.mobs.face(obj, t:get_pos())
				elseif kind == "watch" then
					finish(npc, "lost")
					set_order(npc, {kind = "hold", act = o.act, started = now})
				end
			end
		elseif kind == "go_to" or kind == "stay" then
			local arrived = walk(obj, o, o.at, now)
			if kind == "go_to" then
				if arrived then
					finish(npc, "arrived", {at = D.vec(o.at)})
					npc.order = {kind = "stay", act = o.act, at = o.at, started = now,
						last_progress = now, best = 0}
				elseif now - o.last_progress > STUCK then
					finish(npc, "failed", {why = "no_path", at = D.vec(o.at)})
					D.mobs.halt(obj)
					npc.order = {kind = "stay", act = o.act, at = vector.round(obj:get_pos()),
						started = now, last_progress = now, best = 0}
				end
			elseif arrived then
				o.last_progress, o.best = now, 0
				-- At its post it looks at whoever is near, as a sentry would.
				local near
				for _, pl in ipairs(core.get_connected_players()) do
					if vector.distance(pl:get_pos(), obj:get_pos()) < 8 then
						near = pl
					end
				end
				if near then
					D.mobs.face(obj, near:get_pos())
				end
			end
		elseif kind == "patrol" then
			if o.wait_until then
				if now < o.wait_until then
					return
				end
				o.wait_until = nil
				o.i = o.i % #o.points + 1
				o.best, o.last_progress = math.huge, now
			end
			local arrived = walk(obj, o, o.points[o.i], now)
			if arrived then
				o.wait_until = now + o.pause
			elseif now - o.last_progress > STUCK then
				-- A point it cannot reach is skipped, not the whole patrol.
				D.emit("npc_order", {"npc:" .. npc.name}, {npc = npc.name, order = "patrol",
					act = o.act, outcome = "skipped_point", point = D.vec(o.points[o.i])},
					obj:get_pos())
				o.wait_until = now
			end
		elseif kind == "follow" then
			local t = resolve(o.target)
			if not t then
				finish(npc, "lost")
				set_order(npc, {kind = "stay", act = o.act, at = vector.round(obj:get_pos()),
					started = now, last_progress = now, best = 0})
				return
			end
			local tp = t:get_pos()
			local d = vector.distance(obj:get_pos(), tp)
			if d > o.max then
				if not D.mobs.moving(obj) or now - (o.pathed or 0) > REPATH then
					-- Aim for a point at the near edge of the range, not the
					-- target itself, so it stops before bumping into it.
					local dir = vector.direction(tp, obj:get_pos())
					D.mobs.walk_to(obj, vector.add(tp, vector.multiply(dir, o.min + 0.5)), 1)
					o.pathed = now
				end
				D.mobs.pump_path(obj, STEP)
			elseif d <= o.min + 0.5 and D.mobs.moving(obj) then
				D.mobs.halt(obj)
			end
			if not D.mobs.moving(obj) then
				D.mobs.face(obj, tp)
			end
		elseif kind == "deliver" then
			local player = core.get_player_by_name(o.target)
			local drop_at
			if not player or D.opted_out(o.target) then
				finish(npc, "lost")
				D.rewards[o.act] = nil
				put_down(npc)
				settle(npc, obj, o.act, now)
				return
			end
			local pp = player:get_pos()
			local d = vector.distance(obj:get_pos(), pp)
			if d <= 3 then
				drop_at = vector.round(vector.add(obj:get_pos(), vector.multiply(
					vector.direction(obj:get_pos(), pp), 1)))
			elseif now - o.last_progress > STUCK then
				drop_at = vector.round(obj:get_pos())
			else
				local dir = vector.direction(pp, obj:get_pos())
				walk(obj, o, vector.add(pp, vector.multiply(dir, 2)), now, 2.5)
				return
			end
			D.mobs.halt(obj)
			D.mobs.face(obj, pp)
			local guid = D.drop_reward(drop_at, ItemStack(o.stack), o.act, o.target)
			finish(npc, guid and "delivered" or "failed", {to = o.target, at = D.vec(drop_at),
				reached = d <= 3})
			put_down(npc)
			settle(npc, obj, o.act, now)
		elseif kind == "build" then
			local snap = D.snapshots[o.snap]
			if not snap then
				finish(npc, "failed", {why = "undone"})
				put_down(npc)
				settle(npc, obj, o.act, now)
				return
			end
			local n = o.queue[o.i]
			if not n then
				finish(npc, "built", {placed = o.placed, at = D.vec(o.at)})
				put_down(npc)
				settle(npc, obj, o.act, now)
				return
			end
			-- Walk to the next node until within reach, then lay nodes at
			-- the build rate, facing each one. A node it cannot walk to is
			-- laid from where it stands, as a builder on a ladder would.
			local here = obj:get_pos()
			local function reach(t)
				return now < (o.anywhere_until or 0) or
					vector.distance({x = here.x, y = 0, z = here.z}, {x = t.x, y = 0, z = t.z}) <= 6
			end
			local target = vector.offset(o.p1, n[1], n[2], n[3])
			if not reach(target) then
				o.credit = 0
				if o.walking_for ~= o.i then
					o.walking_for, o.best, o.last_progress = o.i, math.huge, now
				end
				local dir = vector.direction(target, here)
				local stand = vector.add(target, vector.multiply(
					vector.normalize({x = dir.x, y = 0, z = dir.z}), 3))
				walk(obj, o, D.ground_at(stand.x, stand.z, here.y + 4, 2) or stand, now, 3)
				if now - o.last_progress > STUCK then
					o.anywhere_until = now + 10
				end
				return
			end
			if D.mobs.moving(obj) then
				D.mobs.halt(obj)
			end
			o.credit = math.min(o.credit + o.rate * STEP, o.rate)
			while o.credit >= 1 and o.queue[o.i] do
				n = o.queue[o.i]
				target = vector.offset(o.p1, n[1], n[2], n[3])
				if not reach(target) then
					break
				end
				-- Never lay a solid node where a player stands.
				local blocked = false
				if n[4] ~= "air" then
					for _, pl in ipairs(core.get_connected_players()) do
						local pp = vector.round(pl:get_pos())
						if pp.x == target.x and pp.z == target.z
								and (pp.y == target.y or pp.y + 1 == target.y) then
							blocked = true
						end
					end
				end
				if blocked then
					break
				end
				o.i = o.i + 1
				local cur = core.get_node(target)
				if not snap.changed[core.hash_node_position(target)] and cur.name ~= n[4]
						and cur.name ~= "ignore" and not core.is_protected(target, "") then
					core.set_node(target, {name = n[4], param2 = n[5] or 0})
					o.placed = o.placed + 1
					o.credit = o.credit - 1
					D.mobs.face(obj, target)
					if n[4] ~= "air" and o.wielding ~= n[4] and D.mobs.can_wield(obj) then
						D.mobs.wield(obj, n[4])
						o.wielding = n[4]
					end
				end
			end
			o.last_progress = now
		elseif kind == "attack" then
			local t = resolve(o.target)
			local outcome
			if not t then
				outcome = "done"
			elseif o.player and not D.may_target(o.player) then
				outcome = "lost"
			elseif now >= o.leash_until then
				outcome = "leash"
			end
			if outcome then
				end_attack(npc)
				finish(npc, outcome)
				npc.order = {kind = "stay", act = o.act, at = vector.round(obj:get_pos()),
					started = now, last_progress = now, best = 0}
				D.mobs.freeze(obj)
				npc.held = true
			end
		end
	end

	local timer = 0
	core.register_globalstep(function(dtime)
		timer = timer + dtime
		if timer < STEP then
			return
		end
		timer = 0
		if D.stopped then
			return
		end
		local now = D.now()
		for _, npc in pairs(D.npcs) do
			if npc.order then
				local ok, err = pcall(step, npc, now)
				if not ok then
					core.log("warning", "[goanna director] order " .. tostring(npc.order.kind)
						.. " for " .. npc.name .. " failed: " .. tostring(err))
					npc.order = nil
				end
			end
		end
	end)
end
