-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Bounded two-dimensional tiles from an explicitly granted surface provider.
-- This never reads or generates mapblocks. The disk cache is revision scoped.
return function(channel, enabled, distance, storage)
	local provider, water, revision, forest
	local queue, pending, cache, order = {}, {}, {}, {}
	local steps = {[4] = true, [8] = true, [16] = true, [64] = true, [128] = true}
	local function key(step, x, z)
		return step .. ":" .. x .. ":" .. z
	end
	local function remember(k, data)
		if not cache[k] then
			order[#order + 1] = k
		end
		cache[k] = data
		if #order > 128 then
			cache[table.remove(order, 1)] = nil
		end
	end
	local function u16(n)
		n = math.max(-32767, math.min(32767, math.floor(n))) % 65536
		return string.char(math.floor(n / 256), n % 256)
	end
	core.register_on_modchannel_message(function(name, sender, message)
		if name ~= "goanna:v1" or not enabled or not provider then return end
		local version, rev, step, tx, tz = message:match(
				"^surface%? ([12]) (%x+) (%d+) (%-?%d+) (%-?%d+)$")
		if rev ~= revision then return end
		step, tx, tz = tonumber(step), tonumber(tx), tonumber(tz)
		if not steps[step] or math.abs(tx) > 512 or math.abs(tz) > 512 then return end
		local player = core.get_player_by_name(sender)
		if not player then return end
		local p, width = player:get_pos(), step * 16
		local dx = math.max(tx * width - p.x, 0, p.x - (tx + 1) * width)
		local dz = math.max(tz * width - p.z, 0, p.z - (tz + 1) * width)
		if dx * dx + dz * dz > distance * distance then return end
		local k = version .. ":" .. key(step, tx, tz)
		local pk = sender .. ":" .. k
		if pending[pk] or #queue >= 32 then return end
		local count = 0
		for _, job in ipairs(queue) do
			if job.who == sender then count = count + 1 end
		end
		if count >= 8 then return end
		pending[pk] = true
		queue[#queue + 1] = {who = sender, k = k, pk = pk, step = step,
			x = tx, z = tz, version = tonumber(version), i = 0, records = {}, names = {}, indices = {}}
	end)
	local function build(job)
		local spans = {}
		local function index(name)
			name = name or "air"
			if not job.indices[name] then
				assert(#job.names < 254, "surface palette exceeded 254 materials")
				job.names[#job.names + 1] = name
				job.indices[name] = #job.names
			end
			return job.indices[name]
		end
		for i = 0, 255 do
			local x = (job.x * 16 + i % 16) * job.step + job.step / 2
			local z = (job.z * 16 + math.floor(i / 16)) * job.step + job.step / 2
			local sy, top, wy, side = provider(x, z, job.step)
			job.records[#job.records+1] = sy and
					(u16(sy) .. (wy and u16(wy) or string.char(128,0)) ..
					string.char(index(top),index(side or top),wy and index(water) or 0)) or
					string.rep(string.char(0),7)
			if job.version == 2 and forest then
				for _,v in ipairs(forest(x,z,job.step)) do
					-- Local X/Z, absolute Y bounds; geometry is independent of ground.
					spans[#spans+1] = u16(v.x-job.x*16*job.step) .. u16(v.z-job.z*16*job.step) ..
							u16(v.bottom) .. u16(v.top) ..
							string.char(index(v.name),v.param2 or 0,v.size,v.coverage)
				end
			end
			job.i=i+1
			coroutine.yield()
		end
		local raw=table.concat(job.records)
		if job.version==2 then
			assert(#spans<=524288, "forest tile exceeded its decoded geometry bound")
			raw=core.compress(raw..table.concat(spans),"deflate",6)
		end
		local data=table.concat(job.names,",").."|"..core.encode_base64(raw)
		assert(#data<=60000*128, "forest tile exceeded its transfer bound")
		return data
	end
	core.register_globalstep(function()
		if not channel or not channel:is_writeable() or #queue == 0 then return end
		local start, resumes, sent = core.get_us_time(), 0, 0
		while #queue > 0 and resumes < 4096 and sent < 4 do
			local job = queue[1]
			local sk = "surface-forest1:" .. revision .. ":" .. job.k
			local data = cache[job.k]
			if not data and not job.co then
				data = storage:get_string(sk)
				if data == "" then data = nil end
			end
			if not data then
				job.co=job.co or coroutine.create(function() return build(job) end)
				local ok,value=coroutine.resume(job.co)
				resumes=resumes+1
				if not ok then
					core.log("error","[goanna] surface tile failed: "..tostring(value))
					pending[job.pk]=nil
					table.remove(queue,1)
					return
				end
				if coroutine.status(job.co)=="dead" then
					data=value
					storage:set_string(sk,data)
				end
			end
			if data then
				remember(job.k,data)
				local parts=math.ceil(#data/60000)
				job.part=job.part or 0
				if parts==1 then
					channel:send_all(string.format("surface %s %d %s %d %d %d %s",
							job.who,job.version,revision,job.step,job.x,job.z,data))
				else
					channel:send_all(string.format("surface_part %s %d %s %d %d %d %d %d %s",
							job.who,job.version,revision,job.step,job.x,job.z,job.part,parts,
							data:sub(job.part*60000+1,(job.part+1)*60000)))
				end
				job.part=job.part+1
				if job.part>=parts then
					pending[job.pk]=nil
					table.remove(queue,1)
				end
				sent=sent+1
			end
			if core.get_us_time()-start>=2000 then break end
		end
	end)

	return function(fn, opts)
		-- A provider without a stable identity keeps the older summary path.
		if not opts or not opts.revision or not enabled then return end
		provider, water, forest = fn, opts.water or "mcl_core:water_source", opts.forest
		revision = core.sha1(opts.revision)
		goanna_announce("surface_tiles", forest and "2" or "1")
		goanna_announce("surface_revision", revision)
	end
end
