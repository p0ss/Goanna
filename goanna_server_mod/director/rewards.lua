-- SPDX-License-Identifier: LGPL-2.1-or-later
-- Rewards: an item the director makes and puts where a player can choose
-- to take it (docs/agents/director.md, "Rewards").
--
-- The core makes the item from the engine's registry, names it through item
-- metadata, prices it with logic.item_value and drops it on the ground. The
-- items adapter adds what a game knows: enchantments, a name the way the
-- game's own anvil writes it, armour points, and a container to put it in.
-- A reward never goes into an inventory: a player has to be able to leave a
-- gift from a machine where it lies.

return function(D)
	local logic = D.logic
	local MAX_LINES, LINE_CHARS, NAME_CHARS = 4, 60, 40

	local function points_left()
		return D.cfg.reward_points_per_hour - logic.window_sum(D.reward_points, D.now())
	end
	D.reward_points_left = points_left

	-- The stack, or nil, a reason and detail fields.
	local function make(args)
		local item = args.item
		local def = type(item) == "string" and core.registered_items[item]
		if not def or item == "" or item == "air" or item == "ignore" then
			return nil, "unknown_item", {item = item}
		end
		if D.cfg.reward_deny[item] then
			return nil, "denied", {item = item}
		end
		if ((def.groups or {}).not_in_creative_inventory or 0) > 0 then
			return nil, "hidden_item", {item = item}
		end
		local stack_max = def.stack_max or 99
		local count = math.floor(tonumber(args.count) or 1)
		if count < 1 or count > stack_max then
			return nil, "schema", {detail = "count is 1 to " .. stack_max}
		end
		local stack = ItemStack(item)
		stack:set_count(count)
		local enchantments = {}
		if args.enchantments ~= nil then
			if type(args.enchantments) ~= "table" then
				return nil, "schema", {detail = "enchantments: [{name, level}, ...]"}
			end
			for _, e in ipairs(args.enchantments) do
				if type(e) ~= "table" or type(e.name) ~= "string" then
					return nil, "schema", {detail = "enchantments: [{name, level}, ...]"}
				end
				enchantments[#enchantments + 1] = {name = e.name,
					level = math.max(1, math.floor(tonumber(e.level) or 1))}
			end
		end
		if #enchantments > 0 then
			if not (D.items and D.items.enchant) then
				return nil, "no_adapter", {kind = "items", detail = "this game has no enchantments the director knows"}
			end
			local enchanted, why = D.items.enchant(stack, enchantments)
			if not enchanted then
				return nil, "cannot_enchant", {detail = why}
			end
			stack = enchanted
		end
		local name
		if args.name ~= nil then
			name = logic.clean_text(args.name)
			if not name or name == "" or #name > NAME_CHARS then
				return nil, "schema", {detail = "name is 1 to " .. NAME_CHARS .. " characters"}
			end
		end
		local lines = {}
		if args.lines ~= nil then
			if type(args.lines) ~= "table" or #args.lines > MAX_LINES then
				return nil, "schema", {detail = "lines: at most " .. MAX_LINES}
			end
			for _, l in ipairs(args.lines) do
				local t = logic.clean_text(l)
				if not t or #t > LINE_CHARS then
					return nil, "schema", {detail = "each line at most " .. LINE_CHARS .. " characters"}
				end
				if t ~= "" then
					lines[#lines + 1] = t
				end
			end
		end
		if name or #lines > 0 then
			if D.items and D.items.describe then
				stack = D.items.describe(stack, name, lines)
			else
				local text = name or def.description or item
				if #lines > 0 then
					text = text .. "\n" .. table.concat(lines, "\n")
				end
				stack:get_meta():set_string("description", text)
			end
		end
		local value = logic.item_value(D.item_facts(item), count)
		return stack, nil, {cost = logic.reward_cost(value, enchantments), name = name,
			enchantments = #enchantments > 0 and enchantments or nil}
	end

	-- A clear, walkable place 2 to 4 nodes from the player, in front of
	-- them where possible.
	local function spot_near(player)
		local pp = player:get_pos()
		local look = player:get_look_dir()
		local base = math.atan2(look.z, look.x)
		for _, off in ipairs({0, 0.5, -0.5, 1, -1, 1.6, -1.6, 2.4, -2.4, math.pi}) do
			for _, dist in ipairs({2.5, 3.5, 2}) do
				local a = base + off
				local at = D.ground_at(pp.x + math.cos(a) * dist, pp.z + math.sin(a) * dist,
					pp.y + 1, 1)
				if at and not core.is_protected(at, "") then
					return at
				end
			end
		end
		return nil
	end
	D.reward_spot = spot_near

	-- An item entity on the ground. Engine item entities expire after
	-- item_entity_ttl (900 s by default), which stays as it is.
	function D.drop_reward(pos, stack, act, player)
		local obj = core.add_item(vector.offset(pos, 0, 0.3, 0), stack)
		if not obj then
			return nil
		end
		local guid = obj:get_guid()
		D.rewards[act].guid = guid
		D.emit("reward_placed", {"player:" .. player}, {act = act, item = stack:get_name(),
			delivery = D.rewards[act].delivery}, pos)
		return guid
	end

	D.rewards = {}        -- act id -> reward record

	function D.grant_reward_intent(msg, result, refuse)
		local args = msg.args
		local who = type(args.near) == "string" and args.near:gsub("^player:", "")
		local player = who and core.get_player_by_name(who)
		if not player or not D.players[who] then
			return refuse(msg, "not_online", {near = args.near})
		end
		if D.opted_out(who) then
			return refuse(msg, "opted_out", {near = who})
		end
		local stack, why, info = make(args)
		if not stack then
			return refuse(msg, why, info)
		end
		if info.cost > D.cfg.reward_max then
			return refuse(msg, "over_reward_max", {cost = info.cost, max = D.cfg.reward_max})
		end
		local left = points_left()
		if info.cost > left then
			return refuse(msg, "budget", {cost = info.cost, reward_points_left = left})
		end
		local delivery = args.delivery or "drop"
		local rec = {act = msg.req, player = who, delivery = delivery, item = stack:get_name(),
			stack = stack:to_string()}
		local fields = {item = stack:get_name(), count = stack:get_count(), name = info.name,
			enchantments = info.enchantments, cost = info.cost, delivery = delivery}
		if delivery == "drop" then
			local at = spot_near(player)
			if not at then
				return refuse(msg, "no_place")
			end
			D.rewards[msg.req] = rec
			if not D.drop_reward(at, stack, msg.req, who) then
				D.rewards[msg.req] = nil
				return refuse(msg, "no_place")
			end
			fields.at = D.vec(at)
		elseif delivery == "container" then
			local node, list = nil, nil
			if D.items and D.items.container then
				node, list = D.items.container()
			end
			if not node then
				return refuse(msg, "no_container", {detail = "use delivery drop or npc"})
			end
			local at = spot_near(player)
			if not at then
				return refuse(msg, "no_place")
			end
			local dir = vector.direction(at, player:get_pos())
			core.set_node(at, {name = node, param2 = core.dir_to_facedir(dir)})
			local inv = core.get_meta(at):get_inventory()
			if inv:get_size(list) == 0 then
				core.remove_node(at)
				return refuse(msg, "no_container", {detail = node .. " has no " .. list .. " list"})
			end
			inv:add_item(list, stack)
			rec.pos, rec.node, rec.list = at, node, list
			D.rewards[msg.req] = rec
			fields.at = D.vec(at)
			D.emit("reward_placed", {"player:" .. who}, {act = msg.req, item = stack:get_name(),
				delivery = "container"}, at)
		elseif delivery == "npc" then
			local npc = type(args.npc) == "string" and D.npcs[args.npc:lower()]
			if not npc then
				return refuse(msg, "unknown_speaker", {npc = args.npc})
			end
			if not D.obj_by_guid(npc.guid) then
				return refuse(msg, "speaker_gone", {npc = npc.name})
			end
			rec.npc = npc.name:lower()
			D.rewards[msg.req] = rec
			D.order_deliver(npc, who, stack, msg.req)
			fields.npc = npc.name
		else
			return refuse(msg, "schema", {detail = "delivery: drop, container or npc"})
		end
		logic.window_add(D.reward_points, D.now(), info.cost)
		fields.reward_points_left = points_left()
		D.undo[msg.req] = {type = "reward", act = msg.req}
		return result(msg, delivery == "npc" and "accepted" or "completed", fields,
			{effects = {item = rec.stack, delivery = delivery, at = fields.at}, players = {who}})
	end

	-- Undo: take the reward back if nobody has. Once a player has it, it
	-- is theirs.
	function D.undo_reward(u)
		local rec = D.rewards[u.act]
		if not rec then
			return {taken_back = false}
		end
		D.rewards[u.act] = nil
		if rec.guid then
			local obj = D.obj_by_guid(rec.guid)
			if obj then
				obj:remove()
				return {taken_back = true}
			end
			return {taken_back = false, note = "already picked up or expired"}
		end
		if rec.pos then
			local node = core.get_node(rec.pos)
			if node.name ~= rec.node then
				return {taken_back = false, note = "the container is gone"}
			end
			local inv = core.get_meta(rec.pos):get_inventory()
			local list = inv:get_list(rec.list) or {}
			local only = true
			local found = false
			for _, s in ipairs(list) do
				if not s:is_empty() then
					if s:to_string() == rec.stack and not found then
						found = true
					else
						only = false
					end
				end
			end
			if found and only then
				core.remove_node(rec.pos)
				return {taken_back = true}
			end
			return {taken_back = false, note = "a player has opened and changed the container"}
		end
		if rec.npc then
			local npc = D.npcs[rec.npc]
			if npc and npc.order and npc.order.kind == "deliver" and npc.order.act == u.act then
				D.cancel_order(rec.npc)
				return {taken_back = true}
			end
			return {taken_back = false, note = "already handed over"}
		end
		return {taken_back = false}
	end
end
