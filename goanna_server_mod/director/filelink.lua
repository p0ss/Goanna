-- SPDX-License-Identifier: LGPL-2.1-or-later
-- The file transport (docs/director.md, "Transports"): the director service
-- and the server exchange small JSON files in <world>/goanna_director/link.
--
-- The service always runs on the machine that holds the world, so a folder
-- both can see is all the transport needs. Unlike HTTP it needs nothing
-- from the Luanti build (Goanna's bundled server has no curl) and nothing
-- from the operator (no secure.http_mods). It carries exactly what the HTTP
-- transport carries, in the same envelopes and messages, so the rest of the
-- director cannot tell them apart.
--
--   link/director.json   the service's heartbeat: {instance, t, session}
--                        where session is the server session it has had a
--                        hello for. Rewritten every two seconds.
--   link/server.json     the server's heartbeat: {session, t}, rewritten
--                        every second, only while a service is there.
--   link/in/*.json       one message per file from the service (an act or a
--                        query), named <instance>-<id> so they sort in
--                        order; read and removed here.
--   link/out/*.json      batches of envelopes from the server
--                        ({"v":1,"session":...,"batch":[...]}, as HTTP's
--                        push body), named <session>-<n>; read and removed by
--                        the service.
--
-- Each file is written whole and then renamed (core.safe_file_write here, a
-- rename in the service), so neither side reads half a file. The inbox is
-- read on every server step, so an act waits about one step (around 0.1 s),
-- and events are written on the step they happen. With no service, nothing
-- is written at all.
--
-- Anyone who can write in the world folder can drive the director, which is
-- the operator already: they could edit the world itself.

return function(D)
	local logic = D.logic
	local OUTBOX_MAX = 256
	local STALE_S = 10

	local base = core.get_worldpath() .. "/goanna_director/link"
	local in_dir, out_dir = base .. "/in", base .. "/out"
	core.mkdir(base)
	core.mkdir(in_dir)
	core.mkdir(out_dir)

	local outbox = {}

	local function stamp()
		return {game = core.get_gametime(), day = core.get_day_count(),
			tod = math.floor(core.get_timeofday() * 1000) / 1000}
	end

	function D.send(kind, body)
		if #outbox >= OUTBOX_MAX then
			table.remove(outbox, 1)
		end
		outbox[#outbox + 1] = {v = 1, kind = kind, scope = "gm", session = D.session,
			t = stamp(), body = body}
	end

	function D.send_result(msg, body)
		D.send(msg.kind == "query" and "reply" or "result", body)
	end

	local function read_json(path)
		local f = io.open(path, "rb")
		if not f then
			return nil
		end
		local s = f:read("*a")
		f:close()
		local ok, v = pcall(core.parse_json, s)
		return ok and v or nil
	end

	local pushed_seq = 0
	local out_n = 0
	local instance = ""
	local after = 0
	local need_hello = true
	local hello_at = 0

	local function set_connected(on)
		if on and not D.connected then
			D.connected = true
			D.audit({kind = "connected", transport = "file"})
			core.log("action", "[goanna director] a director connected through " .. base)
			if D.on_connect then
				D.on_connect()
			end
		elseif not on and D.connected then
			D.connected = false
			D.audit({kind = "disconnected"})
			core.log("action", "[goanna director] the director stopped answering")
		end
	end

	local function hello()
		local open = {}
		for id, e in pairs(D.encounters) do
			if e.state == "live" then
				open[#open + 1] = {id = id, act = e.act, near = e.player}
			end
		end
		local npcs = {}
		for _, n in pairs(D.npcs) do
			npcs[#npcs + 1] = n.name
		end
		table.insert(outbox, 1, {v = 1, kind = "hello", scope = "gm", session = D.session,
			t = stamp(), body = {session = D.session, last_seq = pushed_seq,
				capabilities = D.capabilities(), encounters = open, npcs = npcs,
				stopped = D.stopped, transport = "file"}})
		need_hello = false
		hello_at = D.now()
	end

	-- Write what is waiting as one batch file.
	local function push()
		if not D.connected then
			return
		end
		if need_hello then
			hello()
		end
		local events, gap = logic.ring_since(D.ring, pushed_seq, 400)
		if #events == 0 and #outbox == 0 then
			return
		end
		local batch = {}
		if #events > 0 then
			batch[1] = D.json({v = 1, kind = "events", scope = "gm", session = D.session,
				t = stamp(), seq = events[#events].seq, body = {events = events, gap = gap or nil}})
		end
		for i = 1, #outbox do
			batch[#batch + 1] = D.json(outbox[i])
		end
		out_n = out_n + 1
		local name = ("%s/%s-%010d.json"):format(out_dir, D.session, out_n)
		local ok = core.safe_file_write(name, '{"v":1,"session":"' .. D.session ..
			'","batch":[' .. table.concat(batch, ",") .. "]}")
		if ok then
			outbox = {}
			if #events > 0 then
				pushed_seq = events[#events].seq
			end
		end
	end
	D.push_now = push

	local function pull()
		local names = core.get_dir_list(in_dir, false)
		if #names == 0 then
			return
		end
		table.sort(names)
		for _, name in ipairs(names) do
			if name:sub(-5) == ".json" then
				local path = in_dir .. "/" .. name
				local m = read_json(path)
				os.remove(path)
				if type(m) == "table" then
					-- Ids belong to one service process; a message from an
					-- older one, written before it stopped, is dropped.
					local id = tonumber(m.id) or 0
					if m.instance == instance and id > after then
						after = id
						local ok, body = pcall(D.handle, m)
						if not ok then
							body = {id = tostring(m.req or m.id), type = m.type, status = "refused",
								reason = "error", detail = tostring(body):sub(1, 200)}
						end
						D.send_result(m, body)
					end
				end
			end
		end
	end

	-- The service's heartbeat, read once a second: is one there, is it the
	-- same process, and has it had a hello for this session.
	local function heartbeat()
		local hb = read_json(base .. "/director.json")
		local fresh = type(hb) == "table" and tonumber(hb.t)
			and math.abs(os.time() - tonumber(hb.t)) <= STALE_S
		if not fresh then
			set_connected(false)
			return
		end
		if hb.instance ~= instance then
			instance = tostring(hb.instance or "")
			after = 0
			need_hello = true
		end
		if hb.session ~= D.session and D.now() - hello_at > 5 then
			need_hello = true
		end
		set_connected(true)
		core.safe_file_write(base .. "/server.json", core.write_json({session = D.session,
			t = os.time()}))
	end

	local beat = 1
	core.register_globalstep(function(dtime)
		beat = beat + dtime
		if beat >= 1 then
			beat = 0
			heartbeat()
		end
		if D.connected then
			pull()
			push()
		end
	end)

	-- Whatever is still in the inbox when the server stops was never
	-- answered; the service reports it as interrupted when the session
	-- changes. Old batches the service never read are left for it.
	core.log("action", "[goanna director] file transport at " .. base)
end
