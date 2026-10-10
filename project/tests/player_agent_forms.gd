# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# The player agent's form actions, offline: a real formspec, built by
# ui/formspec.gd, observed and worked through player_agent_channel.gd with no
# server. Checks that each element is reported as a player sees it, that each
# action sends what a click on the element sends, and that hidden, changed and
# mismatched elements are refused or stale.
#
#   godot --headless --path project -s tests/player_agent_forms.gd
extends SceneTree

const Formspec := preload("res://ui/formspec.gd")
const Channel := preload("res://player_agent_channel.gd")

var failures := 0
var checks := 0

func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("FAIL: ", what)

class FakeClient extends RefCounted:
	var health := 20
	func status() -> Dictionary: return {"state": "ready"}
	func hp() -> int: return health
	func breath() -> int: return 10
	func wield_index() -> int: return 0
	func wield_item_name() -> String: return ""
	func inventory_state() -> Dictionary: return {}
	func sky_state() -> Dictionary: return {}
	func is_underwater(_p: Vector3) -> bool: return false
	var entities: Array = []
	var hud := {"flags": 0xffff, "elements": []}
	func entity_list() -> Array: return entities
	func hud_state() -> Dictionary: return hud
	func server_player_position() -> Vector3: return Vector3.ZERO
	func node_walkable_at(_p: Vector3) -> bool: return false
	func node_name_at(_p: Vector3) -> String: return "air"
	func respawn() -> void: health = 20

class FakeUi extends Node:
	var window: Control = null
	var form: Control
	var form_is_inventory := false
	var chat_open := false
	var chat_lines: Array = []
	var selected := {}
	var death_screen: Control = null
	var pause_menu: Control = null
	var settings_menu: Control = null
	var client: FakeClient
	var sent: Array = []
	func blocks_input() -> bool: return window != null or chat_open
	func _respawn() -> void:
		client.respawn()
		window = null

class FakeMain extends Node:
	var client := FakeClient.new()
	var ui: FakeUi
	var cam := Camera3D.new()
	var pointed := {}
	var last_move := {}
	var pitch := 0.0
	var yaw := 0.0
	var placed := true
	var fly_mode := false
	var agent_dig := false
	var agent_place := false
	var agent_place_pressed := false
	func _hotbar_count() -> int: return 8

const SPEC := "formspec_version[6]size[12,12]" \
	+ "label[0.5,0.4;Pick a trade]" \
	+ "button[0.5,1;3,0.8;buy;Buy bread]" \
	+ "field[0.5,2.4;4,0.8;qty;Quantity;1]" \
	+ "pwdfield[5,2.4;3,0.8;secret;Word]" \
	+ "textarea[0.5,3.6;5,1.5;note;Note;hello]" \
	+ "checkbox[6,3.8;haggle;Haggle;false]" \
	+ "dropdown[6,4.6;3,0.8;coin;copper,silver,gold;1;true]" \
	+ "textlist[0.5,5.6;4,2;goods;bread,cheese,ale;1]" \
	+ "tablecolumns[text;text]table[5,5.6;6,2;stock;loaf,3,wheel,1;0]" \
	+ "tabheader[0,0;tabs;Market,Ledger;1;false;false]" \
	+ "hypertext[0.5,8;8,1;talk;Say <action name=greet>hello</action> or <action name=leave>goodbye</action> <style color=#00ff00><b>known</b></style>]" \
	+ "label[6,1;\u001b(c@#ff0000)red\u001b(c@#ffffff) word]" \
	+ "scrollbaroptions[max=50]scrollbar[11,8;0.5,3;vertical;scroll;0]" \
	+ "scroll_container[0.5,9.5;4,1;scroll;vertical]button[0,3;3,0.8;hidden_btn;Below]scroll_container_end[]"

var main: FakeMain
var channel: Node
var form: Control

func _initialize() -> void:
	OS.set_environment("GOANNA_PLAYER_AGENT", str(41000 + randi() % 2000))
	main = FakeMain.new()
	root.add_child(main)
	main.add_child(main.cam)
	main.ui = FakeUi.new()
	main.ui.client = main.client
	main.add_child(main.ui)
	form = Formspec.new()
	main.ui.add_child(form)
	main.ui.form = form
	form.fields_submitted.connect(func(f: Dictionary, quit: bool) -> void:
		main.ui.sent.append({"fields": f, "quit": quit}))
	channel = Channel.new()
	channel.main = main
	root.add_child(channel)
	_run.call_deferred()

func show() -> void:
	form.show_formspec(SPEC, "shop", Vector2(1200, 900))
	main.ui.window = form
	await process_frame
	await process_frame

func act(kind: String, args: Dictionary) -> Dictionary:
	var obs: Dictionary = channel._observe({})
	if not args.has("based_on"):
		args["based_on"] = obs.sequence
	var rec := {"id": 1, "kind": kind, "based_on": args.based_on, "status": "accepted",
		"reason": "", "effects": {}, "started_ms": 0, "finished_ms": 0, "cancel": false}
	main.ui.sent.clear()
	var problem: Dictionary = channel._check(kind, args)
	if not problem.is_empty():
		channel._finish(rec, problem.status, problem.reason, problem.get("effects", {}))
	else:
		await channel._run(rec, kind, args)
	return rec

func element(obs: Dictionary, name: String) -> Dictionary:
	for e in obs.window.get("elements", []):
		if e.name == name:
			return e
	return {}

func last_fields() -> Dictionary:
	return main.ui.sent[-1].fields if not main.ui.sent.is_empty() else {}

func _run() -> void:
	await show()
	var obs: Dictionary = channel._observe({})
	check(obs.window.kind == "form" and obs.window.formname == "shop", "a form is observed")
	check(element(obs, "buy").get("text") == "Buy bread", "button caption")
	check(element(obs, "qty").get("text") == "1", "field text")
	check(element(obs, "secret").get("secret") == true and element(obs, "secret").get("text") == "",
		"password text is not echoed")
	check(element(obs, "coin").get("items") == ["copper", "silver", "gold"], "dropdown items")
	check(element(obs, "goods").get("selected") == 1, "textlist selection")
	check((element(obs, "stock").get("rows", []) as Array).size() == 2, "table rows")
	check(element(obs, "tabs").get("tabs") == ["Market", "Ledger"], "tab captions")
	var actions: Array = element(obs, "talk").get("actions", [])
	check(actions.size() == 2 and actions[0].action == "greet" and actions[0].text == "hello",
		"hypertext actions with their text: %s" % [actions])
	check(element(obs, "hidden_btn").is_empty(), "a button scrolled out of view is not reported")
	check(obs.window.labels.any(func(l: Dictionary) -> bool: return l.text == "Pick a trade"),
		"label text: %s" % [obs.window.labels])
	var talk_spans: Array = element(obs, "talk").get("spans", [])
	check(talk_spans.any(func(sp: Dictionary) -> bool:
			return sp.get("action") == "greet" and sp.text == "hello" and sp.color == "#0000ff"),
		"hypertext spans carry the link and its colour: %s" % [talk_spans])
	check(talk_spans.any(func(sp: Dictionary) -> bool:
			return sp.text == "known" and sp.color == "#00ff00" and sp.get("bold", false)),
		"hypertext spans carry style colour and weight")
	var coloured: Array = obs.window.labels.filter(func(l: Dictionary) -> bool: return l.text == "red word")
	check(not coloured.is_empty() and coloured[0].get("spans", []).size() == 2 \
		and coloured[0].spans[0].color == "#ff0000", "a colorized label keeps its colours: %s" % [coloured])

	var r := await act("form_field", {"name": "qty", "text": "4"})
	check(r.status == "completed" and main.ui.sent.is_empty(), "typing sends nothing by itself")
	r = await act("form_button", {"name": "buy"})
	check(r.status == "completed" and last_fields().get("buy") == "Buy bread" \
		and last_fields().get("qty") == "4", "button sends itself and the typed field: %s" % [last_fields()])
	r = await act("form_field", {"name": "qty", "text": "7", "enter": true})
	check(last_fields().get("key_enter_field") == "qty", "enter submits the field")
	r = await act("form_check", {"name": "haggle", "checked": true})
	check(last_fields().get("haggle") == "true", "checkbox sends its state")
	r = await act("form_select", {"name": "coin", "text": "gold"})
	check(last_fields().get("coin") == "3", "dropdown with index events sends its index: %s" % [last_fields()])
	r = await act("form_select", {"name": "goods", "index": 2})
	check(last_fields().get("goods") == "CHG:2", "textlist change")
	r = await act("form_select", {"name": "goods", "index": 3, "double": true})
	check(last_fields().get("goods") == "DCL:3", "textlist double click")
	r = await act("form_select", {"name": "stock", "text": "wheel"})
	check(last_fields().get("stock") == "CHG:2:0", "table row by text: %s" % [last_fields()])
	r = await act("form_select", {"name": "stock", "index": 2, "double": true})
	check(last_fields().get("stock") == "DCL:2:1", "table activation includes its column")
	r = await act("form_select", {"name": "tabs", "index": 2})
	check(last_fields().get("tabs") == "2", "tab change")
	r = await act("form_action", {"name": "talk", "action": "leave"})
	check(last_fields().get("talk") == "action:leave", "hypertext action")
	r = await act("form_scroll", {"name": "scroll", "value": 30})
	check(String(last_fields().get("scroll", "")).begins_with("CHG:"), "scrollbar change")
	await process_frame
	obs = channel._observe({})
	check(not element(obs, "hidden_btn").is_empty(), "scrolling brings the hidden button into view")

	# Refusals and staleness.
	await show()
	r = await act("form_button", {"name": "qty"})
	check(r.status == "refused", "form_button on a field is refused")
	r = await act("form_button", {"name": "hidden_btn"})
	check(r.status == "refused", "a hidden button is refused")
	r = await act("form_select", {"name": "coin", "index": 9})
	check(r.status == "refused", "an index past the end is refused")
	obs = channel._observe({})
	(form.named_controls["coin"] as OptionButton).select(2)
	r = await act("form_select", {"name": "coin", "index": 1, "based_on": obs.sequence})
	check(r.status == "stale", "an element changed since the observation is stale")
	obs = channel._observe({})
	form.show_formspec(SPEC, "other", Vector2(1200, 900))
	r = await act("form_button", {"name": "buy", "based_on": obs.sequence})
	check(r.status == "stale", "a different form is stale")

	# The HUD, infotext and nametags.
	main.client.hud = {"flags": 0xffff & ~(1 << 4), "elements": [
		{"id": 1, "type": 1, "pos": Vector2(0, 1), "offset": Vector2(12, -82), "z_index": 2,
			"number": 0xeee1ab, "text": "\u001b(c@#88ff88)hello\u001b(c@#666666) stranger"},
		{"id": 2, "type": 1, "pos": Vector2(0, 1), "offset": Vector2.ZERO, "z_index": 0,
			"number": 0xffffff, "text": ""},
		{"id": 3, "type": 2, "name": "breath", "text": "bubble.png", "number": 10, "item": 20,
			"pos": Vector2(0.5, 1), "offset": Vector2.ZERO, "z_index": 0},
		{"id": 4, "type": 4, "name": "Village store", "text": "m", "number": 0xeee1ab,
			"world_pos": Vector3(0, 0, -20), "pos": Vector2.ZERO, "offset": Vector2.ZERO, "z_index": 0},
		{"id": 5, "type": 4, "name": "Behind", "text": "m", "number": 0,
			"world_pos": Vector3(0, 0, 20), "pos": Vector2.ZERO, "offset": Vector2.ZERO, "z_index": 0},
	]}
	main.pointed = {"type": "node", "node": Vector3(1, 0, -2), "above": Vector3(1, 1, -2),
		"node_name": "kythen:store", "infotext": "\u001b(c@#ffcc00)Store\u001b(c@#ffffff): bread"}
	main.client.entities = [{"id": 7, "name": "kythen:resident", "position": Vector3(0, 0, -5),
		"nametag": "Siku", "local": false}]
	main.ui.window = null
	await process_frame
	obs = channel._observe({})
	var hud: Array = obs.hud
	var speech: Array = hud.filter(func(h: Dictionary) -> bool: return h.type == "text")
	check(speech.size() == 1 and speech[0].text == "hello stranger" \
		and speech[0].spans[0].color == "#88ff88" and speech[0].spans[1].color == "#666666",
		"HUD text with its word colours; empty text left out: %s" % [speech])
	check(not hud.any(func(h: Dictionary) -> bool: return h.type == "statbar"),
		"a statbar the server hid is left out")
	var marks: Array = hud.filter(func(h: Dictionary) -> bool: return h.type == "waypoint")
	check(marks.size() == 1 and marks[0].name == "Village store" and marks[0].distance == 20 \
		and not marks[0].has("world_pos") and absf(float(marks[0].look.yaw)) < 0.01,
		"a waypoint in front, with distance and the look to it, not its coordinates: %s" % [marks])
	check(obs.pointed.get("infotext", {}).get("text") == "Store: bread" \
		and obs.pointed.infotext.spans[0].color == "#ffcc00", "pointed infotext with colour")
	var seen_entities: Array = obs.nearby_entities.seen
	check(seen_entities.size() == 1 and seen_entities[0].get("nametag", {}).get("text") == "Siku",
		"a nametag on an entity in view: %s" % [seen_entities])
	check(obs.has("hud") and not obs.has("frame"), "frames only when asked for")
	obs = channel._observe({"frame": {"width": 320}})
	check(obs.frame.has("error"), "no frame from a client with no renderer")
	var text := JSON.stringify(obs)
	check(not text.contains("(0.0, 1.0)"), "vectors are plain arrays in the JSON")

	# The death screen.
	r = await act("respawn", {})
	check(r.status == "refused", "respawn without the death screen is refused")
	main.ui.death_screen = Control.new()
	main.ui.window = main.ui.death_screen
	main.client.health = 0
	r = await act("respawn", {})
	check(r.status == "completed" and main.client.health > 0, "respawn")

	print("player-agent forms: %d checks, %s" % [checks,
		"PASS" if failures == 0 else "FAIL (%d)" % failures])
	quit(0 if failures == 0 else 1)
