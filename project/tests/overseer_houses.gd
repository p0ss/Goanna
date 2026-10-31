# SPDX-License-Identifier: LGPL-2.1-or-later
## Houses in the overseer view: the layer's `houses` table, housed rooms,
## zones, locks, stations and orders filled in the house's pattern and
## colour, the `access` overlay, and the house named in Inspect and Plans.
## Older servers send none of it. Headless, without a renderer or server:
## godot --headless --path project --script res://tests/overseer_houses.gd
extends SceneTree
const Unit := preload("res://tests/overseer.gd")
const Overseer := preload("res://game/overseer.gd")
var failures := 0
var checks := 0

func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(text)
	print("PASS " if ok else "FAIL ", text)

func _initialize() -> void:
	call_deferred("run")

func sheets_with(view: Node, shader: Shader) -> Array:
	var out: Array = []
	for child in view.overlay_sheets.get_children():
		var material: Variant = child.multimesh.mesh.material
		if material is ShaderMaterial and material.shader == shader:
			out.append(material)
	return out

func run() -> void:
	# Known cells x 0 to 5 on row z 0; x 6 is unexplored.
	var layer := {"v": 1, "t": "layer", "seq": 0, "rev": 1, "y": 0,
		"rect": {"x0": 0, "x1": 6, "z0": 0, "z1": 0},
		"cells": [2, 2, 2, 2, 2, 2, 0], "floors": [0, 0, 0, 0, 0, 0, 0], "dates": [1, 1, 1, 1, 1, 1, -1],
		"palette": [{"name": "stone", "texture": "stone.png"}], "orders": []}
	check(Overseer.house_table(layer).is_empty() and Overseer.house_cells(layer).is_empty()
		and Overseer.access_marks(layer) == {"shared": {}, "locked": {}},
		"a layer from an older server has no houses, fills or access marks")
	var housed := layer.duplicate(true)
	housed.houses = {"1": {"surname": "Stonehelm", "head": "owner", "colour": "#204060", "pattern": "chequy", "owner": true},
		"2": {"surname": "Brightvein", "head": "alice", "colour": "#c03020", "pattern": "lozengy"},
		"3": {"surname": "Oddfield", "head": "bob", "colour": "#30a050", "pattern": "plaid"},
		"4": {"surname": "Broken", "head": "eve", "colour": "red", "pattern": "paly"}}
	var houses := Overseer.house_table(housed)
	check(houses.size() == 3 and not houses.has("4") and houses["2"].colour == Color.html("#c03020")
		and houses["1"].owner and not houses["2"].owner, "houses are read by id; a malformed colour drops its record")
	check(Overseer.house_table({"houses": [{"surname": "A", "colour": "#010203"}, {"surname": "B", "colour": "#040506"}]}).keys() == ["1", "2"],
		"a Lua list of houses (ids 1 to n) is read by position")
	check(Overseer.house_pattern("lozengy") == 2 and Overseer.house_pattern("gyronny") == 8
		and Overseer.house_pattern("semy") == 10 and Overseer.house_pattern("plaid") == 0 and Overseer.house_pattern("") == 0,
		"known field patterns have a shader index; unknown ids fall back to the hatch")
	check(Overseer.house_name(houses, 2.0) == "House Brightvein" and Overseer.house_name(houses, "2") == "House Brightvein"
		and Overseer.house_name(houses, 9) == "" and Overseer.house_name(houses, null) == "",
		"a house id may be a number or a string; unknown ids name nothing")
	housed.overlays = {
		"rooms": [{"rect": {"x0": 0, "x1": 1, "z0": 0, "z1": 0}, "title": "Bedroom", "name": "Ada", "house": 2},
			{"rect": {"x0": 4, "x1": 9, "z0": 0, "z1": 0}, "title": "Hall", "name": "Great", "house": 1},
			{"rect": {"x0": 5, "x1": 6, "z0": 0, "z1": 0}, "title": "Store", "name": "Odd", "house": 3}],
		"zones": [{"id": "z1", "kind": "forbid", "rect": {"x0": 2, "x1": 2, "z0": 0, "z1": 0}, "house": "2"},
			{"id": "z2", "kind": "forbid", "rect": {"x0": 3, "x1": 3, "z0": 0, "z1": 0}}],
		"locks": [{"x": 1, "z": 0, "house": 2}, {"x": 6, "z": 0, "house": 2}],
		"stations": [{"squad": "*", "x": 3, "y": 0, "z": 0, "ring": 1, "house": 9}],
		"access": [{"pos": {"x": 0, "y": 0, "z": 0}, "state": "shared", "house": 2},
			{"pos": {"x": 1, "y": 0, "z": 0}, "state": "locked", "house": 2},
			{"pos": {"x": 5, "y": 0, "z": 0}, "state": "locked", "house": 3},
			{"pos": {"x": 2, "y": 0, "z": 0}, "state": "locked", "house": 7},
			{"pos": {"x": 3, "y": 1, "z": 0}, "state": "shared", "house": 2},
			{"pos": {"x": 6, "y": 0, "z": 0}, "state": "shared", "house": 2},
			{"pos": {"x": 4, "y": 0, "z": 0}, "state": "open", "house": 2}, null, "junk"]}
	housed.orders = [{"pos": {"x": 3, "y": 0, "z": 0}, "kind": "dig", "state": "accepted", "house": 2},
		{"pos": {"x": 4, "y": 0, "z": 0}, "kind": "dig", "state": "accepted"},
		{"pos": {"x": 4, "y": 1, "z": 0}, "kind": "dig", "state": "accepted", "house": 3}]
	var fills := Overseer.house_cells(housed)
	var mine: Array = fills.get("2", [])
	mine.sort()
	check(mine == [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)],
		"a house's room, zone, lock and order fill its known cells once each")
	check(fills.get("3") == [Vector2i(5, 0)], "an unknown pattern still fills, clipped to known cells")
	check(not fills.has("1") and not fills.has("9") and fills.size() == 2,
		"the owner's house, unhoused entries and unknown house ids are drawn as before")
	var access := Overseer.access_marks(housed)
	check(access.shared == {"2": [Vector2i(0, 0)]} and access.locked.get("2") == [Vector2i(1, 0)]
		and access.locked.get("3") == [Vector2i(5, 0)] and access.locked.get("") == [Vector2i(2, 0)],
		"access marks keep this level's known cells, by state and house; an unknown house keys as none")
	# Drawing: fills always, access marks only with the toggle.
	var main := Unit.TestMain.new(); root.add_child(main)
	var client := Unit.TestClient.new(); main.add_child(client)
	var view := Overseer.new(); view.main = main; view.client = client; main.add_child(view)
	view._open()
	view.snapshot = layer
	view._draw_overlays()
	check(view.overlay_sheets.get_child_count() == 0 and view.house_shader == null,
		"an older server's layer draws no house sheets")
	view.snapshot = housed
	view._draw_overlays()
	var fill_sheets := sheets_with(view, view.house_shader)
	check(fill_sheets.size() == 2, "one patterned fill sheet per house in view")
	var patterns := {}
	for m in fill_sheets: patterns[m.get_shader_parameter("pattern")] = m.get_shader_parameter("ink")
	check(patterns.get(2) == Color.html("#c03020") and patterns.get(0) == Color.html("#30a050"),
		"each fill carries its house's colour and pattern index")
	check(view.access_shader == null, "access marks wait for their toggle")
	view.toggle_overlay("access")
	var marks := sheets_with(view, view.access_shader)
	var locked := marks.filter(func(m: ShaderMaterial) -> bool: return m.get_shader_parameter("locked"))
	check(marks.size() == 4 and locked.size() == 3, "the Access toggle draws shared and locked marks per house")
	var unknown := locked.filter(func(m: ShaderMaterial) -> bool:
		return Color(m.get_shader_parameter("ink"), 1.0) == Overseer.ACCESS_UNKNOWN_HOUSE)
	check(unknown.size() == 1, "a mark of an unknown house is drawn in a neutral colour")
	view.toggle_overlay("access")
	check(sheets_with(view, view.access_shader).is_empty(), "the Access toggle hides the marks again")
	# Ownership: access mark, then room, then plan or designation; the
	# owner's house counts; unknown cells and unknown houses stay clear.
	var held := Overseer.ownership_field(housed)
	check(Array(held.owners) == ["2", "2", "2", "2", "1", "3", ""] and Array(held.rank) == [3, 3, 1, 1, 2, 3, 0],
		"each cell is held by its access mark, else its room, else its plan or zone")
	check(Overseer.ownership_field(layer).is_empty(), "an older server's layer has no ownership field")
	view.toggle_overlay("ownership")
	var field_sheets := sheets_with(view, view.ownership_shader)
	check(field_sheets.size() == 1 and sheets_with(view, view.house_shader).is_empty(),
		"the Houses toggle draws one field sheet in place of the patterned fills")
	var flags: Image = field_sheets[0].get_shader_parameter("flags").get_image()
	var colours: Image = field_sheets[0].get_shader_parameter("owners").get_image()
	check(flags.get_pixel(4, 0).g > 0.99 and flags.get_pixel(0, 0).g < 0.01 and flags.get_pixel(6, 0).r < 0.01,
		"the owner's house is flagged apart, and an unheld cell is clear")
	check(colours.get_pixel(6, 0).is_equal_approx(Color.html("#30a050")),
		"an empty neighbour takes the house colour so the edge fades without darkening")
	view.toggle_overlay("ownership")
	check(sheets_with(view, view.house_shader).size() == 2, "the patterned fills return with the Houses toggle off")
	check(Overseer.overlay_notes(housed, {"x": 4, "y": 0, "z": 0}).contains("Held by House Stonehelm (its room)")
		and Overseer.overlay_notes(housed, {"x": 0, "y": 0, "z": 0}).contains("Held by House Brightvein (its access mark)"),
		"Inspect says which house holds a cell, and why")
	# Inspect and Plans name the house where the author or entry shows.
	var notes := Overseer.overlay_notes(housed, {"x": 0, "y": 0, "z": 0})
	check(notes.contains("Bedroom \"Ada\" (House Brightvein)") and notes.contains("Shared by House Brightvein"),
		"Inspect names a room's house and a shared mark")
	notes = Overseer.overlay_notes(housed, {"x": 1, "y": 0, "z": 0})
	check(notes.contains("Locked door (House Brightvein)") and notes.contains("Locked: only House Brightvein may use it"),
		"Inspect names a lock's house and a locked mark")
	check(Overseer.overlay_notes(housed, {"x": 2, "y": 0, "z": 0}).contains("Forbidden area (House Brightvein)")
		and Overseer.overlay_notes(housed, {"x": 3, "y": 0, "z": 0}).contains("Forbidden area: workers")
		and not Overseer.overlay_notes(housed, {"x": 3, "y": 0, "z": 0}).contains("Shared"),
		"Inspect names a zone's house, leaves an unhoused one alone, and ignores marks on other levels")
	check(Overseer.overlay_notes(housed, {"x": 6, "y": 0, "z": 0}).find("Shared") < 0,
		"Inspect reveals no access mark on an unexplored cell")
	view.snapshot = housed
	view.ui.update_plans([{"id": "o1", "kind": "dig", "title": "Excavation", "by": "alice", "house": 2, "state": "Queued",
		"total": 1, "done": 0, "can_cancel": true, "pos": {"x": 3, "y": 0, "z": 0}},
		{"id": "o2", "kind": "dig", "title": "Excavation", "by": "owner", "state": "Queued",
		"total": 1, "done": 0, "can_cancel": true, "pos": {"x": 4, "y": 0, "z": 0}}])
	view.ui.select_plan(0)
	check(view.ui.plan_detail.text.contains("Issued by alice (House Brightvein)"), "Plans names the author's house")
	view.ui.select_plan(1)
	check(view.ui.plan_detail.text.contains("Issued by owner\n"), "an unhoused plan's author reads as before")
	view.free()
	main.queue_free()
	print("Overseer houses: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
