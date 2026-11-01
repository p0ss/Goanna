# SPDX-License-Identifier: LGPL-2.1-or-later
## Structural checks for the shared table widget (ui/data_table.gd): the
## opening sort, heading sorts, search, filters, locked rows, empty states,
## keyboard choice and typing into search. No renderer, server or GPU:
## godot --headless --path project --script res://tests/data_table.gd
extends SceneTree
const DataTable := preload("res://ui/data_table.gd")
var failures := 0
var checks := 0
func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok: failures += 1
	print("PASS " if ok else "FAIL ", text)
func _initialize() -> void:
	call_deferred("run")

func supplies() -> Dictionary:
	return {"title": "Supplies",
		"columns": [{"id": "item", "label": "Item", "kind": "text"},
			{"id": "count", "label": "Count", "kind": "number"},
			{"id": "where", "label": "Where", "kind": "text"}],
		"sort": {"column": "count", "order": "asc"},
		"filters": [{"id": "kind", "label": "Kind", "options": ["Food", "Wood"]}],
		"rows": [
			{"id": "r1", "cells": {"item": "Rye", "count": 12, "where": "Granary"}, "kind": "Food", "pos": {"x": 1, "y": 0, "z": 2}},
			{"id": "r2", "cells": {"item": "Oak planks", "count": 3, "where": "Yard"}, "kind": "Wood"},
			{"id": "r3", "cells": {"item": "Apple", "where": "Granary"}, "kind": "Food"},
			{"id": "r4", "cells": {"item": "Bread", "count": 3.0, "where": "Granary"}, "kind": "Food", "keys": {"count": 0}},
			{"id": "r5", "cells": {"item": "Iron pick", "count": 1, "where": "Forge"}, "kind": "Wood", "state": "locked", "reason": "Needs a smith."}],
		"empty": {"why": "Nothing is stored yet.", "what": "Mark a stockpile area under Zones."},
		"note": "Counts are what workers have seen in stockpiles."}

## Supplies grouped as the server sends it: three planks under one group,
## two wools under another, cobble alone (DorfCraft overseer/groups.lua).
func grouped_supplies() -> Dictionary:
	var row := func(id: String, item: String, count: int, group: String, where := "Yard") -> Dictionary:
		var r := {"id": id, "cells": {"item": item, "count": count, "where": where}, "kind": "Wood"}
		if not group.is_empty(): r["group"] = {"id": group, "label": group.capitalize()}
		return r
	return {"title": "Grouped supplies", "grouped": true,
		"columns": [{"id": "item", "label": "Item", "kind": "text", "wide": true},
			{"id": "count", "label": "Count", "kind": "number", "total": "sum"},
			{"id": "where", "label": "Where", "kind": "text", "total": "same"}],
		"sort": {"column": "count", "order": "asc"},
		"filters": [{"id": "kind", "label": "Kind", "options": ["Wood"]}],
		"rows": [row.call("a", "Oak Planks", 40, "planks"), row.call("b", "Birch Planks", 12, "planks"),
			row.call("c", "Acacia Planks", 6, "planks", "Chest"), row.call("d", "Cobblestone", 20, ""),
			row.call("e", "White Wool", 6, "wool"), row.call("f", "Red Wool", 3, "wool")],
		"groups": [
			{"id": "group:planks", "label": "Planks", "kinds": 3, "rows": ["a", "b", "c"], "kind": "Wood",
				"cells": {"item": "Planks", "count": 58}, "pos": {"x": 1, "y": 0, "z": 1},
				"detail": ["40 Oak Planks: 40 in Yard."]},
			{"id": "group:wool", "label": "Wool", "kinds": 2, "rows": ["e", "f"], "kind": "Wood",
				"cells": {"item": "Wool", "count": 9, "where": "Yard"}, "state": "locked", "reason": "Needs a loom."}]}

func grouped(t) -> void:
	var chosen: Array = []
	var activated: Array = []
	t.row_chosen.connect(func(r: Dictionary) -> void: chosen.append(r))
	t.row_activated.connect(func(r: Dictionary) -> void: activated.append(r))
	t.set_table(grouped_supplies())
	var root_item: TreeItem = t.tree.get_root()
	check(names(t) == ["Wool", "Cobblestone", "Planks"], "groups sort among plain rows by their totals: %s" % [names(t)])
	var planks: TreeItem = root_item.get_child(2)
	check(planks.get_child_count() == 3 and planks.collapsed and planks.get_text(0) == "Planks"
		and planks.get_suffix(0) == "(3 kinds)" and planks.get_text(1) == "58", "a group row shows its label, kinds and total, closed")
	check(planks.get_child(0).get_text(0) == "Acacia Planks" and planks.get_child(2).get_text(0) == "Oak Planks",
		"a group's rows sort the same way beneath it")
	check(root_item.get_child(0).get_custom_color(0) == DataTable.GREY, "a locked group is greyed")
	t.choose_index(2)
	check(chosen[-1].get("group_row", false) and t.selected_row().get("detail", [])[0].begins_with("40 Oak"),
		"choosing a group gives the group, with its detail")
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_RIGHT
	t._tree_input(key)
	check(not planks.collapsed and t.open_groups.has("group:planks"), "the right arrow opens the chosen group")
	t.set_table(grouped_supplies().merged({"note": "Refreshed."}))
	planks = t.tree.get_root().get_child(2)
	check(not planks.collapsed, "an opened group stays open across a refresh")
	planks.get_child(1).select(0)
	key.keycode = KEY_LEFT
	t._tree_input(key)
	planks = t.tree.get_root().get_child(2)
	check(planks.collapsed and t.selected_row().get("id") == "group:planks", "the left arrow on a row closes its group and chooses it")
	t._on_activated()
	check(not planks.collapsed and activated.is_empty(), "Enter opens a group and activates nothing")
	t._on_activated()
	check(planks.collapsed, "Enter again closes it")
	t.search.text = "birch"
	t._refresh_rows()
	check(names(t) == ["Birch Planks"] and t.tree.get_root().get_child(0).get_child_count() == 0,
		"a search leaving one row of a group shows it as its plain row")
	t.search.text = "planks"
	t._refresh_rows()
	planks = t.tree.get_root().get_child(0)
	check(names(t) == ["Planks"] and not planks.collapsed and planks.get_child_count() == 3,
		"a search opens the groups it leaves, and the group's own label matches")
	t.search.text = "wool"
	t._refresh_rows()
	check(names(t) == ["Wool"] and t.tree.get_root().get_child(0).get_child_count() == 2, "a search finds a group by its rows")
	t.search.text = ""
	t._refresh_rows()
	t.choose_id("b")
	check(t.selected_row().get("id") == "b" and not t.tree.get_root().get_child(2).collapsed,
		"choosing a row in a closed group opens it")
	t.clear_choice()

func names(t) -> Array:
	var out := []
	for r in t.shown_rows: out.append(r.cells.item)
	return out

func run() -> void:
	var window := root
	var t := DataTable.new()
	t.size = Vector2(900, 500)
	window.add_child(t)
	var chosen: Array = []
	var activated: Array = []
	t.row_chosen.connect(func(r: Dictionary) -> void: chosen.append(r))
	t.row_activated.connect(func(r: Dictionary) -> void: activated.append(r))
	t.set_table(supplies())
	check(names(t) == ["Bread", "Iron pick", "Oak planks", "Rye", "Apple"], "opening sort uses keys, ties by first column, missing last: %s" % [names(t)])
	check(t.tree.get_column_title(1).begins_with("Count") and t.tree.get_column_title(1) != "Count", "the sorted heading shows its direction")
	check(t.tree.get_column_title(0) == "Item", "other headings stay plain")
	var root_item := t.tree.get_root()
	check(root_item.get_child(0).get_text_alignment(1) == HORIZONTAL_ALIGNMENT_RIGHT, "number columns are right aligned")
	check(root_item.get_child(0).get_text(1) == "3", "whole floats show as integers")
	var locked := root_item.get_child(1)
	check(locked.get_custom_color(0) == DataTable.GREY and locked.get_tooltip_text(0) == "Needs a smith.", "locked rows are greyed with the reason on hover")
	t.sort_by_index(1)
	check(names(t)[0] == "Rye" and names(t)[-1] == "Apple", "clicking the sorted heading reverses it, missing still last")
	t.sort_by_index(0)
	check(names(t)[0] == "Apple" and t.sort_order == "asc", "clicking another heading sorts by it")
	t.search.text = "GRAN"
	t.search.text_changed.emit(t.search.text)
	check(names(t) == ["Apple", "Bread", "Rye"], "search matches any cell, ignoring case")
	var kind: OptionButton = t.filters.get_child(1)
	kind.select(2); kind.item_selected.emit(2)
	check(names(t).is_empty() and t.empty_box.visible and not t.tree.visible and t.empty_why.text == "No rows match." and t.empty_clear.visible,
		"search and filter combine, and an empty result says so with one action")
	t.empty_clear.pressed.emit()
	check(names(t).size() == 5 and t.search.text == "" and (t.filters.get_child(1) as OptionButton).selected == 0, "the empty action clears search and filters")
	t.choose_index(3)
	check(chosen.size() == 1 and chosen[-1].id == "r2", "choosing a row emits it: %s" % [chosen.map(func(r): return r.id)])
	var refreshed := supplies()
	refreshed.rows[1].cells.count = 9
	t.set_table(refreshed)
	check(t.sort_column == "item" and t.selected_row().get("id") == "r2" and t.tree.get_selected() != null, "a refresh of the same table keeps the sort and the choice")
	t.tree.item_activated.emit()
	check(activated.size() == 1 and activated[0].id == "r2", "Enter or a double click activates the chosen row")
	t.tree.grab_focus()
	var key := InputEventKey.new()
	key.pressed = true; key.keycode = KEY_O; key.unicode = "o".unicode_at(0)
	t.tree.gui_input.emit(key)
	check(t.search.text == "o" and t.search.has_focus(), "typing on the rows goes to the search box")
	t.search.text = ""; t.search.text_changed.emit("")
	var down := InputEventKey.new()
	down.pressed = true; down.keycode = KEY_DOWN
	t.search.gui_input.emit(down)
	check(t.tree.has_focus(), "down from the search box moves to the rows")
	var empty := supplies()
	empty.rows = []
	empty.title = "Other"
	t.set_table(empty)
	check(t.empty_box.visible and t.empty_why.text == "Nothing is stored yet." and t.empty_what.text == "Mark a stockpile area under Zones." and not t.empty_clear.visible,
		"an empty table shows the server's why and what")
	check(t.sort_column == "count" and t.selected_id == "", "another table starts from its own opening sort")
	check(t.note.visible and t.note.text.begins_with("Counts"), "the note shows under the table")
	grouped(t)
	var bare := {"title": "Bare", "columns": [{"id": "a", "label": "A"}], "rows": [{"id": "x", "cells": {"a": "One"}}]}
	t.set_table(bare)
	check(t.filters.get_child_count() == 0 and not t.note.visible and t.shown_rows.size() == 1, "a table without filters, sort or note draws")
	var plans := {"title": "Plans", "columns": [{"id": "plan", "label": "Plan", "wide": true},
		{"id": "state", "label": "State"}, {"id": "where", "label": "Where"}],
		"rows": [{"id": "p1", "cells": {"plan": "Raiders were seen at the east gate.", "state": "Danger", "where": "12 east, level 10"}}]}
	t.set_table(plans)
	check(t.tree.is_column_expanding(0) and not t.tree.is_column_expanding(1) and not t.tree.is_column_expanding(2),
		"a wide column takes the spare width; the others are fitted")
	var odd := {"title": "Odd", "columns": "nope", "rows": [1, "x", {"cells": 3}]}
	t.set_table(odd)
	check(t.shown_rows.is_empty() and t.empty_box.visible, "a malformed table draws an empty state, not an error")
	print("Data table: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)
