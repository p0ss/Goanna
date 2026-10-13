-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Copyright (C) 2026 the Goanna contributors
--
-- Pregenerates a box of the world on the server, with no client, and then
-- shuts the server down. tools/dev/make-standard-world.sh installs it as a
-- worldmod for one run and removes it afterwards; it is not for a world
-- anyone plays.
--
-- Settings (from the server conf the script writes):
--   goanna_pregen_min, goanna_pregen_max  the box, as "(x,y,z)"
--   goanna_pregen_parallel               mapchunks queued at once
--
-- The box is cut into mapchunks (80 nodes a side at the default chunksize)
-- and emerged nearest the centre first, a few at a time from each one's
-- completion callback, so the emerge queue never holds the whole box.
-- Progress goes to the log as GOANNA_PREGEN lines, the last of which is
-- GOANNA_PREGEN_DONE.

local function pos_setting(name)
	local p = core.string_to_pos(core.settings:get(name) or "")
	if not p then
		error("standard-world-pregen: " .. name .. " is not set")
	end
	return p
end

local pmin = pos_setting("goanna_pregen_min")
local pmax = pos_setting("goanna_pregen_max")
local parallel = tonumber(core.settings:get("goanna_pregen_parallel") or "") or 4

-- Mapchunks are aligned on -32 + 80k at chunksize 5.
local csize = 16 * (tonumber(core.get_mapgen_setting("chunksize")) or 5)
local offset = -16 * math.floor((csize / 16) / 2)

local function align(v)
	return math.floor((v - offset) / csize) * csize + offset
end

local chunks = {}
local cx = (pmin.x + pmax.x) / 2
local cz = (pmin.z + pmax.z) / 2
for x = align(pmin.x), pmax.x, csize do
	for z = align(pmin.z), pmax.z, csize do
		for y = align(pmin.y), pmax.y, csize do
			local d = (x + csize / 2 - cx) ^ 2 + (z + csize / 2 - cz) ^ 2
			chunks[#chunks + 1] = {x = x, y = y, z = z, d = d}
		end
	end
end
table.sort(chunks, function(a, b)
	if a.d ~= b.d then
		return a.d < b.d
	end
	if a.x ~= b.x then
		return a.x < b.x
	end
	if a.z ~= b.z then
		return a.z < b.z
	end
	return a.y < b.y
end)

local total = #chunks
local next_index = 1
local finished = 0
local started_at

local function report_done()
	core.log("action", string.format("GOANNA_PREGEN_DONE %d chunks in %d s",
		total, os.time() - started_at))
	core.request_shutdown("pregeneration done", false, 1)
end

local start_one

local function on_chunk(_, _, remaining)
	if remaining > 0 then
		return
	end
	finished = finished + 1
	if finished % 50 == 0 or finished == total then
		core.log("action", string.format("GOANNA_PREGEN %d/%d chunks, %d s",
			finished, total, os.time() - started_at))
	end
	if finished == total then
		-- Let the last blocks reach the database before stopping.
		core.after(5, report_done)
		return
	end
	start_one()
end

start_one = function()
	if next_index > total then
		return
	end
	local c = chunks[next_index]
	next_index = next_index + 1
	core.emerge_area(c, {x = c.x + csize - 1, y = c.y + csize - 1, z = c.z + csize - 1},
		on_chunk)
end

core.after(2, function()
	started_at = os.time()
	core.log("action", string.format("GOANNA_PREGEN start %d chunks from %s to %s",
		total, core.pos_to_string(pmin), core.pos_to_string(pmax)))
	if total == 0 then
		report_done()
		return
	end
	for _ = 1, parallel do
		start_one()
	end
end)
