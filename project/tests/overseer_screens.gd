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

func find_button(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text: return node
	for child in node.get_children():
		var found := find_button(child, text)
		if found != null: return found
	return null

## DorfCraft's building part adds a Shape group to Build (docs/building.md).
func shapes(main: Node, client: Node) -> void:
	var view := open_view(main, client, {"sections": sections({})})
	var tools: Array = view.tools.duplicate()
	for pair in [["line", "Line"], ["wall", "Wall"], ["box", "Box"]]:
		tools.append({"id": "shape:" + pair[0], "title": pair[1], "family": "Build", "group": "Shape",
			"group_property": "Shape", "option": pair[1], "material": "block", "height": 3,
			"icon": "build_wall", "group_icon": "build_wall"})
	view.ui.update_capabilities({"tools": tools, "sections": sections({})})
	view.ui.choose_family("Build")
	var group := find_button(view.ui.actions, "Shape")
	check(group != null and group.icon != null, "Build offers one Shape group with its icon")
	group.pressed.emit()
	check(view.tool == "shape:line" and view.ui.zone_options.visible and view.ui.zone_property.text == "Shape"
		and view.ui.zone_options.item_count == 3, "the Shape group picks its shape in the context panel")
	view.ui.zone_options.select(1); view.ui.zone_options.item_selected.emit(1)
	check(view.tool == "shape:wall", "choosing Wall sets the shape tool")
	view._close()

## The footer's View menu replaces the row of overlay toggles.
func view_menu(main: Node, client: Node) -> void:
	var view := open_view(main, client, {"sections": sections({})})
	var ui = view.ui
	var footer_buttons: Array = []
	for child in ui.footer.get_child(0).get_children():
		if child is Button and child.visible: footer_buttons.append(child.text)
	check(footer_buttons == ["View", "Legend"], "the footer holds one View menu and Legend, not a row of toggles: %s" % [footer_buttons])
	var popup: PopupMenu = ui.view_menu.get_popup()
	check(popup.item_count == 7 and popup.is_item_checkable(0) and popup.get_item_text(4) == "Wetness",
		"the View menu lists each overlay as a check item")
	ui.choose_view_item(3)
	check(view.shown_overlays.heat and popup.is_item_checked(3) and ui.view_menu.text == "View: Heat",
		"choosing an item switches its overlay on and names it on the button")
	ui.choose_view_item(4)
	check(view.shown_overlays.wet and ui.view_menu.text == "View (2)", "two overlays on show as a count")
	ui.choose_view_item(3); ui.choose_view_item(4)
	check(not view.shown_overlays.heat and ui.view_menu.text == "View", "choosing again switches it off")
	# The marks part's per-player setting answers once asked.
	check(popup.get_item_index(ui.MARKS_ITEM) == -1, "Marks is not offered before the server answers")
	view._receive({"v": 1, "t": "marks", "shown": true})
	var marks := popup.get_item_index(ui.MARKS_ITEM)
	check(marks >= 0 and popup.is_item_checked(marks), "the server's marks answer adds a checked Marks item")
	client.sent.clear()
	ui.choose_view_item(ui.MARKS_ITEM)
	check(client.sent.size() == 1 and client.sent[0].t == "marks" and client.sent[0].shown == false
		and not popup.is_item_checked(popup.get_item_index(ui.MARKS_ITEM)), "unchecking Marks tells the server to hide them")
	view._close()
	# A task view (DorfCraft task_tools.lua) offers only its own overlays.
	var scoped := open_view(main, client, {"sections": sections({}),
		"scope": {"task": "farming", "title": "Farming", "section": "Zones", "overlays": ["wet", "heat"]}})
	var spopup: PopupMenu = scoped.ui.view_menu.get_popup()
	check(scoped.ui.offered_overlays() == ["heat", "wet"] and spopup.item_count == 2
		and scoped.shown_overlays.wet and not scoped.shown_overlays.heat and scoped.ui.view_menu.text == "View: Wetness",
		"a task view's menu offers only its overlays, the first on")
	var bare := open_view(main, client, {"sections": sections({}),
		"scope": {"task": "felling", "title": "Felling", "section": "Gather", "overlays": []}})
	check(not bare.ui.view_menu.visible, "a task view with no overlays shows no empty View menu")
	# The night watch's dotted ring is explained, and left out of other tasks.
	var watched := {"rect": {"x0": 0, "x1": 2, "z0": 0, "z1": 0}, "cells": [2, 2, 2], "states": [2, 2, 2],
		"overlays": {"watch": [{"kind": "night", "x": 1, "z": 1, "ring": 1}],
			"stations": [{"squad": "*", "x": 1, "y": 0, "z": 0, "ring": 1}]}}
	check(scoped.drawn_zone_marks(watched).watch.is_empty() and scoped.drawn_zone_marks(watched).post.is_empty(),
		"a farming view leaves out the night watch and stations")
	var full := open_view(main, client, {"sections": sections({})})
	check(not full.drawn_zone_marks(watched).watch.is_empty() and not full.drawn_zone_marks(watched).post.is_empty(),
		"the full overseer draws them")
	var legend := find_button(full.ui.footer, "Legend")
	legend.pressed.emit()
	check(full.inspector.text.contains("night watch"), "the legend explains the night watch's small pale blue squares")
	full._close()
	scoped._close(); bare._close()

func plans_shape() -> Dictionary:
	return {"title": "Plans",
		"columns": [{"id": "plan", "label": "Plan", "kind": "text"}, {"id": "kind", "label": "Kind", "kind": "text"},
			{"id": "state", "label": "State", "kind": "text"}, {"id": "progress", "label": "Progress", "kind": "text"},
			{"id": "who", "label": "Asked by", "kind": "text"}, {"id": "level", "label": "Level", "kind": "number"},
			{"id": "where", "label": "Where", "kind": "text"}],
		"sort": {"column": "state", "order": "asc"}, "filters": [{"id": "kind", "label": "Kind", "options": ["Digging", "Officer's page"]}],
		"rows": [
			{"id": "o7", "cells": {"plan": "Excavation", "kind": "Digging", "state": "Working", "progress": "3 of 8",
				"who": "ana", "level": 0, "where": "4 north of the middle"}, "keys": {"state": 5, "progress": 0.375},
				"kind": "Digging", "pos": {"x": 1, "y": 0, "z": 4}, "detail": ["Asked by ana."],
				"actions": [{"id": "cancel", "label": "Cancel"}]},
			{"id": "page:p3", "cells": {"plan": "Nothing here can make stone.", "kind": "Officer's page", "state": "Danger",
				"who": "Ada, manager", "level": 0, "where": "Granary"}, "keys": {"state": 0}, "kind": "Officer's page",
				"pos": {"x": 3, "y": 0, "z": 3}, "page": true, "new": true, "detail": ["Not yet read."],
				"actions": [{"id": "act", "label": "Act", "primary": true}, {"id": "cancel", "label": "Drop"}]}],
		"empty": {"why": "No plans or pages yet.", "what": "Choose a tool under Plan."},
		"note": "Plans are work marked on the map and officers' pages."}

func plans(main: Node, client: Node) -> void:
	var view := open_view(main, client, {"sections": sections({})})
	var ui = view.ui
	ui.choose_family("Plans")
	check(client.sent[-1].t == "plans", "Plans asks the server")
	var list := [{"id": "o7", "kind": "dig", "title": "Excavation", "state": "Working", "done": 3, "total": 8}]
	view._receive({"v": 1, "t": "plans", "plans": list, "table": plans_shape()})
	check(ui.table_panel.visible and ui.table_kind == "plans" and not ui.plans.visible and not ui.panel.visible,
		"Plans is a table covering the map, without the older list")
	check(ui.table.shown_rows[0].id == "page:p3", "Plans opens danger first")
	var texts := ""
	for item in ui.table.tree.get_root().get_children():
		for i in 7: texts += item.get_text(i) + "|"
	check(not "o7" in texts and not "page:" in texts, "no plan id is shown in the table")
	client.sent.clear()
	ui.table.choose_index(0)
	check(ui.panel.visible and ui.title.text == "Nothing here can make stone." and ui.detail_actions.visible,
		"choosing a page shows its detail and actions in the context panel")
	check(client.sent.any(func(m: Dictionary) -> bool: return m.get("t") == "seen" and m.get("id") == "page:p3"),
		"choosing a new page marks it read")
	var labels: Array = []
	var accents := 0
	for b in ui.detail_actions.get_children():
		labels.append(b.text)
		if b.has_theme_stylebox_override("normal"): accents += 1
	if ui.detail_primary.visible and ui.detail_primary.has_theme_stylebox_override("normal"): accents += 1
	check(labels == ["Act", "Drop"] and ui.detail_primary.visible and accents == 1, "Act is the one accent; Drop and Show on map are quiet")
	client.sent.clear()
	ui.detail_actions.get_child(0).pressed.emit()
	check(client.sent.size() == 1 and client.sent[0].t == "act" and client.sent[0].id == "page:p3", "Act sends the page's id")
	view._receive({"v": 1, "t": "reply", "req": client.sent[0].req, "ok": true, "reason": "Acted on 1 request."})
	ui.table.choose_index(1)
	accents = 0
	if ui.detail_primary.has_theme_stylebox_override("normal"): accents += 1
	check(ui.detail_actions.get_child(0).text == "Cancel" and accents == 1, "a plan without a primary action keeps Show on map as the accent")
	client.sent.clear()
	ui.detail_actions.get_child(0).pressed.emit()
	check(client.sent.size() == 1 and client.sent[0].t == "cancel" and client.sent[0].id == "o7", "Cancel sends the plan's id")
	view._receive({"v": 1, "t": "reply", "req": client.sent[0].req, "ok": true, "reason": "Plan cancelled."})
	ui.detail_primary.pressed.emit()
	check(ui.family == "Select" and view.centre == Vector2(1, 4), "Show on map returns to the map at the plan")
	# The Progress verb opens Plans at its plan.
	ui.selected_id = "o7"
	ui.choose_family("Plans")
	view._receive({"v": 1, "t": "plans", "plans": list, "table": plans_shape()})
	check(ui.table.selected_id == "o7" and ui.panel.visible, "Progress opens Plans with its plan chosen")
	view.go_back()
	check(ui.table.selected_id == "" and ui.selected_id == "", "Back clears the chosen plan first")
	view._close()

func houses_table(main: Node, client: Node) -> void:
	var view := open_view(main, client, {"sections": sections({})})
	var tools: Array = view.tools.duplicate()
	tools.append({"id": "access:shared", "title": "Mark shared", "family": "House"})
	view.ui.update_capabilities({"tools": tools, "sections": sections({})})
	var ui = view.ui
	ui.choose_family("Houses")
	check(client.sent[-1].t == "houses" and not ui.table_panel.visible and ui.houses.root.visible,
		"Houses asks the server and says so until the page arrives")
	var page := {"t": "houses", "fid": "f1", "available": true, "owner": "ana", "open": false, "can_open": true,
		"manage_houses": true, "houses": [], "offices": [], "candidates": [], "offices_available": true,
		"panel": {"workers": [], "labours": [], "workshops": []},
		"table": {"title": "Houses",
			"columns": [{"id": "house", "label": "House", "kind": "text"}, {"id": "head", "label": "Head", "kind": "text"},
				{"id": "members", "label": "Players", "kind": "number"}, {"id": "workers", "label": "Workers", "kind": "number"},
				{"id": "colour", "label": "Colour", "kind": "swatch"}, {"id": "shared", "label": "Shared", "kind": "number"},
				{"id": "locked", "label": "Locked", "kind": "number"}],
			"sort": {"column": "house", "order": "asc"},
			"rows": [{"id": "h1", "cells": {"house": "Ironfoot (yours)", "head": "ana of house Ironfoot", "members": 1, "workers": 7,
					"colour": "Red", "shared": 0, "locked": 1}, "swatch": "#aa3322", "detail": ["Workers: Urist."]},
				{"id": "h2", "cells": {"house": "Stonehand", "head": "Bera of house Stonehand", "members": 1, "workers": 2,
					"colour": "Blue", "shared": 1, "locked": 2}, "swatch": "#2266aa", "detail": ["Workers: Kib."]}],
			"empty": {"why": "No houses yet.", "what": "Houses appear when another player joins this fortress."},
			"note": "A house is a player and the workers who came with them."}}
	view._receive({"v": 1, "t": "houses"}.merged(page))
	check(ui.table_panel.visible and ui.table_kind == "houses" and not ui.panel.visible and not ui.actions.visible,
		"Houses is a table covering the map, with no access tools beside it")
	var first: TreeItem = ui.table.tree.get_root().get_child(0)
	check(first.get_icon(4) != null and first.get_text(4) == "Red", "the colour column leads its name with a swatch")
	check(ui.houses_manage.visible and ui.houses_mark.visible, "Offices and workers and Mark access sit with the table's tools")
	ui.table.choose_index(1)
	check(ui.panel.visible and ui.title.text == "Stonehand" and ui.detail_body.text.contains("Locked: 2")
		and not ui.detail_primary.visible and not ui.houses.root.visible, "choosing a house shows its detail alone")
	ui.houses_manage.pressed.emit()
	check(not ui.table_panel.visible and ui.houses.root.visible and ui.houses_back.visible and not ui.actions.visible,
		"Offices and workers shows the owner's controls with a way back")
	view.go_back()
	check(ui.table_panel.visible and ui.houses_mode == "", "Back returns to the houses table")
	ui.houses_mark.pressed.emit()
	check(not ui.table_panel.visible and ui.actions.visible and find_button(ui.actions, "Mark shared") != null
		and not ui.houses.root.visible, "Mark access shows the access tools on the map")
	ui.houses_back.pressed.emit()
	check(ui.table_panel.visible, "Back to houses returns to the table")
	var empty: Dictionary = page.duplicate(true)
	empty.table.rows = []
	empty.v = 1
	view._receive(empty)
	check(ui.table.empty_box.visible and ui.table.empty_why.text == "No houses yet.", "an empty Houses table says why and what to do")
	view._close()

## The workshop picker: one task in the context panel (task 5).
func workshop_picker(main: Node, client: Node) -> void:
	var view := open_view(main, client, {"sections": sections({})})
	var ui = view.ui
	ui.choose_family("Build")
	view.choose_tool("workshop")
	view._update_materials([
		{"name": "forge", "title": "Smithing - Forge", "trade": "Smithing", "station": "Forge", "kind": "station", "missing": true,
			"reason": "Needs a Barrel in fortress stock.", "needs": [{"title": "Barrel", "count": 1, "ready": false}]},
		{"name": "table", "title": "Woodworking - Crafting table", "trade": "Woodworking", "station": "Crafting table", "kind": "station",
			"reason": "The equipment is in fortress stock.", "requirements": "Requires: 1 Crafting table (in stock)."}])
	ui.refresh()
	check(ui.table_kind == "workshops" and not ui.panel.visible, "while choosing, nothing else sits in a context panel")
	ui.table.choose_index(0)
	var shown: Array = []
	for child in ui.context.get_children():
		if child is Control and child.visible: shown.append(child)
	check(ui.panel.visible and not ui.actions.visible and not view.inspector.visible and shown.size() == 2
		and ui.detail.visible and ui.detail_primary.visible and ui.detail_primary.text == "Use this workshop",
		"a chosen workshop's panel holds its detail and one primary action only")
	ui.detail_primary.pressed.emit()
	check(not ui.table_panel.visible and not ui.actions.visible and ui.requirements.visible and ui.other_tools.visible,
		"after choosing, the panel is that workshop's; the Build tools are one press away, not beneath it")
	ui.other_tools.pressed.emit()
	check(view.tool == "inspect" and ui.actions.visible and find_button(ui.actions, "Build wall") != null,
		"Other Build tools returns to the Build tool list")
	view._close()

func run() -> void:
	root.size = Vector2i(1280, 720)
	var main := Unit.TestMain.new(); root.add_child(main)
	var client := Unit.TestClient.new(); main.add_child(client)
	var view := open_view(main, client, {"sections": sections({"houses": ["hidden", "Appears when a second player joins this fortress as a house."],
		"defence": ["locked", "Raise a militia first."]})})
	await rail(view)
	view._close()
	await houses_shown(main, client)
	shapes(main, client)
	view_menu(main, client)
	plans(main, client)
	houses_table(main, client)
	workshop_picker(main, client)
	print("Overseer screens: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
