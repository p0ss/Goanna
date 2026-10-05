-- SPDX-License-Identifier: LGPL-2.1-or-later
-- The director's structures adapter for Mineclonia's mcl_structures.
--
-- Read against Mineclonia release 38561. It calls the public
-- mcl_structures.place_structure, so a structure arrives with the game's
-- own loot, foundations and setup; none of its authors is involved.
--
-- Only structures built from schematic files are offered, because the
-- director has to know the box a structure can touch before it is placed,
-- to snapshot it for undo. Their sizes come from core.read_schematic. A
-- structure made by a function (the igloo, geodes, terrain features) has no
-- size to read and is left out.
--
-- With Mineclonia's level generator on (mcl_levelgen.enable_ersatz, the
-- default in that release), the temples, huts, shipwrecks and ruins are
-- placed by the level generator inside map generation, which nothing can
-- call at run time, and mcl_structures does not register them at all. Their
-- schematic files are still in mcl_structures/schematics, so every file no
-- registered structure uses is offered as a plain schematic: the building,
-- without the game's loot or setup.

return function()
	local A = {name = "mcl_structures", kind = "structures", priority = 10}

	-- mcl_util.create_ground_turnip lays a foundation up to six nodes wider
	-- than the structure's side and seven deep (environment.lua in
	-- mcl_util), and place_structure centres a schematic on x and z.
	local FOUNDATION_WIDE, FOUNDATION_DEEP = 7, 8

	function A.detect()
		local m = rawget(_G, "mcl_structures")
		return m ~= nil and type(m.place_structure) == "function"
			and type(m.registered_structures) == "table"
	end

	local sizes

	-- A schematic file's size and how many nodes it sets (not air, not
	-- left alone), which is what the build budget is charged.
	local function schematic_size(file)
		local ok, s = pcall(core.read_schematic, file, {})
		if not ok or not s or not s.size then
			return nil
		end
		local n = 0
		for _, d in ipairs(s.data or {}) do
			if d.name ~= "air" and (d.prob or 255) > 0 then
				n = n + 1
			end
		end
		return s.size, n
	end

	local function measure()
		sizes = {}
		local used = {}
		for name, def in pairs(mcl_structures.registered_structures) do
			if type(def.filenames) == "table" and #def.filenames > 0
					and not name:find("_test$") and not def.terrain_feature then
				local sx, sy, sz, nodes, ok = 0, 0, 0, 0, true
				for _, f in ipairs(def.filenames) do
					used[f] = true
					local s, n = schematic_size(f)
					if not s then
						ok = false
						break
					end
					sx, sy, sz = math.max(sx, s.x), math.max(sy, s.y), math.max(sz, s.z)
					nodes = math.max(nodes, n)
				end
				-- Daughters sit at offsets from the parent; the box is
				-- widened to hold the farthest of them.
				local reach = 0
				for _, d in pairs(def.daughters or {}) do
					for _, f in ipairs(d.files or {}) do
						local s, n = schematic_size(f)
						if not s then
							ok = false
						else
							nodes = nodes + n
							local p = d.pos or {x = 0, y = 0, z = 0}
							reach = math.max(reach, math.abs(p.x) + s.x, math.abs(p.z) + s.z)
							sy = math.max(sy, math.abs(p.y) + s.y)
						end
					end
				end
				if ok then
					local side = math.max(sx, sz, reach * 2)
					sizes[name] = {side = side, height = sy, nodes = nodes,
						foundation = def.make_foundation}
				end
			end
		end
		local dir = core.get_modpath("mcl_structures")
		dir = dir and dir .. "/schematics"
		for _, file in ipairs(dir and core.get_dir_list(dir, false) or {}) do
			local path = dir .. "/" .. file
			local name = file:match("^mcl_structures_(.+)%.mts$")
			if name and not used[path] and not sizes[name] then
				local s, n = schematic_size(path)
				if s then
					sizes[name] = {plain = true, file = path, x = s.x, z = s.z,
						side = math.max(s.x, s.z), height = s.y, nodes = n}
				end
			end
		end
	end

	local function plain_corner(s, pos)
		return {x = pos.x - math.floor(s.x / 2), y = pos.y, z = pos.z - math.floor(s.z / 2)}
	end

	function A.list()
		if not sizes then
			measure()
		end
		local out = {}
		for name, s in pairs(sizes) do
			if s.plain then
				out[#out + 1] = {name = name, plain = true,
					desc = name:gsub("_", " ") .. ", the building only, no loot",
					size = {s.x, s.height, s.z}, nodes = s.nodes}
			else
				out[#out + 1] = {name = name, desc = (name:gsub("_", " ")),
					size = {s.side, s.height, s.side}, nodes = s.nodes}
			end
		end
		return out
	end

	-- pos is where the director stands a building: the first air node
	-- above the ground. Mineclonia places a structure from the ground node
	-- itself, the position mapgen's decoration notice gives it, so both
	-- functions below step down one.
	--
	-- The box a structure placed at pos can touch, with seed fixing its
	-- random choices. The y offset is drawn first from the same PcgRandom
	-- that place_structure is given, so it is the offset it will use.
	function A.plan(name, pos, seed)
		if not sizes then
			measure()
		end
		local s = sizes[name]
		if s and s.plain then
			local p1 = plain_corner(s, pos)
			return {nodes = s.nodes, p1 = p1,
				p2 = {x = p1.x + s.x - 1, y = p1.y + s.height - 1, z = p1.z + s.z - 1}}
		end
		local def = mcl_structures.registered_structures[name]
		if not s or not def then
			return nil
		end
		pos = vector.offset(pos, 0, -1, 0)
		local y_off = def.y_offset or 0
		if type(y_off) == "function" then
			y_off = y_off(PcgRandom(seed))
		end
		local half = math.ceil(s.side / 2) + (s.foundation and FOUNDATION_WIDE or 1)
		local base = pos.y + math.min(0, y_off) - (s.foundation and FOUNDATION_DEEP or 1)
		return {
			nodes = s.nodes,
			p1 = {x = pos.x - half, y = base, z = pos.z - half},
			p2 = {x = pos.x + half, y = pos.y + math.max(0, y_off) + s.height + 1,
				z = pos.z + half},
		}
	end

	-- The schematic a character builds a structure from: the file the
	-- seed picks, as core.read_schematic gives it. Daughters, loot and the
	-- game's setup are left out, because a character lays nodes and nothing
	-- more.
	function A.schematic(name, seed)
		local s = sizes and sizes[name]
		if s and s.plain then
			local ok, schem = pcall(core.read_schematic, s.file, {})
			return ok and schem or nil
		end
		local def = mcl_structures.registered_structures[name]
		if not def or type(def.filenames) ~= "table" or #def.filenames == 0 then
			return nil
		end
		local file = def.filenames[PcgRandom(seed):next(1, #def.filenames)]
		local ok, s = pcall(core.read_schematic, file, {})
		return ok and s or nil
	end

	-- Placement finishes later, after the game emerges the area, so true
	-- means started.
	function A.place(name, pos, seed)
		local s = sizes and sizes[name]
		if s and s.plain then
			return core.place_schematic(plain_corner(s, pos), s.file, "0", nil, true) ~= nil
		end
		local def = mcl_structures.registered_structures[name]
		if not def then
			return false
		end
		return mcl_structures.place_structure(vector.offset(pos, 0, -1, 0), def, PcgRandom(seed),
			seed) == true
	end

	return A
end
