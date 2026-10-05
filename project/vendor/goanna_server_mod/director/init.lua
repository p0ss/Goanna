-- SPDX-License-Identifier: LGPL-2.1-or-later
-- The director: a game master for a Luanti world, run by a language model
-- the operator connects (docs/director.md).
--
-- The model proposes and the game decides. Every action arrives as an
-- intent, which this code validates against the operator's budgets, the
-- player's opt out, the pacing layer and the world before anything happens,
-- and records in an audit log. The model is never in the per step loop, and
-- the game never waits for it.
--
-- Loaded from goanna_server_mod/init.lua at load time, with the HTTP table
-- that core.request_http_api() returned there (or nil). It is never kept in
-- a global, because any mod could then make requests with the operator's
-- grant. Nothing happens at all unless goanna_director is true.
--
-- What reaches players goes only through ordinary engine channels that a
-- vanilla client renders identically: entities, nametags and chat. Nothing
-- goes over goanna:v1, and nothing secret goes in a goanna_* setting,
-- because init.lua's options() broadcasts every one of them to any Goanna
-- client that says hello. The transport token and endpoint live in
-- <world>/goanna_director.conf.

local MODPATH = core.get_modpath(core.get_current_modname()) .. "/director"

return function(http)
	local function setting(key, default)
		local v = core.settings:get(key)
		if v == nil or v == "" then
			return default
		end
		if type(default) == "number" then
			return tonumber(v) or default
		end
		if type(default) == "boolean" then
			return core.settings:get_bool(key, default)
		end
		return v
	end

	if not setting("goanna_director", false) then
		return
	end

	local logic = dofile(MODPATH .. "/logic.lua")

	local function csv_set(s)
		local out = {}
		for item in tostring(s or ""):gmatch("[^,%s]+") do
			out[item] = true
		end
		return out
	end

	-- Everything the modules share. One table rather than globals, so that
	-- nothing here is reachable from another mod except through the small
	-- goanna_director API at the end.
	local D = {logic = logic, http = http}

	D.cfg = {
		points_per_hour = setting("goanna_director_points_per_hour", 40),
		max_entities = setting("goanna_director_max_entities", 24),
		max_entities_per_player = setting("goanna_director_max_entities_per_player", 8),
		speech_per_minute = setting("goanna_director_speech_per_minute", 6),
		listener_per_minute = setting("goanna_director_listener_per_minute", 12),
		speech_chars = setting("goanna_director_speech_chars", 280),
		earshot = setting("goanna_director_earshot", 24),
		encounter_base = setting("goanna_director_encounter_base", 4),
		encounter_per_gear = setting("goanna_director_encounter_per_gear", 16),
		leash = setting("goanna_director_leash", 180),
		queue_s = setting("goanna_director_queue_s", 300),
		spawn_rules = setting("goanna_director_spawn_rules", "standable"),
		exclusion = setting("goanna_director_exclusion_radius", 24),
		deny = csv_set(setting("goanna_director_deny",
			"mobs_mc:creeper,mobs_mc:enderman,mobs_mc:wither,mobs_mc:enderdragon," ..
			"mobs_mc:ghast,mobs_mc:ravager,mobs_mc:evoker")),
		sees = setting("goanna_director_sees", "exact"),
		chat = setting("goanna_director_chat", "all"),
		memory_text = setting("goanna_director_memory_text", true),
		memory_lines = setting("goanna_director_memory_lines", 8),
		memory_chars = setting("goanna_director_memory_chars", 120),
		info = setting("goanna_director_info", ""),
		reward_points_per_hour = setting("goanna_director_reward_points_per_hour", 30),
		reward_max = setting("goanna_director_reward_max", 12),
		reward_deny = csv_set(setting("goanna_director_reward_deny", "")),
		structures = setting("goanna_director_structures", false),
		build_nodes_per_hour = setting("goanna_director_build_nodes_per_hour", 4000),
		structure_max_volume = setting("goanna_director_structure_max_volume", 32768),
		build_rate = setting("goanna_director_build_rate", 4),
	}
	D.pacing_cfg = {}
	for k, v in pairs(logic.PACING_DEFAULTS) do
		D.pacing_cfg[k] = v
	end
	D.pacing_cfg.peak = setting("goanna_director_peak", logic.PACING_DEFAULTS.peak)
	D.pacing_cfg.relax = setting("goanna_director_relax", logic.PACING_DEFAULTS.relax)
	D.pacing_cfg.relax_after_death = setting("goanna_director_relax_after_death",
		logic.PACING_DEFAULTS.relax_after_death)
	D.pacing_cfg.join_grace = setting("goanna_director_join_grace",
		logic.PACING_DEFAULTS.join_grace)

	function D.now()
		return core.get_us_time() / 1000000
	end

	function D.json(v)
		local ok, s = pcall(core.write_json, v)
		if ok and s then
			return s
		end
		core.log("warning", "[goanna director] could not encode: " .. tostring(s))
		return "null"
	end

	function D.vec(p)
		if not p then
			return nil
		end
		return {math.floor(p.x * 10 + 0.5) / 10, math.floor(p.y * 10 + 0.5) / 10,
			math.floor(p.z * 10 + 0.5) / 10}
	end

	function D.region_id(p)
		return ("r:%d:%d"):format(math.floor(p.x / 128), math.floor(p.z / 128))
	end

	-- The transport's secret and endpoint. Created on first start with a
	-- token from SecureRandom, read with the Settings class, and never put
	-- in a goanna_* setting.
	local conf_path = core.get_worldpath() .. "/goanna_director.conf"
	local conf = Settings(conf_path)
	local token = conf:get("token") or ""
	if #token < 32 then
		local ok, rng = pcall(SecureRandom)
		if not ok or not rng then
			core.log("error", "[goanna director] no secure random source; the director " ..
				"stays off rather than use a guessable token")
			return
		end
		token = rng:next_bytes(32):gsub(".", function(c)
			return ("%02x"):format(c:byte())
		end)
		conf:set("token", token)
	end
	if (conf:get("url") or "") == "" then
		conf:set("url", "http://127.0.0.1:30570")
	end
	conf:write()
	D.url = conf:get("url"):gsub("/+$", "")
	D.token = token

	-- A session id changes on every start, so a director knows its sequence
	-- numbers restarted.
	D.storage = core.get_mod_storage()
	local stored = D.storage:get_string("dir1:meta")
	local meta = stored ~= "" and core.parse_json(stored) or {}
	meta.sessions = (tonumber(meta.sessions) or 0) + 1
	D.stopped = meta.stopped
	D.session = ("%x-%d"):format(os.time(), meta.sessions)
	D.storage:set_string("dir1:meta", core.write_json(meta))
	function D.save_meta()
		meta.stopped = D.stopped
		D.storage:set_string("dir1:meta", core.write_json(meta))
	end

	-- Shared state, kept for the session.
	D.ring = logic.ring(4096)
	D.memory = logic.memory()
	D.owned = {}          -- guid -> record of a director owned entity
	D.encounters = {}     -- id -> encounter
	D.npcs = {}           -- lower case name -> cast character
	D.queue = {}          -- paced intents waiting for a build up
	D.players = {}        -- name -> per player state
	D.regions = {}        -- region id -> counters
	D.undo = {}           -- act id -> undo record
	D.points = logic.window(3600)
	D.reward_points = logic.window(3600)
	D.build_points = logic.window(3600)
	D.speech_rate = logic.rate(D.cfg.speech_per_minute)
	D.listener_rate = logic.rate(D.cfg.listener_per_minute)
	D.connected = false
	D.adapters = {}

	-- The mob adapter, chosen at register_on_mods_loaded, after every
	-- framework has registered.
	local owned_lookup = function(luaentity)
		local obj = luaentity and luaentity.object
		local guid = obj and obj.get_guid and obj:get_guid()
		return guid and D.owned[guid]
	end
	D.adapters.mcl_mobs = dofile(MODPATH .. "/adapters/mcl_mobs.lua")(owned_lookup)
	D.adapters.mcl_items = dofile(MODPATH .. "/adapters/mcl_items.lua")()
	D.adapters.mcl_structures = dofile(MODPATH .. "/adapters/mcl_structures.lua")()
	-- One adapter per kind, the highest priority that detects, each kept
	-- as D.<kind>: D.mobs, D.items, D.structures. A kind with no adapter
	-- is nil, and the core does what the engine alone allows.
	D.KINDS = {"mobs", "items", "structures"}
	D.on_adapters = {}
	core.register_on_mods_loaded(function()
		local names = {}
		for _, kind in ipairs(D.KINDS) do
			local best
			for _, a in pairs(D.adapters) do
				if a.kind == kind and a.detect() and (not best or a.priority > best.priority) then
					best = a
				end
			end
			D[kind] = best
			names[#names + 1] = kind .. " " .. (best and best.name or "none")
		end
		core.log("action", "[goanna director] adapters: " .. table.concat(names, ", "))
		for _, f in ipairs(D.on_adapters) do
			f()
		end
	end)

	function D.opted_out(name)
		local p = D.players[name]
		return p ~= nil and p.optout == true
	end

	dofile(MODPATH .. "/audit.lua")(D)
	dofile(MODPATH .. "/events.lua")(D)
	dofile(MODPATH .. "/summaries.lua")(D)
	dofile(MODPATH .. "/intents.lua")(D)
	dofile(MODPATH .. "/catalogue.lua")(D)
	dofile(MODPATH .. "/structures.lua")(D)
	dofile(MODPATH .. "/rewards.lua")(D)
	dofile(MODPATH .. "/orders.lua")(D)
	dofile(MODPATH .. "/commands.lua")(D)
	dofile(MODPATH .. "/http.lua")(D)

	-- The hook API for games and adapters (docs/director.md, "Lua hook API").
	-- Only the parts phase 1 uses exist yet.
	rawset(_G, "goanna_director", {
		register_adapter = function(name, def)
			D.adapters[name] = def
		end,
		emit = function(ev)
			if type(ev) == "table" and type(ev.type) == "string" then
				D.emit(ev.type, ev.who, ev.data, ev.pos)
			end
		end,
		owned = function(guid)
			local rec = D.owned[guid]
			return rec and {kind = rec.kind, act = rec.act, name = rec.name} or nil
		end,
	})

	core.log("action", ("[goanna director] on, session %s, endpoint %s, transport %s")
		:format(D.session, D.url, http and "http" or "none (add goanna_server_mod to secure.http_mods)"))
end
