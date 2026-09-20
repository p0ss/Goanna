-- Shared dig damage: letting OTHER players see the block you are chipping at.
--
-- What this is and is not, because the name it first carried was wrong and the
-- wrong name led to the wrong threat model.
--
-- A Goanna client already carves the block it is digging, locally, and always
-- has. That needs nothing from a server: the client is redrawing its own
-- memory of its own digging, which gives the player no reach and no
-- information a vanilla client lacks, exactly like the crack overlay. It works
-- on every server including ones that have never heard of Goanna.
--
-- This file is about the OTHER players. It takes one client's account of what
-- a block looks like and relays it to everyone, which is the one thing here a
-- client cannot be taken at its word for. That, and not persistence, is the
-- trust being asked for, and it is why there is an option at all.
--
-- It is also NOT dig progress. Progress is a timing check the server enforces
-- (`serverpackethandler.cpp`: a dig is accepted when it was clean and long, or
-- when the player's dig pool covers it), and enforcement is not something to
-- hand to a client. A server that wants a half mined block to finish faster
-- has to say so in node state the definition can see, because `getDigParams`
-- reads the node's TYPE and not its position. Kythen does that in its own
-- registry; a general purpose server mod cannot, and should not try by
-- loosening a check instead.
--
-- Worth knowing: the anticheat path is skipped entirely in singleplayer
-- (`anticheat_flags & AC_DIGGING && !isSingleplayer()`), so for a world hosted
-- for one person none of that arises.
--
-- The threat this guards against is therefore narrow and specific: a modified
-- client reporting a shape it never dug, on a block it was never near, to
-- everyone else. Hence a reach check, a size cap and a rate limit, and hence
-- off by default.
--
-- CARVE AUTHORITY. A client's own report, relayed here, is necessarily
-- provisional: it is guessed ahead of the server's own gate on whether the
-- blow was diggable at all (`core.get_dig_params`, the tool and the node's
-- own groups), and a Goanna client has no way to know a game's own dig
-- timing or wear rules in advance. A GAME that computes damage itself --
-- Kythen's `form_damage.lua`, which derives it from those same server side
-- checks and writes the result to the SAME `goanna_carve` metadata key this
-- file writes -- is a second, authoritative writer of that key, and the two
-- must not fight over it: whichever write lands last wins, so a client's
-- provisional guess could overwrite the game's own authoritative answer with
-- a shape the game itself never validated.
--
-- `core.settings:get("goanna_carve_authority") == "game"` is how a game
-- says it owns this key. When it is set, this file stops relaying
-- client reported carves entirely, whatever `goanna_shared_dig_damage`
-- says: a client's own LOCAL prediction (see this file's own header, above)
-- is unaffected, since that needs nothing from a server, but nothing here
-- writes it to node metadata for other players to see, leaving that
-- entirely to the game's own mod. The setting is the GAME's own, not this
-- one's -- it is not declared in `settingtypes.txt` here, because a general
-- purpose relay has no default opinion about who owns a specific game's own
-- metadata, and a game that wants it sets it itself (Kythen's own game
-- settings, not this mod's).
return function(channel, enabled)
	if core.settings:get("goanna_carve_authority") == "game" then
		core.log("action", "[goanna] shared dig damage relay is off: "
				.. "goanna_carve_authority=game, the game computes its own damage")
		return
	end
	if not enabled then
		return
	end

	-- The renderer's key, not the game's: whatever writes it, Goanna is what
	-- reads it back and draws from it. Kythen writes the same key for the same
	-- reason. Renaming it is a protocol change.
	local KEY = "goanna_carve"

	-- A v3 carve is at most a version byte, a header byte, four of control
	-- mask, and twenty-six controls of one field byte plus two scalars:
	-- 1 + 1 + 4 + 26 * 3 = 84. The old v1 layout reached 109, so 128 still
	-- covers either.
	local MAX_BYTES = 128

	-- How far from a player a carve may land, in nodes. A client may only
	-- describe something it could have been hitting.
	local REACH = 8

	-- Smallest gap between accepted reports from one player, in seconds. A dig
	-- produces a handful of steps over seconds; anything faster is not a person
	-- mining. Without this the cheapest abuse is not a false shape but a flood
	-- of true ones, since every accepted report writes metadata that the server
	-- then sends to everyone in range.
	local MIN_INTERVAL = 0.15
	local last = {}

	core.register_on_leaveplayer(function(player)
		last[player:get_player_name()] = nil
	end)

	local function may_report(name, pos)
		local now = core.get_us_time() / 1000000
		if last[name] and now - last[name] < MIN_INTERVAL then
			return false
		end
		local player = core.get_player_by_name(name)
		if not player then
			return false
		end
		local eye = player:get_pos()
		eye.y = eye.y + 1.5
		if vector.distance(eye, pos) > REACH then
			return false
		end
		last[name] = now
		return true
	end

	core.register_on_modchannel_message(function(channel_name, sender, message)
		if channel_name ~= "goanna:v1" or sender == "" then
			return
		end
		-- The payload is HEX. Luanti hands this message to Lua through
		-- lua_pushstring, which stops at the first zero byte, and the carve
		-- codec's presence mask nearly always contains one: sent raw, a carve
		-- arrived as its first three bytes and was stored that way. A report
		-- that is not whole hex is not a carve.
		local x, y, z, hex = message:match("^carve (%-?%d+) (%-?%d+) (%-?%d+) (%x*)$")
		if not x or #hex % 2 ~= 0 then
			return
		end
		local payload = hex:gsub("%x%x", function(pair)
			return string.char(tonumber(pair, 16))
		end)
		local pos = { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
		if #payload > MAX_BYTES then
			core.log("warning", ("[goanna] carve from %s at %s is %d bytes, over the %d limit")
					:format(sender, core.pos_to_string(pos), #payload, MAX_BYTES))
			return
		end
		if not may_report(sender, pos) then
			return
		end
		local node = core.get_node_or_nil(pos)
		-- Air has no surface to carve, and a node that has already gone must not
		-- get an entry: a carve outliving its node is a stale byte string that
		-- the next node placed there would wear.
		if not node or node.name == "air" or node.name == "ignore" then
			return
		end
		core.get_meta(pos):set_string(KEY, payload)
	end)

	-- A node replaced is a node whose damage is over. Without this a fresh
	-- block placed where a worn one stood inherits the wear, which reads as the
	-- new block arriving pre damaged.
	local function clear(pos)
		local meta = core.get_meta(pos)
		if meta:get_string(KEY) ~= "" then
			meta:set_string(KEY, "")
		end
	end
	core.register_on_dignode(function(pos) clear(pos) end)
	core.register_on_placenode(function(pos) clear(pos) end)

	core.log("action", "[goanna] shared dig damage is on (goanna_shared_dig_damage)")
end
