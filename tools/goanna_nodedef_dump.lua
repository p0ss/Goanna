-- Goanna: dump every registered node's classification-relevant fields to
-- JSON, so tools/pbr_bake.py can classify textures by material without a
-- live client session. Luanti's own registration data, nothing inferred.
--
-- Install as a worldmod (mod.conf naming it, this file as init.lua), join
-- the world once to trigger the dump, then read
-- <world>/goanna_nodedefs.json back out.

local function tile_name(t)
	local n = t
	if type(t) == "table" then
		n = t.name
	end
	if type(n) ~= "string" then
		return nil
	end
	-- A tile can carry texture modifiers (rotation, recolour, an overlay
	-- composited on top) or be a [combine generator with no single file at
	-- all, sometimes parenthesised as a modifier argument itself, e.g.
	-- "(...)^[transformR180". Only the base texture before the first ^ is
	-- ever a plain file on disk, and only when it is not itself a generator.
	local base = n:match("^([^%^]+)")
	if not base then
		return nil
	end
	local first = base:sub(1, 1)
	if first == "[" or first == "(" or base:find(":") then
		return nil
	end
	return base
end

local function sound_name(s)
	if type(s) == "table" then
		return s.name
	end
	return s
end

local function dump()
	local out = {}
	for name, def in pairs(minetest.registered_nodes) do
		local tiles, seen = {}, {}
		for _, t in ipairs(def.tiles or {}) do
			local n = tile_name(t)
			if n and n ~= "" and not seen[n] then
				seen[n] = true
				tiles[#tiles + 1] = n
			end
		end
		if #tiles > 0 then
			out[#out + 1] = {
				name = name,
				tiles = tiles,
				groups = def.groups or {},
				sound_footstep = def.sounds and sound_name(def.sounds.footstep) or nil,
				drawtype = def.drawtype,
				light_source = def.light_source,
				liquid_viscosity = def.liquid_viscosity,
				damage_per_second = def.damage_per_second,
			}
		end
	end
	local path = minetest.get_worldpath() .. "/goanna_nodedefs.json"
	local ok = minetest.safe_file_write(path, minetest.write_json(out, true))
	minetest.log("action", "[goanna_nodedef_dump] wrote " .. #out .. " nodes to " .. path ..
		(ok and "" or " (write FAILED)"))
end

local done = false
minetest.register_on_joinplayer(function()
	if done then return end
	done = true
	dump()
end)
