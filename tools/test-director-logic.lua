-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Unit tests for goanna_server_mod/director/logic.lua, the part of the
-- director with no engine calls. Runs under a plain LuaJIT or Lua 5.1:
--
--     luajit tools/test-director-logic.lua
--
-- Exits non-zero on the first failure.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local L = dofile(here .. "/../goanna_server_mod/director/logic.lua")

local failures = 0
local function check(cond, what)
	if cond then
		print("ok   " .. what)
	else
		print("FAIL " .. what)
		failures = failures + 1
	end
end

-- The ring keeps the last cap events and reports a gap to a reader that
-- fell behind.
do
	local r = L.ring(3)
	for i = 1, 5 do
		L.ring_push(r, {n = i})
	end
	local evs, gap = L.ring_since(r, 0)
	check(#evs == 3 and evs[1].seq == 3 and evs[3].seq == 5, "ring keeps the last three")
	check(gap == true, "ring reports a gap to a reader behind the oldest")
	evs, gap = L.ring_since(r, 3)
	check(#evs == 2 and gap == false, "ring has no gap for a reader that kept up")
	evs = L.ring_since(r, 0, 1)
	check(#evs == 1, "ring honours a limit")
end

-- Budgets over a rolling hour.
do
	local w = L.window(3600)
	L.window_add(w, 0, 10)
	L.window_add(w, 100, 5)
	check(L.window_sum(w, 200) == 15, "window sums what is inside it")
	check(L.window_sum(w, 3650) == 5, "window drops what has aged out")
end

-- Rate limits per key.
do
	local r = L.rate(2)
	check(L.rate_allow(r, "a", 0) and L.rate_allow(r, "a", 1), "two lines a minute allowed")
	check(not L.rate_allow(r, "a", 2), "the third in the same minute refused")
	check(L.rate_allow(r, "b", 2), "another speaker has its own allowance")
	check(L.rate_allow(r, "a", 61), "allowed again after a minute")
end

-- Pacing: the cycle build_up, peak, fade, relax, build_up.
do
	local cfg = {}
	for k, v in pairs(L.PACING_DEFAULTS) do
		cfg[k] = v
	end
	cfg.join_grace = 0
	local st = L.pacing_new(0, cfg)
	check(st.phase == "build_up", "no join grace starts in build up")
	L.pacing_damage(st, 0.8, 1)
	check(L.pacing_tick(st, cfg, 1, 1, 0) == "peak", "harm past the threshold peaks")
	check(L.pacing_tick(st, cfg, 3, 1, 0) == nil, "peak holds")
	check(L.pacing_tick(st, cfg, 7, 1, 0) == "fade", "peak gives way to fade after its hold")
	local t, phase = 7, nil
	while t < 200 and phase ~= "relax" do
		t = t + 1
		phase = L.pacing_tick(st, cfg, t, 1, 0)
	end
	check(phase == "relax" and st.intensity < cfg.fade_below, "fade ends in relax once intensity decays")
	local relax_start = t
	phase = nil
	while t < relax_start + 200 and phase ~= "build_up" do
		t = t + 1
		phase = L.pacing_tick(st, cfg, t, 1, 0)
	end
	check(phase == "build_up" and t - relax_start == cfg.relax, "relax lasts its configured time")
	L.pacing_death(st, cfg, t)
	check(st.phase == "relax" and st.intensity == 1 and st.relax_for == cfg.relax_after_death,
		"death forces a long relax")
	local before = st.intensity
	L.pacing_tick(st, cfg, t + 1, 1, 2)
	check(st.intensity == 1 and before == 1, "intensity is capped at 1")
	local grace = L.pacing_new(0, L.PACING_DEFAULTS)
	check(grace.phase == "relax", "a joining player starts in a short relax")
end

-- Encounters: composition stays inside the budget and the count.
do
	local cands = {{name = "zombie", cost = 5, weight = 1}, {name = "skeleton", cost = 4, weight = 1}}
	local seq = 0
	local function random(n)
		seq = seq + 1
		return (seq % n) + 1
	end
	local picked, spent = L.compose(cands, 12, 8, random)
	check(spent <= 12 and #picked >= 2, "composition fits a budget of 12 (" .. spent .. ")")
	picked, spent = L.compose(cands, 12, 1, random)
	check(#picked == 1, "composition honours the entity cap")
	picked = L.compose(cands, 3, 8, random)
	check(#picked == 0, "nothing fits a budget below the cheapest mob")
	check(L.mob_cost(20, 3) == 5 and L.mob_cost(20, 2) == 4, "zombie costs 5 and skeleton 4")
end

-- Gear sizes the ceiling.
do
	check(L.gear_score(0, 1, 20, 9) == 0.06, "bare hands score near zero")
	check(L.gear_score(20, 9, 20, 9) == 1, "the best gear scores 1")
	check(L.encounter_ceiling(0, 4, 16) == 4, "no gear allows the base")
	check(L.encounter_ceiling(1, 4, 16) == 20, "full gear allows base plus the gear share")
end

-- Memory: model lines are capped in length and number, oldest dropped.
do
	local m = L.memory()
	local rec = L.memory_get(m, "Grimbold", "alice", 10)
	check(rec and rec.first_met == 10, "a first meeting is recorded")
	check(L.memory_get(m, "Grimbold", "bob") == nil, "reading without a time creates nothing")
	local limits = {facts = 16, model_lines = 2, model_chars = 20}
	check(not L.memory_fact(rec, string.rep("x", 21), "model", 11, limits), "a long line is refused")
	L.memory_fact(rec, "one", "model", 12, limits)
	L.memory_fact(rec, "saw a zombie die", "event", 12, limits)
	L.memory_fact(rec, "two", "model", 13, limits)
	L.memory_fact(rec, "three", "model", 14, limits)
	local model = {}
	for _, f in ipairs(rec.facts) do
		if f.source == "model" then
			model[#model + 1] = f.text
		end
	end
	check(#model == 2 and model[1] == "two" and model[2] == "three", "the oldest model line goes first")
	check(#rec.facts == 3, "event facts are kept apart from the model's")
	check(L.clamp_disposition(250) == 100 and L.clamp_disposition(-300) == -100, "disposition clamps")
end

-- Text and names.
do
	check(L.clean_text("a\27(c@#ff0000)b\n c") == "a (c@#ff0000)b c", "escapes and newlines removed")
	check(L.valid_name("Grimbold") and L.valid_name("Old Mae") and not L.valid_name("x")
		and not L.valid_name("<admin>"), "character names")
	check(L.addressed_to("Grimbold, where is the tower?", "grimbold"), "addressed with a comma")
	check(L.addressed_to("@grimbold hello", "Grimbold"), "addressed with an at sign")
	check(not L.addressed_to("Grimboldson is here", "Grimbold"), "a longer word is not the name")
	check(not L.addressed_to("hello Grimbold", "Grimbold"), "the name later in a line is not address")
end

if failures > 0 then
	print(failures .. " failed")
	os.exit(1)
end
print("all passed")
