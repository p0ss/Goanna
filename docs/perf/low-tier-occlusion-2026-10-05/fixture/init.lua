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

minetest.register_chatcommand("occl_build", {
	privs = {},
	func = function()
		minetest.load_area({x = ORIGIN.x - 4, y = ORIGIN.y - 2, z = ORIGIN.z - 4},
			{x = ORIGIN.x + 16, y = ORIGIN.y + 8, z = ORIGIN.z + 16})
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
		-- The same four along x, faces looking south (-z), at z = 13.
		for i, m in ipairs(mats) do
			for dx = 0, 2 do for y = 1, 3 do
				set(-2 + (i - 1) * 3 + dx, y, 13, m)
			end end
		end
		-- Log columns.
		for y = 1, 4 do
			set(4, y, 2, "mcl_core:tree")
			set(4, y, 8, "mcl_core:tree")
		end
		return true, "built at " .. minetest.pos_to_string(ORIGIN)
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
