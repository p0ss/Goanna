-- SPDX-License-Identifier: LGPL-2.1-or-later
-- The catalogue: what this world contains, for the model to search rather
-- than be sent (docs/director.md, "Catalogue").
--
-- Items, nodes, tools, entities and mods come from the engine's own
-- registries, so the catalogue works in any game. The adapters add what
-- only a framework knows: which entities are creatures and what they cost,
-- which enchantments exist, and the game's own structures. It is built
-- once, the first time it is asked for, because nothing is registered after
-- the mods have loaded.

return function(D)
	local logic = D.logic

	local function first_line(s)
		if type(s) ~= "string" then
			return ""
		end
		s = core.strip_colors and core.strip_colors(s) or s
		s = s:gsub("\27%b()", ""):gsub("\27.", "")
		return (logic.clean_text(s:match("^[^\n]*") or "") or ""):sub(1, 80)
	end
	D.first_line = first_line

	local function mod_of(name)
		return name:match("^([^:]+):") or ""
	end

	-- The engine's facts about an item's worth, for logic.item_value, with
	-- what the items adapter adds (armour points, a game's own value).
	function D.item_facts(name)
		local def = core.registered_items[name]
		if not def then
			return nil
		end
		local caps = def.tool_capabilities
		local damage, level = 0, 0
		if caps then
			for _, v in pairs(caps.damage_groups or {}) do
				damage = math.max(damage, tonumber(v) or 0)
			end
			for _, gc in pairs(caps.groupcaps or {}) do
				level = math.max(level, tonumber(gc.maxlevel) or 0)
			end
		end
		local f = {tool = def.type == "tool" or damage > 2, damage = damage, level = level,
			stack_max = def.stack_max or tonumber(core.settings:get("default_stack_max")) or 99}
		if D.items and D.items.item_facts then
			for k, v in pairs(D.items.item_facts(name, def) or {}) do
				f[k] = v
			end
		end
		return f
	end

	local entries, by_name, counts, fingerprint

	local function build()
		entries, by_name, counts = {}, {}, {kinds = {}, mods = {}}
		local names = {}
		local function add(e)
			entries[#entries + 1] = e
			by_name[e.kind .. ":" .. e.name] = e
			counts.kinds[e.kind] = (counts.kinds[e.kind] or 0) + 1
			if e.mod ~= "" and e.kind ~= "mod" then
				counts.mods[e.mod] = (counts.mods[e.mod] or 0) + 1
			end
		end
		for name, def in pairs(core.registered_items) do
			if name ~= "" and name ~= "air" and name ~= "ignore" and name ~= "unknown" then
				names[#names + 1] = name
				local kind = def.type == "node" and "node"
					or (def.type == "tool" or def.tool_capabilities and
						D.item_facts(name).tool) and "tool" or "item"
				add({name = name, kind = kind, item = true, mod = mod_of(name),
					desc = first_line(def.description), groups = def.groups or {},
					hidden = (def.groups or {}).not_in_creative_inventory ~= nil
						and (def.groups or {}).not_in_creative_inventory ~= 0})
			end
		end
		local creatures = {}
		if D.mobs and D.mobs.list then
			for _, m in ipairs(D.mobs.list()) do
				creatures[m.name] = true
				local e = {name = m.name, kind = "creature", mod = mod_of(m.name),
					desc = first_line(m.desc), category = m.category}
				local hp, dmg = D.mobs.cost_parts(m.name)
				if hp then
					e.cost = logic.mob_cost(hp, dmg)
				end
				e.denied = D.cfg.deny[m.name] or nil
				add(e)
			end
		end
		for name, def in pairs(core.registered_entities) do
			names[#names + 1] = "entity " .. name
			if not creatures[name] and not name:find("^__builtin") then
				add({name = name, kind = "entity", mod = mod_of(name),
					desc = first_line(def.description)})
			end
		end
		if D.items and D.items.enchantments then
			for _, en in ipairs(D.items.enchantments()) do
				add({name = en.name, kind = "enchantment", mod = "", desc = first_line(en.desc),
					max_level = en.max_level, curse = en.curse or nil,
					treasure = en.treasure or nil})
			end
		end
		if D.structures and D.structures.list then
			for _, st in ipairs(D.structures.list()) do
				add({name = st.name, kind = "structure", mod = "", desc = first_line(st.desc),
					size = st.size, plain = st.plain})
			end
		end
		local mods = core.get_modnames()
		table.sort(mods)
		for _, m in ipairs(mods) do
			add({name = m, kind = "mod", mod = m, desc = "", items = nil})
		end
		table.sort(entries, function(a, b)
			if a.kind ~= b.kind then
				return a.kind < b.kind
			end
			return a.name < b.name
		end)
		table.sort(names)
		local game = core.get_game_info and core.get_game_info() or {}
		fingerprint = core.sha1((game.id or "") .. "\n" .. table.concat(mods, ",") .. "\n" ..
			table.concat(names, ",")):sub(1, 12)
	end

	function D.catalogue_fingerprint()
		if not entries then
			build()
		end
		return fingerprint
	end

	function D.catalogue_entry(kind, name)
		if not entries then
			build()
		end
		return by_name[kind .. ":" .. tostring(name)]
	end

	-- One short record per entry; groups only when asked for.
	local function view(e, detail)
		local r = {name = e.name, kind = e.kind, desc = e.desc ~= "" and e.desc or nil}
		if e.kind == "creature" then
			r.category, r.cost, r.denied = e.category, e.cost, e.denied
		elseif e.kind == "enchantment" then
			r.max_level, r.curse, r.treasure = e.max_level, e.curse, e.treasure
		elseif e.kind == "structure" then
			r.size = e.size
			r.loot = not e.plain
		elseif e.kind == "mod" then
			r.items = counts.mods[e.name] or 0
		elseif e.item then
			local f = D.item_facts(e.name)
			-- Points for one tool or armour piece, or for a full stack.
			r.value = f and logic.item_value(f, f.tool and 1 or f.stack_max) or nil
			if e.kind == "tool" then
				r.damage = f and f.damage or nil
			end
			r.hidden = e.hidden or nil
			r.denied = D.cfg.reward_deny[e.name] or nil
		end
		if detail and e.groups then
			local g = {}
			for k, v in pairs(e.groups) do
				if v ~= 0 then
					g[#g + 1] = k
				end
			end
			table.sort(g)
			r.groups = g
		end
		return r
	end

	function D.catalogue(args)
		if not entries then
			build()
		end
		local game = core.get_game_info and core.get_game_info() or {}
		local filtered = args.kind or args.text or args.group or args.mod
		if not filtered then
			local mods = {}
			for m, n in pairs(counts.mods) do
				mods[#mods + 1] = {mod = m, entries = n}
			end
			table.sort(mods, function(a, b)
				return a.entries > b.entries or (a.entries == b.entries and a.mod < b.mod)
			end)
			return {fingerprint = fingerprint, game = game.id, game_title = game.title,
				kinds = counts.kinds, mods = mods,
				adapters = {mobs = D.mobs and D.mobs.name or "none",
					items = D.items and D.items.name or "none",
					structures = D.structures and D.structures.name or "none"},
				hint = "search with kind, text, group or mod; page with cursor"}
		end
		local list = entries
		if not args.hidden then
			list = {}
			for _, e in ipairs(entries) do
				if not e.hidden then
					list[#list + 1] = e
				end
			end
		end
		local page, total, cursor = logic.search(list, {kind = args.kind, text = args.text,
			group = args.group, mod = args.mod, limit = args.limit, cursor = args.cursor})
		local out = {}
		for i, e in ipairs(page) do
			out[i] = view(e, args.detail)
		end
		return {fingerprint = fingerprint, total = total, next_cursor = cursor, entries = out}
	end
end
