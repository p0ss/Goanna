-- Goanna PBR test pack: serves LabPBR companion textures as ordinary media.
-- Maps composed from Null-MC/Textureless (CC0-1.0).
--
-- Also builds a material gallery in open sky, so materials can be judged
-- somewhere lit and known rather than in a night jungle underwater. Each
-- material gets a wall facing +z and a floor patch in front of it, because
-- a normal map reads differently on the two orientations.

local BASE = {x = 180, y = 78, z = -150}

-- ordered so the interesting channels sit together: plain, then metals,
-- then translucents, then emitters
local MATS = {
	"mcl_core:stone", "mcl_core:cobble", "mcl_core:dirt", "mcl_core:sand",
	"mcl_core:gravel", "mcl_core:wood", "mcl_core:tree", "mcl_core:brick_block",
	"mcl_core:ironblock", "mcl_core:goldblock", "mcl_copper:block",
	"mcl_core:diamondblock", "mcl_core:emeraldblock", "mcl_core:lapisblock",
	"mcl_core:obsidian", "mcl_core:glass", "mcl_core:ice", "mcl_core:packed_ice",
	"mcl_nether:glowstone", "mcl_ocean:sea_lantern", "mcl_nether:netherrack",
	"mcl_core:snowblock", "mcl_core:coalblock", "mcl_core:redstoneblock",
}

local function build()
	local placed, missing = {}, {}
	local i = 0
	for _, name in ipairs(MATS) do
		if not minetest.registered_nodes[name] then
			missing[#missing + 1] = name
		else
			local x = BASE.x + i * 4
			-- 3 wide by 3 high wall
			for dx = 0, 2 do
				for dy = 0, 2 do
					minetest.set_node({x = x + dx, y = BASE.y + 1 + dy, z = BASE.z}, {name = name})
				end
			end
			-- 3 by 3 floor patch in front of it
			for dx = 0, 2 do
				for dz = 1, 3 do
					minetest.set_node({x = x + dx, y = BASE.y, z = BASE.z + dz}, {name = name})
				end
			end
			placed[#placed + 1] = name
			i = i + 1
		end
	end
	minetest.log("action", "[goanna_pbr] gallery: " .. #placed .. " materials at " ..
		minetest.pos_to_string(BASE) .. " -> " .. table.concat(placed, " "))
	if #missing > 0 then
		minetest.log("action", "[goanna_pbr] not registered: " .. table.concat(missing, " "))
	end
end

local built = false
minetest.register_on_joinplayer(function()
	if built then return end
	built = true
	local n = #MATS
	local p1 = {x = BASE.x - 4, y = BASE.y - 2, z = BASE.z - 4}
	local p2 = {x = BASE.x + n * 4 + 4, y = BASE.y + 6, z = BASE.z + 8}
	minetest.emerge_area(p1, p2, function(_, _, calls_remaining)
		if calls_remaining == 0 then
			-- clear the air around the gallery so nothing shadows it
			for x = p1.x, p2.x do
				for y = BASE.y + 1, p2.y do
					for z = p1.z, p2.z do
						minetest.set_node({x = x, y = y, z = z}, {name = "air"})
					end
				end
			end
			for x = p1.x, p2.x do
				for z = p1.z, p2.z do
					minetest.set_node({x = x, y = BASE.y, z = z}, {name = "mcl_core:stone"})
				end
			end
			build()
		end
	end)
end)
