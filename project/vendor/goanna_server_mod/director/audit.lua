-- SPDX-License-Identifier: LGPL-2.1-or-later
-- The audit log: one line of JSON per intent and per effect, in
-- <world>/goanna_director/audit-<date>.jsonl, appended by a paced writer so
-- a callback never touches the disk. /director log reads the recent entries
-- back from memory.

return function(D)
	local dir = core.get_worldpath() .. "/goanna_director"
	core.mkdir(dir)
	local pending = {}
	local recent = {}
	local RECENT = 200

	-- entry: {kind, id, type, args, reason, outcome, effects, undo, players}
	function D.audit(entry)
		entry.real = os.date("!%Y-%m-%dT%H:%M:%SZ")
		entry.game = core.get_gametime()
		entry.scope = entry.scope or "gm"
		entry.session = D.session
		pending[#pending + 1] = D.json(entry)
		recent[#recent + 1] = entry
		if #recent > RECENT then
			table.remove(recent, 1)
		end
	end

	function D.audit_recent(filter, limit)
		local out = {}
		for i = #recent, 1, -1 do
			local e = recent[i]
			if not filter or filter(e) then
				out[#out + 1] = e
				if #out >= (limit or 10) then
					break
				end
			end
		end
		return out
	end

	local function flush()
		if #pending == 0 then
			return
		end
		local path = dir .. "/audit-" .. os.date("!%Y-%m-%d") .. ".jsonl"
		local f = io.open(path, "a")
		if not f then
			core.log("warning", "[goanna director] cannot append to " .. path)
			pending = {}
			return
		end
		f:write(table.concat(pending, "\n"), "\n")
		f:close()
		pending = {}
	end
	D.audit_flush = flush

	local timer = 0
	core.register_globalstep(function(dtime)
		timer = timer + dtime
		if timer >= 1 then
			timer = 0
			flush()
		end
	end)
	core.register_on_shutdown(flush)
end
