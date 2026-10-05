# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Read aloud (ui/narrator.gd), offline: what it says and when, with a fake
# voice that writes down every utterance instead of speaking it.
#
#   godot --headless --path project -s tests/narrator.gd
extends SceneTree

const Narrator := preload("res://ui/narrator.gd")
const Formspec := preload("res://ui/formspec.gd")

var failures := 0
var checks := 0

func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("FAIL: ", what)

class FakeVoice extends RefCounted:
	var said: Array = []
	func available() -> bool: return true
	func speak(text: String, interrupt: bool) -> void:
		said.append({"text": text, "interrupt": interrupt})
	func stop() -> void: pass

class FakeClient extends Node:
	var hud := {"elements": []}
	var wield := ""
	var health := 20
	func hud_state() -> Dictionary: return hud
	func wield_item_name() -> String: return wield
	func item_description(item: String) -> String:
		return "Wooden Pickaxe\nA tool" if item == "default:pick_wood" else ""
	func hp() -> int: return health

class FakeMain extends Node:
	var pointed := {}

class FakeUi extends Control:
	var chat_lines: Array = []
	var window: Control = null
	var form: Control
	var form_is_inventory := false
	var main_node: Node
	var saved := {}
	func _main_node() -> Node: return main_node
	func _save_setting(key: String, value: float) -> void: saved[key] = value

var narrator: Node
var voice := FakeVoice.new()
var client: FakeClient
var ui: FakeUi

func _initialize() -> void:
	client = FakeClient.new()
	root.add_child(client)
	ui = FakeUi.new()
	ui.main_node = FakeMain.new()
	ui.add_child(ui.main_node)
	ui.form = Formspec.new()
	ui.add_child(ui.form)
	root.add_child(ui)
	narrator = Narrator.new()
	narrator.voice = voice
	narrator.client = client
	narrator.ui = ui
	root.add_child(narrator)
	_run.call_deferred()

func run_for(seconds: float) -> Array:
	voice.said.clear()
	for i in roundi(seconds * 60.0):
		narrator._process(1.0 / 60.0)
	return voice.said.map(func(u: Dictionary) -> String: return u.text)

func _run() -> void:
	ui.chat_lines.append({"text": "<sam> hello"})
	check(run_for(1.0).is_empty(), "nothing is said while read aloud is off")
	narrator.set_enabled(true)
	check(voice.said.size() == 1 and voice.said[0].text == "Read aloud on" and voice.said[0].interrupt,
		"turning it on says so")
	ui.chat_lines.append({"text": "<sam> over here"})
	var said := run_for(0.2)
	check(said == ["<sam> over here"], "chat is read as it arrives, from when it was turned on: %s" % [said])
	# HUD text: read once it holds still, once, and never while it keeps changing.
	client.hud = {"elements": [{"id": 4, "type": 1, "text": "\u001b(c@#88ff88)Nobody's ground"},
		{"id": 9, "type": 1, "text": "Position 0, 0, 0"}]}
	voice.said.clear()
	for i in 60:
		client.hud.elements[1].text = "Position %d, 0, 0" % i
		narrator._process(1.0 / 60.0)
	said = voice.said.map(func(u: Dictionary) -> String: return u.text)
	check(said == ["Nobody's ground"], "settled HUD text is read without its colour escapes, changing text is not: %s" % [said])
	client.hud.elements.pop_back()
	check(run_for(1.0).is_empty(), "the same HUD text is not read again")
	# Infotext of what the crosshair is on.
	ui.main_node.pointed = {"type": "node", "infotext": "Chest (owned by sam)"}
	check(run_for(0.3).is_empty() and run_for(0.5) == ["Chest (owned by sam)"],
		"infotext is read once it settles")
	# The wielded item, by its description's first line.
	client.wield = "default:pick_wood"
	check(run_for(0.1) == ["Wooden Pickaxe"], "the wielded item is named")
	# Health, once a change settles.
	client.health = 14
	check(run_for(1.0) == ["Health 14"], "health is read when it changes")
	# A form: a summary as it opens, then the focused control, interrupting.
	ui.form.show_formspec("formspec_version[6]size[10,6]label[0.5,0.5;Pick a trade]" \
		+ "button[0.5,1;3,0.8;buy;Buy bread]button[4,1;3,0.8;sell;Sell]" \
		+ "checkbox[0.5,2.5;haggle;Haggle;true]", "shop", Vector2(1200, 900))
	ui.window = ui.form
	await process_frame
	said = run_for(0.1)
	check(said.size() >= 1 and said[0].contains("Pick a trade") and said[0].contains("2 buttons")
		and said[0].contains("1 checkbox") and voice.said[0].interrupt,
		"an opening form is summed up: %s" % [said])
	check(voice.said.slice(1).all(func(u: Dictionary) -> bool: return not u.interrupt),
		"the focus it opens with waits for the summary")
	(ui.form.named_controls["buy"] as Control).grab_focus()
	check(run_for(0.1) == ["Buy bread, button"] and voice.said[0].interrupt,
		"the focused button is read, interrupting")
	(ui.form.named_controls["haggle"] as Control).grab_focus()
	check(run_for(0.1) == ["Haggle, checkbox, checked"], "a checkbox says its state")
	check(run_for(0.5).is_empty(), "focus that stays put is not read again")
	ui.window = null
	run_for(0.1)
	# Ctrl+B turns it off and saves that.
	var key := InputEventKey.new()
	key.keycode = KEY_B
	key.ctrl_pressed = true
	key.pressed = true
	voice.said.clear()
	narrator._input(key)
	check(not narrator.enabled and voice.said.back().text == "Read aloud off"
		and ui.saved.get("read_aloud", -1.0) == 0.0, "Ctrl+B turns it off, says so and saves it")
	print("narrator: %d checks, %s" % [checks, "PASS" if failures == 0 else "FAIL (%d)" % failures])
	quit(0 if failures == 0 else 1)
