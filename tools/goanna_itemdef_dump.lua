-- Goanna: dump every registered item's own texture to JSON, the same idea as
-- goanna_nodedef_dump.lua but for the images an item carries rather than the
-- faces a node draws with.
--
-- Worth baking even though an inventory slot is drawn flat and unlit: the same
-- image is the item in the player's hand and the item lying on the ground,
-- both of which are real geometry in a lit scene. Nodes that place as blocks
-- are skipped, because their faces are already covered by the nodedef dump and
-- baking them twice wastes generation budget.
--
-- Install as a worldmod (mod.conf naming it, this file as init.lua), join the
-- world once to trigger the dump, then read <world>/goanna_itemdefs.json back
-- out.

local function tile_name(t)
	local n = t
	if type(t) == "table" then
		n = t.name
	end
	if type(n) ~= "string" then
		return nil
	end
	-- strip a texture modifier chain: only the base image is a real file
	local base = n:match("^([^%^]+)")
	if not base then
		return nil
	end
	local first = base:sub(1, 1)
	if first == "[" or first == "(" or base:find(":") then
		return nil
	end
	if not base:find("%.png$") then
		return nil
	end
	return base
end

local function dump()
	local out = {}
	for name, def in pairs(minetest.registered_items) do
		-- a placeable node's art is its tiles, which the nodedef dump has
		if minetest.registered_nodes[name] then
			goto continue
		end
		local textures, seen = {}, {}
		for _, field in ipairs({ def.inventory_image, def.wield_image }) do
			local n = tile_name(field)
			if n and not seen[n] then
				seen[n] = true
				textures[#textures + 1] = n
			end
		end
		if #textures > 0 then
			out[#out + 1] = {
				name = name,
				textures = textures,
				wield_scale = def.wield_scale and def.wield_scale.x or nil,
			}
		end
		::continue::
	end
	local path = minetest.get_worldpath() .. "/goanna_itemdefs.json"
	local ok = minetest.safe_file_write(path, minetest.write_json(out, true))
	minetest.log("action", "[goanna_itemdef_dump] wrote " .. #out .. " items to " .. path ..
		(ok and "" or " (write FAILED)"))
end

local done = false
minetest.register_on_joinplayer(function()
	if done then return end
	done = true
	dump()
end)
