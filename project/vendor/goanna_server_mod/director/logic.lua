-- SPDX-License-Identifier: LGPL-2.1-or-later
-- The director's bookkeeping, with no engine calls in it.
--
-- Everything here takes the time as an argument and touches nothing but its
-- own tables, so tools/test-director-logic.lua runs it under a plain LuaJIT
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

return L
