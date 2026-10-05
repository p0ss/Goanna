-- Fixture for Goanna's low tier occlusion review, 2026-10-05. Private copy of
-- test_world only. /occl_build lays a floating stone platform at ORIGIN with
-- short walls of cobble, stone, stone brick and brick, and log columns, so
-- a camera can see them in open sky at a low sun. /occl_zombie places a held
-- zombie on the platform that does not burn or walk.
local ORIGIN = {x = -40, y = 90, z = 420}
local held = {}

local function set(x, y, z, name)
	minetest.set_node({x = ORIGIN.x + x, y = ORIGIN.y + y, z = ORIGIN.z + z}, {name = name})
end

local function build()
	for x = -2, 14 do for z = -2, 14 do
		set(x, 0, z, "mcl_core:stone")
		for y = 1, 6 do set(x, y, z, "air") end
	end end
	-- Walls along z, faces looking west (-x): four materials in turn,
	-- three nodes wide and three high, at x = 8.
	local mats = {"mcl_core:cobble", "mcl_core:stone", "mcl_core:stonebrick", "mcl_core:brick_block"}
	for i, m in ipairs(mats) do
		for dz = 0, 2 do for y = 1, 3 do
			set(8, y, (i - 1) * 3 + dz, m)
		end end
	end
	-- Three along x at z = 10, faces looking south (-z), which a low sun
	-- from the west only rakes: cobble, brick, and stone brick past the
	-- log column at x = 4. Inside the platform's own map block (z 416 to
	-- 431): a wall built at z = 13, in the next block, never reached the
	-- client while this was written.
	for x = 0, 13 do for y = 1, 3 do set(x - 2, y, 13, "air") end end
	local south = {{-2, "mcl_core:cobble"}, {1, "mcl_core:brick_block"}, {5, "mcl_core:stonebrick"}}
	for _, w in ipairs(south) do
		for dx = 0, 2 do for y = 1, 3 do
			set(w[1] + dx, y, 10, w[2])
		end end
	end
	-- Log columns.
	local log = minetest.registered_nodes["mcl_trees:tree_oak"] and "mcl_trees:tree_oak"
		or "mcl_core:tree"
	for y = 1, 4 do
		set(4, y, 2, log)
		set(4, y, 8, log)
	end
end

-- Emerged first: a node set in a block mapgen has not yet made is lost
-- when mapgen makes it.
minetest.register_chatcommand("occl_build", {
	privs = {},
	func = function()
		minetest.emerge_area({x = ORIGIN.x - 4, y = ORIGIN.y - 2, z = ORIGIN.z - 4},
			{x = ORIGIN.x + 16, y = ORIGIN.y + 8, z = ORIGIN.z + 16},
			function(_, _, remaining)
				if remaining == 0 then
					build()
				end
			end)
		return true, "building at " .. minetest.pos_to_string(ORIGIN)
	end,
})

-- Built once at server start too, before any client asks for the blocks:
-- a client that already holds the empty blocks was not seen to receive the
-- edits /occl_build makes (2026-10-05, Goanna in fly mode nearby).
minetest.register_on_mods_loaded(function()
	minetest.after(1, function()
		minetest.emerge_area({x = ORIGIN.x - 4, y = ORIGIN.y - 2, z = ORIGIN.z - 4},
			{x = ORIGIN.x + 16, y = ORIGIN.y + 8, z = ORIGIN.z + 16},
			function(_, _, remaining)
				if remaining == 0 then
					build()
				end
			end)
	end)
end)

minetest.register_chatcommand("occl_check", {
	privs = {},
	func = function(name)
		local n = minetest.get_node({x = ORIGIN.x + 8, y = ORIGIN.y + 1, z = ORIGIN.z})
		local player = minetest.get_player_by_name(name)
		local at = player and minetest.pos_to_string(player:get_pos()) or "?"
		return true, n.name .. " player " .. at .. " held " .. #held
	end,
})

minetest.register_chatcommand("occl_zombie", {
	privs = {},
	params = "<dx> <dz> <yaw>",
	func = function(_, param)
		local dx, dz, yaw = param:match("^(%S+)%s+(%S+)%s+(%S+)$")
		dx, dz, yaw = tonumber(dx) or 2, tonumber(dz) or 5, tonumber(yaw) or 0
		local pos = {x = ORIGIN.x + dx, y = ORIGIN.y + 1, z = ORIGIN.z + dz}
		local obj = minetest.add_entity(pos, "mobs_mc:zombie")
		if not obj then
			return false, "no zombie"
		end
		local ent = obj:get_luaentity()
		if ent then
			ent.ignited_by_sunlight = false
			ent.walk_velocity = 0
			ent.run_velocity = 0
		end
		held[#held + 1] = {obj = obj, pos = pos, yaw = yaw}
		return true, "zombie at " .. minetest.pos_to_string(pos)
	end,
})

minetest.register_globalstep(function()
	for _, h in ipairs(held) do
		if h.obj:get_pos() then
			h.obj:set_pos(h.pos)
			h.obj:set_velocity({x = 0, y = 0, z = 0})
			h.obj:set_yaw(h.yaw)
			local ent = h.obj:get_luaentity()
			if ent then
				ent.burn_time = 0
			end
		end
	end
end)
