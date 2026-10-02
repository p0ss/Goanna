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
	func entity_list() -> Array: return []
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
	+ "hypertext[0.5,8;8,1;talk;Say <action name=greet>hello</action> or <action name=leave>goodbye</action>]" \
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
	check("Pick a trade" in obs.window.labels, "label text: %s" % [obs.window.labels])

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
	check(last_fields().get("stock") == "CHG:2", "table row by text: %s" % [last_fields()])
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
