-- Goanna: dump every registered entity's textures to JSON, the same idea as
-- goanna_nodedef_dump.lua but for mobs and other "mesh"/"sprite" visuals,
-- whose textures tools/pbr_bake.py should never be pointed at with tiling
-- turned on: a mob skin is a single UV-unwrapped sheet, not a repeating
-- block face, and forcing it through the 3x3 replicate trick would waste
-- generation budget on eight copies of a texture that is never seen tiled.
--
-- Install as a worldmod (mod.conf naming it, this file as init.lua), join
-- the world once to trigger the dump, then read
-- <world>/goanna_entitydefs.json back out.

local function tile_name(t)
	local n = t
	if type(t) == "table" then
		n = t.name
	end
	if type(n) ~= "string" then
		return nil
	end
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

local function dump()
	local out = {}
	for name, def in pairs(minetest.registered_entities) do
		local props = def.initial_properties or def
		local textures, seen = {}, {}
		for _, t in ipairs(props.textures or {}) do
			local n = tile_name(t)
			if n and n ~= "" and not seen[n] then
				seen[n] = true
				textures[#textures + 1] = n
			end
		end
		if #textures > 0 then
			out[#out + 1] = {
				name = name,
				textures = textures,
				visual = props.visual,
				mesh = props.mesh,
			}
		end
	end
	local path = minetest.get_worldpath() .. "/goanna_entitydefs.json"
	local ok = minetest.safe_file_write(path, minetest.write_json(out, true))
	minetest.log("action", "[goanna_entitydef_dump] wrote " .. #out .. " entities to " .. path ..
		(ok and "" or " (write FAILED)"))
end

local done = false
minetest.register_on_joinplayer(function()
	if done then return end
	done = true
	dump()
end)
