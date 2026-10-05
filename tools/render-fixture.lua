-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Copyright (C) 2026 the Goanna contributors
--
-- The render service's worldmod (tools/goanna-render). Installed only into
-- the service's own world, which it rebuilds: never into a world anyone
-- plays. It lays a floor at the stage, and gives the service chat commands
-- to place nodes and held mob statues for a job and to put everything back
-- afterwards. Coordinates in the commands are Luanti's, absolute; the
-- service converts a job's stage relative ones before sending them.
--
--   /rs_box x1 y1 z1 x2 y2 z2 node   fill a box, remembering what was there
--   /rs_statue entity x y z yaw [ai] a held entity; yaw in degrees
--   /rs_status                       pending boxes, statues, saved nodes
--   /rs_node x y z                   the node there, as the server holds it
--   /rs_reset                        statues removed, every box put back
--
-- Chat is the channel because it is what a vanilla client can send: the
-- control channel's chat command carries these and returns the reply.

local stage = core.string_to_pos(core.settings:get("goanna_render_stage") or "") or
	{x = 1000, y = 32, z = 1000}
local floor_node = core.settings:get("goanna_render_floor") or ""
local floor_radius = tonumber(core.settings:get("goanna_render_floor_radius") or "") or 24
local MAX_VOLUME = 65536

local pending = 0
local saved = {}      -- hash -> {pos, node}, the node before the first box over it
local statues = {}

local function num(word)
	local v = tonumber(word)
	if v == nil then
		error("not a number: " .. tostring(word))
	end
	return v
end

local function words(param)
	local out = {}
	for w in param:gmatch("%S+") do
		out[#out + 1] = w
	end
	return out
end

local function sorted_box(x1, y1, z1, x2, y2, z2)
	return {x = math.min(x1, x2), y = math.min(y1, y2), z = math.min(z1, z2)},
		{x = math.max(x1, x2), y = math.max(y1, y2), z = math.max(z1, z2)}
end

-- Emerged first: a node set in a block mapgen has not made yet is lost when
-- mapgen makes it.
local function fill(minp, maxp, name, remember, done)
	pending = pending + 1
	core.emerge_area(minp, maxp, function(_, _, remaining)
		if remaining ~= 0 then
			return
		end
		for x = minp.x, maxp.x do
			for y = minp.y, maxp.y do
				for z = minp.z, maxp.z do
					local pos = {x = x, y = y, z = z}
					if remember then
						local h = core.hash_node_position(pos)
						if not saved[h] then
							saved[h] = {pos = pos, node = core.get_node(pos)}
						end
					end
					core.set_node(pos, {name = name})
				end
			end
		end
		pending = pending - 1
		if done then
			done()
		end
	end)
end

local function lay_floor()
	if floor_node == "" or not core.registered_nodes[floor_node] then
		core.log("action", "GOANNA_RENDER_STAGE_READY no floor (" .. floor_node .. ")")
		return
	end
	local r = floor_radius
	fill({x = stage.x - r, y = stage.y - 1, z = stage.z - r},
		{x = stage.x + r, y = stage.y - 1, z = stage.z + r}, floor_node, false, function()
			core.log("action", "GOANNA_RENDER_STAGE_READY " .. floor_node .. " at " ..
				core.pos_to_string(stage))
		end)
end

core.register_on_mods_loaded(function()
	core.after(1, lay_floor)
end)

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	local privs = core.get_player_privs(name)
	for _, p in ipairs({"interact", "shout", "teleport", "fly", "fast", "noclip",
			"settime", "give", "debug"}) do
		if core.registered_privileges[p] then
			privs[p] = true
		end
	end
	if core.registered_privileges["weather_manager"] then
		privs.weather_manager = true
	end
	core.set_player_privs(name, privs)
	-- A player in the void falls for ever, and the server streams around
	-- wherever it has fallen to.
	player:set_physics_override({gravity = 0})
end)

core.register_chatcommand("rs_box", {
	params = "<x1> <y1> <z1> <x2> <y2> <z2> <node>",
	description = "Render service: fill a box, remembering what was there",
	privs = {},
	func = function(_, param)
		local w = words(param)
		if #w ~= 7 then
			return false, "rs_box wants x1 y1 z1 x2 y2 z2 node"
		end
		local ok, minp, maxp = pcall(function()
			return sorted_box(num(w[1]), num(w[2]), num(w[3]), num(w[4]), num(w[5]), num(w[6]))
		end)
		if not ok then
			return false, "rs_box: " .. tostring(minp)
		end
		local node = w[7]
		if node ~= "air" and not core.registered_nodes[node] then
			return false, "rs_box: no node " .. node
		end
		local volume = (maxp.x - minp.x + 1) * (maxp.y - minp.y + 1) * (maxp.z - minp.z + 1)
		if volume > MAX_VOLUME then
			return false, "rs_box: " .. volume .. " nodes is more than " .. MAX_VOLUME
		end
		fill(minp, maxp, node, true)
		return true, "rs_box queued " .. volume .. " " .. node
	end,
})

-- A statue is kept as what to spawn, not only as the object: a block with
-- no player near is deactivated and its objects go with it, and a job's
-- statues are placed while the player waits away from the stage. So the
-- objects are not saved with the block (static_save off), and the
-- globalstep spawns one again whenever its block is active and it is gone.
local function spawn(s)
	local obj = core.add_entity(s.pos, s.name)
	if not obj then
		return nil
	end
	obj:set_properties({static_save = false})
	local ent = obj:get_luaentity()
	if ent then
		ent.ignited_by_sunlight = false
		ent.can_despawn = false
		ent.walk_velocity = 0
		ent.run_velocity = 0
		if not s.ai then
			-- Shadows the definition's on_step on this one object: no AI,
			-- no despawn timer, no sunlight burn. The animation it set on
			-- activation keeps playing.
			ent.on_step = function() end
		end
	end
	obj:set_velocity({x = 0, y = 0, z = 0})
	obj:set_acceleration({x = 0, y = 0, z = 0})
	obj:set_yaw(s.yaw)
	s.obj = obj
	return obj
end

local function block_active(pos)
	if core.compare_block_status then
		return core.compare_block_status(pos, "active") == true
	end
	return core.get_node_or_nil(pos) ~= nil
end

core.register_chatcommand("rs_statue", {
	params = "<entity> <x> <y> <z> <yaw> [ai]",
	description = "Render service: a held entity that does not walk, burn or despawn",
	privs = {},
	func = function(_, param)
		local w = words(param)
		if #w < 5 then
			return false, "rs_statue wants entity x y z yaw"
		end
		local name = w[1]
		if not core.registered_entities[name] then
			return false, "rs_statue: no entity " .. name
		end
		local ok, pos = pcall(function()
			return {x = num(w[2]), y = num(w[3]), z = num(w[4])}
		end)
		if not ok then
			return false, "rs_statue: " .. tostring(pos)
		end
		local s = {name = name, pos = pos, yaw = math.rad(tonumber(w[5]) or 0), ai = w[6] == "ai"}
		statues[#statues + 1] = s
		local now = block_active(pos) and spawn(s)
		return true, "rs_statue " .. #statues .. " " .. name .. " at " ..
			core.pos_to_string(pos) .. (now and " spawned" or " waiting for its block")
	end,
})

core.register_globalstep(function()
	for _, s in ipairs(statues) do
		if s.obj and s.obj:get_pos() then
			s.obj:set_pos(s.pos)
			s.obj:set_velocity({x = 0, y = 0, z = 0})
			s.obj:set_yaw(s.yaw)
			local ent = s.obj:get_luaentity()
			if ent then
				ent.burn_time = 0
			end
		elseif block_active(s.pos) then
			spawn(s)
		end
	end
end)

core.register_chatcommand("rs_status", {
	description = "Render service: what is pending, placed and held",
	privs = {},
	func = function()
		local alive = 0
		for _, s in ipairs(statues) do
			if s.obj and s.obj:get_pos() then
				alive = alive + 1
			end
		end
		local n = 0
		for _ in pairs(saved) do
			n = n + 1
		end
		return true, string.format("rs_status pending=%d statues=%d saved=%d", pending, alive, n)
	end,
})

core.register_chatcommand("rs_node", {
	params = "<x> <y> <z>",
	description = "Render service: the node at a position, as the server holds it",
	privs = {},
	func = function(_, param)
		local w = words(param)
		local ok, pos = pcall(function()
			return {x = num(w[1]), y = num(w[2]), z = num(w[3])}
		end)
		if not ok then
			return false, "rs_node wants x y z"
		end
		return true, "rs_node " .. core.get_node(pos).name
	end,
})

core.register_chatcommand("rs_reset", {
	description = "Render service: remove the statues and put every box back",
	privs = {},
	func = function()
		local removed = 0
		for _, s in ipairs(statues) do
			if s.obj and s.obj:get_pos() then
				s.obj:remove()
				removed = removed + 1
			end
		end
		statues = {}
		local restored = 0
		for _, entry in pairs(saved) do
			core.load_area(entry.pos)
			core.set_node(entry.pos, entry.node)
			restored = restored + 1
		end
		saved = {}
		return true, string.format("rs_reset statues=%d nodes=%d", removed, restored)
	end,
})
