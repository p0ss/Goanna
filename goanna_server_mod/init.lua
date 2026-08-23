-- Goanna server mod: tells a Goanna client what this server permits.
--
-- The whole design rests on one rule. A Goanna client must never give a player
-- reach or information a vanilla Luanti client lacks. Some of the things
-- Goanna could do would break that rule if the client simply decided to do
-- them. So it does not decide. This mod is how a server operator grants them,
-- and a server without this mod grants nothing, which is why absence is the
-- safe default rather than a failure: every option here is off unless someone
-- deliberately turned it on.
--
-- Nothing about this is required. Goanna connects to unmodified servers over
-- the ordinary protocol and renders them exactly as it does today. This only
-- ever adds.

local CHANNEL = "goanna:v1"
local channel = core.mod_channel_join(CHANNEL)

local function conf_bool(key, default)
	local v = core.settings:get_bool(key)
	if v == nil then return default end
	return v
end

local function conf_num(key, default)
	local v = tonumber(core.settings:get(key))
	return v or default
end

-- What we advertise, and the reason this mod does not enumerate capabilities.
--
-- The obvious design is a list here: far_rendering, source_movement, and one
-- more line every time a capability is added. That forces this mod to be
-- updated in lockstep with every client feature, and leaves a server running
-- last year's copy unable to authorise anything newer, for no reason beyond
-- bookkeeping.
--
-- So it enumerates nothing. Every setting named goanna_* is relayed as it is
-- found, and neither end needs this mod to understand what any of them mean.
-- A client that knows a key uses it; one that does not ignores it; a key no
-- client knows yet costs nothing. Adding a permission is then an edit to
-- minetest.conf, not a new release of this mod.
--
-- Two consequences worth stating. Unknown keys must be ignored silently at
-- both ends, which is what makes this safe to extend. And nothing secret goes
-- in a goanna_* setting, because all of them are broadcast to every client
-- that asks.
local extra = {}

-- For submods: a capability needing server side behaviour rather than only
-- the operator's consent announces itself here. See README.md for when a
-- submod is the right shape and when a setting is enough.
function goanna_announce(key, value)
	extra[key] = tostring(value)
end

local function options()
	local o = {}
	local seen = {}
	for _, key in ipairs(core.settings:get_names()) do
		if key:sub(1, 7) == "goanna_" and not seen[key] then
			seen[key] = true
			-- strip the prefix: the namespace exists to find them in the
			-- server's config, not to be repeated on the wire
			o[#o + 1] = key:sub(8) .. "=" .. tostring(core.settings:get(key))
		end
	end
	for k, v in pairs(extra) do
		if not seen["goanna_" .. k] then
			o[#o + 1] = k .. "=" .. v
		end
	end
	table.sort(o)
	return table.concat(o, "\n")
end

-- Far terrain summaries: the "places you have not been" half of far
-- rendering (docs/far-rendering.md). A Goanna client may ask for a coarse
-- summary of an area of the map, and this answers from terrain the server
-- has already generated, never generating any: an ungenerated block is
-- reported unknown and stays a hole. It reads the same map any player would
-- eventually be sent, and it only answers at all when the operator granted
-- far rendering, so the reach is given, not taken.
--
-- Request:  "farsum? <ver> <cell> <ox> <oy> <oz> <edge>"  (block coords, edge
-- in blocks; only cell 16 and edge 8 are served today).
-- Reply:    "farsum <who> <ver> <cell> <ox> <oy> <oz> <edge> <names,csv>|<base64>"
--
-- The reply names its requester because a mod channel has no unicast: Luanti
-- only offers send_all, so every client on the channel sees every reply and
-- filters by that name. Worth an operator knowing plainly: granting far
-- rendering grants coarse summaries of terrain near any player who asks, to
-- every Goanna client on the server, not only to the one that asked. The
-- distance check below is against the asking player, and the grant is server
-- wide, so this widens what is seen by other players' whereabouts rather
-- than by any distance beyond the grant.
--
-- The version number is how a client and a mod that disagree on the record
-- refuse each other rather than misreading each other's bytes: a request or
-- reply at another version gets a logged warning and no answer. Version 3,
-- 2026-08-23, is 69 bytes per block, laid out above block_summary below.
-- Version 2 (2026-08-22) was 21 bytes, one height per 4 node cell; version 1
-- one height per block. The blob is one record per block, x fastest then y
-- then z, base64 encoded after the area's name list.
--
-- Reading the map is paced by goanna_far_summary_blocks_per_step, so it
-- costs the server a bounded slice of each step, and the operator owns the
-- knob next to the grant itself. Since 2026-08-23 a block is read once and
-- its record kept (see "The summary store" below), so that rate paces the
-- reading and not the answering: an area the store knows is answered at
-- once.

local far_enabled = conf_bool("goanna_far_rendering", false)
local far_distance = conf_num("goanna_far_rendering_distance", 512)
-- One mapblock is a 16 cubed VoxelManip read, a few hundred microseconds.
--
-- This is the rate the whole far view fills at, and it was the reason a
-- horizon arrived as a mosaic. The queue is one job at a time, an area is
-- 512 mapblocks, so 32 a step is 16 steps, about 1.6 seconds an area, which
-- is 320 mapblocks a second for every client on the server put together. A
-- 1024 node grant is 128 by 128 mapblocks around each player, so one
-- horizontal layer of it is 16384 blocks and takes eight minutes. The
-- player watching that sees panels appear one at a time for the whole of it.
--
-- 96 is three times the rate and still a bounded slice: measured against
-- mineclonia on this machine, one step of 96 blocks is a few milliseconds
-- against a 100 ms step. The guard below is what makes raising it safe,
-- rather than the number itself being cautious.
local blocks_per_step = conf_num("goanna_far_summary_blocks_per_step", 96)
-- Stop summarising while the server is behind, the same guard and the same
-- default as pregeneration's. Without it the knob above is a promise the
-- operator cannot take back on a loaded server; with it, the rate is what
-- the server can afford rather than what someone guessed. See the note
-- above goanna_far_pregenerate_lag for why 0.5 rather than something near
-- the step length.
local summary_lag_limit = conf_num("goanna_far_summary_lag", 0.5)
local c_ignore = core.CONTENT_IGNORE
local c_air = core.CONTENT_AIR

-- content id -> {filled, solid, liquid, veg}, from the node's registration.
-- The same rule the client's chain uses: a full cube or cube shaped drawtype
-- or a liquid draws, a full solid cube blocks light. Vegetation is what the
-- far surface keeps out of the ground: trees, leaves, cacti, bamboo and the
-- plant groups, by the node's own groups, the list mirrored in
-- src/goanna_lod.cpp so a summary and a chain built from nodes agree on
-- what the terrain is.
local VEG_GROUPS = {"tree", "leaves", "cactus", "bamboo", "plant", "flora", "sapling",
	"flower", "mushroom", "fruit", "vines"}
local cls_cache = {}
local function classify(cid)
	local c = cls_cache[cid]
	if c then
		return c
	end
	c = {filled = false, solid = false, liquid = false, veg = false}
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
			local groups = def.groups or {}
			for _, g in ipairs(VEG_GROUPS) do
				if (groups[g] or 0) > 0 then
					c.veg = true
					break
				end
			end
		end
	end
	cls_cache[cid] = c
	return c
end

-- One block's record, or nil if the block is not generated. Protocol
-- version 3, 2026-08-23, 69 bytes:
--   flags (2 occludes, 4 lit, 8 liquid, 16 known)
--   16 terrain heights: per 4 node cell (z * 4 + x), the highest filled node
--     that is not vegetation, as height within the block, 0 to 16, 0 none
--   16 vegetation bases and 16 vegetation tops: per cell, the lowest and
--     highest vegetation node above the cell's terrain, 1 to 16, 0 none
--   16 terrain top content indices, per cell, 1 based into the name list
--   vegetation content index (one for the block), side content index
--   day light, night light (raw 0 to 15)
-- Version 2 carried one height per cell with no base and no split, so a
-- canopy crossing a block boundary was drawn as a slab on that block's floor
-- and a tree was a pillar of ground; the surface the client now draws over
-- the terrain heights needs the vegetation kept out of them.
local function block_summary(bx, by, bz, names, name_index)
	local pmin = vector.new(bx * 16, by * 16, bz * 16)
	local pmax = vector.add(pmin, 15)
	-- read_from_map is what get_voxel_manip does; the emerged area may be
	-- larger than asked, and an ungenerated block reads back as ignore.
	local vm = core.get_voxel_manip(pmin, pmax)
	local emin, emax = vm:get_emerged_area()
	local data = vm:get_data()
	local light = vm:get_light_data()
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local solidn = 0
	local terr, terr_c, veg_lo, veg_hi = {}, {}, {}, {}
	for i = 0, 15 do
		terr[i], terr_c[i], veg_lo[i], veg_hi[i] = 0, nil, 0, 0
	end
	local veg_counts, side_counts = {}, {}
	local day, night = 0, 0
	local lit = false
	local known = false
	local liquid_tops, tops = 0, 0
	for z = pmin.z, pmax.z do
		local cz = math.floor((z - pmin.z) / 4)
		for x = pmin.x, pmax.x do
			local cx = math.floor((x - pmin.x) / 4)
			local cell = cz * 4 + cx
			local col_top = false
			local col_terr, col_terr_c = 0, nil
			local col_veg_lo, col_veg_hi = 0, 0
			for y = pmax.y, pmin.y, -1 do
				local cid = data[area:index(x, y, z)]
				if cid ~= c_ignore then
					known = true
					local c = classify(cid)
					if c.filled then
						if c.solid then
							solidn = solidn + 1
						end
						local h = y - pmin.y + 1
						if not col_top then
							col_top = true
							tops = tops + 1
							if c.liquid then
								liquid_tops = liquid_tops + 1
							end
							-- light of the node above the surface
							local li = light[area:index(x, math.min(y + 1, pmax.y), z)] or 0
							local d = li % 16
							local n = math.floor(li / 16) % 16
							if d > day then day = d end
							if n > night then night = n end
							if d > 0 or n > 0 then lit = true end
						end
						if c.veg then
							if col_terr == 0 then
								-- vegetation above the terrain
								if col_veg_hi == 0 then
									col_veg_hi = h
								end
								col_veg_lo = h
								veg_counts[cid] = (veg_counts[cid] or 0) + 1
							end
						elseif col_terr == 0 then
							col_terr, col_terr_c = h, cid
						else
							side_counts[cid] = (side_counts[cid] or 0) + 1
						end
					end
				end
			end
			if col_terr > terr[cell] then
				terr[cell], terr_c[cell] = col_terr, col_terr_c
			end
			if col_veg_hi > 0 then
				if col_veg_hi > veg_hi[cell] then
					veg_hi[cell] = col_veg_hi
				end
				if veg_lo[cell] == 0 or col_veg_lo < veg_lo[cell] then
					veg_lo[cell] = col_veg_lo
				end
			end
		end
	end
	if not known then
		return nil
	end
	local function mode(counts)
		local best, bn = nil, 0
		for cid, n in pairs(counts) do
			if n > bn then
				best, bn = cid, n
			end
		end
		return best
	end
	local function idx_of(cid)
		if not cid then
			return 0
		end
		local name = core.get_name_from_content_id(cid)
		if not name then
			return 0
		end
		local i = name_index[name]
		if not i then
			i = #names + 1
			if i > 255 then
				return 0
			end
			names[i] = name
			name_index[name] = i
		end
		return i
	end
	-- Vegetation that sits inside the cell's terrain run, a bush beside a
	-- taller column, is hidden in it and is not a box; clamp the base above
	-- the terrain and drop what does not reach.
	local terr_counts = {}
	for i = 0, 15 do
		if veg_hi[i] <= terr[i] then
			veg_lo[i], veg_hi[i] = 0, 0
		elseif veg_lo[i] <= terr[i] then
			veg_lo[i] = terr[i] + 1
		end
		if terr_c[i] then
			terr_counts[terr_c[i]] = (terr_counts[terr_c[i]] or 0) + 1
		end
	end
	local topc = mode(terr_counts)
	local vegc = mode(veg_counts)
	local sidec = mode(side_counts) or topc
	local flags = 16
	if solidn >= 256 then flags = flags + 2 end
	if lit then flags = flags + 4 end
	if topc and classify(topc).liquid and liquid_tops * 2 >= tops then flags = flags + 8 end
	local parts = {string.char(flags)}
	for i = 0, 15 do parts[#parts + 1] = string.char(math.min(terr[i], 16)) end
	for i = 0, 15 do parts[#parts + 1] = string.char(math.min(veg_lo[i], 16)) end
	for i = 0, 15 do parts[#parts + 1] = string.char(math.min(veg_hi[i], 16)) end
	for i = 0, 15 do parts[#parts + 1] = string.char(idx_of(terr_c[i])) end
	parts[#parts + 1] = string.char(idx_of(vegc), idx_of(sidec), day, night)
	return table.concat(parts)
end

-- The summary store, 2026-08-23.
--
-- Until today every request read every block of its area through a
-- VoxelManip at the moment it was asked, one job at a time for every client
-- on the server, so a 1024 node grant took five to ten minutes to fill for
-- one client on an idle server and was recomputed from nothing for every
-- client that joined. The rate the far view filled at was the rate this mod
-- could read the map, and that is not a rate anyone wants to watch.
--
-- Now a block is summarised once and kept. Records live in areas of 8 by 8
-- by 8 mapblocks, the unit a client asks for, as one string of 512 records
-- in the same 21 byte layout the wire carries (x fastest, then y, then z),
-- with the area's own name list beside it. A record whose known bit is clear
-- is a block this mod has not summarised, or has looked at and found
-- ungenerated. A request for an area whose records are all known is
-- answered the same step, by lookup; one with gaps has only the gaps read.
--
-- Three things fill the store without anyone asking:
--   - register_on_generated: every freshly generated block is summarised
--     within a few steps, while it is still in memory, so terrain made
--     while the server runs is known before any client wants it.
--   - register_on_mapblocks_changed: a block someone has dug, built on or
--     flooded is summarised again, with a short cooling period because the
--     blocks around a player change every step.
--   - backfill: when the queues are idle, the nearest area to a player
--     that is not yet settled is summarised anyway, so a world generated
--     before this store existed is read once in the background rather than
--     on the first client's clock.
-- Everything is paced by goanna_far_summary_blocks_per_step and paused by
-- the lag guard, as before, and asked jobs go ahead of all of it.
--
-- Areas are written to mod storage as names|base64(records) under a key
-- that carries the protocol version, a few seconds after they change and
-- all of them on shutdown, and loaded back the first time they are touched.
-- Areas untouched for ten minutes are let go once the store grows past
-- goanna_far_summary_cache_areas, and reloaded from storage when wanted.
--
-- What this does not do yet: tell a client that a block it has already been
-- given has changed. A client never asks twice for an area that came back
-- complete, so far terrain someone else has altered stays as it was until
-- the client rejoins or walks there. The pregeneration offers below are
-- the one unasked push there is.
local REC = 69
local AREA = 8
local AREA_BLOCKS = AREA * AREA * AREA
local STORE_KEY = "fs3:"
local EMPTY_BLOB = string.rep("\0", REC * AREA_BLOCKS)
local cache_limit = conf_num("goanna_far_summary_cache_areas", 4096)
local backfill_enabled = conf_bool("goanna_far_summary_backfill", true)
local storage = core.get_mod_storage()

local store = {}
local store_count = 0

local function now()
	return core.get_us_time() / 1e6
end

local function fdiv(a, b)
	return math.floor(a / b)
end

local function area_key(ax, ay, az)
	return ax .. ":" .. ay .. ":" .. az
end

local function split_csv(s)
	local out = {}
	if s == "" then
		return out
	end
	for name in s:gmatch("[^,]+") do
		out[#out + 1] = name
	end
	return out
end

local function record_known(blob, i)
	return blob:byte(i * REC + 1) % 32 >= 16
end

local function load_area(ax, ay, az)
	local key = area_key(ax, ay, az)
	local a = store[key]
	if a then
		a.touched = now()
		return a
	end
	a = {
		ax = ax, ay = ay, az = az, key = key,
		blob = EMPTY_BLOB, known = 0, names = {}, name_index = {},
		checked = {}, nchecked = 0, dirty = false, saved = 0, touched = now(),
	}
	local s = storage:get_string(STORE_KEY .. key)
	if s ~= "" then
		local csv, b64, synth_csv = s:match("^([^|]*)|([^|]*)|?(.*)$")
		local blob = b64 and core.decode_base64(b64)
		if blob and #blob == REC * AREA_BLOCKS then
			a.blob = blob
			for i, name in ipairs(split_csv(csv)) do
				a.names[i] = name
				a.name_index[name] = i
			end
			for i = 0, AREA_BLOCKS - 1 do
				if record_known(blob, i) then
					a.known = a.known + 1
				end
			end
			if synth_csv and synth_csv ~= "" then
				a.synth = {}
				for i in synth_csv:gmatch("[^,]+") do
					a.synth[tonumber(i)] = true
				end
			end
		end
	end
	store[key] = a
	store_count = store_count + 1
	return a
end

local function save_area(a)
	local synth = {}
	if a.synth then
		for i in pairs(a.synth) do
			synth[#synth + 1] = tostring(i)
		end
	end
	storage:set_string(STORE_KEY .. a.key,
			table.concat(a.names, ",") .. "|" .. core.encode_base64(a.blob) .. "|" ..
			table.concat(synth, ","))
	a.dirty = false
	a.saved = now()
end

local function set_record(a, i, rec)
	local was = record_known(a.blob, i)
	a.blob = a.blob:sub(1, i * REC) .. rec .. a.blob:sub((i + 1) * REC + 1)
	if not was then
		a.known = a.known + 1
	end
	if a.checked[i] then
		a.checked[i] = nil
		a.nchecked = a.nchecked - 1
	end
	a.dirty = true
end

-- Every record is known or has been looked at and found ungenerated. Such
-- an area is not worth reading again: the only way a record in it changes
-- is generation, which register_on_generated reports, or a node change,
-- which register_on_mapblocks_changed reports.
local function area_settled(a)
	return a.known + a.nchecked >= AREA_BLOCKS
end

local last_summarised = {}

-- Settled areas, kept as a set so the backfill can pass over them without
-- loading them, and persisted as one list because it is monotonic: the only
-- things that change a settled area's records, generation and node changes,
-- keep it settled.
local settled = {}
local settled_dirty = false
do
	local s = storage:get_string(STORE_KEY .. "settled")
	for key in s:gmatch("[^,]+") do
		settled[key] = true
	end
end

-- Summarise one block into the store. Returns true when the map was read,
-- which is what the per step budget counts; false when the store already
-- had an answer and nothing was spent. `force` reads whatever the store
-- holds, for a block that has changed; `fresh` reads a block the store has
-- only ever seen ungenerated, for one that has just been generated.
-- A far surface provider, 2026-08-23: the answer to "must it be explored".
--
-- The far field needs one thing per column, where the ground is and what it
-- is made of, and a mapgen that can say that for any (x, z) without
-- generating anything can give it directly: the terrain diffusion mapgen
-- reads a baked elevation and climate cache, and the engine mapgens can
-- not, which is why this is a hook rather than a built in. Distant Horizons'
-- server side does the same thing, asking the world generator at reduced
-- detail. A registered provider is asked for the columns of any block the
-- store finds ungenerated, at one sample per 4 node cell, and the record
-- made from that is served as known, so a client sees the whole grant in
-- seconds on a world nobody has walked. When a block is really generated,
-- register_on_generated replaces the synthesised record with the real one
-- (detail noise, trees, caves) and the area is offered again to the clients
-- near it, which take the newer summary over the synthesised chain.
--
--   goanna_register_far_surface(fn, opts)
--     fn(x, z) -> surface_y, top_name, water_y, side_name
--       surface_y: y of the topmost ground node, or nil if unknown
--       top_name:  node name of that ground node
--       water_y:   y of the water surface over it, or nil
--       side_name: node name under the surface (optional)
--     opts.water: node name of the water (default "mcl_core:water_source")
-- Nothing here generates or changes the world, and the server decides to
-- offer it; the client asks for the same summaries as before.
local far_provider = nil
local far_provider_water = "mcl_core:water_source"
function goanna_register_far_surface(fn, opts)
	far_provider = fn
	if opts and opts.water then
		far_provider_water = opts.water
	end
end

-- Fill every record in the area that is not known with what the provider
-- says. Records made this way are remembered in a.synth so a real read can
-- replace them later.
local function synthesise_area(a)
	if not far_provider or a.known + 0 >= AREA_BLOCKS then
		return false
	end
	local x0, y0, z0 = a.ax * AREA * 16, a.ay * AREA * 16, a.az * AREA * 16
	local cols = {} -- per 4 node cell over the area footprint: 32 x 32
	local ok_any = false
	for cz = 0, AREA * 4 - 1 do
		for cx = 0, AREA * 4 - 1 do
			local sy, top, wy, side = far_provider(x0 + cx * 4 + 2, z0 + cz * 4 + 2)
			if sy then
				ok_any = true
				cols[cz * 32 + cx] = {sy = sy, top = top, wy = wy, side = side or top}
			end
		end
	end
	if not ok_any then
		return false
	end
	a.synth = a.synth or {}
	local function idx_of(name)
		if not name then
			return 0
		end
		local i = a.name_index[name]
		if not i then
			i = #a.names + 1
			if i > 255 then
				return 0
			end
			a.names[i] = name
			a.name_index[name] = i
		end
		return i
	end
	local made = 0
	for i = 0, AREA_BLOCKS - 1 do
		if not record_known(a.blob, i) then
			local bx = i % AREA
			local by = math.floor(i / AREA) % AREA
			local bz = math.floor(i / (AREA * AREA))
			local floor_y = y0 + by * 16
			local parts = {}
			local tops, liquid, solid_cells, air_cells = {}, 0, 0, 0
			local heights, tidx = {}, {}
			local any = false
			for c = 0, 15 do
				local col = cols[(bz * 4 + math.floor(c / 4)) * 32 + bx * 4 + c % 4]
				local th, ti = 0, 0
				if col then
					any = true
					local top_y, top_name = col.sy, col.top
					if col.wy and col.wy >= col.sy then
						top_y, top_name = col.wy, far_provider_water
					end
					local raw = top_y - floor_y + 1
					th = raw
					if th < 0 then th = 0 elseif th > 16 then th = 16 end
					if raw > 16 then
						-- the surface is above this block: what shows here,
						-- if anything ever does, is what is under it, or the
						-- water standing over the ground
						ti = idx_of(col.wy and col.wy > floor_y + 15 and col.sy <= floor_y + 15
								and far_provider_water or col.side)
						solid_cells = solid_cells + 1
					elseif raw >= 1 then
						-- the surface node is in this block, at its ceiling
						-- when raw is 16, and it is still the surface
						ti = idx_of(top_name)
						tops[top_name] = (tops[top_name] or 0) + 1
						if top_name == far_provider_water then
							liquid = liquid + 1
						end
						if raw == 16 then
							solid_cells = solid_cells + 1
						end
					else
						air_cells = air_cells + 1
					end
				end
				heights[c] = th
				tidx[c] = ti
			end
			if any then
				local flags = 16
				if solid_cells == 16 then flags = flags + 2 end
				if solid_cells < 16 then flags = flags + 4 end
				if liquid * 2 >= 16 then flags = flags + 8 end
				parts[1] = string.char(flags)
				for c = 0, 15 do parts[#parts + 1] = string.char(heights[c]) end
				parts[#parts + 1] = string.rep("\0", 32) -- no vegetation
				for c = 0, 15 do parts[#parts + 1] = string.char(tidx[c]) end
				-- vegetation index, side index, day, night
				local side_name = nil
				for c = 0, 15 do
					local col = cols[(bz * 4 + math.floor(c / 4)) * 32 + bx * 4 + c % 4]
					if col then side_name = col.side break end
				end
				parts[#parts + 1] = string.char(0, idx_of(side_name), solid_cells < 16 and 15 or 0, 0)
				set_record(a, i, table.concat(parts))
				a.synth[i] = true
				made = made + 1
			end
		end
	end
	if made > 0 and not settled[a.key] and area_settled(a) then
		settled[a.key] = true
		settled_dirty = true
	end
	return made > 0
end

-- Summarise one block into the store. Returns true when the map was read,
-- which is what the per step budget counts; false when the store already
-- had an answer and nothing was spent.
local reoffer = {}

local function summarise(bx, by, bz, force, fresh)
	local ax, ay, az = fdiv(bx, AREA), fdiv(by, AREA), fdiv(bz, AREA)
	local a = load_area(ax, ay, az)
	local i = (bx - ax * AREA) + (by - ay * AREA) * AREA + (bz - az * AREA) * AREA * AREA
	local synth = a.synth and a.synth[i]
	if not force and ((record_known(a.blob, i) and not (synth and fresh)) or
			(a.checked[i] and not fresh)) then
		return false
	end
	local rec = block_summary(bx, by, bz, a.names, a.name_index)
	if rec then
		set_record(a, i, rec)
		if synth then
			-- A real block where the provider's guess was: the clients that
			-- were given the guess are offered the area again.
			a.synth[i] = nil
			reoffer[a.key] = a
		end
	elseif not a.checked[i] then
		a.checked[i] = true
		a.nchecked = a.nchecked + 1
	end
	if not settled[a.key] and area_settled(a) then
		settled[a.key] = true
		settled_dirty = true
	end
	last_summarised[core.hash_node_position({x = bx, y = by, z = bz})] = now()
	return true
end

-- Jobs that end in a reply: a client asked, or pregeneration offers an area
-- it has just finished. An asked job goes ahead of every offered one, after
-- whichever job is part way through, as before: no work is lost and the
-- player waiting on the view in front of them is served first. A job only
-- reads the blocks the store does not know, so on a store that is warm it
-- finishes in the step it was queued.
local far_queue = {}

local function queue_area(player_name, cell, ox, oy, oz, edge, offered)
	local job = {
		who = player_name, cell = cell, ox = ox, oy = oy, oz = oz, edge = edge,
		i = 0, offered = offered,
	}
	if not offered then
		for i = 2, #far_queue do
			if far_queue[i].offered then
				table.insert(far_queue, i, job)
				return
			end
		end
	end
	far_queue[#far_queue + 1] = job
end

local FARSUM_VERSION = 3

local function send_area(job)
	if not (channel and channel:is_writeable()) then
		return
	end
	local a = load_area(fdiv(job.ox, AREA), fdiv(job.oy, AREA), fdiv(job.oz, AREA))
	channel:send_all(string.format("farsum %s %d %d %d %d %d %d %s|%s",
			job.who, FARSUM_VERSION, job.cell, job.ox, job.oy, job.oz, job.edge,
			table.concat(a.names, ","), core.encode_base64(a.blob)))
end

-- Blocks to summarise that nobody is waiting on: freshly generated ones
-- first, then changed ones once their cooling period is over.
local gen_queue, gen_set = {}, {}
local gen_head = 1
local change_due = {}
local CHANGE_COOL = 5

core.register_on_generated(function(minp, maxp)
	-- The blocks are written to the map after this callback returns, so they
	-- are read on a later step, by which time they are in memory.
	for bz = fdiv(minp.z, 16), fdiv(maxp.z, 16) do
		for by = fdiv(minp.y, 16), fdiv(maxp.y, 16) do
			for bx = fdiv(minp.x, 16), fdiv(maxp.x, 16) do
				local h = core.hash_node_position({x = bx, y = by, z = bz})
				if not gen_set[h] then
					gen_set[h] = true
					gen_queue[#gen_queue + 1] = h
				end
			end
		end
	end
end)

if core.register_on_mapblocks_changed then
	core.register_on_mapblocks_changed(function(modified_blocks)
		local t = now() + CHANGE_COOL
		for h in pairs(modified_blocks) do
			if not gen_set[h] and not change_due[h] then
				change_due[h] = t
			end
		end
	end)
else
	core.log("warning", "[goanna] this server has no register_on_mapblocks_changed " ..
			"(Luanti 5.7 or later); far summaries will not follow node changes")
end

-- Nearest area to any player, in the player's own layer or the one either
-- side, that is not yet settled. This is the background read of a world
-- that existed before the store did; on one generated under this mod it
-- finds nothing to do.
local function backfill_pick()
	local cands = {}
	local aradius = math.ceil(far_distance / 128)
	for _, player in ipairs(core.get_connected_players()) do
		local pp = player:get_pos()
		local ax, ay, az = fdiv(pp.x, 128), fdiv(pp.y, 128), fdiv(pp.z, 128)
		for dz = -aradius, aradius do
			for dy = -1, 1 do
				for dx = -aradius, aradius do
					local key = area_key(ax + dx, ay + dy, az + dz)
					if not settled[key] then
						local cx, cz = (ax + dx) * 128 + 64, (az + dz) * 128 + 64
						local d = math.max(math.abs(cx - pp.x), math.abs(cz - pp.z))
						if d <= far_distance then
							cands[#cands + 1] = {
								x = ax + dx, y = ay + dy, z = az + dz,
								rank = d + math.abs(dy) * 64,
							}
						end
					end
				end
			end
		end
	end
	table.sort(cands, function(p, q) return p.rank < q.rank end)
	-- Nearest first, loading only until one is found that is really not
	-- settled; an area settled before the set was kept is added to it here.
	for _, c in ipairs(cands) do
		local a = load_area(c.x, c.y, c.z)
		if area_settled(a) then
			settled[a.key] = true
			settled_dirty = true
		else
			return a
		end
	end
	return nil
end

local backfill = {area = nil, i = 0, wait = 0}

-- Persistence and memory. A dirty area is written a few seconds after it
-- last changed rather than on every record, since generation and changes
-- touch the same area many times in a row; everything dirty is written on
-- shutdown. Past the cache limit, areas untouched for ten minutes are let
-- go and come back from storage when next wanted.
local flush_timer = 0
local function flush(all)
	if settled_dirty then
		local keys = {}
		for key in pairs(settled) do
			keys[#keys + 1] = key
		end
		storage:set_string(STORE_KEY .. "settled", table.concat(keys, ","))
		settled_dirty = false
	end
	local n = 0
	local t = now()
	for _, a in pairs(store) do
		if a.dirty and (all or t - a.saved > 5) then
			save_area(a)
			n = n + 1
			if not all and n >= 4 then
				return
			end
		end
	end
end

core.register_on_shutdown(function()
	flush(true)
end)

local sweep_timer = 0
local function sweep()
	local t = now()
	for h, at in pairs(last_summarised) do
		if t - at > CHANGE_COOL then
			last_summarised[h] = nil
		end
	end
	if store_count <= cache_limit then
		return
	end
	for key, a in pairs(store) do
		if t - a.touched > 600 then
			if a.dirty then
				save_area(a)
			end
			store[key] = nil
			store_count = store_count - 1
		end
	end
end

local EDGE_BLOCKS = AREA_BLOCKS

core.register_globalstep(function(dtime)
	flush_timer = flush_timer + dtime
	if flush_timer > 1 then
		flush_timer = 0
		flush(false)
	end
	sweep_timer = sweep_timer + dtime
	if sweep_timer > 60 then
		sweep_timer = 0
		sweep()
	end
	-- A job that is part way through is not abandoned, only paused: the
	-- records already read are in the store and it carries on when the
	-- server catches up.
	if core.get_server_max_lag() > summary_lag_limit then
		return
	end
	local budget = blocks_per_step
	local sent = 0
	-- Replies first. A job whose area the store already knows costs nothing
	-- and is sent at once; several can go in one step, bounded so a warm
	-- store does not turn one step into a burst the connection will queue.
	while far_queue[1] and sent < 4 do
		local job = far_queue[1]
		while job.i < EDGE_BLOCKS and budget > 0 do
			local i = job.i
			local bx = job.ox + i % job.edge
			local by = job.oy + math.floor(i / job.edge) % job.edge
			local bz = job.oz + math.floor(i / (job.edge * job.edge))
			if summarise(bx, by, bz, false) then
				budget = budget - 1
			end
			job.i = i + 1
		end
		if job.i < EDGE_BLOCKS then
			break
		end
		table.remove(far_queue, 1)
		if far_provider then
			synthesise_area(load_area(fdiv(job.ox, AREA), fdiv(job.oy, AREA), fdiv(job.oz, AREA)))
		end
		send_area(job)
		sent = sent + 1
	end
	-- Areas whose provider guess has been replaced by real terrain since they
	-- were last sent: offered again to the players near them, a few a step.
	if next(reoffer) then
		local offered = 0
		for key, a in pairs(reoffer) do
			reoffer[key] = nil
			for _, player in ipairs(core.get_connected_players()) do
				local pp = player:get_pos()
				local d = math.max(math.abs(a.ax * 128 + 64 - pp.x), math.abs(a.az * 128 + 64 - pp.z))
				if d <= far_distance + 128 then
					queue_area(player:get_player_name(), 16, a.ax * 8, a.ay * 8, a.az * 8, 8, true)
				end
			end
			offered = offered + 1
			if offered >= 2 then
				break
			end
		end
	end
	-- Freshly generated blocks, while they are still in memory.
	while budget > 0 and gen_head <= #gen_queue do
		local h = gen_queue[gen_head]
		gen_queue[gen_head] = nil
		gen_head = gen_head + 1
		gen_set[h] = nil
		local p = core.get_position_from_hash(h)
		if summarise(p.x, p.y, p.z, false, true) then
			budget = budget - 1
		end
	end
	if gen_head > #gen_queue then
		gen_queue, gen_head = {}, 1
	end
	-- Changed blocks, once they have stopped changing for a moment.
	if budget > 0 then
		local t = now()
		for h, due in pairs(change_due) do
			if budget <= 0 then
				break
			end
			if due <= t then
				change_due[h] = nil
				local last = last_summarised[h]
				if not last or t - last >= CHANGE_COOL then
					local p = core.get_position_from_hash(h)
					if summarise(p.x, p.y, p.z, true) then
						budget = budget - 1
					end
				else
					change_due[h] = last + CHANGE_COOL
				end
			end
		end
	end
	-- Backfill, with what is left.
	if not backfill_enabled or budget <= 0 then
		return
	end
	if not backfill.area then
		backfill.wait = backfill.wait - dtime
		if backfill.wait > 0 then
			return
		end
		local a = backfill_pick()
		if not a then
			backfill.wait = 5
			return
		end
		backfill.area, backfill.i = a, 0
	end
	local a = backfill.area
	while budget > 0 and backfill.i < AREA_BLOCKS do
		local i = backfill.i
		local bx = a.ax * AREA + i % AREA
		local by = a.ay * AREA + math.floor(i / AREA) % AREA
		local bz = a.az * AREA + math.floor(i / (AREA * AREA))
		if summarise(bx, by, bz, false) then
			budget = budget - 1
		end
		backfill.i = i + 1
	end
	if backfill.i >= AREA_BLOCKS then
		if far_provider then
			synthesise_area(a)
		end
		backfill.area = nil
	end
end)

-- Pregeneration: the other half of "places you have never been" on a world
-- that has none yet. A summary can only digest terrain that exists, and a
-- server generates only within the range its client asks for (clientiface
-- caps max_block_generate_distance by the client's wanted range), so a fresh
-- world has a 192 node horizon whatever the grant says, and the first player
-- on it sees exactly that. This is the server's own answer, and it is off
-- unless the operator turns it on, because it spends mapgen CPU and map
-- memory on terrain no one has walked to: one 128 node area at a time,
-- nearest to a player first, with a pause between areas, out to the far
-- rendering distance. Nothing here changes what a client may ask; the server
-- generates its own world on its own schedule, exactly as it would for a
-- player walking there, and then tells the clients near it what it made.
--
-- Each finished area is summarised for every client within range without
-- being asked, because a client that asked while the area was still
-- ungenerated was told there was nothing there and does not ask twice.
--
-- It must lose that race to the player, and the first version of it did not.
-- An area is 8 by 8 by 8 mapblocks, and `core.emerge_area` on the whole of
-- it put all 512 into the server's emerge queue in one call. Lua's emerge
-- carries BLOCK_EMERGE_FORCE_QUEUE (`l_env.cpp`), so none of the queue
-- limits that hold an ordinary client's requests back apply to it, and each
-- emerge thread's queue is a plain FIFO: the blocks the player is waiting
-- for went in behind the whole backlog. Measured on mineclonia, one such
-- batch is up to about three seconds of mapgen, and 400 blocks around a
-- player arriving somewhere new took 5.3 seconds to arrive where the same
-- world with pregeneration off took 4.0 (docs/far-rendering.md,
-- "Pregeneration yields to the player").
--
-- So an area is emerged a slice at a time, `pregen_slice` mapblocks on a
-- side, and the next slice is started from the previous one's completion
-- callback rather than on a clock. The queue then holds one slice rather
-- than one area, the player's own requests are never more than a slice
-- behind, and the horizon still fills at the rate the interval sets, since
-- the interval now paces areas and the slices within one run back to back.
-- `core.get_server_max_lag` is the other half: a server already behind its
-- step gets left alone until it catches up.
local pregen_enabled = far_enabled and conf_bool("goanna_far_pregenerate", false)
local pregen_interval = conf_num("goanna_far_pregenerate_interval", 1)
-- Mapblocks on a side of one emerge call. 4 is 64 blocks, smaller than the
-- 5 cubed chunk mapgen works in, so a slice is one or two chunks of work.
-- Must divide 8; anything else is rounded down to the nearest that does.
local pregen_slice = conf_num("goanna_far_pregenerate_slice", 4)
if pregen_slice >= 8 then
	pregen_slice = 8
elseif pregen_slice >= 4 then
	pregen_slice = 4
elseif pregen_slice >= 2 then
	pregen_slice = 2
else
	pregen_slice = 1
end
-- Seconds of server step time above which pregeneration waits. Read
-- get_server_max_lag before choosing a number: it is a running maximum that
-- halves every minute (`Server::AsyncRunStep`), not an average, so one slow
-- step pins it high for a long time afterwards. A threshold near the step
-- length therefore reads as "behind" almost permanently: at 0.2 this mod's
-- own summary pass tripped it, and pregeneration stalled to a third of its
-- rate on a server that was fine. Half a second is five times the 0.1 s
-- step, high enough to mean something is really wrong.
local pregen_lag_limit = conf_num("goanna_far_pregenerate_lag", 0.5)
local pregen_slices = math.floor((8 / pregen_slice) ^ 3)
local pregen = {
	busy = false, since = 0, wait = 0, done = {}, pending = {},
	area = nil, slice = 0,
}

-- What the store says about an area's faces, for the vertical walk below:
-- ground reaching its ceiling means the column carries on above; air along
-- its floor means there is something under it worth making. An area the
-- store has not settled says nothing either way.
local function area_faces(ax, ay, az)
	local a = load_area(ax, ay, az)
	if not area_settled(a) or a.known == 0 then
		return false, false, false
	end
	local open_above, open_below = false, false
	local blob = a.blob
	for i = 0, AREA_BLOCKS - 1 do
		local ly = math.floor(i / AREA) % AREA
		if (ly == 0 or ly == AREA - 1) and record_known(blob, i) then
			local base = i * REC + 1
			for c = 0, 15 do
				local th = blob:byte(base + 1 + c)
				local vh = blob:byte(base + 33 + c)
				if ly == AREA - 1 and (th >= 16 or vh >= 16) then
					open_above = true
				end
				if ly == 0 and th == 0 then
					open_below = true
				end
			end
		end
	end
	return true, open_above, open_below
end

-- Nearest area to any connected player that this session has not generated.
-- Nearest counts the vertical too, which is not fussiness: a tie between
-- the layer the player is in and the one below went to the one found first,
-- which was always the one below, so every column was generated deep stone
-- first and surface last.
--
-- The search used to stop one area above and below the player's own, which
-- on ordinary terrain is the whole of what can be seen. On terrain with
-- three kilometres of relief it is not: a player on a 500 node mountain had
-- the valleys under them never generated, because the lowland was three
-- layers down. So beyond the one layer either side, an area is a candidate
-- only when the area nearer the player's layer is generated and its summary
-- (this mod's own store, which pregeneration fills as it goes) says the
-- terrain carries on that way: ground at its ceiling for upward, air along
-- its floor for downward. Sky above a plain and rock under it are never
-- asked for, and a mountain or a valley is followed to its end. The same
-- rule the client's request walk uses (docs/far-rendering.md, "Lids, layers
-- and the vertical walk").
local PREGEN_LAYERS = 5
local function pregen_pick()
	local best, best_d
	local aradius = math.ceil(far_distance / 128)
	for _, player in ipairs(core.get_connected_players()) do
		local pp = player:get_pos()
		local ax, ay, az = math.floor(pp.x / 128), math.floor(pp.y / 128), math.floor(pp.z / 128)
		for dz = -aradius, aradius do
			for dx = -aradius, aradius do
				local cx, cz = (ax + dx) * 128 + 64, (az + dz) * 128 + 64
				local d = math.max(math.abs(cx - pp.x), math.abs(cz - pp.z))
				if d <= far_distance then
					for dy = -PREGEN_LAYERS, PREGEN_LAYERS do
						local key = (ax + dx) .. ":" .. (ay + dy) .. ":" .. (az + dz)
						local rank = d + math.abs(dy) * 64
						if not pregen.done[key] and (not best_d or rank < best_d) then
							local wanted = math.abs(dy) <= 1
							if not wanted then
								local towards = dy > 0 and -1 or 1
								local nkey = (ax + dx) .. ":" .. (ay + dy + towards) .. ":" .. (az + dz)
								if pregen.done[nkey] then
									local settled, above, below = area_faces(ax + dx, ay + dy + towards, az + dz)
									wanted = settled and ((dy > 0 and above) or (dy < 0 and below))
								end
							end
							if wanted then
								best = {x = ax + dx, y = ay + dy, z = az + dz, key = key}
								best_d = rank
							end
						end
					end
				end
			end
		end
	end
	return best
end

-- One slice of the current area, or the next area's first slice. The
-- completion callback runs on an emerge thread, so it only sets the state
-- the globalstep above reads.
local function pregen_emerge()
	if not pregen.area then
		local a = pregen_pick()
		if not a then
			-- Nothing left in range. The search is a few hundred keys, so
			-- pause before asking again rather than every step.
			pregen.wait = pregen_interval
			return
		end
		pregen.done[a.key] = true
		pregen.area, pregen.slice = a, 0
	end
	local a, i = pregen.area, pregen.slice
	-- floored: a float here would put fractional node coordinates in pmin
	local n = math.floor(8 / pregen_slice)
	local edge = pregen_slice * 16
	local pmin = vector.new(
			a.x * 128 + (i % n) * edge,
			a.y * 128 + (math.floor(i / n) % n) * edge,
			a.z * 128 + math.floor(i / (n * n)) * edge)
	local pmax = vector.add(pmin, edge - 1)
	pregen.busy, pregen.since = true, 0
	core.emerge_area(pmin, pmax, function(blockpos, action, calls_remaining)
		if calls_remaining > 0 then
			return
		end
		pregen.busy = false
		pregen.slice = i + 1
		if pregen.slice < pregen_slices then
			return
		end
		-- The area is whole: pause, and offer it to the clients near it.
		pregen.area, pregen.slice = nil, 0
		pregen.wait = pregen_interval
		for _, player in ipairs(core.get_connected_players()) do
			local pp = player:get_pos()
			local d = math.max(math.abs(a.x * 128 + 64 - pp.x), math.abs(a.z * 128 + 64 - pp.z))
			if d <= far_distance + 128 then
				pregen.pending[#pregen.pending + 1] = {
					who = player:get_player_name(), x = a.x, y = a.y, z = a.z,
				}
			end
		end
	end)
end

core.register_globalstep(function(dtime)
	if not pregen_enabled then
		return
	end
	-- Finished areas are offered as the queue has room. Depth is not what
	-- costs a client here, since queue_area puts an asked job ahead of every
	-- offered one; this only bounds the memory a backlog of offers holds.
	while #pregen.pending > 0 and #far_queue < 8 do
		local a = table.remove(pregen.pending, 1)
		queue_area(a.who, 16, a.x * 8, a.y * 8, a.z * 8, 8, true)
	end
	if pregen.busy then
		pregen.since = pregen.since + dtime
		if pregen.since > 120 then
			pregen.busy = false -- the emerge never reported back; move on
		end
		return
	end
	pregen.wait = pregen.wait - dtime
	if pregen.wait > 0 then
		return
	end
	if core.get_server_max_lag() > pregen_lag_limit then
		-- Behind already. Look again soon: the check costs nothing and a
		-- long pause here turns one slow step into a long stall.
		pregen.wait = 0.5
		return
	end
	pregen_emerge()
end)

core.register_on_modchannel_message(function(channel_name, sender, message)
	if channel_name ~= CHANNEL then
		return
	end
	-- A server mod cannot see who joined a channel, only messages arriving on
	-- it, so the client says hello and this answers. send_all goes to everyone
	-- on the channel, which is fine: the options are a property of the server,
	-- not of the player, and there is nothing private in them.
	if message == "hello" and channel and channel:is_writeable() then
		-- Not cached: a submod may announce after this mod loaded.
		channel:send_all(options())
		return
	end
	local ver, cell, ox, oy, oz, edge =
			message:match("^farsum%? (%d+) (%d+) (%-?%d+) (%-?%d+) (%-?%d+) (%d+)$")
	if not ver then
		-- A pre-version request has five numbers where this one has six, so
		-- it does not match above; tell the operator plainly rather than
		-- leaving an old client's summaries silently absent.
		if far_enabled and message:match("^farsum%? %d+ %-?%d+ %-?%d+ %-?%d+ %d+$") then
			core.log("warning", "[goanna] a client asked for a far summary in the pre " ..
					"version 2 format; it will get no reply. Update its Goanna build.")
		end
		return
	end
	if not far_enabled then
		return
	end
	ver, cell, ox, oy, oz, edge =
			tonumber(ver), tonumber(cell), tonumber(ox), tonumber(oy), tonumber(oz), tonumber(edge)
	if ver ~= FARSUM_VERSION then
		core.log("warning", "[goanna] a client asked for a far summary at protocol version " ..
				ver .. ", this mod speaks version " .. FARSUM_VERSION .. "; no reply sent.")
		return
	end
	if cell ~= 16 or edge ~= 8 then
		return
	end
	-- The store is kept in areas of 8 by 8 by 8 blocks, so a request has to
	-- be one of those. A Goanna client only ever asks for aligned areas.
	if ox % 8 ~= 0 or oy % 8 ~= 0 or oz % 8 ~= 0 then
		return
	end
	-- Within the granted distance of the asking player, with a margin of one
	-- area, or it is refused silently. The grant is the boundary.
	local player = core.get_player_by_name(sender)
	if not player then
		return
	end
	local pp = player:get_pos()
	local cx, cz = (ox + edge / 2) * 16, (oz + edge / 2) * 16
	local dist = math.max(math.abs(cx - pp.x), math.abs(cz - pp.z))
	if dist > far_distance + edge * 16 then
		return
	end
	-- Only jobs someone asked for count against the limit. Counting the
	-- offered ones too meant pregeneration could fill the queue and this
	-- would refuse a player's own request, silently, and the client does not
	-- ask twice: the horizon then depended entirely on being offered the
	-- right area.
	local asked = 0
	for i = 1, #far_queue do
		if not far_queue[i].offered then
			asked = asked + 1
		end
	end
	if asked < 8 then
		queue_area(sender, cell, ox, oy, oz, edge)
	end
end)

if far_enabled then
	goanna_announce("far_summaries", "true")
end

-- Source movement produces speeds and airborne paths the server's movement
-- check rejects, so it has to be told to allow them or the option silently
-- does nothing. The setting is anticheat_flags in 5.16; disable_anticheat is
-- the old name and is migrated, but reading it here would report the wrong
-- answer on any server configured the current way. "movement" is one of the
-- flags, and clearing it is what this needs.
if conf_bool("goanna_source_movement", false) then
	local flags = core.settings:get("anticheat_flags") or "digging,interaction,movement"
	if flags:find("movement") and not flags:find("nomovement") then
		core.log("warning", "[goanna] goanna_source_movement is on but anticheat_flags " ..
				"still includes movement, so the server will reject the movement it " ..
				"produces and the option will appear to do nothing. Set " ..
				"anticheat_flags = digging,interaction to allow it.")
	end
end

core.log("action", "[goanna] server mod loaded, advertising on " .. CHANNEL)
