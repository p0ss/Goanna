-- Remembered dig progress: a block half dug and left stays half dug.
--
-- Players found it annoying to dig a block most of the way, look away or
-- stop, and come back to dig it again from nothing (owner, 2026-10-04).
-- Luanti keeps no progress: a dig is a timing check the server makes from
-- the moment the player starts on a block (serverpackethandler.cpp), and
-- damage.lua's header explains why a mod must not loosen that check.
--
-- This does not loosen it. The server watches each player itself: every
-- step it reads whether the player is holding dig, finds the block they
-- are pointing at with a ray from their eye within the reach of what they
-- hold, and adds the elapsed time against that block's own dig time for
-- that tool (core.get_dig_params, the same rule the engine uses). Nothing
-- the client says is trusted. When a block that already carries progress
-- from an earlier go reaches its full time, the server digs it through the
-- node's own on_dig, so drops, tool wear, protection and the game's own dig
-- rules apply exactly as for an ordinary dig.
--
-- A dig finished in one go is left to the engine, as before: this only
-- steps in for a block the player is coming back to. Progress is kept in
-- memory, per position, until the block changes or the server stops, and
-- every player's time on a block adds to the same total.
--
-- The client is not told. Its crack overlay starts from nothing on a block
-- it comes back to and the block breaks before the crack completes; a
-- Goanna client with shared dig damage on shows the carve as it was left.
return function(enabled)
	if not enabled then
		return
	end

	local STEP = 0.1
	local MAX_ENTRIES = 4096
	-- entries[hash] = {name, done (0..1), stretches (finished stretches of
	-- digging), at (last update, seconds)}
	local entries = {}
	local count = 0
	-- digging[player name] = hash of the block they were on last step
	local digging = {}
	local clock = 0
	local timer = 0

	local function hand_of(player)
		local inv = player:get_inventory()
		if inv and inv:get_size("hand") > 0 then
			local hand = inv:get_stack("hand", 1)
			if not hand:is_empty() then
				return hand
			end
		end
		return ItemStack("")
	end

	-- The tool the engine would dig with, and that dig's parameters: the
	-- wielded item, or the hand when the wielded item cannot dig this node.
	local function dig_params(player, groups)
		local tool = player:get_wielded_item()
		local params = core.get_dig_params(groups, tool:get_tool_capabilities(), tool:get_wear())
		if params.diggable then
			return params
		end
		local hand = hand_of(player)
		return core.get_dig_params(groups, hand:get_tool_capabilities(), hand:get_wear())
	end

	local function reach_of(player)
		local def = player:get_wielded_item():get_definition()
		if def and def.range then
			return def.range
		end
		local hand = hand_of(player):get_definition()
		return (hand and hand.range) or 4
	end

	local function pointed_node(player)
		local eye = player:get_pos()
		local props = player:get_properties()
		eye.y = eye.y + (props.eye_height or 1.625)
		local dir = player:get_look_dir()
		local ray = core.raycast(eye, vector.add(eye, vector.multiply(dir, reach_of(player))),
				false, false)
		for hit in ray do
			if hit.type == "node" then
				return hit.under
			end
		end
	end

	local function forget(hash)
		if entries[hash] then
			entries[hash] = nil
			count = count - 1
		end
	end

	local function prune()
		if count <= MAX_ENTRIES then
			return
		end
		local oldest, oldest_at
		for hash, entry in pairs(entries) do
			if not oldest_at or entry.at < oldest_at then
				oldest, oldest_at = hash, entry.at
			end
		end
		forget(oldest)
	end

	local function finish(player, pos, node, def)
		local on_dig = def.on_dig or core.node_dig
		on_dig(pos, node, player)
	end

	core.register_globalstep(function(dtime)
		clock = clock + dtime
		timer = timer + dtime
		if timer < STEP then
			return
		end
		local elapsed = timer
		timer = 0
		for _, player in ipairs(core.get_connected_players()) do
			local name = player:get_player_name()
			local pos = player:get_player_control().dig and pointed_node(player)
			local hash = pos and core.hash_node_position(pos)
			local was = digging[name]
			-- A stretch on a block ends when the player stops digging it.
			if was and was ~= hash and entries[was] then
				entries[was].stretches = entries[was].stretches + 1
			end
			digging[name] = hash
			if pos then
				local node = core.get_node(pos)
				local def = core.registered_nodes[node.name]
				if def and def.diggable ~= false then
					local params = dig_params(player, def.groups or {})
					if params.diggable and params.time and params.time > 0 then
						local entry = entries[hash]
						if entry and entry.name ~= node.name then
							forget(hash)
							entry = nil
						end
						if not entry then
							entry = {name = node.name, done = 0, stretches = 0, at = clock}
							entries[hash] = entry
							count = count + 1
							prune()
						end
						entry.done = entry.done + elapsed / params.time
						entry.at = clock
						if entry.done >= 1 and entry.stretches > 0 then
							forget(hash)
							digging[name] = nil
							finish(player, pos, node, def)
						end
					end
				end
			end
		end
	end)

	-- Whatever removes or replaces a block ends its progress.
	core.register_on_dignode(function(pos)
		forget(core.hash_node_position(pos))
	end)
	core.register_on_placenode(function(pos)
		forget(core.hash_node_position(pos))
	end)
	core.register_on_leaveplayer(function(player)
		digging[player:get_player_name()] = nil
	end)

	core.log("action", "[goanna] remembered dig progress is on (goanna_dig_progress)")
end
