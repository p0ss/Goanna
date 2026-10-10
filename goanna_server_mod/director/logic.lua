-- SPDX-License-Identifier: LGPL-2.1-or-later
-- The director's bookkeeping, with no engine calls in it.
--
-- Everything here takes the time as an argument and touches nothing but its
-- own tables, so tools/test/test-director-logic.lua runs it under a plain LuaJIT
-- with no server. The engine facing modules (events.lua, intents.lua and the
-- rest) keep the state these functions work on and supply the clock.

local L = {}

-- The event ring. Every event gets the next sequence number for the scope;
-- the ring keeps the last `cap` of them. A reader asking for events after a
-- sequence older than the oldest kept gets `gap = true`, and is expected to
-- re-read summaries rather than replay (docs/director.md, "Events").
function L.ring(cap)
	return {cap = cap, items = {}, first = 1, last = 0, seq = 0}
end

function L.ring_push(r, ev)
	r.seq = r.seq + 1
	ev.seq = r.seq
	r.last = r.last + 1
	r.items[r.last] = ev
	if r.last - r.first + 1 > r.cap then
		r.items[r.first] = nil
		r.first = r.first + 1
	end
	return r.seq
end

function L.ring_since(r, after, limit)
	local out = {}
	local oldest = r.items[r.first]
	local gap = oldest ~= nil and after < oldest.seq - 1
	for i = r.first, r.last do
		local ev = r.items[i]
		if ev.seq > after then
			out[#out + 1] = ev
			if limit and #out >= limit then
				break
			end
		end
	end
	return out, gap
end

-- A rolling window, for budgets per hour. Entries older than the window are
-- dropped as the sum is taken, so the cost is the number of spends in the
-- window, which a budget keeps small.
function L.window(seconds)
	return {seconds = seconds, entries = {}}
end

function L.window_sum(w, now)
	local kept, sum = {}, 0
	for _, e in ipairs(w.entries) do
		if now - e.t < w.seconds then
			kept[#kept + 1] = e
			sum = sum + e.amount
		end
	end
	w.entries = kept
	return sum
end

function L.window_add(w, now, amount)
	w.entries[#w.entries + 1] = {t = now, amount = amount}
end

-- A rate limit per key: at most `per_minute` events in any sixty seconds.
function L.rate(per_minute)
	return {per_minute = per_minute, keys = {}}
end

function L.rate_allow(r, key, now)
	local w = r.keys[key]
	if not w then
		w = L.window(60)
		r.keys[key] = w
	end
	if L.window_sum(w, now) >= r.per_minute then
		return false
	end
	L.window_add(w, now, 1)
	return true
end

-- Pacing, after Left 4 Dead's director (docs/director.md, "Pacing"). One
-- state per player. Intensity rises with harm, with hostiles near and with
-- kills, is set to 1 on death, and decays once things have been quiet for a
-- few seconds. The phase cycles build_up, peak, fade, relax.
L.PACING_DEFAULTS = {
	peak = 0.7,            -- intensity that ends a build up
	peak_hold = 5,         -- seconds a peak is held
	fade_below = 0.3,      -- intensity a fade waits for
	relax = 45,            -- seconds of relax after a fade
	relax_after_death = 120,
	decay_tau = 20,        -- seconds, I = I * exp(-dt / tau)
	quiet = 5,             -- seconds without harm or hostiles before decay
	per_hostile = 0.02,    -- per second, per hostile within 16 nodes
	per_kill = 0.05,
	join_grace = 30,       -- seconds of relax when a player joins
}

function L.pacing_new(now, cfg)
	cfg = cfg or L.PACING_DEFAULTS
	local st = {intensity = 0, phase = "relax", since = now, last_harm = -math.huge,
		relax_for = cfg.join_grace}
	if cfg.join_grace <= 0 then
		st.phase = "build_up"
	end
	return st
end

local function clamp01(v)
	if v < 0 then return 0 end
	if v > 1 then return 1 end
	return v
end

function L.pacing_damage(st, fraction, now)
	st.intensity = clamp01(st.intensity + math.max(0, fraction))
	st.last_harm = now
end

function L.pacing_kill(st, cfg, now)
	cfg = cfg or L.PACING_DEFAULTS
	st.intensity = clamp01(st.intensity + cfg.per_kill)
	st.last_harm = now
end

function L.pacing_death(st, cfg, now)
	cfg = cfg or L.PACING_DEFAULTS
	st.intensity = 1
	st.last_harm = now
	st.phase = "relax"
	st.since = now
	st.relax_for = cfg.relax_after_death
	return "relax"
end

-- Advance one tick. Returns the new phase when it changed, else nil.
function L.pacing_tick(st, cfg, now, dt, hostiles)
	cfg = cfg or L.PACING_DEFAULTS
	if hostiles > 0 then
		st.intensity = clamp01(st.intensity + cfg.per_hostile * hostiles * dt)
		st.last_harm = now
	elseif now - st.last_harm >= cfg.quiet then
		st.intensity = st.intensity * math.exp(-dt / cfg.decay_tau)
	end
	local old = st.phase
	if st.phase == "build_up" then
		if st.intensity >= cfg.peak then
			st.phase = "peak"
		end
	elseif st.phase == "peak" then
		if now - st.since >= cfg.peak_hold then
			st.phase = "fade"
		end
	elseif st.phase == "fade" then
		if st.intensity < cfg.fade_below then
			st.phase = "relax"
			st.relax_for = cfg.relax
		end
	elseif st.phase == "relax" then
		if now - st.since >= (st.relax_for or cfg.relax) then
			st.phase = "build_up"
		end
	end
	if st.phase ~= old then
		st.since = now
		return st.phase
	end
	return nil
end

-- Encounters. Candidates are {name, cost, weight}; the composition draws
-- by weight, with `random(n)` returning an integer in 1..n, until nothing
-- that is left fits the budget or the count runs out. The caller seeds the
-- random source, so a session replays from its audit log.
function L.compose(candidates, budget, max_count, random)
	local picked, spent = {}, 0
	while #picked < max_count do
		local fits, total = {}, 0
		for _, c in ipairs(candidates) do
			if c.cost <= budget - spent and c.weight > 0 then
				fits[#fits + 1] = c
				total = total + c.weight
			end
		end
		if #fits == 0 then
			break
		end
		local roll = random(total)
		local chosen = fits[#fits]
		for _, c in ipairs(fits) do
			roll = roll - c.weight
			if roll <= 0 then
				chosen = c
				break
			end
		end
		picked[#picked + 1] = chosen.name
		spent = spent + chosen.cost
	end
	return picked, spent
end

-- A mob's cost: maximum health over 10 plus its damage, at least 1.
function L.mob_cost(hp_max, damage)
	local cost = (tonumber(hp_max) or 10) / 10 + (tonumber(damage) or 0)
	return math.max(1, math.floor(cost + 0.5))
end

-- Gear score in 0 to 1: armour points over the game's best, and the best
-- weapon's damage over the game's best, weighted equally.
function L.gear_score(armour, weapon, best_armour, best_weapon)
	local a = best_armour > 0 and math.min(armour / best_armour, 1) or 0
	local w = best_weapon > 0 and math.min(weapon / best_weapon, 1) or 0
	return math.floor((a + w) * 50 + 0.5) / 100
end

-- The largest encounter a player's gear allows. A model may ask for less,
-- never more.
function L.encounter_ceiling(score, base, per_gear)
	return math.floor(base + score * per_gear + 0.5)
end

-- NPC memory: what one NPC knows of one player, for the session. Facts come
-- from events (source "event") or from the model ("model"); the model's are
-- capped in length and in number, and the oldest is dropped first.
function L.memory()
	return {}
end

function L.memory_get(m, npc, player, now)
	local by_npc = m[npc]
	if not by_npc then
		by_npc = {}
		m[npc] = by_npc
	end
	local rec = by_npc[player]
	if not rec and now then
		rec = {first_met = now, last_seen = now, spoken = 0, addressed = 0,
			disposition = 0, facts = {}}
		by_npc[player] = rec
	end
	return rec
end

function L.memory_fact(rec, text, source, now, limits)
	local cap = source == "model" and limits.model_lines or limits.facts
	local chars = source == "model" and limits.model_chars or 200
	if #text > chars then
		return false, "too_long"
	end
	local same = 0
	for _, f in ipairs(rec.facts) do
		if f.source == source then
			same = same + 1
		end
	end
	if same >= cap then
		for i, f in ipairs(rec.facts) do
			if f.source == source then
				table.remove(rec.facts, i)
				break
			end
		end
	end
	rec.facts[#rec.facts + 1] = {t = now, text = text, source = source}
	return true
end

function L.clamp_disposition(v)
	v = math.floor(tonumber(v) or 0)
	if v < -100 then return -100 end
	if v > 100 then return 100 end
	return v
end

-- Text a model asks to have said or remembered: one line, printable, no
-- escape sequences (which would let it recolour or fake a client's chat).
function L.clean_text(s)
	if type(s) ~= "string" then
		return nil
	end
	s = s:gsub("[%z\1-\31\127]", " "):gsub("%s+", " ")
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	return s
end

-- A name a model may give a character: letters, spaces, apostrophes and
-- hyphens, 2 to 24 characters.
function L.valid_name(s)
	return type(s) == "string" and #s >= 2 and #s <= 24
		and s:match("^[%a][%a '%-]*$") ~= nil
end

-- Is a chat line addressed to this name? "Name, ...", "Name: ...",
-- "@Name ...", or the name alone. Case does not matter.
function L.addressed_to(line, name)
	local l, n = line:lower(), name:lower()
	l = l:gsub("^%s+", ""):gsub("^@", "")
	if l:sub(1, #n) ~= n then
		return false
	end
	local rest = l:sub(#n + 1)
	return rest == "" or rest:match("^[%s,:!%?%.]") ~= nil
end

-- The catalogue's search. entries is a sorted list of records, each with
-- `name`, `kind`, `mod`, `desc` and an optional `groups` set. filter has
-- `kind`, `text` (plain, case blind, against name and description), `group`,
-- `mod`, `limit` and `cursor` (the index to start after). Returns the page,
-- the number that matched and the cursor for the next page, or nil at the
-- end.
function L.search(entries, filter)
	local kind, mod, group = filter.kind, filter.mod, filter.group
	local text = type(filter.text) == "string" and filter.text:lower() or nil
	if text == "" then
		text = nil
	end
	local limit = math.max(1, math.min(tonumber(filter.limit) or 40, 200))
	local start = math.max(0, math.floor(tonumber(filter.cursor) or 0))
	local page, total, next_cursor = {}, 0, nil
	for _, e in ipairs(entries) do
		local ok = (not kind or e.kind == kind or (kind == "item" and e.item))
			and (not mod or e.mod == mod)
			and (not group or (e.groups and e.groups[group]))
		if ok and text then
			ok = e.name:lower():find(text, 1, true) ~= nil
				or (e.desc or ""):lower():find(text, 1, true) ~= nil
		end
		if ok then
			total = total + 1
			if total > start then
				if #page < limit then
					page[#page + 1] = e
				elseif not next_cursor then
					next_cursor = start + limit
				end
			end
		end
	end
	return page, total, next_cursor
end

-- What an item is worth to the reward budget, from facts the caller reads
-- off its definition: `tool` (true for a tool or weapon), `damage` (its
-- largest damage group), `level` (its largest dig level), `armour` (its
-- armour points, or 0), `stack_max`, and `value`, a game's own figure from
-- an adapter, which wins when given. A tool or armour piece is worth more
-- as it hits harder, digs deeper or protects more; anything else is one
-- point per full stack, so a handful of food is cheap and a stack of
-- diamonds is not free.
function L.item_value(f, count)
	count = math.max(1, math.floor(tonumber(count) or 1))
	if tonumber(f.value) then
		return math.max(0, tonumber(f.value)) * count
	end
	if f.tool or (tonumber(f.armour) or 0) > 0 then
		local each = 1 + math.floor((tonumber(f.damage) or 0) / 2)
			+ (tonumber(f.level) or 0) + math.floor((tonumber(f.armour) or 0) / 2)
		return each * count
	end
	local stack = math.max(1, tonumber(f.stack_max) or 99)
	return math.ceil(count / stack)
end

-- A reward's cost: the item's value plus each enchantment's level.
function L.reward_cost(value, enchantments)
	local cost = value
	for _, e in ipairs(enchantments or {}) do
		cost = cost + math.max(1, math.floor(tonumber(e.level) or 1))
	end
	return cost
end

-- An authored schematic: palette maps one character to a node name ("air"
-- clears), and layers go from the bottom up, each a list of rows along z,
-- each row a string along x. A space, or a character past the end of a
-- short row, leaves the world's node. node_ok(name) says whether a node may
-- be used, returning false and a reason when not. limits has max_side and
-- max_volume. Returns {size = {x, y, z}, nodes = {{x, y, z, name}, ...},
-- count = nodes that are not air} or nil, a reason and a detail.
function L.parse_schematic(palette, layers, node_ok, limits)
	if type(palette) ~= "table" or type(layers) ~= "table" or #layers == 0 then
		return nil, "schema", "palette (an object) and layers (a list) are required"
	end
	for key, name in pairs(palette) do
		if type(key) ~= "string" or #key ~= 1 or key == " " or type(name) ~= "string" then
			return nil, "schema", "palette keys are single characters other than space"
		end
		if name ~= "air" then
			local ok, why = node_ok(name)
			if not ok then
				return nil, why or "bad_node", name
			end
		end
	end
	local sx, sz = 0, 0
	for _, layer in ipairs(layers) do
		if type(layer) ~= "table" then
			return nil, "schema", "each layer is a list of rows"
		end
		sz = math.max(sz, #layer)
		for _, row in ipairs(layer) do
			if type(row) ~= "string" then
				return nil, "schema", "each row is a string"
			end
			sx = math.max(sx, #row)
		end
	end
	local sy = #layers
	local side = math.max(sx, sy, sz)
	if side > limits.max_side or sx * sy * sz > limits.max_volume then
		return nil, "too_large", ("%dx%dx%d"):format(sx, sy, sz)
	end
	if sx == 0 or sz == 0 then
		return nil, "schema", "the schematic is empty"
	end
	local nodes, count = {}, 0
	for y, layer in ipairs(layers) do
		for z, row in ipairs(layer) do
			for x = 1, #row do
				local c = row:sub(x, x)
				if c ~= " " then
					local name = palette[c]
					if not name then
						return nil, "schema", ("character %q is not in the palette"):format(c)
					end
					nodes[#nodes + 1] = {x - 1, y - 1, z - 1, name}
					if name ~= "air" then
						count = count + 1
					end
				end
			end
		end
	end
	return {size = {sx, sy, sz}, nodes = nodes, count = count}
end

-- The order a character builds in: bottom layer first, and within a layer
-- the solid nodes before air, so it digs out a room after raising its walls
-- rather than before.
function L.build_order(nodes)
	local list = {}
	for i, n in ipairs(nodes) do
		list[i] = n
	end
	table.sort(list, function(a, b)
		if a[2] ~= b[2] then
			return a[2] < b[2]
		end
		local aa, ba = a[4] == "air", b[4] == "air"
		if aa ~= ba then
			return ba
		end
		if a[3] ~= b[3] then
			return a[3] < b[3]
		end
		return a[1] < b[1]
	end)
	return list
end

-- Rulesets (docs/director.md, "Lua hook API"). A ruleset's names become
-- message types on the wire and parts of MCP tool names, so they are kept
-- to lower case letters, digits and underscores.
function L.ident_ok(s)
	return type(s) == "string" and #s >= 1 and #s <= 32 and s:match("^[a-z][a-z0-9_]*$") ~= nil
end

-- The JSON Schema subset a ruleset describes its arguments with. The same
-- table is checked here and handed to the model as the tool's input schema,
-- so what the model is told and what the server accepts cannot drift apart.
-- Supported: type (object, string, number, integer, boolean, array),
-- properties, required, additionalProperties = false, enum, minimum,
-- maximum, maxLength, items, maxItems, description.
local SCHEMA_TYPES = {object = true, string = true, number = true, integer = true,
	boolean = true, array = true}

-- Whether a schema is one this subset understands. Returns true, or false
-- and why.
function L.schema_valid(s, depth)
	depth = depth or 0
	if depth > 8 then
		return false, "nested too deep"
	end
	if type(s) ~= "table" then
		return false, "a schema is a table"
	end
	if s.type ~= nil and not SCHEMA_TYPES[s.type] then
		return false, "unknown type " .. tostring(s.type)
	end
	if s.properties ~= nil then
		if type(s.properties) ~= "table" then
			return false, "properties is a table"
		end
		for k, v in pairs(s.properties) do
			if type(k) ~= "string" then
				return false, "property names are strings"
			end
			local ok, why = L.schema_valid(v, depth + 1)
			if not ok then
				return false, k .. ": " .. why
			end
		end
	end
	if s.required ~= nil then
		if type(s.required) ~= "table" then
			return false, "required is a list"
		end
		for _, k in ipairs(s.required) do
			if type(k) ~= "string" then
				return false, "required names are strings"
			end
		end
	end
	if s.items ~= nil then
		local ok, why = L.schema_valid(s.items, depth + 1)
		if not ok then
			return false, "items: " .. why
		end
	end
	if s.enum ~= nil and type(s.enum) ~= "table" then
		return false, "enum is a list"
	end
	return true
end

local function is_list(t)
	local n = 0
	for k in pairs(t) do
		if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
			return false
		end
		n = n + 1
	end
	return n == #t
end

-- Check a value against a schema. Returns true, or false and a short
-- description of the first problem, naming where it is.
function L.schema_check(s, v, where, depth)
	where = where or "args"
	depth = depth or 0
	if s == nil then
		return true
	end
	if depth > 8 then
		return false, where .. ": nested too deep"
	end
	local t = s.type
	if t == "string" then
		if type(v) ~= "string" then
			return false, where .. ": expected a string"
		end
		if s.maxLength and #v > s.maxLength then
			return false, where .. ": longer than " .. s.maxLength
		end
	elseif t == "number" or t == "integer" then
		if type(v) ~= "number" or v ~= v then
			return false, where .. ": expected a number"
		end
		if t == "integer" and v % 1 ~= 0 then
			return false, where .. ": expected an integer"
		end
		if s.minimum and v < s.minimum then
			return false, where .. ": below " .. s.minimum
		end
		if s.maximum and v > s.maximum then
			return false, where .. ": above " .. s.maximum
		end
	elseif t == "boolean" then
		if type(v) ~= "boolean" then
			return false, where .. ": expected true or false"
		end
	elseif t == "array" then
		if type(v) ~= "table" or not is_list(v) then
			return false, where .. ": expected a list"
		end
		if s.maxItems and #v > s.maxItems then
			return false, where .. ": more than " .. s.maxItems .. " items"
		end
		for i, item in ipairs(v) do
			local ok, why = L.schema_check(s.items, item, where .. "[" .. i .. "]", depth + 1)
			if not ok then
				return false, why
			end
		end
	elseif t == "object" then
		if type(v) ~= "table" then
			return false, where .. ": expected an object"
		end
		local props = s.properties or {}
		for _, k in ipairs(s.required or {}) do
			if v[k] == nil then
				return false, where .. "." .. k .. " is required"
			end
		end
		for k, item in pairs(v) do
			local p = props[k]
			if p then
				local ok, why = L.schema_check(p, item, where .. "." .. tostring(k), depth + 1)
				if not ok then
					return false, why
				end
			elseif s.additionalProperties == false then
				return false, where .. "." .. tostring(k) .. " is not an argument"
			end
		end
	end
	if s.enum then
		for _, e in ipairs(s.enum) do
			if e == v then
				return true
			end
		end
		return false, where .. ": not one of the allowed values"
	end
	return true
end

return L
