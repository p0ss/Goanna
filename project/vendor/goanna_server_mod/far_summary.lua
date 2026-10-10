-- SPDX-License-Identifier: LGPL-2.1-or-later
-- One mapblock's far summary, worked out from a VoxelManip.
--
-- This is the expensive half of a far summary: 4096 nodes, each classified
-- and folded into 64 coarse cells. Reading the block out of the map has to
-- happen on the server thread, but this does not, so the same code runs in
-- two places. init.lua loads it with dofile for servers without an async
-- environment, and registers it with core.register_async_dofile, where it
-- runs on Luanti's async workers against a copy of the VoxelManip
-- (docs/history/far-rendering-log.md, "Summaries off the server thread").
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
-- area, so a trunk buried in a crown cannot repaint that crown as wood; the
-- vote is surface_material.lua's, written out here.
--
-- Written for speed on 2026-10-10: index arithmetic instead of
-- VoxelArea:index, one cached kind per content id, and the surface vote
-- inline rather than through a sampling closure. About 2.8 times faster
-- under LuaJIT on terrain shaped blocks (80 us against 220 to 290), and
-- identical on 1000 test blocks, including emerged areas larger than the
-- block, part generated ones and missing light values. It matters once the
-- async workers rather than the server step are the limit
-- (docs/history/far-rendering-log.md, "Summaries off the server thread").
-- content id -> 0 empty or not drawn, 1 filled, 2 filled liquid.
local kind_cache = {}
local function kind(cid)
	local k = kind_cache[cid]
	if k then
		return k
	end
	local c = classify(cid)
	k = c.liquid and 2 or c.filled and 1 or 0
	kind_cache[cid] = k
	return k
end

local function summarise_vm(vm, pmin)
	local emin, emax = vm:get_emerged_area()
	local data = vm:get_data()
	local light = vm:get_light_data()
	local ystride = emax.x - emin.x + 1
	local zstride = ystride * (emax.y - emin.y + 1)
	-- Index of the block's own corner; VoxelArea:index without the calls.
	local base0 = (pmin.z - emin.z) * zstride + (pmin.y - emin.y) * ystride +
			(pmin.x - emin.x) + 1
	local cells, tops, mask = {}, {}, {0, 0, 0, 0, 0, 0, 0, 0}
	local block_liquid = nil
	local block_known, block_complete = false, true
	local block_day, block_night = 0, 0
	local counts, order = {}, {}
	for cz = 0, 3 do
		for cy = 0, 3 do
			for cx = 0, 3 do
				local ci = (cz * 4 + cy) * 4 + cx
				local cbase = base0 + cz * 4 * zstride + cy * 4 * ystride + cx * 4
				local chosen_liquid = nil
				local liquid_top = 0
				local cell_known, day, night = false, 0, 0
				for z = 0, 3 do
					for y = 0, 3 do
						local vi = cbase + z * zstride + y * ystride
						for _ = 0, 3 do
							local cid = data[vi]
							if cid ~= c_ignore then
								cell_known = true
								local li = light[vi] or 0
								local d = li % 16
								if d > day then day = d end
								local n = (li - d) / 16 % 16
								if n > night then night = n end
								if kind(cid) == 2 then
									if y + 1 > liquid_top then liquid_top = y + 1 end
									chosen_liquid = cid
								end
							else
								block_complete = false
							end
							vi = vi + 1
						end
					end
				end
				-- The visible top area votes: in each column, the highest
				-- filled node that is not liquid. Ties go to the content
				-- seen last among those with the most columns, as
				-- surface_material.lua decides.
				local norder = 0
				for z = 0, 3 do
					for x = 0, 3 do
						local vi = cbase + z * zstride + 3 * ystride + x
						for _ = 3, 0, -1 do
							local cid = data[vi]
							if kind(cid) == 1 then
								local c = counts[cid]
								if not c then
									norder = norder + 1
									order[norder] = cid
									counts[cid] = 1
								else
									counts[cid] = c + 1
								end
								break
							end
							vi = vi - ystride
						end
					end
				end
				local chosen, best = nil, 0
				for k = 1, norder do
					local cid = order[k]
					local c = counts[cid]
					if c >= best then chosen, best = cid, c end
					counts[cid] = nil
				end
				if cell_known then
					block_known = true
					cells[ci] = chosen or false
				else
					cells[ci] = -1
				end
				if chosen_liquid then
					block_liquid = chosen_liquid
					local b = math.floor(ci / 8)
					mask[b + 1] = mask[b + 1] + 2 ^ (ci % 8)
					if liquid_top < 4 then
						local t = math.floor(ci / 4)
						tops[t] = (tops[t] or 0) + liquid_top * 2 ^ ((ci % 4) * 2)
					end
				end
				if day > block_day then block_day = day end
				if night > block_night then block_night = night end
			end
		end
	end
	if not block_known then
		return nil
	end
	local top_chars = {}
	for i = 0, 15 do
		top_chars[i + 1] = string.char(tops[i] or 0)
	end
	for b = 1, 8 do
		mask[b] = string.char(mask[b])
	end
	return {
		complete = block_complete, cells = cells, tops = table.concat(top_chars),
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
