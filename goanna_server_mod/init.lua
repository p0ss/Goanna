-- Goanna server mod: tells a Goanna client what this server permits.
--
-- The whole design rests on one rule. A Goanna client must never give a player
-- reach or information a vanilla Luanti client lacks. Some of the things
-- Goanna could do would break that rule if the client simply decided to do
-- them. So it does not decide. This mod is how a server operator grants them,
-- and a server without this mod grants nothing, which is why absence is the
-- safe default rather than a failure: every option here is off unless someone
-- deliberately turned it on.
--
-- Nothing about this is required. Goanna connects to unmodified servers over
-- the ordinary protocol and renders them exactly as it does today. This only
-- ever adds.

local CHANNEL = "goanna:v1"
local channel = core.mod_channel_join(CHANNEL)

local function conf_bool(key, default)
	local v = core.settings:get_bool(key)
	if v == nil then return default end
	return v
end

local function conf_num(key, default)
	local v = tonumber(core.settings:get(key))
	return v or default
end

-- What we advertise, and the reason this mod does not enumerate capabilities.
--
-- The obvious design is a list here: far_rendering, source_movement, and one
-- more line every time a capability is added. That forces this mod to be
-- updated in lockstep with every client feature, and leaves a server running
-- last year's copy unable to authorise anything newer, for no reason beyond
-- bookkeeping.
--
-- So it enumerates nothing. Every setting named goanna_* is relayed as it is
-- found, and neither end needs this mod to understand what any of them mean.
-- A client that knows a key uses it; one that does not ignores it; a key no
-- client knows yet costs nothing. Adding a permission is then an edit to
-- minetest.conf, not a new release of this mod.
--
-- Two consequences worth stating. Unknown keys must be ignored silently at
-- both ends, which is what makes this safe to extend. And nothing secret goes
-- in a goanna_* setting, because all of them are broadcast to every client
-- that asks.
local extra = {}

-- For submods: a capability needing server side behaviour rather than only
-- the operator's consent announces itself here. See README.md for when a
-- submod is the right shape and when a setting is enough.
function goanna_announce(key, value)
	extra[key] = tostring(value)
end

local function options()
	local o = {}
	local seen = {}
	for _, key in ipairs(core.settings:get_names()) do
		if key:sub(1, 7) == "goanna_" and not seen[key] then
			seen[key] = true
			-- strip the prefix: the namespace exists to find them in the
			-- server's config, not to be repeated on the wire
			o[#o + 1] = key:sub(8) .. "=" .. tostring(core.settings:get(key))
		end
	end
	for k, v in pairs(extra) do
		if not seen["goanna_" .. k] then
			o[#o + 1] = k .. "=" .. v
		end
	end
	table.sort(o)
	return table.concat(o, "\n")
end

core.register_on_modchannel_message(function(channel_name, sender, message)
	if channel_name ~= CHANNEL then
		return
	end
	-- A server mod cannot see who joined a channel, only messages arriving on
	-- it, so the client says hello and this answers. send_all goes to everyone
	-- on the channel, which is fine: the options are a property of the server,
	-- not of the player, and there is nothing private in them.
	if message == "hello" and channel and channel:is_writeable() then
		-- Not cached: a submod may announce after this mod loaded.
		channel:send_all(options())
	end
end)

-- Source movement produces speeds and airborne paths the server's movement
-- check rejects, so it has to be told to allow them or the option silently
-- does nothing. The setting is anticheat_flags in 5.16; disable_anticheat is
-- the old name and is migrated, but reading it here would report the wrong
-- answer on any server configured the current way. "movement" is one of the
-- flags, and clearing it is what this needs.
if conf_bool("goanna_source_movement", false) then
	local flags = core.settings:get("anticheat_flags") or "digging,interaction,movement"
	if flags:find("movement") and not flags:find("nomovement") then
		core.log("warning", "[goanna] goanna_source_movement is on but anticheat_flags " ..
				"still includes movement, so the server will reject the movement it " ..
				"produces and the option will appear to do nothing. Set " ..
				"anticheat_flags = digging,interaction to allow it.")
	end
end

core.log("action", "[goanna] server mod loaded, advertising on " .. CHANNEL)
