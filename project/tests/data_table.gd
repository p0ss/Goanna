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
	var bare := {"title": "Bare", "columns": [{"id": "a", "label": "A"}], "rows": [{"id": "x", "cells": {"a": "One"}}]}
	t.set_table(bare)
	check(t.filters.get_child_count() == 0 and not t.note.visible and t.shown_rows.size() == 1, "a table without filters, sort or note draws")
	var odd := {"title": "Odd", "columns": "nope", "rows": [1, "x", {"cells": 3}]}
	t.set_table(odd)
	check(t.shown_rows.is_empty() and t.empty_box.visible, "a malformed table draws an empty state, not an error")
	print("Data table: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)
