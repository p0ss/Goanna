-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Copyright (C) 2026 the Goanna contributors
--
-- Deterministic, spatially isolated renderer fixtures. This mod is only for a
-- dedicated singlenode test world. It never builds anything until a player
-- asks for a named fixture with /goanna_fixture.

local SITE_GAP = 1024
local FLOOR_Y = 64
local HALF_SIZE = 32

local sites = {
	lighting_walk = {index = 0, spawn = {x = -4, y = FLOOR_Y + 1, z = 16}},
	ao = {index = 1, spawn = {x = SITE_GAP - 8, y = FLOOR_Y + 1, z = 14}},
	materials = {index = 2, spawn = {x = SITE_GAP * 2 - 8, y = FLOOR_Y + 1, z = 14}},
	ice = {index = 3, spawn = {x = SITE_GAP * 3 - 8, y = FLOOR_Y + 1, z = 14}},
	light_pool = {index = 4, spawn = {x = SITE_GAP * 4 - 26, y = FLOOR_Y + 1, z = 6}},
	eaves = {index = 5, spawn = {x = SITE_GAP * 5, y = FLOOR_Y + 1, z = 14}},
}

local function solid_node(description, colour, light)
	return {
		description = description,
		tiles = {"[fill:16x16:" .. colour},
		groups = {cracky = 1},
		is_ground_content = false,
		light_source = light or 0,
	}
end

core.register_node("goanna_visual_test:neutral", solid_node(
		"Fixture neutral", "#808080"))
core.register_node("goanna_visual_test:dark", solid_node(
		"Fixture dark", "#303030"))
core.register_node("goanna_visual_test:warm", solid_node(
		"Fixture warm", "#a45b32"))
core.register_node("goanna_visual_test:cool", solid_node(
		"Fixture cool", "#365f9a"))
core.register_node("goanna_visual_test:light", solid_node(
		"Fixture light", "#fff0c0", 10))
-- A second, weaker and differently coloured lamp. The pool sorts on distance
-- alone, so a field of identical lamps hides any ordering defect behind its
-- own symmetry.
core.register_node("goanna_visual_test:dim", solid_node(
		"Fixture dim light", "#c0d8ff", 5))

local function site_origin(site)
	return {x = site.index * SITE_GAP, y = FLOOR_Y, z = 0}
end

local function add(a, b)
	return {x = a.x + b.x, y = a.y + b.y, z = a.z + b.z}
end

local function put(origin, x, y, z, name)
	core.set_node(add(origin, {x = x, y = y, z = z}), {name = name})
end

local function box(origin, p1, p2, name)
	for z = p1.z, p2.z do
		for y = p1.y, p2.y do
			for x = p1.x, p2.x do
				put(origin, x, y, z, name)
			end
		end
	end
end

local function clear_and_floor(origin)
	local p1 = add(origin, {x = -HALF_SIZE, y = 0, z = -HALF_SIZE})
	local p2 = add(origin, {x = HALF_SIZE, y = 18, z = HALF_SIZE})
	local vm = VoxelManip()
	local emin, emax = vm:read_from_map(p1, p2)
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local data = vm:get_data()
	local air = core.CONTENT_AIR
	local floor = core.get_content_id("goanna_visual_test:neutral")
	for z = p1.z, p2.z do
		for y = p1.y, p2.y do
			for x = p1.x, p2.x do
				data[area:index(x, y, z)] = y == FLOOR_Y and floor or air
			end
		end
	end
	vm:set_data(data)
	vm:write_to_map()
	vm:update_map()
end

local function build_lighting_walk(origin)
	local neutral = "goanna_visual_test:neutral"
	local dark = "goanna_visual_test:dark"
	local warm = "goanna_visual_test:warm"
	local cool = "goanna_visual_test:cool"
	local light = "goanna_visual_test:light"

	-- A small roofed building, symmetrical around the walking line. Coloured
	-- interior walls make indirect bounce visible without texture variation.
	box(origin, {x = -6, y = 1, z = -8}, {x = 6, y = 6, z = -8}, neutral)
	box(origin, {x = -6, y = 1, z = -8}, {x = -6, y = 6, z = 1}, neutral)
	box(origin, {x = 6, y = 1, z = -8}, {x = 6, y = 6, z = 1}, neutral)
	box(origin, {x = -7, y = 7, z = -9}, {x = 7, y = 7, z = 3}, dark)
	box(origin, {x = -6, y = 1, z = 0}, {x = -2, y = 6, z = 0}, neutral)
	box(origin, {x = 2, y = 1, z = 0}, {x = 6, y = 6, z = 0}, neutral)
	box(origin, {x = -1, y = 5, z = 0}, {x = 1, y = 6, z = 0}, neutral)
	box(origin, {x = -5, y = 1, z = -7}, {x = -1, y = 5, z = -7}, warm)
	box(origin, {x = 1, y = 1, z = -7}, {x = 5, y = 5, z = -7}, cool)

	-- Repeated steps and overhangs expose directional-shadow cascade changes.
	for x = -5, 5, 2 do
		box(origin, {x = x, y = 1, z = 2}, {x = x, y = 3, z = 2}, dark)
		box(origin, {x = x, y = 4, z = 1}, {x = x + 1, y = 4, z = 3}, neutral)
	end
	box(origin, {x = -3, y = 1, z = 4}, {x = 3, y = 1, z = 6}, dark)
	box(origin, {x = -1, y = 2, z = 4}, {x = 1, y = 2, z = 5}, neutral)

	-- Ten local lights straddle the nearest-eight shadow boundary. Their fixed
	-- positions make pool churn measurable rather than dependent on a village's
	-- lamp placement.
	for x = -4, 4, 2 do
		put(origin, x, 5, 3, light)
		put(origin, x, 4, -4, light)
	end
end

local function build_ao(origin)
	local neutral = "goanna_visual_test:neutral"
	for i = 0, 7 do
		box(origin, {x = -8 + i * 2, y = 1, z = -2},
				{x = -7 + i * 2, y = 1 + i % 4, z = 2}, neutral)
	end
	box(origin, {x = -8, y = 1, z = -8}, {x = 8, y = 8, z = -8}, neutral)
	box(origin, {x = -8, y = 1, z = -7}, {x = -8, y = 8, z = 7}, neutral)
end

local function build_materials(origin)
	local names = {
		"goanna_visual_test:dark", "goanna_visual_test:neutral",
		"goanna_visual_test:warm", "goanna_visual_test:cool",
		"goanna_visual_test:light",
	}
	for i, name in ipairs(names) do
		local x = -10 + (i - 1) * 5
		box(origin, {x = x, y = 1, z = -1}, {x = x + 2, y = 3, z = 1}, name)
	end
end

local function build_ice(origin)
	local neutral = "goanna_visual_test:neutral"
	local cool = "goanna_visual_test:cool"
	box(origin, {x = -10, y = 1, z = -5}, {x = 10, y = 1, z = 5}, cool)
	box(origin, {x = -10, y = 2, z = -5}, {x = -10, y = 7, z = 5}, neutral)
	box(origin, {x = 10, y = 2, z = -5}, {x = 10, y = 7, z = 5}, neutral)
end

-- A lit subject at one end, and a crowd of lamps at the other that steals its
-- shadows.
--
-- The obvious layout, a row of lamps walked along, does not reproduce the
-- defect: the lamps nearest the player are the ones being looked at, so they
-- always hold their shadows and nothing visibly changes. The reported case is
-- the other way round. A pavilion with two lamps sits in view, the player
-- walks toward other lamps elsewhere, and the pavilion's lamps are pushed out
-- of the shadow-casting set by lamps that are nearer but somewhere else
-- entirely. The subject never moves and never changes, and its shadows
-- vanish.
--
-- So: the subject is fixed at one end with its own posts and a wall to catch
-- their shadows, and fourteen decoys sit at the other end. Walk from the
-- subject toward the decoys with the camera looking back, and the subject
-- crosses the boundary at a known place with nothing else changing.
local function build_light_pool(origin)
	local neutral = "goanna_visual_test:neutral"
	local dark = "goanna_visual_test:dark"
	local light = "goanna_visual_test:light"
	local dim = "goanna_visual_test:dim"

	-- subject: wall, two posts, two lamps
	box(origin, {x = -26, y = 1, z = -6}, {x = -14, y = 8, z = -6}, neutral)
	box(origin, {x = -22, y = 1, z = -2}, {x = -22, y = 5, z = -2}, dark)
	box(origin, {x = -18, y = 1, z = -2}, {x = -18, y = 5, z = -2}, dark)
	put(origin, -22, 6, 1, light)
	put(origin, -18, 6, 1, light)

	-- Sixty decoys, more than the forty-eight the renderer keeps at all, so a
	-- walk crosses both boundaries: the eighth, where a lamp stops casting
	-- shadows, and the forty-eighth, where it stops existing. Heterogeneous on
	-- purpose. Identical lamps at identical distances are a tie, and ties are
	-- resolved by whatever order the pool happened to build, which is its own
	-- source of churn and would mask the effect being looked for.
	for i = 0, 59 do
		local col = i % 10
		local row = math.floor(i / 10)
		put(origin, 6 + col * 2, 2 + (i % 3), -8 + row * 4,
				(i % 4 == 0) and dim or light)
	end
end

-- A lantern hanging under an overhang, plus fifty decoy lamps close enough to
-- outrank it for a shadow.
--
-- The point is a mechanism that is easy to mistake for something else. A
-- lantern is a solid node, so it occludes its own light upward: while it holds
-- a shadow map the eave directly above it is dark, and the moment it loses one
-- the light passes straight through the lantern block and the eave underside
-- glows. Walking sideways changes which lamps are inside the shadow budget, so
-- a surface brightens with no lamp having moved, appeared or disappeared.
local function build_eaves(origin)
	local neutral = "goanna_visual_test:neutral"
	local dark = "goanna_visual_test:dark"
	local light = "goanna_visual_test:light"

	-- back wall, and an overhang reaching out over the walking line
	box(origin, {x = -8, y = 1, z = -2}, {x = 8, y = 7, z = -2}, neutral)
	box(origin, {x = -8, y = 8, z = -2}, {x = 8, y = 8, z = 4}, dark)
	-- the lantern, two below the overhang and clear of the wall
	put(origin, 0, 6, 3, light)

	-- Decoys off to one side, far enough not to light the overhang themselves.
	--
	-- Set the shadow budget to 0 and the underside above the lantern brightens
	-- several fold, because the light now passes through the lantern block; set
	-- it high and the underside goes dark again. That contrast is the thing
	-- being tested, and it is what a lamp crossing the budget does in a village.
	--
	-- Making the lantern cross the budget mid-walk is harder than it looks and
	-- is deliberately not attempted here. Decoys near enough to outrank it are
	-- also near enough to light the overhang themselves, which swamps the
	-- measurement; decoys far enough not to interfere never outrank it.
	for i = 0, 49 do
		put(origin, 14 + (i % 10) * 3, 2 + (i % 3), 6 + math.floor(i / 10) * 2, light)
	end
end

local builders = {
	eaves = build_eaves,
	light_pool = build_light_pool,
	lighting_walk = build_lighting_walk,
	ao = build_ao,
	materials = build_materials,
	ice = build_ice,
}

local built = {}
local building = {}
local waiting = {}

local function finish_site(name)
	local site = sites[name]
	local origin = site_origin(site)
	clear_and_floor(origin)
	builders[name](origin)
	core.fix_light(add(origin, {x = -HALF_SIZE, y = 0, z = -HALF_SIZE}),
			add(origin, {x = HALF_SIZE, y = 18, z = HALF_SIZE}))
	built[name] = true
	building[name] = nil
	for _, player_name in ipairs(waiting[name] or {}) do
		local player = core.get_player_by_name(player_name)
		if player then
			player:set_pos(site.spawn)
			player:set_look_horizontal(math.pi)
			player:set_look_vertical(math.rad(-5))
			player:set_clouds({density = 0})
			core.chat_send_player(player_name, "fixture ready: " .. name)
		end
	end
	waiting[name] = nil
end

local function request_site(name, player_name)
	local site = sites[name]
	if not site then
		return false, "unknown fixture '" .. name .. "'"
	end
	if core.get_mapgen_setting("mg_name") ~= "singlenode" then
		return false, "visual fixtures require a dedicated singlenode world"
	end
	if built[name] then
		local player = core.get_player_by_name(player_name)
		if player then
			player:set_pos(site.spawn)
			player:set_look_horizontal(math.pi)
			player:set_look_vertical(math.rad(-5))
			player:set_clouds({density = 0})
		end
		return true, "fixture ready: " .. name
	end
	waiting[name] = waiting[name] or {}
	table.insert(waiting[name], player_name)
	if building[name] then
		return true, "fixture is still building: " .. name
	end
	building[name] = true
	local origin = site_origin(site)
	local p1 = add(origin, {x = -HALF_SIZE, y = 0, z = -HALF_SIZE})
	local p2 = add(origin, {x = HALF_SIZE, y = 18, z = HALF_SIZE})
	core.emerge_area(p1, p2, function(_, _, calls_remaining)
		if calls_remaining == 0 then
			core.after(0, finish_site, name)
		end
	end)
	return true, "building fixture: " .. name
end

-- A small platform at the world spawn.
--
-- The sites sit a thousand blocks apart and a joining client is only moved to
-- one when it asks for a fixture by name, so until then it hangs in the void
-- of a singlenode world. That reads as a broken client rather than a harness
-- waiting to be told what to do, and it makes every screenshot taken before
-- the teleport worthless. Somewhere to stand costs nothing and says plainly
-- that the world is up and waiting.
local LANDING = {x = -SITE_GAP, y = FLOOR_Y, z = 0}

-- A block that bare hands can actually break, with four coloured quarters.
--
-- The quarters are the point: a broken node throws off pieces that each show a
-- random patch of its texture, so a flat colour cannot tell you whether the
-- patches differ or whether every piece is showing the same thing. Four
-- quarters makes that visible at a glance.
core.register_node("goanna_visual_test:soft", {
	description = "Goanna visual test soft block",
	tiles = {"[fill:16x16:#e06020"},
	groups = {crumbly = 3, oddly_breakable_by_hand = 3},
	is_ground_content = false,
})

-- Rebuilt on every join, not once per server. The dig harness breaks a block
-- each run and the world keeps the hole, so after a few runs the player is
-- standing in a pit pointing at a floor it cannot dig and the test quietly
-- stops testing anything. A fixture that does not reset is not a fixture.
local function build_landing()
	local origin = LANDING
	box(origin, {x = -6, y = 0, z = -6}, {x = 6, y = 0, z = 6},
			"goanna_visual_test:neutral")
	-- A layer of breakable blocks at foot level, with the spawn cell left clear.
	-- The dig harness looks down at its own feet, so this is the only thing it
	-- can reach, and standing in the gap means breaking one does not drop the
	-- player through the floor.
	box(origin, {x = -6, y = 1, z = -6}, {x = 6, y = 1, z = 6},
			"goanna_visual_test:soft")
	-- one marker per fixture, so the list of sites is visible from the floor
	local i = 0
	for name, _ in pairs(sites) do
		box(origin, {x = -5 + i * 2, y = 1, z = -5}, {x = -5 + i * 2, y = 2, z = -5},
				"goanna_visual_test:dark")
		put(origin, -5 + i * 2, 3, -5, "goanna_visual_test:light")
		i = i + 1
	end
	core.fix_light(add(origin, {x = -8, y = 0, z = -8}),
			add(origin, {x = 8, y = 6, z = 8}))
end

core.register_on_joinplayer(function(player)
	-- Move first, build second. A joining player is at the world spawn, so the
	-- landing a thousand blocks away is not loaded yet and set_node would be
	-- writing into blocks that are not there. Emerging the area and building
	-- once it exists is the difference between a floor and nothing at all.
	player:set_pos({x = LANDING.x, y = LANDING.y + 1, z = LANDING.z})
	core.emerge_area(add(LANDING, {x = -8, y = -2, z = -8}),
			add(LANDING, {x = 8, y = 6, z = 8}), function(_, _, remaining)
		if remaining == 0 then
			build_landing()
			player:set_pos({x = LANDING.x, y = LANDING.y + 1, z = LANDING.z})
		end
	end)
	player:set_clouds({density = 0})
	core.chat_send_player(player:get_player_name(),
			"goanna_visual_test ready. /goanna_fixture <name> to go to a site.")
end)

core.register_chatcommand("goanna_fixture", {
	params = "<lighting_walk|light_pool|ao|materials|ice>",
	description = "Build and enter an isolated Goanna visual fixture",
	privs = {},
	func = function(player_name, param)
		return request_site(param:trim(), player_name)
	end,
})

local fixed_time = 0.5
local elapsed = 0
core.register_globalstep(function(dtime)
	elapsed = elapsed + dtime
	if elapsed >= 1 then
		elapsed = 0
		core.set_timeofday(fixed_time)
	end
end)

core.log("action", "[goanna_visual_test] loaded; sites are " .. SITE_GAP ..
		" nodes apart, time fixed at " .. fixed_time)
