-- SPDX-License-Identifier: LGPL-2.1-or-later
-- What players and the operator see of the director: the notice on joining,
-- /director, the per player opt out, stop and start, and the log.
--
-- Players are told. A joiner gets one chat line saying a director is
-- active, what it sees, and how to opt out, as soon as a director is
-- connected (on joining, or when one connects later). The opt out is kept
-- in the player's own metadata, so it lasts across sessions until they opt
-- back in.

return function(D)
	core.register_privilege("goanna_director", {
		description = "May stop and start the director and read its log",
		give_to_singleplayer = true,
		give_to_admin = true,
	})

	local function may_operate(name)
		local privs = core.get_player_privs(name)
		return privs.server or privs.goanna_director
	end

	local NOTICE = "#a9c4ff"

	local function notice(optout)
		local sees = D.cfg.sees == "exact"
			and "players' exact positions, health and gear"
			or "the region each player is in and a score for their gear"
		local chat = ({
			addressed = "public chat lines addressed to its characters",
			all = "all public chat",
			none = "no chat",
		})[D.cfg.chat] or "public chat lines addressed to its characters"
		local more = D.cfg.info ~= "" and (" More: " .. D.cfg.info .. ".") or ""
		local line = "This server runs a director: a language model acting as game master " ..
			"(scope gm). It may stage encounters near you and speak as characters; " ..
			"its speech is always marked as a character or as narration. It sees " .. sees ..
			", and " .. chat .. ", never private messages. Type /director for details" ..
			(optout and ". You have opted out: it will leave you alone (/director optin to undo)."
				or ", or /director optout to be left alone.") .. more
		return core.colorize(NOTICE, "[director] ") .. line
	end

	local function tell(name)
		local p = D.players[name]
		if p and not p.told then
			p.told = true
			core.chat_send_player(name, notice(p.optout))
		end
	end

	function D.on_join(player, p)
		if D.connected and not D.stopped then
			tell(p.name)
		end
	end

	-- Called by http.lua when a director answers for the first time.
	function D.on_connect()
		if D.stopped then
			return
		end
		for name in pairs(D.players) do
			tell(name)
		end
	end

	local function describe(name)
		local b = D.budget_status()
		local lines = {
			"The director is a language model acting as game master on this server, " ..
				"run by its operator. Everything it does arrives as an intent the game checks first.",
			("State: %s. Director connected: %s."):format(
				D.stopped and ("stopped by " .. D.stopped) or "running",
				D.connected and "yes" or "no"),
			("Budgets: %d of %d encounter points used in the last hour; %d of %d director creatures live " ..
				"(at most %d per player); %d lines a minute per speaker."):format(
				b.points_spent_last_hour, b.points_per_hour, b.live_entities, b.max_entities,
				b.max_entities_per_player, b.speech_per_minute),
		}
		if not D.connected and may_operate(name) then
			local how = core.get_worldpath() .. "/goanna_director/connect.txt"
			local f = io.open(how, "r")
			if f then
				f:close()
				lines[#lines + 1] = "To connect a game master, see " .. how
			end
		end
		local p = D.players[name]
		if p then
			lines[#lines + 1] = p.optout
				and "You have opted out. /director optin to undo."
				or "/director optout to be left alone."
		end
		local recent = D.audit_recent(function(e)
			return e.kind == "intent" and e.players and table.indexof(e.players, name) > 0
				or (e.args and (e.args.near == name or e.args.to == name or e.args.player == name))
		end, 5)
		if #recent > 0 then
			lines[#lines + 1] = "What it did near you recently:"
			for _, e in ipairs(recent) do
				lines[#lines + 1] = ("  %s %s: %s"):format(e.real:sub(12, 19), e.type or e.kind,
					e.outcome or "")
			end
		end
		return table.concat(lines, "\n")
	end

	core.register_chatcommand("director", {
		params = "[optout | optin | stop | start | log [player]]",
		description = "What the director (an AI game master) is, and your opt out",
		func = function(name, param)
			local verb, rest = param:match("^%s*(%S*)%s*(.-)%s*$")
			if verb == "" then
				return true, describe(name)
			elseif verb == "optout" or verb == "optin" then
				local player = core.get_player_by_name(name)
				if not player then
					return false, "Only a connected player can opt out."
				end
				local out = verb == "optout"
				player:get_meta():set_string("goanna_director_optout", out and "1" or "")
				D.optout_seen[name] = out
				local p = D.players[name]
				if p then
					p.optout = out
				end
				D.audit({kind = verb, players = {name}})
				if out then
					-- Leaving is immediate: encounters around them end now.
					for _, e in pairs(D.encounters) do
						if e.state == "live" and e.player == name then
							D.end_encounter(e, "opted_out")
						end
					end
					return true, "The director will leave you alone: no encounters, no speech, " ..
						"nothing about you in what it reads. /director optin to undo."
				end
				return true, "The director may include you again."
			elseif verb == "stop" or verb == "start" then
				if not may_operate(name) then
					return false, "Needs the server or goanna_director privilege."
				end
				if verb == "stop" then
					D.stop("operator:" .. name, rest ~= "" and rest or nil)
					return true, "Director stopped. Its creatures are gone and it is refused " ..
						"everything until /director start."
				end
				D.start("operator:" .. name)
				return true, "Director started."
			elseif verb == "log" then
				if not may_operate(name) then
					return false, "Needs the server or goanna_director privilege."
				end
				local who = rest ~= "" and rest or nil
				local entries = D.audit_recent(function(e)
					if not who then
						return true
					end
					return (e.players and table.indexof(e.players, who) > 0)
						or (e.args and (e.args.near == who or e.args.to == who or e.args.player == who))
				end, 12)
				if #entries == 0 then
					return true, "Nothing in the log this session."
				end
				local lines = {}
				for i = #entries, 1, -1 do
					local e = entries[i]
					lines[#lines + 1] = ("%s %s %s %s%s"):format(e.real:sub(12, 19), e.kind,
						e.type or "", e.outcome or "", e.refusal and (" (" .. e.refusal .. ")") or "")
				end
				return true, table.concat(lines, "\n")
			end
			return false, "Usage: /director [optout | optin | stop | start | log [player]]"
		end,
	})
end
