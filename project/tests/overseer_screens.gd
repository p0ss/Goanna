# SPDX-License-Identifier: LGPL-2.1-or-later
## Checks the overseer's second screens pass (DorfCraft docs/interface-rules.md,
## "Screens to bring in line"): the grouped rail with Select and Map focus in
## the header. Stand ins from tests/overseer.gd; no renderer, server or GPU:
## godot --headless --path project --script res://tests/overseer_screens.gd
extends SceneTree
const Unit := preload("res://tests/overseer.gd")
const Overseer := preload("res://game/overseer.gd")
var failures := 0
var checks := 0
func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok: failures += 1
	print("PASS " if ok else "FAIL ", text)
func _initialize() -> void:
	call_deferred("run")

const CLAIM := {"min": {"x": -32, "y": -32, "z": -32}, "max": {"x": 32, "y": 32, "z": 32}}

func sections(states: Dictionary) -> Array:
	var out: Array = []
	for pair in [["select", "Select", "tools"], ["zones", "Zones", "plan"], ["build", "Build", "plan"],
			["terrain", "Terrain", "plan"], ["gather", "Gather", "plan"], ["devices", "Devices", "plan"],
			["defence", "Defence", "plan"], ["people", "People", "fortress"], ["supplies", "Supplies", "fortress"],
			["houses", "Houses", "fortress"], ["plans", "Plans", "fortress"]]:
		var sec := {"id": pair[0], "label": pair[1], "group": pair[2], "state": "shown"}
		if states.has(pair[0]):
			sec.state = states[pair[0]][0]
			sec.how = states[pair[0]][1]
		out.append(sec)
	return out

func open_view(main: Node, client: Node, caps: Dictionary) -> Node:
	var view := Overseer.new(); view.main = main; view.client = client; main.add_child(view)
	view._open()
	var tools := [{"id": "inspect", "title": "Inspect", "family": "Select"},
		{"id": "dig", "title": "Dig", "family": "Terrain", "height": 2},
		{"id": "wall", "title": "Build wall", "family": "Build", "material": "block"},
		{"id": "door", "title": "Place door", "family": "Build", "material": "door"},
		{"id": "workshop", "title": "Set up workshop", "family": "Build", "material": "station", "width": 3, "depth": 3}]
	caps.tools = tools
	view._receive({"v": 1, "t": "hello", "claim": CLAIM, "y": 0, "body": {"x": 0, "y": 0, "z": 0},
		"tools": tools, "capabilities": caps})
	return view

func rail_order(ui) -> Array:
	var out: Array = []
	for child in ui.rail.get_children():
		if not child.visible: continue
		if child is Label: out.append("[" + child.text + "]")
		elif child is Button and child.has_meta("family"): out.append(child.get_meta("family"))
	return out

func rail(view: Node) -> void:
	var ui = view.ui
	check(ui.select_button() != null and ui.select_button().get_parent() != ui.rail
		and ui.map_button.get_parent() == ui.select_button().get_parent(), "Select and Map focus sit in the header")
	check(rail_order(ui) == ["[Plan]", "Zones", "Build", "Terrain", "Gather", "Devices", "Defence",
		"[Fortress]", "People", "Supplies", "Plans"], "the rail groups Plan and Fortress; Houses is absent while hidden")
	for i in 3: await process_frame
	var wrapped: Array = []
	for b in ui.family_buttons:
		if b.visible and (b.autowrap_mode != TextServer.AUTOWRAP_OFF or b.size.x + 0.5 < b.get_combined_minimum_size().x):
			wrapped.append(b.text)
	check(wrapped.is_empty(), "no section label wraps or is cut at 100 percent text: %s" % [wrapped])
	var supplies: Button
	for b in ui.family_buttons: if b.get_meta("family") == "Supplies": supplies = b
	check(supplies.get_global_rect().end.x <= ui.left.get_global_rect().end.x, "Supplies fits inside the rail")
	check(ui.rail_scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED, "the rail does not scroll sideways at 100 percent")
	var defence: Button
	for b in ui.family_buttons: if b.get_meta("family") == "Defence": defence = b
	check(defence.modulate.a < 1.0 and defence.tooltip_text == "Raise a militia first.", "a locked section is greyed with how to unlock it")
	ui.choose_family("Defence")
	check(ui.family == "Select" and view.inspector.text == "Raise a militia first.", "choosing a locked section says why and stays")
	ui.select_button().pressed.emit()
	check(ui.family == "Select" and ui.select_button().button_pressed, "Select in the header chooses the map's own section")
	ui.choose_family("Build")
	check(ui.family == "Build" and not ui.select_button().button_pressed, "a rail section unpresses Select")
	check(ui.first_section().get_meta("family") == "Zones", "the controller's rail focus starts at the first section")
	view.root_control.theme.default_font_size = 36
	for i in 5: await process_frame
	wrapped.clear()
	for b in ui.family_buttons:
		if b.visible and b.get_parent() == ui.rail and b.autowrap_mode != TextServer.AUTOWRAP_OFF: wrapped.append(b.text)
	check(wrapped.is_empty() and ui.left.get_global_rect().end.x <= 1280 * 0.25 + 12.5, "at 200 percent the rail stays a quarter wide and its labels whole")
	view.root_control.theme.default_font_size = 18
	for i in 2: await process_frame

func houses_shown(main: Node, client: Node) -> void:
	var view := open_view(main, client, {"sections": sections({})})
	check(rail_order(view.ui).has("Houses"), "Houses joins the Fortress group once the server shows it")
	var only_select := open_view(main, client, {"sections": sections({"zones": ["hidden", ""], "build": ["hidden", ""],
		"terrain": ["hidden", ""], "gather": ["hidden", ""], "devices": ["hidden", ""], "defence": ["hidden", ""]})})
	check(not rail_order(only_select.ui).has("[Plan]") and rail_order(only_select.ui).has("[Fortress]"),
		"a group with every section hidden loses its heading")
	view._close(); only_select._close()

func run() -> void:
	root.size = Vector2i(1280, 720)
	var main := Unit.TestMain.new(); root.add_child(main)
	var client := Unit.TestClient.new(); main.add_child(client)
	var view := open_view(main, client, {"sections": sections({"houses": ["hidden", "Appears when a second player joins this fortress as a house."],
		"defence": ["locked", "Raise a militia first."]})})
	await rail(view)
	view._close()
	await houses_shown(main, client)
	print("Overseer screens: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
