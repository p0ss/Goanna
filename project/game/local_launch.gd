# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## The split screen roster and server, handed from the menu to the local play
## shell. menu/menu.gd fills the static fields and changes scene;
## game/local_play.gd reads them once in _ready and clears them. Never
## instanced: everything is static. docs/systems/local-multiplayer.md has
## the whole picture.
extends RefCounted

# A handoff, consumed once by the shell. Passwords never enter goanna.cfg.
static var players: Array = []
static var server: RefCounted
static var layout := "grid"
static var graphics_profile := "low"

## Checks a roster of {name, device, password?} dictionaries before any slot
## is made. Returns "" when it is usable, else the message to show the player.
## Device -1 is the keyboard and mouse, -2 a slot still waiting for a
## controller (any number may wait), 0 and up a joypad id.
static func validate(roster: Array) -> String:
	if roster.is_empty():
		return "Add at least one player."
	var names := {}
	var devices := {}
	for player in roster:
		if not player is Dictionary:
			return "Each player must have a name and a control assignment."
		var player_name := str(player.get("name", "")).strip_edges()
		if player_name.is_empty():
			return "Every player needs a name."
		if names.has(player_name):
			return "Each player needs a different name."
		names[player_name] = true
		var device := int(player.get("device", -2))
		if device < -2:
			return "Unknown control assignment."
		if device != -2 and devices.has(device):
			return "Assign each controller, and the keyboard, to one player."
		devices[device] = true
	return ""

## The roster GOANNA_LOCAL_PLAY asks for, for test and developer launches:
## either a player count (the first on the keyboard, the rest on connected
## controllers or waiting) or a JSON array of player dictionaries.
static func from_environment() -> Array:
	var value := OS.get_environment("GOANNA_LOCAL_PLAY")
	if value.is_valid_int():
		var roster: Array = []
		var pads := Input.get_connected_joypads()
		var base := OS.get_environment("GOANNA_NAME")
		if base.is_empty():
			base = "player"
		for i in maxi(0, int(value)):
			roster.append({"name": base if i == 0 else "%s_%d" % [base, i + 1],
				"device": -1 if i == 0 else pads[i - 1] if i - 1 < pads.size() else -2})
		return roster
	var parsed: Variant = JSON.parse_string(value) if not value.is_empty() else null
	return parsed if parsed is Array else []
