# SPDX-License-Identifier: LGPL-2.1-or-later
## Checks noun-first selection: Select asks the server what a selection is,
## the verb strip draws only its answer, and a verb becomes the existing
## tool and draft. Uses the stand ins from tests/overseer.gd. No renderer,
## server or GPU:
## godot --headless --path project --script res://tests/overseer_verbs.gd
extends SceneTree
const Unit := preload("res://tests/overseer.gd")
const Overseer := preload("res://game/overseer.gd")
const OverseerUI := preload("res://game/overseer_ui.gd")
var failures := 0
var checks := 0
func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok: failures += 1
	print("PASS " if ok else "FAIL ", text)
func _initialize() -> void:
	call_deferred("run")
func key(code: Key, shift := false) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code; event.pressed = true; event.shift_pressed = shift
	return event
# Sent messages pass through JSON, so their numbers come back as floats.
func at(p: Variant, x: int, y: int, z: int) -> bool:
	return p is Dictionary and int(p.get("x", 1e9)) == x and int(p.get("y", 1e9)) == y and int(p.get("z", 1e9)) == z
func last_sent(client: Node, type: String) -> Dictionary:
	for i in range(client.sent.size() - 1, -1, -1):
		if client.sent[i].get("t") == type: return client.sent[i]
	return {}
func run() -> void:
	var main := Unit.TestMain.new(); root.add_child(main)
	var client := Unit.TestClient.new(); main.add_child(client)
	var view := Overseer.new(); view.main = main; view.client = client; main.add_child(view)
	view._open()
	var tools := [{"id":"inspect", "title":"Inspect", "family":"Select"},
		{"id":"chop", "title":"Fell trees in area", "family":"Gather"},
		{"id":"stockpile_area", "title":"Hauling stockpile", "family":"Zones", "group":"Storage", "group_property":"Storage type", "option":"General hauling"},
		{"id":"refuse_area", "title":"Refuse stockpile", "family":"Zones", "group":"Storage", "group_property":"Storage type", "option":"Refuse"},
		{"id":"floor", "title":"Replace floor below", "family":"Build", "material":"block", "disabled":true, "reason":"Building requires the manage right."},
		{"id":"cancel", "title":"Cancel", "family":"Plans"}]
	view._receive({"v":1,"t":"hello","claim":{"min":{"x":-32,"y":-32,"z":-32},"max":{"x":32,"y":32,"z":32}},
		"y":0,"body":{"x":0,"y":0,"z":0},"tools":tools})
	view.select_cell({"x":2,"y":0,"z":3})
	var ask := last_sent(client, "affordances")
	check(at(ask.get("a"), 2, 0, 3) and at(ask.get("b"), 2, 0, 3) and str(ask.get("req", "")).begins_with("verbs:"),
		"Select asks the server about the selected cell")
	check(view.ui.verb_strip.visible and view.ui.verb_heading.text.begins_with("Asking"),
		"the strip waits for the server instead of guessing")
	var before := client.sent.size()
	view._receive({"v":1,"t":"affordances","req":"verbs:old","ok":true,"nouns":[{"kind":"tree","count":1}],
		"verbs":[{"id":"chop","tool":"chop","label":"Fell"}]})
	check(view.verbs.is_empty(), "an answer to an older selection is ignored")
	view._receive({"v":1,"t":"affordances","req":ask.req,"ok":true,"nouns":[{"kind":"tree","count":1}],
		"verbs":[{"id":"chop","tool":"chop","label":"Fell","icon":"chop"},{"id":"smuggle","tool":"smuggle","label":"Hidden"}]})
	check(view.verbs.size() == 1 and view.ui.first_verb() != null and view.ui.first_verb().text == "1  Fell",
		"the strip shows server verbs for known tools only, numbered")
	check(view.ui.first_verb().icon == OverseerUI.icon_for("chop") and view.ui.first_verb().icon != null,
		"a verb draws the icon the server names")
	check(OverseerUI.icon_for("no_such_icon") == null and OverseerUI.icon_for("../icon") == null and OverseerUI.icon_for(3) == null,
		"an unknown or malformed icon name draws nothing")
	var unreadable: Array = []
	for file in DirAccess.get_files_at(OverseerUI.ICONS):
		if file.ends_with(".svg") and OverseerUI.icon_for(file.get_basename()) == null: unreadable.append(file)
	check(DirAccess.get_files_at(OverseerUI.ICONS).size() > 20 and unreadable.is_empty(), "every verb icon loads %s" % [unreadable])
	view._input(key(KEY_1))
	check(view.tool == "chop" and view.ui.family == "Gather" and view.first_corner == {"x":2,"y":0,"z":3}
		and view.last_corner == view.first_corner and view.can_submit(),
		"pressing 1 prefills the existing Fell tool and draft from the selection")
	check(client.sent.size() == before and not view.ui.verb_strip.visible,
		"choosing a verb sends nothing; review and submit are unchanged")
	view.submit_draft()
	var order := last_sent(client, "order")
	check(order.get("tool") == "chop" and at(order.get("a"), 2, 0, 3) and at(order.get("b"), 2, 0, 3),
		"submitting sends the ordinary order message")
	view._receive({"v":1,"t":"reply","req":order.req,"ok":true,"reason":"Work planned"})
	view.go_back(); view.go_back()
	check(view.tool == "inspect", "Back leaves the tool after the draft is submitted")
	# A box selection by keyboard: Enter, move, Shift+Enter.
	view.ui.choose_family("Select")
	view.ui.focus_map()
	view.cursor = {"x":0,"y":0,"z":0}
	view._input(key(KEY_ENTER))
	view._input(key(KEY_RIGHT)); view._input(key(KEY_RIGHT)); view._input(key(KEY_UP))
	view._input(key(KEY_ENTER, true))
	ask = last_sent(client, "affordances")
	check(at(ask.get("a"), 0, 0, 0) and at(ask.get("b"), 2, 0, 1),
		"Shift+Enter extends the selection to a box")
	view._receive({"v":1,"t":"affordances","req":ask.req,"ok":true,"nouns":[{"kind":"floor","count":6}],
		"verbs":[{"id":"stockpile_area","tool":"stockpile_area","label":"Hauling stockpile","group":"Storage","icon":"zone_storage","group_icon":"zone_storage"},
			{"id":"refuse_area","tool":"refuse_area","label":"Refuse stockpile","group":"Storage"},
			{"id":"floor","tool":"floor","label":"Replace floor","disabled":true,"reason":"Building requires the manage right."}]})
	var entries: Array = Overseer.strip_entries(view.verbs)
	check(entries.size() == 2 and entries[0].label == "Storage" and entries[0].icon == "zone_storage", "a tool group folds into one verb, with the group's icon")
	check(view.ui.verb_heading.text == "Floor (6 cells)", "the strip names what the server found")
	view._input(key(KEY_2))
	check(view.tool == "inspect" and view.inspector.text == "Building requires the manage right." and view.first_corner == null,
		"an unavailable verb explains the server's reason and changes nothing")
	check(view.ui.first_verb() != null and view.ui.first_verb().text == "1  Storage",
		"the strip keeps its buttons across refreshes")
	var first: Button = view.ui.first_verb()
	view.ui.refresh()
	check(view.ui.first_verb() == first, "a layer refresh does not rebuild the strip and drop focus")
	view.ui.first_verb().pressed.emit()
	check(view.tool == "stockpile_area" and view.ui.zone_options.visible and view.last_corner == {"x":2,"y":0,"z":1},
		"a grouped verb opens its tool with the group's type control and the box")
	view.discard_draft(); view.choose_tool("inspect")
	view.select_cell({"x":5,"y":0,"z":5})
	ask = last_sent(client, "affordances")
	view._receive({"v":1,"t":"affordances","req":ask.req,"ok":true,"nouns":[{"kind":"plan","count":1,"plans":["o7"]}],
		"verbs":[{"id":"progress","label":"Progress","plans":["o7"]},{"id":"cancel","tool":"cancel","label":"Cancel pending work"}]})
	view._input(key(KEY_1))
	check(view.ui.family == "Plans" and view.ui.selected_id == "o7" and last_sent(client, "plans") != {},
		"Progress opens Plans at the selected plan")
	view.ui.choose_family("Select")
	view.select_cell({"x":5,"y":0,"z":5})
	ask = last_sent(client, "affordances")
	view._receive({"v":1,"t":"affordances","req":ask.req,"ok":true,"nouns":[{"kind":"tree","count":1},{"kind":"plan","count":1,"plans":["o7"]}],"verbs":[]})
	check(view.ui.verb_heading.text.ends_with("no shared actions") and view.ui.first_verb() == null,
		"a mixed selection with nothing shared says so")
	view.select_cell({"x":9,"y":0,"z":9})
	ask = last_sent(client, "affordances")
	view._receive({"v":1,"t":"affordances","req":ask.req,"ok":true,"nouns":[],"verbs":[]})
	check(view.ui.verb_heading.text == "Nothing known here to act on", "an unknown cell offers nothing")
	view.go_back()
	check(view.selection.is_empty() and not view.ui.verb_strip.visible and view.active,
		"Back clears the selection first")
	view.select_cell({"x":1,"y":0,"z":1})
	view.change_level(1)
	check(view.selection.is_empty() and not view.ui.verb_strip.visible, "changing level drops the selection")
	view.change_level(-1)
	view.select_cell({"x":1,"y":0,"z":1})
	ask = last_sent(client, "affordances")
	view._receive({"v":1,"t":"affordances","req":ask.req,"ok":false,"reason":"Selection is too large."})
	check(view.verbs.is_empty() and view.inspector.text.ends_with("Selection is too large."), "a refusal is shown, not hidden")
	var many: Array = []
	for i in 8: many.append({"id":"chop","tool":"chop","label":"Fell %d" % i})
	view.select_cell({"x":1,"y":0,"z":1})
	ask = last_sent(client, "affordances")
	view._receive({"v":1,"t":"affordances","req":ask.req,"ok":true,"nouns":[{"kind":"tree","count":1}],"verbs":many})
	var labels: Array = []
	for child in view.ui.verb_row.get_children():
		if not child.is_queued_for_deletion(): labels.append(child.text)
	check(labels.size() == 7 and labels[6] == "More", "six verbs show, the rest under More")
	view.ui.verb_row.get_child(view.ui.verb_row.get_child_count() - 1).pressed.emit()
	labels = []
	for child in view.ui.verb_row.get_children():
		if not child.is_queued_for_deletion(): labels.append(child.text)
	check(labels.size() == 8 and labels[7] == "Fell 7", "More shows the remaining verbs in place")
	print("Overseer verbs: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)
