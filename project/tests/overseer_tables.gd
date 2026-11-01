# SPDX-License-Identifier: LGPL-2.1-or-later
## Checks the overseer's table screens: People and Supplies covering the
## map, the chosen row's detail in the context panel, Show on map, Back, and
## the workshop picker with greyed workshops. Stand ins from tests/overseer.gd;
## no renderer, server or GPU:
## godot --headless --path project --script res://tests/overseer_tables.gd
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

func people_table() -> Dictionary:
	return {"title": "People",
		"columns": [{"id": "name", "label": "Name", "kind": "text"}, {"id": "labour", "label": "Labours", "kind": "text"},
			{"id": "doing", "label": "Doing", "kind": "text"}, {"id": "where", "label": "Where", "kind": "text"},
			{"id": "seen", "label": "Seen", "kind": "text"}],
		"sort": {"column": "doing", "order": "asc"},
		"filters": [{"id": "doing", "label": "Doing", "options": ["Digging", "Idle", "Not seen"]}],
		"rows": [
			{"id": "p1", "cells": {"name": "Ana", "labour": "Mining", "doing": "Digging", "where": "Level 0", "seen": "Now"},
				"keys": {"doing": "1Digging", "seen": 0}, "doing": "Digging", "pos": {"x": 4, "y": -2, "z": 7}, "detail": ["Labours: Mining"]},
			{"id": "p2", "cells": {"name": "Bo", "labour": "Hauling", "doing": "Idle", "where": "Bedroom 2", "seen": "Now"},
				"keys": {"doing": "0", "seen": 0}, "doing": "Idle", "pos": {"x": 1, "y": 0, "z": 1}},
			{"id": "p3", "cells": {"name": "Cy", "labour": "Farming", "doing": "Not seen", "where": "Not seen", "seen": "Not seen"},
				"keys": {"doing": "2", "seen": 1000000000}, "doing": "Not seen"}],
		"empty": {"why": "This fortress has no living workers.", "what": "Workers join as migrants arrive."},
		"note": "Labours are fortress records."}

func supplies_table(rows: Array) -> Dictionary:
	return {"title": "Supplies",
		"columns": [{"id": "item", "label": "Item", "kind": "text"}, {"id": "count", "label": "Count", "kind": "number"},
			{"id": "where", "label": "Where", "kind": "text"}, {"id": "kind", "label": "Kind", "kind": "text"}],
		"sort": {"column": "count", "order": "asc"}, "filters": [{"id": "kind", "label": "Kind", "options": ["Food", "Stone"]}],
		"rows": rows,
		"empty": {"why": "No stockpiles yet.", "what": "Mark a storage area under Zones; workers carry goods there."},
		"note": "Counts are what workers found in stockpiles."}

func button_texts(node: Node, out: Array) -> Array:
	if node is Button: out.append((node as Button).text)
	for child in node.get_children(): button_texts(child, out)
	return out

func run() -> void:
	var main := Unit.TestMain.new(); root.add_child(main)
	var client := Unit.TestClient.new(); main.add_child(client)
	var view := Overseer.new(); view.main = main; view.client = client; main.add_child(view)
	view._open()
	var tools := [{"id": "inspect", "title": "Inspect", "family": "Select"},
		{"id": "harvest", "title": "Harvest", "family": "Gather", "disabled": true, "reason": "No gathering authority"},
		{"id": "wall", "title": "Wall", "family": "Build", "material": "block"},
		{"id": "workshop", "title": "Set up workshop", "family": "Build", "material": "station", "width": 3, "depth": 3, "help": "Visit the ledger"}]
	view._receive({"v": 1, "t": "hello", "claim": {"min": {"x": -32, "y": -32, "z": -32}, "max": {"x": 32, "y": 32, "z": 32}},
		"y": 0, "body": {"x": 0, "y": 0, "z": 0}, "tools": tools})
	var ui = view.ui
	ui.choose_family("People")
	check(client.sent[-1].t == "overview", "People asks the server for its tables")
	view._receive({"v": 1, "t": "overview", "people": [], "supplies": [], "tables": {"people": people_table(),
		"supplies": supplies_table([])}})
	check(ui.table_panel.visible and ui.table_kind == "people", "People is a table covering the map")
	var shown_toggles := 0
	for child in ui.footer.get_child(0).get_children():
		if child is Button and child.visible: shown_toggles += 1
	check(shown_toggles == 0, "map overlay toggles are put away while a table covers the map")
	check(not ui.nav.visible and not ui.panel.visible and not ui.overview_text.visible, "the map's navigation and an empty context panel step aside")
	check(ui.table.shown_rows[0].cells.name == "Bo" and ui.table.shown_rows[-1].cells.name == "Cy", "People opens idle first and unseen last")
	ui.table.choose_index(1)
	check(ui.panel.visible and ui.detail.visible and ui.title.text == "Ana" and ui.detail_body.text.contains("Where: Level 0"),
		"choosing a row opens its detail in the context panel")
	check(ui.detail_primary.visible and ui.detail_primary.text == "Show on map", "a row with a place offers Show on map")
	check(ui.table_panel.offset_right <= ui.panel.offset_left, "the table makes room for the context panel")
	ui.table.choose_index(2)
	check(not ui.detail_primary.visible, "an unseen worker has nowhere to show")
	ui.table.choose_index(1)
	ui.detail_primary.pressed.emit()
	check(ui.family == "Select" and view.level == -2 and view.centre == Vector2(4, 7) and view.cursor.x == 4 and not ui.table_panel.visible,
		"Show on map returns to the map centred on the row's place")
	check(ui.nav.visible, "the map's navigation returns with the map")
	var toggles := 0
	for child in ui.footer.get_child(0).get_children():
		if child is Button and child.visible: toggles += 1
	check(toggles > 0 and ui.footer_hidden.is_empty(), "the overlay toggles come back with the map")
	ui.choose_family("Supplies")
	view._receive({"v": 1, "t": "overview", "tables": {"people": people_table(), "supplies": supplies_table([])}})
	check(ui.table.empty_box.visible and ui.table.empty_why.text == "No stockpiles yet." and ui.table.empty_what.text.contains("Zones"),
		"an empty Supplies table says why and what to do")
	view._receive({"v": 1, "t": "overview", "tables": {"supplies": supplies_table([
		{"id": "s1", "cells": {"item": "Cobblestone", "count": 35, "where": "Chest, level 0 and 1 more", "kind": "Stone"}, "kind": "Stone", "pos": {"x": 1, "y": 0, "z": 3}, "detail": ["30 in Chest, level 0", "5 in Barrel, level 0"]},
		{"id": "s2", "cells": {"item": "Bread", "count": 2, "where": "Granary", "kind": "Food"}, "kind": "Food"},
		{"id": "s3", "cells": {"item": "Iron pick", "count": 1, "where": "Forge", "kind": "Stone"}, "kind": "Stone", "state": "locked", "reason": "Held for the militia."}])}})
	check(ui.table.shown_rows[0].cells.item == "Iron pick" and ui.table.shown_rows[-1].cells.item == "Cobblestone", "Supplies opens lowest first")
	ui.table.choose_index(2)
	check(ui.detail_body.text.contains("30 in Chest, level 0") and ui.detail_body.text.contains("Count: 35"), "the detail lists each place")
	view.go_back()
	check(ui.family == "Supplies" and ui.table.selected_id == "" and not ui.panel.visible, "Back clears the chosen row first")
	ui.table.choose_index(0)
	check(ui.detail_reason.visible and ui.detail_reason.text == "Held for the militia." and not ui.detail_primary.visible,
		"a locked row shows its reason and offers nothing")
	var level: int = view.level
	var page := InputEventKey.new(); page.pressed = true; page.keycode = KEY_PAGEDOWN
	view._input(page)
	check(view.level == level, "Page Down on a table does not change the map level")
	view.go_back(); view.go_back()
	check(ui.family == "Select", "Back again leaves the table")
	# An older server sends lists without tables: the side panel stays.
	ui.choose_family("People")
	view._receive({"v": 1, "t": "overview", "people": [{"name": "Ada", "assignment": "Farmer", "activity": "Walking", "observed": "Now"}]})
	check(not ui.table_panel.visible and ui.overview_text.visible and ui.overview_text.text.contains("Ada"), "an older server's lists stay in the side panel")
	# The workshop picker.
	ui.choose_family("Build")
	view.choose_tool("workshop")
	view._update_materials([
		{"name": "forge", "title": "Smithing - Forge", "trade": "Smithing", "station": "Forge", "kind": "station", "missing": true,
			"reason": "Needs a Barrel in fortress stock.", "requirements": "Requires: 1 Forge (in stock), 1 Barrel (needed).",
			"needs": [{"title": "Forge", "count": 1, "ready": true}, {"title": "Barrel", "count": 1, "ready": false}]},
		{"name": "table", "title": "Woodworking - Crafting table", "trade": "Woodworking", "station": "Crafting table", "kind": "station",
			"reason": "The equipment is in fortress stock.", "requirements": "Requires: 1 Crafting table (in stock)."}])
	ui.refresh()
	check(ui.table_kind == "workshops" and ui.table_panel.visible and not view.build_material.visible, "Set up workshop opens the picker table, not a dropdown")
	check(not ui.panel.visible and not ui.actions.visible, "the picker covers the map alone; the Build tools are not beside it")
	check(ui.table.shown_rows[0].cells.workshop == "Woodworking" and ui.table.row_locked(ui.table.shown_rows[1]), "ready workshops come first; the rest are greyed")
	var locked_item: TreeItem = ui.table.tree.get_root().get_child(1)
	check(locked_item.get_tooltip_text(0) == "Needs a Barrel in fortress stock.", "a greyed workshop says what it needs on hover")
	ui.table.choose_index(1)
	check(ui.detail_reason.text == "Needs a Barrel in fortress stock." and not ui.detail_primary.visible and ui.detail_body.text.contains("1 Barrel: needed"),
		"choosing a greyed workshop shows what is missing and offers nothing")
	check(view.build_material.selected == -1, "a greyed workshop is never chosen")
	ui.table.choose_index(0)
	check(ui.detail_primary.visible and ui.detail_primary.text == "Use this workshop", "a ready workshop offers Use this workshop")
	ui.detail_primary.pressed.emit()
	check(view.build_material.selected == 1 and not ui.table_panel.visible and ui.change_workshop.visible, "using a workshop returns to the map with it chosen")
	check(ui.requirements.visible and ui.requirements.text.begins_with("Woodworking - Crafting table") and ui.requirements.text.count("Requires") == 1,
		"the chosen workshop's detail shows once in the context panel")
	ui.change_workshop.pressed.emit()
	check(ui.table_panel.visible and ui.table_kind == "workshops", "Change workshop reopens the picker")
	ui.table.choose_index(0); ui.table.row_activated.emit(ui.table.selected_row())
	check(not ui.table_panel.visible and view.build_material.selected == 1, "Enter on a ready workshop uses it")
	view.level = 0
	view.select_cell({"x": 0, "y": 0, "z": 0}); view.select_cell({"x": 2, "y": 0, "z": 2})
	check(view.can_submit(), "a chosen workshop and a 3 by 3 site can submit")
	ui.choose_family("Gather")
	var texts := button_texts(view.root_control, [])
	var labelled := false
	for t in texts: if "(unavailable)" in str(t): labelled = true
	check(not labelled, "no control is labelled (unavailable)")
	for child in ui.actions.get_children():
		if child is Button and child.get_meta("tool", "") == "harvest":
			check(child.get_theme_color("font_color") == ui.QUIET and child.tooltip_text == "No gathering authority", "an unavailable tool is greyed with its reason")
	# Stations of one trade group under it (Armoury: a smithing table and
	# an anvil); Use this workshop on the trade takes its first ready one.
	var stations := [
		{"id": "w0", "index": 0, "cells": {"workshop": "Armoury", "station": "Smithing table", "equipment": "Needed"}, "state": "locked"},
		{"id": "w1", "index": 1, "cells": {"workshop": "Armoury", "station": "Anvil", "equipment": "In stock"}, "state": "shown"},
		{"id": "w2", "index": 2, "cells": {"workshop": "Brewing", "station": "Still", "equipment": "In stock"}, "state": "shown"}]
	var groups: Array = ui.workshop_groups(stations)
	check(groups.size() == 1 and groups[0].label == "Armoury" and groups[0].rows == ["w0", "w1"] and int(groups[0].index) == 1
		and groups[0].cells.equipment == "1 in stock" and groups[0].state == "shown",
		"stations of one trade group under it, ready when any is, using the first ready")
	print("Overseer tables: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)
