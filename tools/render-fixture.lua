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
--   /rs_box x1 y1 z1 x2 y2 z2 node [param2] [swap]
--                                    fill a box, remembering what was there;
--                                    swap uses swap_node, so no on_construct
--                                    or on_destruct runs (a portal set with
--                                    set_node is destroyed by Mineclonia)
--   /rs_statue entity x y z yaw [ai] a held entity; yaw in degrees
--   /rs_statue_json BASE64           the same from a JSON object, with
--                                    props, animation, attach and burn
--   /rs_lua BASE64                   run a Lua chunk for a job (node meta,
--                                    pots, books), with helpers in its scope
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
local tracked = {}    -- objects a job's Lua made, removed by /rs_reset

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
local function fill(minp, maxp, name, remember, done, param2, swap)
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
					if swap then
						core.swap_node(pos, {name = name, param2 = param2 or 0})
					else
						core.set_node(pos, {name = name, param2 = param2 or 0})
					end
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

-- A figure with the player's own model and texture slots (skin, armour,
-- a third the game leaves blank), for a job that dresses a player shaped
-- statue: props.textures sets what it wears. Mineclonia's model, so only
-- where that game is loaded.
if core.get_modpath("mcl_armor") then
	core.register_entity("goanna_render_fixture:figure", {
		initial_properties = {
			visual = "mesh", mesh = "mcl_armor_character.b3d",
			textures = {"character.png", "blank.png", "blank.png"},
			visual_size = {x = 1, y = 1}, collisionbox = {-0.3, 0, -0.3, 0.3, 1.8, 0.3},
			physical = false, pointable = false, static_save = false,
		},
		on_activate = function(self)
			self.object:set_animation({x = 0, y = 79}, 30, 0, true)
		end,
	})
end

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
	params = "<x1> <y1> <z1> <x2> <y2> <z2> <node> [param2] [swap]",
	description = "Render service: fill a box, remembering what was there",
	privs = {},
	func = function(_, param)
		local w = words(param)
		if #w < 7 or #w > 9 then
			return false, "rs_box wants x1 y1 z1 x2 y2 z2 node [param2] [swap]"
		end
		local param2, swap = 0, false
		for i = 8, #w do
			if w[i] == "swap" then
				swap = true
			elseif tonumber(w[i]) then
				param2 = tonumber(w[i])
			else
				return false, "rs_box: " .. w[i] .. " is neither a param2 nor swap"
			end
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
		fill(minp, maxp, node, true, nil, param2, swap)
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
	-- A job's own look for the statue: armour textures on a figure, a
	-- mob's texture set, a pose frame. Applied after on_activate, which is
	-- where mobs pick their textures.
	if s.props then
		obj:set_properties(s.props)
	end
	if s.animation then
		obj:set_animation({x = s.animation[1], y = s.animation[2] or s.animation[1]},
			s.animation[3] or 0, 0, true)
	end
	s.attached = {}
	for _, a in ipairs(s.attach or {}) do
		local child = core.add_entity(s.pos, a.entity)
		if child then
			child:set_properties({static_save = false})
			if a.props then
				child:set_properties(a.props)
			end
			child:set_attach(obj, a.bone or "", a.pos and vector.new(a.pos[1], a.pos[2], a.pos[3]),
				a.rot and vector.new(a.rot[1], a.rot[2], a.rot[3]))
			s.attached[#s.attached + 1] = child
		end
	end
	if s.burn and mcl_burning then
		-- The statue's on_step is shadowed, so mcl_burning.tick never runs
		-- down this burn and the flame stays attached.
		mcl_burning.set_on_fire(obj, 1000000)
	end
	s.obj = obj
	return obj
end

local function remove_statue(s)
	for _, child in ipairs(s.attached or {}) do
		if child:get_pos() then
			child:remove()
		end
	end
	s.attached = {}
	if s.obj and s.obj:get_pos() then
		s.obj:remove()
		return true
	end
	return false
end

local function block_active(pos)
	if core.compare_block_status then
		return core.compare_block_status(pos, "active") == true
	end
	return core.get_node_or_nil(pos) ~= nil
end

local function add_statue(s)
	statues[#statues + 1] = s
	local now = block_active(s.pos) and spawn(s)
	return true, "rs_statue " .. #statues .. " " .. s.name .. " at " ..
		core.pos_to_string(s.pos) .. (now and " spawned" or " waiting for its block")
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
		return add_statue(s)
	end,
})

-- The JSON form: {"entity", "pos": [x, y, z], "yaw" (degrees), "ai",
-- "props" (object properties set after activation), "animation": [from,
-- to, speed], "attach": [{"entity", "bone", "pos", "rot", "props"}], "burn"}.
-- Base64, because chat is the channel.
core.register_chatcommand("rs_statue_json", {
	params = "<base64 json>",
	description = "Render service: a held entity described by a JSON object",
	privs = {},
	func = function(_, param)
		local text = core.decode_base64(param:match("%S+") or "")
		local d = text and core.parse_json(text)
		if type(d) ~= "table" or type(d.pos) ~= "table" then
			return false, "rs_statue_json: not a statue object"
		end
		if not core.registered_entities[d.entity or ""] then
			return false, "rs_statue_json: no entity " .. tostring(d.entity)
		end
		for _, a in ipairs(d.attach or {}) do
			if not core.registered_entities[a.entity or ""] then
				return false, "rs_statue_json: no entity " .. tostring(a.entity) .. " to attach"
			end
		end
		return add_statue({name = d.entity, pos = {x = d.pos[1], y = d.pos[2], z = d.pos[3]},
			yaw = math.rad(tonumber(d.yaw) or 0), ai = d.ai == true, props = d.props,
			animation = d.animation, attach = d.attach, burn = d.burn == true})
	end,
})

core.register_globalstep(function()
	for _, s in ipairs(statues) do
		if s.obj and s.obj:get_pos() then
			s.obj:set_pos(s.pos)
			s.obj:set_velocity({x = 0, y = 0, z = 0})
			s.obj:set_yaw(s.yaw)
			local ent = s.obj:get_luaentity()
			if ent and not s.burn then
				ent.burn_time = 0
			end
		elseif block_active(s.pos) then
			spawn(s)
		end
	end
end)

-- A Lua chunk for what a box cannot say: node meta (a decorated pot's
-- faces, a bookshelf's books), a callback a node needs after it is set.
-- Its scope reads through to the global one and adds:
--   S             the stage, absolute
--   P(x, y, z)    a stage relative position, absolute
--   save(pos)     remember the node there, so /rs_reset puts it back
--   set(pos, node) and swap(pos, node), which save first
--   track(obj)    an object /rs_reset removes
-- It runs once the nodes queued before it are placed. Base64, because chat
-- is the channel. Only the render service's own world has this mod.
local function lua_scope()
	local scope = {S = vector.new(stage.x, stage.y, stage.z)}
	scope.P = function(x, y, z)
		return vector.new(stage.x + x, stage.y + y, stage.z + z)
	end
	scope.save = function(pos)
		pos = vector.round(pos)
		local h = core.hash_node_position(pos)
		if not saved[h] then
			core.load_area(pos)
			saved[h] = {pos = pos, node = core.get_node(pos)}
		end
	end
	scope.set = function(pos, node)
		scope.save(pos)
		core.set_node(pos, type(node) == "string" and {name = node} or node)
	end
	scope.swap = function(pos, node)
		scope.save(pos)
		core.swap_node(pos, type(node) == "string" and {name = node} or node)
	end
	scope.track = function(obj)
		if obj then
			tracked[#tracked + 1] = obj
		end
		return obj
	end
	return setmetatable(scope, {__index = _G})
end

core.register_chatcommand("rs_lua", {
	params = "<base64 lua>",
	description = "Render service: run a job's Lua chunk",
	privs = {},
	func = function(name, param)
		if name ~= "render" then
			return false, "rs_lua: only the render service's own player"
		end
		local src = core.decode_base64(param:match("%S+") or "")
		if not src then
			return false, "rs_lua: not base64"
		end
		local fn, err = loadstring(src, "=rs_lua")
		if not fn then
			return false, "rs_lua error " .. tostring(err)
		end
		setfenv(fn, lua_scope())
		local ok, got = pcall(fn)
		if not ok then
			return false, "rs_lua error " .. tostring(got)
		end
		return true, "rs_lua ok " .. tostring(got)
	end,
})

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
			if remove_statue(s) then
				removed = removed + 1
			end
		end
		statues = {}
		for _, obj in ipairs(tracked) do
			if obj:get_pos() then
				obj:remove()
				removed = removed + 1
			end
		end
		tracked = {}
		local restored = 0
		for _, entry in pairs(saved) do
			core.load_area(entry.pos)
			-- swap_node, so no destructor runs: a portal or obsidian set
			-- back with set_node fires Mineclonia's destroy_portal, and a
			-- pot's on_destruct would look for its faces. The meta a job
			-- gave the node goes with it.
			core.swap_node(entry.pos, entry.node)
			core.get_meta(entry.pos):from_table(nil)
			restored = restored + 1
		end
		saved = {}
		return true, string.format("rs_reset statues=%d nodes=%d", removed, restored)
	end,
})
