-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Fixture for Goanna's fire material review, 2026-10-05. Private copy of
-- test_world (Mineclonia) only. Lays a floating stone platform at ORIGIN
-- holding, along z = 4, a campfire, fire on netherrack, soul fire, a lit
-- candle and a burning zombie; fire in front of a water pool; fire behind
-- and beside a glass wall; and a field of fire to fill the near frame.
local ORIGIN = {x = -40, y = 90, z = 420}
local held = {}

local function at(x, y, z)
	return {x = ORIGIN.x + x, y = ORIGIN.y + y, z = ORIGIN.z + z}
end

local function set(x, y, z, name)
	minetest.set_node(at(x, y, z), {name = name})
end

-- Every flame the fixture keeps lit, set again if anything puts it out.
local flames = {}
local function flame(x, y, z, name)
	set(x, y, z, name)
	flames[#flames + 1] = {pos = at(x, y, z), name = name}
end

local function build()
	flames = {}
	for x = -4, 30 do for z = -4, 16 do
		set(x, 0, z, "mcl_core:stone")
		for y = 1, 6 do set(x, y, z, "air") end
	end end
	-- The row of five, two nodes apart.
	flame(0, 1, 4, "mcl_campfires:campfire_lit")
	set(3, 1, 4, "mcl_nether:netherrack")
	flame(3, 2, 4, "mcl_fire:eternal_fire")
	set(6, 1, 4, "mcl_blackstone:soul_soil")
	flame(6, 2, 4, "mcl_blackstone:soul_fire")
	flame(9, 1, 4, "mcl_candles:candle_lit_4")
	-- Fire in front of water: a pool at z 9 to 11, a fire at z 7.
	for x = -1, 5 do for z = 8, 12 do set(x, 1, z, "mcl_core:stone") end end
	for x = 0, 4 do for z = 9, 11 do set(x, 1, z, "mcl_core:water_source") end end
	set(2, 1, 7, "mcl_nether:netherrack")
	flame(2, 2, 7, "mcl_fire:eternal_fire")
	-- Glass: a wall at z = 8, x 8 to 11, a fire behind it at z = 9 and
	-- one beside it at x = 12.
	for x = 8, 11 do for y = 1, 3 do set(x, y, 8, "mcl_core:glass") end end
	set(9, 1, 9, "mcl_nether:netherrack")
	flame(9, 2, 9, "mcl_fire:eternal_fire")
	set(12, 1, 8, "mcl_nether:netherrack")
	flame(12, 2, 8, "mcl_fire:eternal_fire")
	-- The field: nine by nine of fire on netherrack, x 18 to 26.
	for x = 18, 26 do for z = 0, 8 do
		set(x, 1, z, "mcl_nether:netherrack")
		flame(x, 2, z, "mcl_fire:eternal_fire")
	end end
end

local function emerge_then(fn)
	minetest.emerge_area(at(-6, -2, -6), at(32, 8, 18), function(_, _, remaining)
		if remaining == 0 then
			fn()
		end
	end)
end

minetest.register_chatcommand("fire_build", {
	privs = {},
	func = function()
		emerge_then(build)
		return true, "building at " .. minetest.pos_to_string(ORIGIN)
	end,
})

-- Built at server start too, before any client asks for the blocks.
minetest.register_on_mods_loaded(function()
	minetest.after(1, function() emerge_then(build) end)
end)

minetest.register_chatcommand("fire_check", {
	privs = {},
	func = function()
		local lit = 0
		for _, f in ipairs(flames) do
			if minetest.get_node(f.pos).name == f.name then lit = lit + 1 end
		end
		return true, "flames " .. lit .. "/" .. #flames .. " zombies " .. #held
	end,
})

-- A zombie that stays put, stays alive and keeps burning.
minetest.register_chatcommand("fire_zombie", {
	privs = {},
	params = "<dx> <dz> <yaw>",
	func = function(_, param)
		local dx, dz, yaw = param:match("^(%S+)%s+(%S+)%s+(%S+)$")
		dx, dz, yaw = tonumber(dx) or 12, tonumber(dz) or 4, tonumber(yaw) or 0
		local pos = at(dx, 1, dz)
		local obj = minetest.add_entity(pos, "mobs_mc:zombie")
		if not obj then
			return false, "no zombie"
		end
		local ent = obj:get_luaentity()
		if ent then
			ent.walk_velocity = 0
			ent.run_velocity = 0
		end
		held[#held + 1] = {obj = obj, pos = pos, yaw = yaw}
		return true, "zombie at " .. minetest.pos_to_string(pos)
	end,
})

local since = 0
minetest.register_globalstep(function(dtime)
	for _, h in ipairs(held) do
		if h.obj:get_pos() then
			h.obj:set_pos(h.pos)
			h.obj:set_velocity({x = 0, y = 0, z = 0})
			h.obj:set_yaw(h.yaw)
			local ent = h.obj:get_luaentity()
			if ent then
				ent.health = ent.hp_max or 20
			end
		end
	end
	since = since + dtime
	if since < 1 then return end
	since = 0
	for _, h in ipairs(held) do
		if h.obj:get_pos() and mcl_burning then
			mcl_burning.set_on_fire(h.obj, 30)
		end
	end
	for _, f in ipairs(flames) do
		if minetest.get_node(f.pos).name ~= f.name then
			minetest.set_node(f.pos, {name = f.name})
		end
	end
end)
