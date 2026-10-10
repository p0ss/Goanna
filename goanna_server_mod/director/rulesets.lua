-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Game rulesets (docs/design/director-design.md, "Game rulesets" and "Lua hook API").
--
-- A game or mod registers a ruleset with goanna_director.register_ruleset
-- at load time, and its intents and queries then run through the same
-- pipeline as the director's own: schema, scope, stop, budget, the
-- ruleset's rules, the place, pacing, apply with an undo record, audit.
-- The ruleset supplies the parts only it knows (its rules, how to apply and
-- undo), and the director keeps the parts it owes the operator and the
-- players: the schema check, the opt out, the stop, the hourly points, the
-- protection and exclusion checks, the pacing queue and the audit log.
--
-- Rulesets also say who may be spoken for (speaker) and which chat lines
-- are addressed to their own characters (addressed). Both are asked only
-- after the director's own cast characters, and speech for a ruleset's
-- speaker keeps the director's escape stripping, length cap, attribution
-- and rate limits.
--
-- Every hook is called through pcall: a ruleset's error refuses its own
-- intent or answers nothing, and never stops the director.

return function(D)
	local logic = D.logic

	D.rulesets = {}         -- name -> ruleset
	D.ruleset_order = {}    -- names in the order they were registered
	D.ruleset_intents = {}  -- intent name -> {ruleset, intent}
	D.ruleset_queries = {}  -- query name -> {ruleset, query}

	-- Registration is for load time, as the engine's own registrations are,
	-- so that the first hello already lists everything.
	local started = false
	core.after(0, function()
		started = true
	end)

	local function warn(what)
		core.log("warning", "[goanna director] " .. what)
	end

	local function call(rs, hook, ...)
		local ok, a, b, c = pcall(hook, ...)
		if not ok then
			warn("ruleset " .. rs.name .. ": " .. tostring(a))
			return false, nil, nil, tostring(a)
		end
		return true, a, b, c
	end

	local function opt_fn(def, key)
		local v = def[key]
		if v ~= nil and type(v) ~= "function" then
			return nil, key .. " must be a function"
		end
		return true
	end

	local function text(s, max)
		s = logic.clean_text(s)
		return s and s:sub(1, max) or nil
	end

	-- name, def -> true, or false and why. Nothing is registered unless the
	-- whole definition is sound.
	function D.register_ruleset(name, def)
		if started then
			return false, "rulesets are registered at load time"
		end
		if not logic.ident_ok(name) or name == "director" then
			return false, "a ruleset name is 1 to 32 of a-z, 0-9 and _, starting with a letter, " ..
				"and not \"director\""
		end
		if D.rulesets[name] then
			return false, "ruleset " .. name .. " is already registered"
		end
		if type(def) ~= "table" then
			return false, "the definition is a table"
		end
		for _, key in ipairs({"on_stop", "addressed", "speaker", "speak", "spoken", "undo"}) do
			local ok, why = opt_fn(def, key)
			if not ok then
				return false, why
			end
		end
		local rs = {
			name = name,
			description = text(def.description, 1000) or "",
			capabilities = type(def.capabilities) == "table" and def.capabilities or nil,
			intents = {},
			queries = {},
			on_stop = def.on_stop,
			addressed = def.addressed,
			speaker = def.speaker,
			speak = def.speak,
			spoken = def.spoken,
			undo = def.undo,
			points = logic.window(3600),
		}
		-- The operator's setting wins over the ruleset's own figure; with
		-- neither, the ruleset's costs are reported but not capped.
		local pph = tonumber(core.settings:get("goanna_director_" .. name .. "_points_per_hour") or "")
			or tonumber(def.points_per_hour)
		rs.points_per_hour = pph and math.max(0, pph) or nil

		local taken = {}
		for iname, it in pairs(type(def.intents) == "table" and def.intents or {}) do
			if not logic.ident_ok(iname) then
				return false, "intent name " .. tostring(iname) .. " is not a-z, 0-9 and _"
			end
			if D.builtin_intents[iname] or D.ruleset_intents[iname] then
				return false, "intent " .. iname .. " is already taken"
			end
			if type(it) ~= "table" or type(it.apply) ~= "function" then
				return false, "intent " .. iname .. " needs an apply function"
			end
			for _, key in ipairs({"scope", "rules", "places", "subjects", "undo"}) do
				local ok, why = opt_fn(it, key)
				if not ok then
					return false, "intent " .. iname .. ": " .. why
				end
			end
			if it.cost ~= nil and type(it.cost) ~= "number" and type(it.cost) ~= "function" then
				return false, "intent " .. iname .. ": cost is a number or a function"
			end
			local schema = it.schema or {type = "object", properties = {}}
			local ok, why = logic.schema_valid(schema)
			if not ok or schema.type ~= "object" then
				return false, "intent " .. iname .. ": schema: " .. (why or "the top is an object")
			end
			rs.intents[iname] = {
				name = iname,
				description = text(it.description, 1000) or "",
				schema = schema,
				scope = it.scope,
				cost = it.cost or 0,
				rules = it.rules,
				places = it.places,
				subjects = it.subjects,
				paced = it.paced == true,
				apply = it.apply,
				undo = it.undo,
				follow_up = type(it.follow_up) == "string" and it.follow_up or nil,
			}
			taken[iname] = true
		end
		for qname, q in pairs(type(def.queries) == "table" and def.queries or {}) do
			if not logic.ident_ok(qname) then
				return false, "query name " .. tostring(qname) .. " is not a-z, 0-9 and _"
			end
			if D.builtin_queries[qname] or D.ruleset_queries[qname] or taken[qname] then
				return false, "query " .. qname .. " is already taken"
			end
			if type(q) == "function" then
				q = {answer = q}
			end
			if type(q) ~= "table" or type(q.answer) ~= "function" then
				return false, "query " .. qname .. " needs an answer function"
			end
			local schema = q.schema or {type = "object", properties = {}}
			local ok, why = logic.schema_valid(schema)
			if not ok or schema.type ~= "object" then
				return false, "query " .. qname .. ": schema: " .. (why or "the top is an object")
			end
			rs.queries[qname] = {name = qname, description = text(q.description, 1000) or "",
				schema = schema, answer = q.answer}
		end

		D.rulesets[name] = rs
		D.ruleset_order[#D.ruleset_order + 1] = name
		for iname, it in pairs(rs.intents) do
			D.ruleset_intents[iname] = {ruleset = rs, intent = it}
		end
		for qname, q in pairs(rs.queries) do
			D.ruleset_queries[qname] = {ruleset = rs, query = q}
		end
		core.log("action", ("[goanna director] ruleset %s registered by %s"):format(name,
			core.get_current_modname() or "?"))
		return true
	end

	-- What the hello and the capabilities query say about each ruleset: the
	-- descriptions and schemas the MCP service turns into tools.
	function D.rulesets_advert()
		local out = {}
		for _, name in ipairs(D.ruleset_order) do
			local rs = D.rulesets[name]
			local intents, queries = {}, {}
			for iname, it in pairs(rs.intents) do
				intents[iname] = {description = it.description, schema = it.schema,
					paced = it.paced or nil, follow_up = it.follow_up,
					undoable = (it.undo or rs.undo) and true or nil}
			end
			for qname, q in pairs(rs.queries) do
				queries[qname] = {description = q.description, schema = q.schema}
			end
			out[name] = {description = rs.description, capabilities = rs.capabilities,
				intents = intents, queries = queries, points_per_hour = rs.points_per_hour,
				points_left = rs.points_per_hour and math.max(0, rs.points_per_hour
					- logic.window_sum(rs.points, D.now())) or nil}
		end
		return out
	end

	local function context(rs, msg, from_queue)
		return {ruleset = rs.name, act = msg.req, scope = msg.scope or "gm",
			based_on = msg.based_on, reason = msg.reason, queued = from_queue or nil}
	end

	local function as_pos(p)
		if type(p) ~= "table" then
			return nil
		end
		local x, y, z = p.x or p[1], p.y or p[2], p.z or p[3]
		if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
			return nil
		end
		return {x = x, y = y, z = z}
	end

	-- The intent pipeline for a ruleset's intent. result and refuse are
	-- intents.lua's, so the audit and the result body are the same as for
	-- the director's own intents.
	function D.ruleset_act(msg, result, refuse, from_queue)
		local entry = D.ruleset_intents[msg.type]
		local rs, it = entry.ruleset, entry.intent
		local args, now = msg.args, D.now()
		local ctx = context(rs, msg, from_queue)

		-- 1. Schema.
		local ok, why = logic.schema_check(it.schema, args)
		if not ok then
			return refuse(msg, "schema", {detail = why})
		end
		-- 2. Scope, and the players the intent concerns. Only gm reaches
		-- here (D.handle refuses every other scope); the ruleset may still
		-- refuse what gm asks about this subject.
		if it.scope then
			local fine, allowed, reason, detail = call(rs, it.scope, ctx.scope, args, ctx)
			if not fine then
				return refuse(msg, "error", {detail = detail})
			end
			if not allowed then
				return refuse(msg, "not_in_scope", {rule = reason, detail = detail})
			end
		end
		local subjects = {}
		if it.subjects then
			local fine, list = call(rs, it.subjects, args, ctx)
			if not fine then
				return refuse(msg, "error")
			end
			for _, s in ipairs(type(list) == "table" and list or {}) do
				if type(s) == "string" then
					subjects[#subjects + 1] = (s:gsub("^player:", ""))
				end
			end
		end
		for _, name in ipairs(subjects) do
			if D.opted_out(name) then
				return refuse(msg, "opted_out", {player = name})
			end
			local p = D.players[name]
			if p and type(msg.based_on) == "number" and p.died_seq > msg.based_on then
				return result(msg, "stale", {reason = "player_changed", player = name,
					since = p.died_seq})
			end
		end
		-- 3. Stop: D.handle refuses everything while stopped, and the queue
		-- holds nothing back while stopped.
		-- 4. Budget.
		local cost = it.cost
		if type(cost) == "function" then
			local fine, c = call(rs, cost, args, ctx)
			if not fine then
				return refuse(msg, "error")
			end
			cost = c
		end
		cost = math.max(0, tonumber(cost) or 0)
		local left
		if rs.points_per_hour then
			left = rs.points_per_hour - logic.window_sum(rs.points, now)
			if cost > left then
				return refuse(msg, "budget", {cost = cost, points_left = left,
					points_per_hour = rs.points_per_hour})
			end
		end
		-- 5. The ruleset's rules.
		if it.rules then
			local fine, allowed, reason, detail = call(rs, it.rules, args, ctx)
			if not fine then
				return refuse(msg, "error", {detail = detail})
			end
			if not allowed then
				return refuse(msg, "rules", {rule = reason, detail = detail})
			end
		end
		-- 6. Place: every position the intent will change is loaded, not
		-- protected, and clear of static spawn and of players who opted out.
		if it.places then
			local fine, list = call(rs, it.places, args, ctx)
			if not fine then
				return refuse(msg, "error")
			end
			for _, raw in ipairs(type(list) == "table" and list or {}) do
				local pos = as_pos(raw)
				if not pos then
					return refuse(msg, "error", {detail = "places returned something not a position"})
				end
				pos = vector.round(pos)
				if not core.get_node_or_nil(pos) then
					return refuse(msg, "not_loaded", {pos = D.vec(pos)})
				end
				if core.is_protected(pos, "") then
					return refuse(msg, "protected", {pos = D.vec(pos)})
				end
				local ex = D.excluded(pos)
				if ex then
					return refuse(msg, ex, {pos = D.vec(pos)})
				end
			end
		end
		-- 7. Pacing: a paced intent waits until every online player it
		-- concerns is in a build up. "when": "now" refuses instead of
		-- waiting, as stage_encounter does.
		if it.paced and not from_queue then
			local waiting
			for _, name in ipairs(subjects) do
				local p = D.players[name]
				if p and p.pacing.phase ~= "build_up" then
					waiting = waiting or name
				end
			end
			if waiting then
				if args.when == "now" then
					return refuse(msg, "pacing", {player = waiting,
						phase = D.players[waiting].pacing.phase})
				end
				local valid = math.min(tonumber(args.valid_for_s) or D.cfg.queue_s, D.cfg.queue_s)
				D.queue[#D.queue + 1] = {msg = msg, id = msg.req, type = msg.type, args = args,
					until_t = now + valid, player = waiting,
					run = function(m)
						return D.ruleset_act(m, result, refuse, true)
					end,
					ready = function()
						for _, name in ipairs(subjects) do
							local p = D.players[name]
							if p and p.pacing.phase ~= "build_up" then
								return false
							end
						end
						return true
					end}
				return result(msg, "queued", {player = waiting,
					phase = D.players[waiting].pacing.phase, valid_for_s = valid})
			end
		end
		-- 8. Apply, keeping the undo record the ruleset returns.
		local fine, out, undo_rec, detail = call(rs, it.apply, args, ctx)
		if not fine then
			return refuse(msg, "error", {detail = detail})
		end
		if out == false then
			return refuse(msg, "rules", {rule = undo_rec, detail = detail})
		end
		local fields = {}
		for k, v in pairs(type(out) == "table" and out or {}) do
			fields[k] = v
		end
		local status = fields.status
		fields.status, fields.id, fields.type = nil, nil, nil
		if status ~= "accepted" then
			status = "completed"
		end
		if cost > 0 then
			logic.window_add(rs.points, now, cost)
		end
		fields.ruleset = rs.name
		fields.cost = cost > 0 and cost or nil
		fields.points_left = left and (left - cost) or nil
		local audit = {effects = out, players = #subjects > 0 and subjects or nil}
		if undo_rec ~= nil and (it.undo or rs.undo) then
			D.undo[msg.req] = {type = "ruleset", ruleset = rs.name, intent = it.name,
				record = undo_rec}
			audit.undo = undo_rec
			fields.undoable = true
		end
		-- 9. Audit, in result().
		return result(msg, from_queue and "completed" or status, fields, audit)
	end

	-- Undo of a ruleset act: the intent's own undo, else the ruleset's.
	function D.ruleset_undo(u)
		local rs = D.rulesets[u.ruleset]
		local it = rs and rs.intents[u.intent]
		local hook = it and it.undo or rs and rs.undo
		if not hook then
			return {ruleset = u.ruleset, undone = false}
		end
		local fine, out = call(rs, hook, u.record, {ruleset = rs.name, intent = u.intent})
		local fields = {ruleset = rs.name}
		if not fine then
			fields.undo_failed = true
		elseif type(out) == "table" then
			for k, v in pairs(out) do
				if k ~= "status" and k ~= "id" and k ~= "type" then
					fields[k] = v
				end
			end
		end
		return fields
	end

	-- A ruleset's query. Returns the reply body.
	function D.ruleset_query(msg)
		local entry = D.ruleset_queries[msg.type]
		local rs, q = entry.ruleset, entry.query
		local ok, why = logic.schema_check(q.schema, msg.args)
		if not ok then
			return {id = msg.req, type = msg.type, status = "error", reason = "schema", detail = why}
		end
		local fine, body, _, detail = call(rs, q.answer, msg.args, context(rs, msg))
		if not fine then
			return {id = msg.req, type = msg.type, status = "error", reason = "error",
				detail = detail and detail:sub(1, 200)}
		end
		return {id = msg.req, type = msg.type, status = "ok", ruleset = rs.name, body = body}
	end

	function D.rulesets_stop(by, why)
		for _, name in ipairs(D.ruleset_order) do
			local rs = D.rulesets[name]
			if rs.on_stop then
				call(rs, rs.on_stop, by, why)
			end
		end
	end

	-- Chat addressed to a ruleset's own characters. Asked by the chat
	-- callback after the director's cast characters, for a public line from
	-- a player who has not opted out. The first ruleset to claim the line
	-- has it reported as npc_addressed with its data.
	function D.ruleset_addressed(name, message)
		for _, rname in ipairs(D.ruleset_order) do
			local rs = D.rulesets[rname]
			if rs.addressed then
				local fine, hit = call(rs, rs.addressed, name, message)
				if fine and type(hit) == "table" and logic.valid_name(hit.npc) then
					local data = {}
					for k, v in pairs(type(hit.data) == "table" and hit.data or {}) do
						data[k] = v
					end
					data.npc = hit.npc
					data.ruleset = rs.name
					data.text = message:sub(1, 280)
					local player = core.get_player_by_name(name)
					D.emit("npc_addressed", {"player:" .. name, "npc:" .. hit.npc}, data,
						player and player:get_pos())
					return true
				end
			end
		end
		return false
	end

	-- A speaker the director did not cast: the first ruleset whose speaker
	-- hook knows the name. Returns {name, label, pos, remote, ruleset} or
	-- nil. The name must be a valid character name and no player's, so a
	-- ruleset's speaker can never pass for a player.
	function D.ruleset_speaker(as)
		for _, rname in ipairs(D.ruleset_order) do
			local rs = D.rulesets[rname]
			if rs.speaker then
				local fine, sp = call(rs, rs.speaker, as)
				if fine and type(sp) == "table" then
					local name = type(sp.name) == "string" and sp.name or as
					if not logic.valid_name(name) then
						return nil, "bad_speaker"
					end
					if core.player_exists(name) or core.player_exists(name:lower()) then
						return nil, "name_taken"
					end
					local remote = {}
					if type(sp.remote) == "table" then
						for k, v in pairs(sp.remote) do
							if type(k) == "string" and v then
								remote[k] = true
							elseif type(v) == "string" then
								remote[v] = true
							end
						end
					end
					local label = text(sp.label, 60)
					return {name = name, label = (label and label ~= "") and label or name,
						pos = as_pos(sp.pos), remote = remote, ruleset = rs}
				end
			end
		end
		return nil
	end

	-- The ruleset's own check of a line before it is delivered, and its
	-- record of what was said after.
	function D.ruleset_speak_check(sp, text_, listeners)
		local rs = sp.ruleset
		if not rs.speak then
			return true
		end
		local fine, ok, reason, detail = call(rs, rs.speak, sp.name, text_, listeners)
		if not fine then
			return false, "error"
		end
		return ok and true or false, reason, detail
	end

	function D.ruleset_spoken(sp, text_, delivered)
		local rs = sp.ruleset
		if rs.spoken then
			call(rs, rs.spoken, sp.name, text_, delivered)
		end
	end
end
