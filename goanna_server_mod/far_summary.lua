-- SPDX-License-Identifier: LGPL-2.1-or-later
-- One mapblock's far summary, worked out from a VoxelManip.
--
-- This is the expensive half of a far summary: 4096 nodes, each classified
-- and folded into 64 coarse cells. Reading the block out of the map has to
-- happen on the server thread, but this does not, so the same code runs in
-- two places. init.lua loads it with dofile for servers without an async
-- environment, and registers it with core.register_async_dofile, where it
-- runs on Luanti's async workers against a copy of the VoxelManip
-- (docs/far-rendering.md, "Summaries off the server thread").
--
-- What it returns holds content ids, not the area palette indices the wire
-- record carries. The palette belongs to the area in the server thread's
-- store and grows as blocks are summarised, so only the server thread may
-- assign indices; init.lua's pack_record turns this into the 92 byte record.
--   nil when no node of the block is generated, else a table:
--     complete  every node was generated
--     cells     [0..63] chosen content id, false for none (air), -1 unknown
--     tops      16 bytes of packed 2-bit liquid surface heights
--     day, night  maximum raw light (0 to 15)
--     liquid    one liquid content id for the block, or nil
--     mask      8 bytes, the 64-bit per-cell liquid mask

local modname = core.get_current_modname and core.get_current_modname() or "goanna_server_mod"
local surface_material = dofile(core.get_modpath(modname) .. "/surface_material.lua")

local c_ignore = core.CONTENT_IGNORE
local c_air = core.CONTENT_AIR

-- content id -> {filled, solid, liquid}, from the node's registration.
-- The same rule the client's chain uses: a full cube or cube shaped drawtype
-- or a liquid draws, and a full solid cube blocks light. Version 4 treats
-- vegetation as ordinary occupied voxels; there is no separate heightfield
-- path that needs to classify it away from terrain. The async environment
-- has its own copy of registered_nodes, with every field this reads.
local cls_cache = {}
local function classify(cid)
	local c = cls_cache[cid]
	if c then
		return c
	end
	c = {filled = false, solid = false, liquid = false}
	if cid ~= c_ignore and cid ~= c_air then
		local name = core.get_name_from_content_id(cid)
		local def = name and core.registered_nodes[name]
		if def then
			local dt = def.drawtype or "normal"
			if dt == "normal" then
				c.filled = true
				c.solid = true
			elseif dt == "allfaces" or dt == "allfaces_optional" or dt == "glasslike"
					or dt == "glasslike_framed" or dt == "glasslike_framed_optional" then
				c.filled = true
			elseif dt == "liquid" or dt == "flowingliquid" then
				c.filled = true
				c.liquid = true
			end
		end
	end
	cls_cache[cid] = c
	return c
end

-- A coarse cell chooses a representative from its 4 cubed nodes: any filled
-- node keeps the cell occupied. Its material represents the visible top
-- area, so a trunk buried in a crown cannot repaint that crown as wood.
local function summarise_vm(vm, pmin)
	local emin, emax = vm:get_emerged_area()
	local data = vm:get_data()
	local light = vm:get_light_data()
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local cells, liquid_tops, liquid_cells = {}, {}, {}
	local block_liquid = nil
	local block_known, block_complete = false, true
	local block_day, block_night = 0, 0
	for cz = 0, 3 do
		for cy = 0, 3 do
			for cx = 0, 3 do
				local ci = (cz * 4 + cy) * 4 + cx
				local chosen_liquid = nil
				local liquid_top = 0
				local cell_known, day, night = false, 0, 0
				for z = pmin.z + cz * 4, pmin.z + cz * 4 + 3 do
					for y = pmin.y + cy * 4, pmin.y + cy * 4 + 3 do
						for x = pmin.x + cx * 4, pmin.x + cx * 4 + 3 do
							local vi = area:index(x, y, z)
							local cid = data[vi]
							if cid ~= c_ignore then
								cell_known, block_known = true, true
								local li = light[vi] or 0
								day = math.max(day, li % 16)
								night = math.max(night, math.floor(li / 16) % 16)
								local c = classify(cid)
								if c.filled then
									if c.liquid then
										liquid_top = math.max(liquid_top,
											y - (pmin.y + cy * 4) + 1)
										chosen_liquid, block_liquid = cid, cid
									end
								end
							else
								block_complete = false
							end
						end
					end
				end
				local chosen = surface_material(4, function(x, y, z)
					local cid = data[area:index(pmin.x + cx * 4 + x,
						pmin.y + cy * 4 + y, pmin.z + cz * 4 + z)]
					local c = classify(cid)
					if c.filled and not c.liquid then return cid end
				end)
				if not cell_known then
					cells[ci] = -1
				else
					cells[ci] = chosen or false
				end
				liquid_cells[ci] = chosen_liquid ~= nil
				liquid_tops[ci] = chosen_liquid and liquid_top < 4 and liquid_top or 0
				block_day = math.max(block_day, day)
				block_night = math.max(block_night, night)
			end
		end
	end
	if not block_known then
		return nil
	end
	local tops = {}
	for i = 0, 15 do
		local packed = 0
		for j = 0, 3 do
			packed = packed + (liquid_tops[i * 4 + j] or 0) * 2 ^ (j * 2)
		end
		tops[#tops + 1] = string.char(packed)
	end
	local mask = {}
	for b = 0, 7 do
		local packed = 0
		for j = 0, 7 do
			if liquid_cells[b * 8 + j] then packed = packed + 2 ^ j end
		end
		mask[#mask + 1] = string.char(packed)
	end
	return {
		complete = block_complete, cells = cells, tops = table.concat(tops),
		day = block_day, night = block_night, liquid = block_liquid,
		mask = table.concat(mask),
	}
end

-- A batch of blocks, for one async job: a list of {vm, pmin}, answered by a
-- list of the same length in which a block that is not generated, or whose
-- summary failed, is false. The pcall is not caution for its own sake: an
-- error escaping an async job is a mod error, which stops the server.
local function summarise_batch(blocks)
	local out = {}
	for i, b in ipairs(blocks) do
		local ok, s = pcall(summarise_vm, b[1], b[2])
		if ok then
			out[i] = s or false
		else
			core.log("warning", "[goanna] far summary failed: " .. tostring(s))
			out[i] = false
		end
	end
	return out
end

-- In the async environment there is nothing to return the functions to, so
-- the job that init.lua sends finds them by a global name instead. The
-- server thread's environment has core.get_player_by_name; the async one does
-- not.
if not core.get_player_by_name then
	rawset(_G, "goanna_far_summary_batch", summarise_batch)
end

return {block = summarise_vm, batch = summarise_batch}
