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
-- reply at another version gets a logged warning and no answer. Version 7,
-- 2026-08-26, is 92 bytes per block, laid out above block_summary below.
-- It is a 4 by 4 by 4 voxel field rather than a heightfield, so caves,
-- overhangs and floating islands retain coarse vertical occupancy; packed
-- liquid tops keep flat water at its real height through every mip. Unlike
-- version 5, its flags distinguish a useful partial record from a complete
-- one, so a partially emerged mountain is retried rather than cached forever.
-- Version 5 was the same record without the completeness flag.
-- Version 4 (2026-08-25) was the same occupancy field without liquid tops.
-- Version 3 (2026-08-23) was 69 bytes per block, terrain heights and
-- vegetation bounds per 4 node horizontal cell.
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
-- A procedural surface provider can answer much farther away without
-- emerging or reading mapblocks. Keep that cheap horizon independent from
-- the real/generated-data grant, which also drives backfill and optional
-- pregeneration. Without this split, extending TDL's horizon to 4096 nodes
-- would ask Luanti to generate the same enormous voxel volume.
local far_provider_distance = conf_num("goanna_far_provider_distance", far_distance)
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

-- content id -> {filled, solid, liquid}, from the node's registration.
-- The same rule the client's chain uses: a full cube or cube shaped drawtype
-- or a liquid draws, and a full solid cube blocks light. Version 4 treats
-- vegetation as ordinary occupied voxels; there is no separate heightfield
-- path that needs to classify it away from terrain.
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

-- One block's record, or nil if the block is not generated. Protocol
-- version 7, 2026-08-26, 92 bytes:
--   flags (16 has emerged data, 8 all nodes emerged/record complete)
--   64 coarse contents, indexed (z * 4 + y) * 4 + x:
--       0 known air, 1..254 one based into the area's name list,
--       255 unknown (only possible at a partially emerged frontier)
--   16 bytes of packed 2-bit liquid surface heights, four cells per byte:
--       0 full cell/non-liquid, 1..3 height within the 4-node cell
--   maximum raw day and night light for the block (0 to 15)
--   one liquid content id for the block, then a 64-bit per-cell liquid mask
-- Solid contents and liquid occupancy are independent, so a coarse cell can
-- retain both its opaque seabed and the water envelope over it.
-- Per-voxel light would make an 8 cubed area's base64 exceed Luanti's 16-bit
-- mod-channel string limit. Occupancy is the topology-critical part; light
-- stays at v3's block granularity until replies are chunked.
--
-- A coarse cell chooses a representative from its 4 cubed nodes: any filled
-- node keeps the cell occupied, opaque wins over non-opaque, and ties use a
-- stable z/y/x scan order. The client uses the same rule on live/store nodes
-- and recursively for cell 8 and 16, so changing source or tier does not
-- reinterpret a heightfield. Most importantly Y is never discarded.
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
	local function idx_of(cid)
		if not cid then
			return 0
		end
		local name = core.get_name_from_content_id(cid)
		if not name then
			return #names > 0 and 1 or 0
		end
		local i = name_index[name]
		if not i then
			i = #names + 1
			if i > 254 then
				-- Preserve occupancy even if an exceptionally varied area
				-- exhausts the one-byte palette. Its first material is a
				-- better degradation than turning this voxel into air.
				return 1
			end
			names[i] = name
			name_index[name] = i
		end
		return i
	end
	local contents, liquid_tops, liquid_cells = {}, {}, {}
	local block_liquid = nil
	local block_known, block_complete = false, true
	local block_day, block_night = 0, 0
	for cz = 0, 3 do
		for cy = 0, 3 do
			for cx = 0, 3 do
				local ci = (cz * 4 + cy) * 4 + cx
				local chosen, chosen_score, chosen_liquid = nil, -1, nil
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
									else
										local score = c.solid and 2 or 1
										if score >= chosen_score then
											chosen, chosen_score = cid, score
										end
									end
								end
							else
								block_complete = false
							end
						end
					end
				end
				contents[ci] = not cell_known and 255 or idx_of(chosen)
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
	local parts = {string.char(16 + (block_complete and 8 or 0))}
	for i = 0, 63 do parts[#parts + 1] = string.char(contents[i]) end
	for i = 0, 15 do
		local packed = 0
		for j = 0, 3 do
			packed = packed + (liquid_tops[i * 4 + j] or 0) * 2 ^ (j * 2)
		end
		parts[#parts + 1] = string.char(packed)
	end
	parts[#parts + 1] = string.char(block_day, block_night)
	parts[#parts + 1] = string.char(idx_of(block_liquid))
	for b = 0, 7 do
		local packed = 0
		for j = 0, 7 do
			if liquid_cells[b * 8 + j] then packed = packed + 2 ^ j end
		end
		parts[#parts + 1] = string.char(packed)
	end
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
-- in the same 92 byte layout the wire carries (x fastest, then y, then z),
-- with the area's own name list beside it. A record whose complete bit is
-- clear is ungenerated or only partly emerged. A request for an area whose
-- records are all complete is answered by lookup; one with gaps retries only
-- those records while still sending their useful partial contents.
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
local REC = 92
local AREA = 8
local AREA_BLOCKS = AREA * AREA * AREA
-- Protocol v7, provider-shell schema 1. The wire layout did not change, but
-- old provider records materialised every buried block in a 128-node slab.
-- Keep their persistent cache separate so a restart cannot resurrect that
-- million-block interior after the visible-shell fix.
local STORE_KEY = "fs7s1:"
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
	-- Complete, not merely useful. A partial record remains in the blob and
	-- can be sent to clients, but every request retries it until all of the
	-- mapblock has emerged.
	return blob:byte(i * REC + 1) % 16 >= 8
end

local function record_available(blob, i)
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
	assert(#rec == REC, "far summary record has the wrong size")
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

-- Every record is complete or has been looked at and found wholly
-- ungenerated. A partial record does not settle its area and is retried.
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
	goanna_announce("far_provider_distance", tostring(far_provider_distance))
end

-- Fill every record in the area that is not known with what the provider
-- says. Records made this way are remembered in a.synth so a real read can
-- replace them later.
local function synthesise_area(a)
	if not far_provider or a.known + 0 >= AREA_BLOCKS then
		return false
	end
	local x0, y0, z0 = a.ax * AREA * 16, a.ay * AREA * 16, a.az * AREA * 16
	-- One-cell border lets the visible-shell test agree across area edges.
	-- Without it, every 128-node boundary was treated as an exposed cliff.
	local cols = {} -- per 4 node cell, bordered 34 x 34
	local ok_any = false
	for cz = -1, AREA * 4 do
		for cx = -1, AREA * 4 do
			local sy, top, wy, side = far_provider(x0 + cx * 4 + 2, z0 + cz * 4 + 2)
			if sy then
				ok_any = true
				cols[(cz + 1) * 34 + cx + 1] = {sy = sy, top = top, wy = wy, side = side or top}
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
			if i > 254 then
				return 0
			end
			a.names[i] = name
			a.name_index[name] = i
		end
		return i
	end
	local made = 0
	for i = 0, AREA_BLOCKS - 1 do
		-- Never replace real partial voxel data with the provider's height
		-- estimate. Partial records are retried by summarise(); synthesis is
		-- only for a block for which the map supplied nothing at all.
		if not record_available(a.blob, i) then
			local bx = i % AREA
			local by = math.floor(i / AREA) % AREA
			local bz = math.floor(i / (AREA * AREA))
			local floor_y = y0 + by * 16
			local contents, liquid_tops, liquid_cells = {}, {}, {}
			local any = false
			local any_air = false
			for cz = 0, 3 do
				for cy = 0, 3 do
					for cx = 0, 3 do
						local ci = (cz * 4 + cy) * 4 + cx
						local gx, gz = bx * 4 + cx, bz * 4 + cz
						local col = cols[(gz + 1) * 34 + gx + 1]
						if not col then
							contents[ci] = 255
						else
							any = true
							local lo, hi = floor_y + cy * 4, floor_y + cy * 4 + 3
							local name, liquid_top, liquid = nil, 0, false
							-- Retain the visible height shell, not every fully buried
							-- 4-node cell down to the bottom of this 128-node slab. A
							-- column descends only as far as its lowest neighbour, which
							-- preserves cliffs while removing occluded interior blocks.
							local exposed_floor = col.sy
							local neighbours = {
								cols[(gz + 1) * 34 + gx],
								cols[(gz + 1) * 34 + gx + 2],
								cols[gz * 34 + gx + 1],
								cols[(gz + 2) * 34 + gx + 1],
							}
							for _, neighbour in ipairs(neighbours) do
								if neighbour then exposed_floor = math.min(exposed_floor, neighbour.sy) end
							end
							if lo <= col.sy and hi >= exposed_floor - 3 then
								name = col.sy >= lo and col.sy <= hi and col.top or col.side
							end
							-- Solid and liquid are independent. In a shallow cell the
							-- seabed occupies its lower nodes while water occupies the
							-- nodes above it; choosing one with elseif reopened exactly
							-- the shoreline holes this representation is meant to close.
							if col.wy and hi > col.sy and lo <= col.wy then
								liquid = true
								liquid_top = col.wy < hi and col.wy - lo + 1 or 0
							end
						contents[ci] = idx_of(name)
						liquid_cells[ci] = liquid
							liquid_tops[ci] = liquid_top
							any_air = any_air or not name
						end
					end
				end
			end
			if any then
				local complete = true
				for c = 0, 63 do
					if contents[c] == 255 then complete = false break end
				end
				local parts = {string.char(16 + (complete and 8 or 0))}
				for c = 0, 63 do parts[#parts + 1] = string.char(contents[c]) end
				for b = 0, 15 do
					local packed = 0
					for j = 0, 3 do
						packed = packed + (liquid_tops[b * 4 + j] or 0) * 2 ^ (j * 2)
					end
					parts[#parts + 1] = string.char(packed)
				end
				parts[#parts + 1] = string.char(any_air and 15 or 0, 0)
				parts[#parts + 1] = string.char(idx_of(far_provider_water))
				for b = 0, 7 do
					local packed = 0
					for j = 0, 7 do
						if liquid_cells[b * 8 + j] then packed = packed + 2 ^ j end
					end
					parts[#parts + 1] = string.char(packed)
				end
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
			(a.checked[i] and not record_available(a.blob, i) and not fresh)) then
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
	elseif not record_available(a.blob, i) and not a.checked[i] then
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
-- it has just finished. A completed offer goes immediately after whichever
-- job is part way through: it is useful new frontier already paid for by
-- mapgen, whereas an ask can be a speculative scan of 512 ungenerated
-- blocks. Letting asks stay ahead forever saturated the summary budget and
-- made asynchronously generated terrain wait indefinitely to be published.
local far_queue = {}

local function queue_area(player_name, cell, ox, oy, oz, edge, offered)
	-- A slow or partly generated area can be requested again before its old
	-- job reaches the head. Keeping both copies let four client retries grow
	-- into an effectively permanent queue, and completed pregeneration offers
	-- then had no room to enter it. One player needs at most one pending reply
	-- for one area. A direct request upgrades an existing background offer and
	-- moves it ahead of the remaining offers.
	for i = 1, #far_queue do
		local old = far_queue[i]
		if old.who == player_name and old.ox == ox and old.oy == oy and old.oz == oz and
				old.cell == cell and old.edge == edge then
			if not offered and old.offered then
				old.offered = false
			end
			return false
		end
	end
	local job = {
		who = player_name, cell = cell, ox = ox, oy = oy, oz = oz, edge = edge,
		i = 0, offered = offered,
	}
	if offered and #far_queue > 0 then
		-- Keep the active head in place, then the FIFO run of completed
		-- offers, then speculative asks.
		local at = 2
		while at <= #far_queue and far_queue[at].offered do
			at = at + 1
		end
		table.insert(far_queue, at, job)
		return true
	end
	far_queue[#far_queue + 1] = job
	return true
end

local FARSUM_VERSION = 7

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
	-- Generated blocks are the output side of the asynchronous producer.
	-- Requests used to run first and could consume this whole budget forever
	-- by scanning new empty areas, leaving completed mapgen unindexed and its
	-- offers unable to become complete wire areas. Reserve half for fresh
	-- output before servicing speculative reads; the ordinary pass below may
	-- still use anything left after replies.
	local fresh_budget = math.max(1, math.floor(blocks_per_step / 2))
	while budget > 0 and fresh_budget > 0 and gen_head <= #gen_queue do
		local h = gen_queue[gen_head]
		gen_queue[gen_head] = nil
		gen_head = gen_head + 1
		gen_set[h] = nil
		local p = core.get_position_from_hash(h)
		if summarise(p.x, p.y, p.z, false, true) then
			budget = budget - 1
			fresh_budget = fresh_budget - 1
		end
	end
	if gen_head > #gen_queue then
		gen_queue, gen_head = {}, 1
	end
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
local far_log_stats = conf_bool("goanna_far_log_stats", false)
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
-- Number of independent area streams. emerge_area itself is asynchronous,
-- but one stream waits for each slice callback before submitting the next;
-- at flying speed that serial producer cannot keep the horizon around the
-- player. A small pipeline keeps the emerge workers occupied without ever
-- putting more than one slice per stream into their forced FIFO queue.
local pregen_concurrency = math.max(1,
		math.min(8, math.floor(conf_num("goanna_far_pregenerate_concurrency", 2))))
local pregen_slices = math.floor((8 / pregen_slice) ^ 3)
local pregen = {
	wait = 0, done = {}, pending = {}, active = {},
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
			for z = 0, 3 do
				for x = 0, 3 do
					local bottom = blob:byte(base + 1 + (z * 4) * 4 + x)
					local top = blob:byte(base + 1 + (z * 4 + 3) * 4 + x)
					if ly == AREA - 1 and top > 0 and top < 255 then
						open_above = true
					end
					if ly == 0 and (bottom == 0 or bottom == 255) then
						open_below = true
					end
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

-- Submit one slice for one independent area stream. The completion callback
-- only advances this job; the globalstep submits its next slice, which keeps
-- callback re-entry and the emerge queue bounded and predictable.
local function pregen_emerge(job)
	local a, i = job.area, job.slice
	-- floored: a float here would put fractional node coordinates in pmin
	local n = math.floor(8 / pregen_slice)
	local edge = pregen_slice * 16
	local pmin = vector.new(
			a.x * 128 + (i % n) * edge,
			a.y * 128 + (math.floor(i / n) % n) * edge,
			a.z * 128 + math.floor(i / (n * n)) * edge)
	local pmax = vector.add(pmin, edge - 1)
	job.busy, job.since = true, 0
	job.serial = job.serial + 1
	local serial = job.serial
	core.emerge_area(pmin, pmax, function(blockpos, action, calls_remaining)
		if calls_remaining > 0 or job.serial ~= serial then
			return
		end
		job.busy = false
		job.slice = i + 1
		if job.slice < pregen_slices then
			return
		end
		-- The area is whole: retire this stream and offer it to nearby
		-- clients. Queue deduplication keeps this from duplicating an ask.
		job.complete = true
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

local function pregen_start_area()
	local a = pregen_pick()
	if not a then
		return false
	end
	pregen.done[a.key] = true
	pregen.active[#pregen.active + 1] = {
		area = a, slice = 0, busy = false, since = 0, serial = 0, complete = false,
	}
	return true
end

core.register_globalstep(function(dtime)
	if not pregen_enabled then
		return
	end
	-- Finished areas are offered as the queue has room. Depth is not what
	-- costs a client here, since queue_area puts an asked job ahead of every
	-- offered one; this only bounds the memory a backlog of offers holds.
	-- Completed areas are bounded independently of the eight speculative
	-- asks. Otherwise a permanently full ask queue prevents the output of
	-- pregeneration from entering at all.
	while #pregen.pending > 0 and #far_queue < 32 do
		local a = table.remove(pregen.pending, 1)
		queue_area(a.who, 16, a.x * 8, a.y * 8, a.z * 8, 8, true)
	end
	-- Retire completed streams, and recover a slice whose callback was lost.
	-- Incrementing serial makes a very late old callback harmless.
	for i = #pregen.active, 1, -1 do
		local job = pregen.active[i]
		if job.complete then
			table.remove(pregen.active, i)
		elseif job.busy then
			job.since = job.since + dtime
			if job.since > 120 then
				job.serial = job.serial + 1
				job.busy = false
			end
		end
	end
	pregen.wait = pregen.wait - dtime
	if core.get_server_max_lag() > pregen_lag_limit then
		-- Behind already. Look again soon: the check costs nothing and a
		-- long pause here turns one slow step into a long stall.
		pregen.wait = 0.5
		return
	end
	-- Keep every stream moving, but only one slice per stream may be queued.
	for _, job in ipairs(pregen.active) do
		if not job.busy then
			pregen_emerge(job)
		end
	end
	-- Fill the pipeline gradually. The interval now paces stream starts;
	-- slices within each stream still run back to back.
	if #pregen.active < pregen_concurrency and pregen.wait <= 0 then
		if pregen_start_area() then
			pregen.wait = pregen_interval
			pregen_emerge(pregen.active[#pregen.active])
		else
			pregen.wait = math.max(pregen_interval, 1)
		end
	end
end)

-- Low-frequency pipeline evidence for long-running servers. The far path is
-- otherwise intentionally quiet, which made an hour-long stall impossible to
-- distinguish from a client rendering failure after the fact.
if far_log_stats then
	local stats_timer = 0
	core.register_globalstep(function(dtime)
		stats_timer = stats_timer + dtime
		if stats_timer < 30 then
			return
		end
		stats_timer = 0
		local done, asked = 0, 0
		for _ in pairs(pregen.done) do done = done + 1 end
		for _, job in ipairs(far_queue) do
			if not job.offered then asked = asked + 1 end
		end
		local generated = math.max(0, #gen_queue - gen_head + 1)
		core.log("action", string.format(
				"[goanna] far stats: areas_started=%d active=%d pending=%d " ..
				"reply_queue=%d asked=%d generated_queue=%d cache_areas=%d " ..
				"lua_mb=%.1f max_lag=%.3f",
				done, #pregen.active, #pregen.pending, #far_queue, asked,
				generated, store_count, collectgarbage("count") / 1024,
				core.get_server_max_lag()))
	end)
end

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
	local request_distance = far_provider and far_provider_distance or far_distance
	if dist > request_distance + edge * 16 then
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
	-- Providers synthesise from their bake without VoxelManip/emerge work, so
	-- let the client keep a wider bounded network window while filling a 4 km
	-- baseline. Generated-world summaries retain the conservative old limit.
	local asked_limit = far_provider and 24 or 8
	if asked < asked_limit then
		queue_area(sender, cell, ox, oy, oz, edge)
		-- A camera above the cloud layer otherwise has to discover empty
		-- 128-node Y slabs one request round at a time before it ever asks for
		-- the ground. A procedural provider already knows the surface without
		-- map reads, so publish the matching ground slab as a companion offer.
		-- This is the provider equivalent of a height-indexed LOD database and
		-- is what lets an aerial horizon fill outward instead of downward.
		if far_provider then
			local sy = far_provider(cx, cz)
			if sy then
				local ground_oy = fdiv(math.floor(sy), AREA * 16) * AREA
				if ground_oy ~= oy then
					queue_area(sender, cell, ox, ground_oy, oz, edge, true)
				end
			end
		end
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
