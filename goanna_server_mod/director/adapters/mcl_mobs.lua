-- SPDX-License-Identifier: LGPL-2.1-or-later
-- The director's adapter for Mineclonia's mcl_mobs, and mcl_armor for gear.
--
-- Read against Mineclonia release 38561. It reads public tables of mcl_mobs
-- and mcl_armor; none of their authors is involved. VoxeLibre forked the
-- same code and has diverged (docs/design/director-design.md, "mcl_mobs, VoxeLibre"), so
-- detection tests for Mineclonia's rule based targeting and not for the
-- name "mcl_mobs".
--
-- Director state never goes on the luaentity, because mcl_mobs serialises
-- every plain field of it into staticdata. The one exception is the rule
-- list, which has to be on the instance for run_targeting_rules to see it;
-- get_staticdata_table is shadowed on the instance to leave it out.

return function(owned_lookup)
	local A = {name = "mcl_mobs", kind = "mobs", priority = 10}

	function A.detect()
		local m = rawget(_G, "mcl_mobs")
		return m ~= nil and type(m.register_spawner) == "function"
			and type(m.build_target_rule) == "function"
			and m.mob_class ~= nil and m.mob_class._targeting_rules ~= nil
	end

	local function def_of(name)
		return mcl_mobs.registered_mobs and mcl_mobs.registered_mobs[name]
	end

	function A.is_mob(luaentity)
		return luaentity ~= nil and luaentity.is_mob == true
	end

	function A.known(name)
		return def_of(name) ~= nil
	end

	function A.category(name)
		local def = def_of(name)
		return def and (def._spawn_category or def.type) or nil
	end

	function A.hostile(luaentity)
		return A.is_mob(luaentity) and luaentity.type == "monster" and not luaentity.dead
	end

	-- Cost by docs/agents/director.md: maximum health over 10 plus damage.
	function A.cost_parts(name)
		local def = def_of(name)
		if not def then
			return nil
		end
		local hp = def.hp_max or (def.initial_properties and def.initial_properties.hp_max) or 10
		return hp, tonumber(def.damage) or 0
	end

	-- Every registered mob, for the catalogue: name, description and
	-- category.
	function A.list()
		local out = {}
		for name, def in pairs(mcl_mobs.registered_mobs or {}) do
			out[#out + 1] = {name = name, desc = def.description,
				category = def._spawn_category or def.type}
		end
		return out
	end

	function A.collisionbox(name)
		local def = def_of(name)
		local props = def and def.initial_properties
		return props and props.collisionbox or {-0.3, 0, -0.3, 0.3, 1.8, 0.3}
	end

	-- What spawns in a biome, by category, with weights. Read lazily:
	-- mcl_mobs replaces the table at register_on_mods_loaded.
	function A.fauna(biome, category)
		local by_biome = mcl_mobs.registered_spawners and mcl_mobs.registered_spawners[biome]
		local list = by_biome and by_biome[category]
		local out = {}
		for _, s in ipairs(list or {}) do
			out[#out + 1] = {name = s.name, weight = s.weight or 1,
				pack_min = s.pack_min, pack_max = s.pack_max}
		end
		return out
	end

	function A.biome_at(pos)
		local d = rawget(_G, "mcl_biome_dispatch")
		if d and d.get_biome_name then
			local ok, name = pcall(d.get_biome_name, pos)
			if ok and name then
				return name, "provider:mcl_biome_dispatch"
			end
		end
		local data = core.get_biome_data(pos)
		return data and core.get_biome_name(data.biome) or nil, "engine"
	end

	-- The framework's own spawn rules: light, clearance, generation.
	function A.natural_spawn_ok(pos, name)
		if not mcl_mobs.spawning_possible then
			return nil
		end
		local ok, res = pcall(mcl_mobs.spawning_possible, pos, name)
		return ok and res and true or false
	end

	local RULE
	local function director_rule(self)
		local rec = owned_lookup(self)
		if not rec then
			return nil
		end
		-- A creature the director ordered this mob to attack (orders.lua).
		if rec.target_guid then
			local obj = core.objects_by_guid[rec.target_guid]
			if obj and obj:is_valid() and obj:get_pos() then
				return obj
			end
			return nil
		end
		if not rec.target then
			return nil
		end
		local player = core.get_player_by_name(rec.target)
		if player and rec.may_target(rec.target) then
			return player
		end
		return nil
	end

	local function ensure_rule(e)
		if not RULE then
			RULE = mcl_mobs.build_target_rule({fn = director_rule})
		end
		local rules = rawget(e, "_targeting_rules")
		if rules and rules[1] == RULE then
			return
		end
		local list = {RULE}
		for _, f in ipairs(e._targeting_rules or {}) do
			if f ~= RULE then
				list[#list + 1] = f
			end
		end
		e._targeting_rules = list
		if not rawget(e, "get_staticdata_table") then
			e.get_staticdata_table = function(self)
				local data = mcl_mobs.mob_class.get_staticdata_table(self)
				if data then
					data._targeting_rules = nil
				end
				return data
			end
		end
	end

	function A.spawn(pos, name)
		local obj = core.add_entity(pos, name)
		if not obj then
			return nil, "spawn_failed"
		end
		local e = obj:get_luaentity()
		if not e then
			return nil, "spawn_failed"
		end
		-- Without this a mob with no player in range is removed on its first
		-- step (check_despawn). The director cleans up after itself instead.
		e.persistent = true
		return obj
	end

	-- Make sure an owned mob carries the director's rule. Called once a
	-- second for every live owned mob, so a mob that was unloaded and came
	-- back gets it again.
	function A.apply_target(obj)
		local e = obj:get_luaentity()
		if not A.is_mob(e) then
			return false
		end
		ensure_rule(e)
		return true
	end

	function A.clear_target(obj)
		local e = obj:get_luaentity()
		if not e then
			return
		end
		local rules = rawget(e, "_targeting_rules")
		if rules and rules[1] == RULE then
			e._targeting_rules = nil
			e.get_staticdata_table = nil
		end
	end

	function A.set_name(obj, text)
		local e = obj:get_luaentity()
		if not e then
			return false
		end
		if text and text ~= "" then
			if e.set_nametag then
				e:set_nametag(text)
			else
				obj:set_nametag_attributes({text = text})
			end
		else
			e.nametag = nil
			if e.update_tag then
				e:update_tag()
			else
				obj:set_nametag_attributes({text = ""})
			end
		end
		return true
	end

	function A.current_name(obj)
		local e = obj:get_luaentity()
		return e and e.nametag
	end

	-- Hold a mob in place with mcl_mobs' own stupefied state, which its
	-- on_step honours: no AI, no wandering, but physics, fall damage, death
	-- and the per step caches still run. Shadowing on_step, as the probe
	-- did, stops those too, and a villager killed while held that way
	-- crashed the server from its murder report (target_visible indexing a
	-- cache only on_step creates, 1 October 2026).
	function A.freeze(obj)
		local e = obj:get_luaentity()
		if not e then
			return false
		end
		e.stupefied = true
		obj:set_velocity(vector.zero())
		return true
	end

	function A.release(obj)
		local e = obj:get_luaentity()
		if e then
			e.stupefied = nil
		end
	end

	-- Character orders (orders.lua). A held mob's own AI is off, but
	-- mcl_mobs still turns it and walks it along waypoints it already has,
	-- so movement goes through mcl_mobs' own pathfinder: gopath sets up a
	-- search, and pump_path advances that search, which a held mob's
	-- on_step skips until the waypoints exist.

	function A.face(obj, pos)
		local e = obj:get_luaentity()
		local here = obj:get_pos()
		if not e or not here then
			return
		end
		local yaw = math.atan2(-(pos.x - here.x), pos.z - here.z)
		if e.set_yaw then
			e:set_yaw(yaw)
		else
			obj:set_yaw(yaw)
		end
	end

	function A.walk_to(obj, pos, tolerance)
		local e = obj:get_luaentity()
		if not e or not e.gopath then
			return false
		end
		local ok = pcall(e.gopath, e, vector.round(pos), 1, "walk", tolerance or 1)
		return ok
	end

	function A.pump_path(obj, dtime)
		local e = obj:get_luaentity()
		if e and e.pathfinding_context and not e.waypoints and e.next_waypoint then
			pcall(e.next_waypoint, e, dtime)
		end
	end

	function A.moving(obj)
		local e = obj:get_luaentity()
		return e ~= nil and (e.waypoints ~= nil or e.pathfinding_context ~= nil)
	end

	function A.halt(obj)
		local e = obj:get_luaentity()
		if not e then
			return
		end
		if e.cancel_navigation then
			pcall(e.cancel_navigation, e)
		end
		if e.halt_in_tracks then
			pcall(e.halt_in_tracks, e)
		end
		if e.set_animation then
			pcall(e.set_animation, e, "stand")
		end
	end

	-- Whether this mob fights at all: villagers have no attack type and no
	-- damage, so ordering one to attack would do nothing.
	function A.can_attack(name)
		local def = def_of(name)
		return def ~= nil and def.attack_type ~= nil and (tonumber(def.damage) or 0) > 0
	end

	-- Let the mob's AI run with the director's rule as its only target
	-- source, so it fights whom it was ordered to and nobody else nearby.
	function A.attack_mode(obj, on)
		local e = obj:get_luaentity()
		if not e then
			return false
		end
		if on then
			if not RULE then
				RULE = mcl_mobs.build_target_rule({fn = director_rule})
			end
			e._targeting_rules = {RULE}
			if not rawget(e, "get_staticdata_table") then
				e.get_staticdata_table = function(self)
					local data = mcl_mobs.mob_class.get_staticdata_table(self)
					if data then
						data._targeting_rules = nil
					end
					return data
				end
			end
			e.stupefied = nil
		else
			e._targeting_rules = nil
			e.get_staticdata_table = nil
			e._active_target = nil
			e.attack = nil
			e.stupefied = true
			A.halt(obj)
		end
		return true
	end

	function A.can_wield(obj)
		local e = obj:get_luaentity()
		return e ~= nil and e.can_wield_items == true and e.set_wielditem ~= nil
	end

	function A.wield(obj, item)
		local e = obj:get_luaentity()
		if not e or not e.set_wielditem then
			return false
		end
		local ok = pcall(e.set_wielditem, e, ItemStack(item or ""), 0)
		return ok
	end

	function A.can_trade(obj)
		local e = obj:get_luaentity()
		return e ~= nil and e.show_trade_formspec ~= nil and e.set_profession ~= nil
	end

	A.professions = {"armorer", "butcher", "cartographer", "cleric", "farmer", "fisherman",
		"fletcher", "leatherworker", "librarian", "mason", "shepherd", "toolsmith",
		"weaponsmith"}

	-- Open this villager's trades for a player. A profession is set first
	-- when it has none (or another is asked for), and it is given a little
	-- experience so mobs_mc does not take the profession back for want of a
	-- job site.
	function A.open_trade(obj, player, profession)
		local e = obj:get_luaentity()
		if not e or not e.show_trade_formspec then
			return false, "cannot_trade"
		end
		if profession and profession ~= e._profession then
			local ok = pcall(e.set_profession, e, profession)
			if not ok then
				return false, "bad_profession"
			end
		elseif not e._profession or e._profession == "unemployed" or e._profession == "nitwit" then
			pcall(e.set_profession, e, "farmer")
		end
		e._xp = math.max(tonumber(e._xp) or 0, 1)
		if e.reload_trades and (not e._trades or #e._trades == 0) then
			pcall(e.reload_trades, e)
		end
		local ok, shown = pcall(e.show_trade_formspec, e, player, 0)
		if not ok or shown == false then
			return false, "busy"
		end
		return true, e._profession
	end

	-- Whom the mob is after now, as mcl_mobs itself decided this step.
	function A.target_of(obj)
		local e = obj:get_luaentity()
		local t = e and e._active_target
		if t and t:is_valid() and t:is_player() then
			return t:get_player_name()
		end
		return nil
	end

	function A.health(obj)
		local e = obj:get_luaentity()
		return e and e.health
	end

	-- After a removal: did it die, and who killed it? mcl_mobs sets
	-- self.dead when health runs out and keeps the last player to hit it,
	-- and counts the kill as theirs within five seconds (physics.lua).
	function A.death(luaentity)
		if not luaentity or not luaentity.dead then
			return false
		end
		local killer
		if luaentity.last_player_hit_time and luaentity.last_player_hit_name
				and core.get_gametime() - luaentity.last_player_hit_time <= 5 then
			killer = luaentity.last_player_hit_name
		end
		return true, killer
	end

	-- Gear. mcl_armor keeps worn armour in the player's "armor" list, and
	-- its points come from the mcl_armor_points item group. A weapon is the
	-- best fleshy damage in the hotbar.
	local best_armour, best_weapon
	local function bests()
		if best_armour then
			return best_armour, best_weapon
		end
		local slots = {armor_head = 0, armor_torso = 0, armor_legs = 0, armor_feet = 0}
		best_weapon = 1
		for name, def in pairs(core.registered_items) do
			local groups = def.groups or {}
			local points = groups.mcl_armor_points or 0
			if points > 0 and not groups.not_in_creative_inventory then
				for slot in pairs(slots) do
					if (groups[slot] or 0) > 0 and points > slots[slot] then
						slots[slot] = points
					end
				end
			end
			local caps = def.tool_capabilities
			local fleshy = caps and caps.damage_groups and caps.damage_groups.fleshy
			if fleshy and not groups.not_in_creative_inventory and fleshy > best_weapon then
				best_weapon = fleshy
			end
		end
		best_armour = 0
		for _, p in pairs(slots) do
			best_armour = best_armour + p
		end
		if best_armour == 0 then
			best_armour = 20
		end
		return best_armour, best_weapon
	end

	function A.equipment(player)
		local inv = player:get_inventory()
		local armour, pieces = 0, {}
		for _, stack in ipairs(inv:get_list("armor") or {}) do
			if not stack:is_empty() then
				local name = stack:get_name()
				local points = core.get_item_group(name, "mcl_armor_points")
				if points > 0 then
					armour = armour + points
					pieces[#pieces + 1] = name
				end
			end
		end
		local weapon, weapon_name = 1, nil
		local hotbar = player:hud_get_hotbar_itemcount() or 9
		local main = inv:get_list("main") or {}
		for i = 1, math.min(hotbar, #main) do
			local stack = main[i]
			if not stack:is_empty() then
				local caps = stack:get_tool_capabilities()
				local fleshy = caps and caps.damage_groups and caps.damage_groups.fleshy or 0
				if fleshy > weapon then
					weapon, weapon_name = fleshy, stack:get_name()
				end
			end
		end
		local ba, bw = bests()
		return {armour = armour, armour_best = ba, pieces = pieces,
			weapon = weapon_name, weapon_damage = weapon, weapon_best = bw}
	end

	return A
end
