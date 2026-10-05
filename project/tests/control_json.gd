# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Every control channel reply must be strict JSON. Luanti's coloured text
# carries raw escape characters (core.colorize writes "\u001b(c@#...)"), and
# Godot's JSON.stringify passes them through unescaped, so an entity list
# with a coloured nametag could not be parsed by tools/goanna-control.
#
#   godot --headless --path project -s tests/control_json.gd
extends SceneTree

var failures := 0

func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		print("FAIL: ", what)

func _init() -> void:
	var channel: GDScript = load("res://control_channel.gd")
	var esc := char(27)
	var tag := esc + "(c@#ff0000)Bob" + esc + "(c@#ffffff)"
	var msg := {"id": 1, "ok": true, "result": {"entities": [
		{"nametag": tag, "infotext": "a\tb\nc" + char(1) + char(31)}]}}
	var line: String = channel.json_line(msg)
	for code in range(1, 32):
		check(not line.contains(char(code)),
			"no raw control character %d in the reply" % code)
	check(line.contains("\\u001b(c@#ff0000)Bob"), "ESC escaped as \\u001b")
	var parsed = JSON.parse_string(line)
	check(parsed is Dictionary, "the reply parses")
	if parsed is Dictionary:
		var e: Dictionary = parsed["result"]["entities"][0]
		check(e["nametag"] == tag, "the nametag survives the round trip")
		check(e["infotext"] == "a\tb\nc" + char(1) + char(31), "tab, newline and the rest survive")
	print("control_json: %d failure(s)" % failures)
	quit(1 if failures else 0)
