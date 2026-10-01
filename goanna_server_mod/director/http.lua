-- SPDX-License-Identifier: LGPL-2.1-or-later
-- The HTTP transport (docs/director.md, "HTTP").
--
-- The server mod is the HTTP client. It POSTs batches of envelopes to
-- <url>/v1/push and keeps one long poll open on <url>/v1/pull for the
-- model's intents and queries. Both carry the token from
-- <world>/goanna_director.conf as a bearer token, and a pull reply must
-- carry proof that the endpoint knows the same token, so a process that
-- happens to hold the port cannot drive the director. HTTPApiTable.fetch is
-- asynchronous, so the server step never waits.
--
-- Nothing travels to any player: no player object, no mod channel, and so
-- nothing a Goanna client sees that a vanilla one does not.

return function(D)
	local http, logic = D.http, D.logic
	local outbox = {}
	local OUTBOX_MAX = 256
	local BATCH_BYTES = 60000

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

	if not http then
		core.log("warning", "[goanna director] goanna_director is on but the HTTP API was " ..
			"not granted. Add goanna_server_mod to secure.http_mods, or nothing can connect.")
		return
	end

	local headers = {"Authorization: Bearer " .. D.token, "Content-Type: application/json"}
	local pushed_seq = 0
	local push_busy, pull_busy = false, false
	local after = 0
	-- Message ids are the endpoint's own, and start again when that process
	-- restarts, so they are only compared within one endpoint instance.
	local instance = ""
	local retry_at = 0
	local need_hello = true

	local function set_connected(on)
		if on and not D.connected then
			D.connected = true
			D.audit({kind = "connected", url = D.url})
			core.log("action", "[goanna director] a director answered at " .. D.url)
			if D.on_connect then
				D.on_connect()
			end
		elseif not on and D.connected then
			D.connected = false
			D.audit({kind = "disconnected"})
			core.log("action", "[goanna director] lost the director at " .. D.url)
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
				stopped = D.stopped}})
		need_hello = false
	end

	local push
	push = function()
		if push_busy or D.now() < retry_at then
			return
		end
		if need_hello then
			hello()
		end
		local batch, size = {}, 0
		local events, gap = logic.ring_since(D.ring, pushed_seq, 400)
		local last_seq = pushed_seq
		if #events > 0 then
			local env = {v = 1, kind = "events", scope = "gm", session = D.session, t = stamp(),
				seq = events[#events].seq, body = {events = events, gap = gap or nil}}
			local s = D.json(env)
			batch[1], size = s, #s
			last_seq = events[#events].seq
		end
		local taken = 0
		for i = 1, #outbox do
			local s = D.json(outbox[i])
			if size + #s > BATCH_BYTES and #batch > 0 then
				break
			end
			batch[#batch + 1] = s
			size = size + #s
			taken = i
		end
		if #batch == 0 then
			return
		end
		local sent = {}
		for i = 1, taken do
			sent[i] = table.remove(outbox, 1)
		end
		push_busy = true
		http.fetch({
			url = D.url .. "/v1/push", method = "POST", timeout = 5, quiet = true,
			extra_headers = headers,
			data = '{"v":1,"session":"' .. D.session .. '","batch":[' .. table.concat(batch, ",") .. "]}",
		}, function(res)
			push_busy = false
			if res.succeeded and res.code >= 200 and res.code < 300 then
				pushed_seq = math.max(pushed_seq, last_seq)
				local reply = res.data ~= "" and core.parse_json(res.data) or nil
				if type(reply) == "table" and reply.known_session == false then
					need_hello = true
				end
				if #outbox > 0 or D.ring.seq > pushed_seq then
					core.after(0, push)
				end
				return
			end
			-- Put the unsent envelopes back, oldest first, and try later.
			for i = #sent, 1, -1 do
				table.insert(outbox, 1, sent[i])
			end
			while #outbox > OUTBOX_MAX do
				table.remove(outbox, 1)
			end
			if res.code == 401 or res.code == 403 then
				core.log("warning", "[goanna director] the endpoint refused the token")
			end
			need_hello = true
			set_connected(false)
			retry_at = D.now() + 5
		end)
	end
	D.push_now = push

	local pull
	pull = function()
		if pull_busy or D.now() < retry_at then
			return
		end
		pull_busy = true
		local asked_after = after
		http.fetch({
			url = ("%s/v1/pull?scope=gm&after=%d&wait=20&session=%s&instance=%s"):format(
				D.url, after, D.session, instance),
			method = "GET", timeout = 25, quiet = true, extra_headers = headers,
		}, function(res)
			pull_busy = false
			if not res.succeeded or res.code >= 400 or res.code == 0 then
				if not res.timeout then
					set_connected(false)
					retry_at = D.now() + 5
				end
				return
			end
			if res.code == 204 or res.data == "" then
				set_connected(true)
				core.after(0, pull)
				return
			end
			local reply = core.parse_json(res.data)
			if type(reply) ~= "table" or reply.v ~= 1 then
				core.log("warning", "[goanna director] a pull reply that is not protocol 1; ignored")
				retry_at = D.now() + 5
				return
			end
			local proof = core.sha256(D.token .. ":" .. D.session .. ":" .. asked_after)
			if reply.auth ~= proof then
				core.log("warning", "[goanna director] a pull reply without proof of the token; " ..
					"ignored. Is something else listening at " .. D.url .. "?")
				retry_at = D.now() + 10
				return
			end
			set_connected(true)
			if type(reply.instance) == "string" and reply.instance ~= instance then
				instance = reply.instance
				after = 0
			end
			local messages = type(reply.messages) == "table" and reply.messages or {}
			table.sort(messages, function(a, b)
				return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
			end)
			for _, m in ipairs(messages) do
				local id = tonumber(m.id) or 0
				if type(m) == "table" and id > after then
					after = id
					local ok, body = pcall(D.handle, m)
					if not ok then
						body = {id = tostring(m.req or m.id), type = m.type, status = "refused",
							reason = "error", detail = tostring(body):sub(1, 200)}
					end
					D.send_result(m, body)
				end
			end
			push()
			core.after(0, pull)
		end)
	end

	local timer = 0
	core.register_globalstep(function(dtime)
		timer = timer + dtime
		if timer < 1 then
			return
		end
		timer = 0
		push()
		pull()
	end)
end
