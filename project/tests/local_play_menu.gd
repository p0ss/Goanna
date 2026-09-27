# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
extends SceneTree

var failures := 0

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	_run.call_deferred()

func buttons(node: Node, text: String) -> Array:
	var found: Array = []
	if node is Button and node.text == text:
		found.append(node)
	for child in node.get_children():
		found.append_array(buttons(child, text))
	return found

func _run() -> void:
	OS.set_environment("GOANNA_MENU", "1")
	OS.set_environment("GOANNA_NO_SHOWCASE", "1")
	var menu := preload("res://menu.tscn").instantiate()
	root.add_child(menu)
	menu.local_roster = [{"name": "one", "device": -1},
		{"name": "two", "device": -2, "password": "not-persisted"}]
	menu._show_local_players()
	await process_frame
	var save := buttons(menu.screen, "Save and back")
	check(save.size() == 1, "Local setup exposes its save action")
	if not save.is_empty():
		save[0].pressed.emit()
	check(menu.local_roster[0]["device"] == -1, "Keyboard assignment survives the menu")
	check(menu.local_roster[1]["device"] == -2, "Waiting assignment survives the menu")
	check(menu.local_roster[1]["password"] == "not-persisted", "Password survives the in-memory handoff")
	var cfg := ConfigFile.new()
	cfg.load("user://goanna.cfg")
	var saved: Array = cfg.get_value("local_play", "players", [])
	check(saved.size() == 2, "Player identities are remembered")
	for player in saved:
		check(not player.has("password"), "Passwords are not saved")
	check(cfg.get_value("local_play", "graphics_profile", "") == "low", "Local graphics start on Low")
	menu._show_local_players()
	var picks: Array[Node] = menu.screen.find_children("*", "OptionButton", true, false)
	var found_lowest := false
	for picker in picks:
		for i in picker.item_count:
			if picker.get_item_text(i) == "Local graphics: Lowest":
				picker.select(i)
				picker.item_selected.emit(i)
				found_lowest = true
	check(found_lowest, "Local setup offers Lowest")
	buttons(menu.screen, "Save and back")[0].pressed.emit()
	cfg.load("user://goanna.cfg")
	check(cfg.get_value("local_play", "graphics_profile", "") == "lowest", "Lowest selection persists")
	menu.free()
	await process_frame
	print("local play menu: %d failures" % failures)
	quit(1 if failures else 0)
