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
-- Version 2, 2026-08-22: the record grew from 6 bytes to 21, so a client and
-- a mod that disagree on <ver> must not try to read each other's bytes as if
-- they agreed. A pre-version request or reply has five numbers where this one
-- has six, so the pattern below simply does not match it, and GoannaClient
-- logs a plain error rather than silently drawing whatever six bytes happened
-- to fall out of a twenty-one byte record. The blob is one 21 byte record per
-- block, x fastest then y then z:
--   flags (2 occludes, 4 lit, 8 liquid, 16 known; bit 1 is unused since this
--   version, see below), a 4 by 4 grid of surface heights within the block
--   (one byte each, 0 to 16, x fastest then z, over 4 node cells), top
--   content index, side content index (1 based into the name list, 0 none),
--   day light, night light (raw 0-15).
--
-- Version 1 sent one height for the whole block and gated the whole record on
-- at least half its columns being filled, so a block that was mostly empty
-- but for a beach's thin edge or a hill's sloped flank was reported as
-- entirely empty. The per cell grid makes that gate pointless: a cell with
-- nothing in it already reports height 0, and the client's chain builder
-- reads "filled" straight off the height rather than off a whole block
-- majority, which is also why the flags byte's old bit 1 goes unused now.
--
-- Work is queued and paced by goanna_far_summary_blocks_per_step, so a
-- request costs the server a bounded slice of each step, and the operator
-- owns the knob next to the grant itself. The larger record does not raise
-- the per block cost much: it is still one VoxelManip read per block, now
-- bucketing each column into one of 16 height cells instead of one, which is
-- index arithmetic on data already read rather than a second read.

local far_enabled = conf_bool("goanna_far_rendering", false)
local far_distance = conf_num("goanna_far_rendering_distance", 512)
-- One mapblock is a 16 cubed VoxelManip read, a few hundred microseconds.
-- 32 a step keeps an 8 cubed area (512 blocks) to about 1.5 seconds of
-- wall clock without any step costing much, and the operator owns the knob.
local blocks_per_step = conf_num("goanna_far_summary_blocks_per_step", 32)
local c_ignore = core.CONTENT_IGNORE
local c_air = core.CONTENT_AIR

-- content id -> {filled, solid, liquid}, from the node's registration. The
-- same rule the client's chain uses: a full cube or cube shaped drawtype or
-- a liquid draws, a full solid cube blocks light.
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

-- One block's 21 byte record, or nil if the block is not generated. The
-- height grid is 4 by 4 over the block's 16 by 16 footprint, one byte per
-- 4 node cell, index z * 4 + x; top and side content stay a single pair for
-- the whole block, which is most of what keeps the record at 21 bytes rather
-- than one per cell.
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
	local cell_top = {}
	for i = 0, 15 do cell_top[i] = 0 end
	local top_counts, side_counts = {}, {}
	local day, night = 0, 0
	local lit = false
	local known = false
	local liquid_tops = 0
	for z = pmin.z, pmax.z do
		local cz = math.floor((z - pmin.z) / 4)
		for x = pmin.x, pmax.x do
			local cx = math.floor((x - pmin.x) / 4)
			local cell = cz * 4 + cx
			local col_top
			for y = pmax.y, pmin.y, -1 do
				local cid = data[area:index(x, y, z)]
				if cid ~= c_ignore then
					known = true
					local c = classify(cid)
					if c.filled then
						if c.solid then
							solidn = solidn + 1
						end
						if not col_top then
							col_top = cid
							local h = y - pmin.y + 1
							if h > cell_top[cell] then
								cell_top[cell] = h
							end
							if c.liquid then
								liquid_tops = liquid_tops + 1
							end
							top_counts[cid] = (top_counts[cid] or 0) + 1
							-- light of the node above the surface
							local li = light[area:index(x, math.min(y + 1, pmax.y), z)] or 0
							local d = li % 16
							local n = math.floor(li / 16) % 16
							if d > day then day = d end
							if n > night then night = n end
							if d > 0 or n > 0 then lit = true end
						else
							side_counts[cid] = (side_counts[cid] or 0) + 1
						end
					end
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
	local topc = mode(top_counts)
	local sidec = mode(side_counts) or topc
	local flags = 16
	if solidn >= 256 then flags = flags + 2 end
	if lit then flags = flags + 4 end
	if topc and classify(topc).liquid and liquid_tops * 2 >= 256 then flags = flags + 8 end
	local heights = {}
	for i = 0, 15 do
		heights[i + 1] = string.char(math.min(cell_top[i], 16))
	end
	return string.char(flags) .. table.concat(heights) ..
			string.char(idx_of(topc), idx_of(sidec), day, night)
end

-- Per player work queue: one request is an area; blocks are summarised a few
-- per step and the reply sent when the area completes.
--
-- Two kinds of job share it. A client asked for one and is waiting on it; a
-- pregenerated area is offered unasked and nobody is waiting. A job is 512
-- blocks, about a second and a half, so a plain queue put an asking client
-- behind however many offers happened to be in front of it. An asked job
-- therefore goes ahead of every offered one, after whichever job is part
-- way through: no work is lost, the offers still go out, and the player
-- waiting on the view in front of them is served first.
local far_queue = {}

local function queue_area(player_name, cell, ox, oy, oz, edge, offered)
	local job = {
		who = player_name, cell = cell, ox = ox, oy = oy, oz = oz, edge = edge,
		i = 0, records = {}, names = {}, name_index = {}, offered = offered,
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

-- Version 2's record; see the protocol comment above block_summary.
local FARSUM_VERSION = 2
local EMPTY_RECORD = string.rep("\0", 21)

core.register_globalstep(function()
	local job = far_queue[1]
	if not job then
		return
	end
	local total = job.edge * job.edge * job.edge
	local n = 0
	while job.i < total and n < blocks_per_step do
		local i = job.i
		local bx = job.ox + i % job.edge
		local by = job.oy + math.floor(i / job.edge) % job.edge
		local bz = job.oz + math.floor(i / (job.edge * job.edge))
		job.records[i + 1] = block_summary(bx, by, bz, job.names, job.name_index) or EMPTY_RECORD
		job.i = i + 1
		n = n + 1
	end
	if job.i >= total then
		table.remove(far_queue, 1)
		if channel and channel:is_writeable() then
			channel:send_all(string.format("farsum %s %d %d %d %d %d %d %s|%s",
					job.who, FARSUM_VERSION, job.cell, job.ox, job.oy, job.oz, job.edge,
					table.concat(job.names, ","),
					core.encode_base64(table.concat(job.records))))
		end
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

-- Nearest area to any connected player that this session has not generated.
-- Nearest counts the vertical too, which is not fussiness: the search covers
-- one area above and below the player's own, all three at the same
-- horizontal distance, and a tie went to the first one found, which was
-- always the one below. Every column was therefore generated deep stone
-- first and surface last, which is the layer nobody can see being paid for
-- before the only one anybody looks at. docs/launch-target.md task 8 is the
-- rest of that story: the vertical extent asked for is still mostly sky and
-- stone, and only the client asking within the generated extent fixes it.
local function pregen_pick()
	local best, best_d
	local aradius = math.ceil(far_distance / 128)
	for _, player in ipairs(core.get_connected_players()) do
		local pp = player:get_pos()
		local ax, ay, az = math.floor(pp.x / 128), math.floor(pp.y / 128), math.floor(pp.z / 128)
		for dz = -aradius, aradius do
			for dy = -1, 1 do
				for dx = -aradius, aradius do
					local key = (ax + dx) .. ":" .. (ay + dy) .. ":" .. (az + dz)
					if not pregen.done[key] then
						local cx, cz = (ax + dx) * 128 + 64, (az + dz) * 128 + 64
						local d = math.max(math.abs(cx - pp.x), math.abs(cz - pp.z))
						-- the player's own layer first, then the two beside it
						local rank = d + math.abs(dy) * 64
						if d <= far_distance and (not best_d or rank < best_d) then
							best = {x = ax + dx, y = ay + dy, z = az + dz, key = key}
							best_d = rank
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
	if ver ~= 2 then
		core.log("warning", "[goanna] a client asked for a far summary at protocol version " ..
				ver .. ", this mod speaks version 2; no reply sent.")
		return
	end
	if cell ~= 16 or edge ~= 8 then
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
