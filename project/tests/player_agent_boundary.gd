# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# The player agent interface must never grow a developer verb. Checks the
# channel's own command list, the MCP wrapper's tool names and the CLI's
# commands against the control channel's, and the channel's source for the
# facilities that would make any command an escape hatch.
#
#   godot --headless --path project -s tests/player_agent_boundary.gd
extends SceneTree

# Names both interfaces use for different things: here they are an ordinary
# player's look, chat and wait, not the control channel's camera aim, chat
# with a reply, and expression wait.
const SHARED_NAMES := ["look", "chat", "wait"]
const FORBIDDEN := ["eval", "run", "call", "callv", "tp", "teleport", "pose", "inspect",
	"time", "weather", "set", "get", "settings", "shot", "reload_shader", "fly", "spawn",
	"give", "grant", "privs", "bench", "route", "quit", "key", "ui_tree", "ui_click",
	"ui_hover", "ui_type", "ui_scroll", "node", "scene", "render", "materials", "sky",
	"entities", "deviations", "label", "exec", "command"]

var failures := 0

func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		print("FAIL: ", what)

func _init() -> void:
	var player: GDScript = load("res://player_agent_channel.gd")
	var developer: GDScript = load("res://control_channel.gd")
	check(player != null and player.can_instantiate(), "player_agent_channel.gd compiles")
	check(developer != null, "control_channel.gd loads")
	var constants: Dictionary = player.get_script_constant_map()
	var commands: Array = constants["COMMANDS"]
	var dev_only: Array = FORBIDDEN.duplicate()
	for name in developer.get_script_constant_map()["COMMANDS"]:
		if name not in SHARED_NAMES and name not in dev_only:
			dev_only.append(name)
	for name in commands:
		check(name not in dev_only, "player command '%s' is a developer verb" % name)
	var listed: Array = constants["QUERIES"] + constants["ACTIONS"]
	check(listed.size() == commands.size(), "COMMANDS is QUERIES plus ACTIONS")
	for name in listed:
		check(name in commands, "%s is in COMMANDS" % name)
	for status in ["accepted", "completed", "interrupted", "refused", "stale"]:
		check(status in constants["RESULTS"], "result %s is advertised" % status)

	# The source: no dispatcher into arbitrary code, no method by name, no
	# position write, and the one shell call is the token file's umask.
	var source := FileAccess.get_file_as_string("res://player_agent_channel.gd")
	for pattern in ["_dispatch(", "callv(", ".call(", "Expression.new(", "GDScript.new(",
			"set_player_pose", "teleport_to(", "inventory_action(", "res://control_channel",
			"\"/teleport", "execute_with_pipe", "create_process"]:
		check(not source.contains(pattern), "player channel source contains %s" % pattern)
	check(source.count("OS.execute(") == 1 and source.contains("umask 077"),
		"the only shell call writes the token file")
	check(source.contains("_token_matches(") and source.contains("\"127.0.0.1\""),
		"token check and loopback bind")

	# The wrappers expose the same vocabulary and nothing else.
	var tools := ProjectSettings.globalize_path("res://").path_join("../tools")
	var mcp := FileAccess.get_file_as_string(tools.path_join("goanna-player-mcp"))
	check(mcp != "", "tools/goanna-player-mcp is readable")
	var tool_names := RegEx.create_from_string("\\btool\\(\"([a-z_]+)\"")
	var seen := 0
	for m in tool_names.search_all(mcp):
		seen += 1
		var verb := m.get_string(1)
		check(verb in commands, "MCP tool goanna_player_%s maps to a player command" % verb)
		check(verb not in dev_only, "MCP tool goanna_player_%s is a developer verb" % verb)
	check(seen >= commands.size(), "MCP exposes every player command (%d tools)" % seen)
	var cli := FileAccess.get_file_as_string(tools.path_join("goanna-player"))
	for name in dev_only:
		check(not cli.contains("add_parser(\"%s\"" % name) and not cli.contains("action(\"%s\"" % name),
			"CLI offers %s" % name)

	print("player-agent boundary: %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	quit(0 if failures == 0 else 1)
