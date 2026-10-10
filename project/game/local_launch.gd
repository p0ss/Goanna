# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
extends RefCounted

# A handoff, consumed once by the shell. Passwords never enter goanna.cfg.
static var players: Array = []
static var server: RefCounted
static var layout := "grid"
static var graphics_profile := "low"

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
