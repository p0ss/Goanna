# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Read aloud: speaks what is on the screen, for a player who cannot see it,
# through a voice provider (the system's text to speech by default, so the
# player's own voice, rate and screen reader set up apply). Off unless the
# player turns it on: Ctrl+B, as in Minecraft, the Read aloud setting, or
# GOANNA_READ_ALOUD=1 at launch.
#
# What it speaks is what is shown, nothing the screen does not show:
#   - chat lines as they arrive;
#   - HUD text once it has held still for a moment, so a line that changes
#     every frame (coordinates) is not read at all;
#   - the infotext of what the crosshair is on;
#   - the wielded item, when it changes;
#   - health, when it changes;
#   - a form or menu when it opens, then the element under the pointer or the
#     keyboard focus, with what kind of control it is and its state.
# The first five wait their turn; the last interrupts, since only the newest
# focus matters.
extends Node

const FormspecScript := preload("res://ui/formspec.gd")

# How long a HUD text or infotext must hold still before it is read.
const SETTLE_S := 0.5
# A form's opening summary is cut to this many characters.
const SUMMARY_MAX := 400

var client: Node
var ui: Node                          # game_ui.gd
var enabled := false
var rate := 1.0                       # 1 is the voice's normal rate
var speech_volume := 1.0
# The voice provider: anything with speak(text, interrupt) and available().
var voice: Object

var _chat_seen = null
var _hud_shown := {}                  # HUD element id -> {text, since, spoken}
var _infotext := {"text": "", "since": 0.0, "spoken": ""}
var _wield := ""
var _hp := -1
var _hp_since := 0.0
var _window_key := ""
var _focus_name := ""
var _focus_queues := false            # the first focus after an opening waits its turn
var _clock := 0.0

# The system's text to speech (speech-dispatcher on Linux), through Godot.
class SystemVoice extends RefCounted:
	var narrator
	func available() -> bool:
		return not DisplayServer.tts_get_voices().is_empty()
	func speak(text: String, interrupt: bool) -> void:
		var voices := DisplayServer.tts_get_voices_for_language(TranslationServer.get_locale())
		if voices.is_empty():
			voices = DisplayServer.tts_get_voices_for_language("en")
		var id: String = voices[0] if not voices.is_empty() else ""
		DisplayServer.tts_speak(text, id, int(narrator.speech_volume * 100.0), 1.0,
			narrator.rate, 0, interrupt)
	func stop() -> void:
		DisplayServer.tts_stop()

func _ready() -> void:
	if voice == null:
		var system := SystemVoice.new()
		system.narrator = self
		voice = system
	if OS.get_environment("GOANNA_READ_ALOUD") in ["1", "true", "yes"]:
		enabled = true

func say(text: String, interrupt := false) -> void:
	text = FormspecScript.strip_enriched(text).strip_edges()
	if text == "" or voice == null:
		return
	if OS.get_environment("GOANNA_DEBUG_SPEECH") != "":
		print("speech%s: %s" % [" (interrupting)" if interrupt else "", text])
	voice.speak(text, interrupt)

# Ctrl+B turns it on and off from anywhere, form or no form, and says which.
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_B and event.ctrl_pressed:
		set_enabled(not enabled)
		if ui != null and ui.has_method("_save_setting"):
			ui._save_setting("read_aloud", 1.0 if enabled else 0.0)
		get_viewport().set_input_as_handled()

func set_enabled(on: bool) -> void:
	enabled = on
	if voice != null and voice.has_method("stop"):
		voice.stop()
	voice.speak("Read aloud on" if on else "Read aloud off", true)
	if on:
		_window_key = ""   # read what is open now
		# Chat from before it was turned on is not read out.
		if ui != null and not ui.chat_lines.is_empty():
			_chat_seen = ui.chat_lines[ui.chat_lines.size() - 1]
		if voice.has_method("available") and not voice.available():
			push_warning("read aloud: the system has no text to speech voices "
				+ "(on Linux, install speech-dispatcher and a voice such as espeak-ng)")

func _process(delta: float) -> void:
	_clock += delta
	if not enabled or client == null or ui == null:
		return
	_chat()
	_window()
	if ui.window == null:
		_hud()
		_pointed()
		_wielded()
	_health()

# --- what it watches -----------------------------------------------------------

# game_ui keeps the last few chat lines and drops the oldest, so new lines
# are the ones after the last one read.
func _chat() -> void:
	var lines: Array = ui.chat_lines
	var start := 0
	if _chat_seen != null:
		start = lines.size()
		for i in range(lines.size() - 1, -1, -1):
			if is_same(lines[i], _chat_seen):
				break
			start = i
	for i in range(start, lines.size()):
		say(String(lines[i].get("text", "")))
	if not lines.is_empty():
		_chat_seen = lines[lines.size() - 1]

func _hud() -> void:
	var shown := {}
	for e in client.hud_state().get("elements", []):
		if int(e.get("type", -1)) != 1:   # HUD_ELEM_TEXT
			continue
		var id := int(e.get("id", 0))
		var text := FormspecScript.strip_enriched(String(e.get("text", ""))).strip_edges()
		shown[id] = true
		var seen: Dictionary = _hud_shown.get(id, {"text": "", "since": _clock, "spoken": ""})
		if text != seen.text:
			seen = {"text": text, "since": _clock, "spoken": seen.spoken}
		elif text != "" and text != seen.spoken and _clock - float(seen.since) >= SETTLE_S:
			say(text)
			seen.spoken = text
		_hud_shown[id] = seen
	for id in _hud_shown.keys():
		if not shown.has(id):
			_hud_shown.erase(id)

func _pointed() -> void:
	var m: Node = ui._main_node() if ui.has_method("_main_node") else null
	var pointed: Dictionary = m.pointed if m != null and m.get("pointed") is Dictionary else {}
	var text := FormspecScript.strip_enriched(String(pointed.get("infotext", ""))).strip_edges()
	if text != _infotext.text:
		_infotext = {"text": text, "since": _clock, "spoken": _infotext.spoken if text != "" else ""}
	elif text != "" and text != _infotext.spoken and _clock - float(_infotext.since) >= SETTLE_S:
		say(text)
		_infotext.spoken = text

func _wielded() -> void:
	var item: String = client.wield_item_name()
	if item == _wield:
		return
	_wield = item
	if item == "":
		say("Empty hand")
		return
	var desc := ""
	if client.has_method("item_description"):
		desc = String(client.item_description(item))
	say(FormspecScript.strip_enriched(desc).split("\n")[0] if desc != "" else item)

# Luanti counts health in half hearts; it is read as the number shown.
func _health() -> void:
	var hp: int = client.hp()
	if _hp < 0:
		_hp = hp
		return
	if hp == _hp:
		_hp_since = _clock
		return
	if _clock - _hp_since >= SETTLE_S:
		_hp = hp
		_hp_since = _clock
		say("Health %d" % hp)

# --- windows -------------------------------------------------------------------

func _window() -> void:
	var w: Control = ui.window
	var key := ""
	if w != null:
		key = "form:" + String(ui.form.formname) if w == ui.form else String(w.name)
	if key != _window_key:
		_window_key = key
		_focus_name = ""
		if w != null:
			say(_summary(w), true)
			_focus_queues = true
	if w != null:
		_focus()

# A form or menu as it opens: its text, then its controls' captions, in
# order, cut short.
func _summary(w: Control) -> String:
	var parts := []
	if w == ui.form:
		parts.append("Inventory" if ui.form_is_inventory else "Form")
	else:
		parts.append(String(w.name).capitalize())
	var counts := {}
	for c in _visible_controls(w):
		var role := ""
		if c is CheckBox:
			role = "checkbox"
		elif c is BaseButton:
			role = "button"
		elif c is LineEdit or c is TextEdit:
			role = "text field"
		elif c.get("listname") != null:
			role = "slot"
		if c is TabBar:
			var tb := c as TabBar
			var titles := []
			for i in tb.tab_count:
				titles.append(tb.get_tab_title(i))
			parts.append("Tabs %s, %s selected" % [", ".join(titles), tb.get_tab_title(tb.current_tab)])
		elif role != "":
			counts[role] = int(counts.get(role, 0)) + 1
		elif c is Label or c is RichTextLabel:
			var t: String = (c as Label).text if c is Label else (c as RichTextLabel).get_parsed_text()
			if t.strip_edges() != "" and not (c.get_parent() is BaseButton):
				parts.append(t.strip_edges())
	for role in ["button", "checkbox", "text field", "slot"]:
		var n := int(counts.get(role, 0))
		if n > 0:
			parts.append("%d %s%s" % [n, role, "" if n == 1 else "s"])
	var out := ". ".join(parts)
	return out.left(SUMMARY_MAX)

func _visible_controls(root: Control) -> Array:
	var out := []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var children := n.get_children()
		children.reverse()
		for child in children:
			stack.append(child)
		if n != root and n is Control and (n as Control).is_visible_in_tree():
			out.append(n)
	return out

# The control under the keyboard focus, or failing that under the pointer.
func _focus() -> void:
	var c: Control = get_viewport().gui_get_focus_owner()
	if c == null or not ui.window.is_ancestor_of(c):
		c = get_viewport().gui_get_hovered_control()
	while c != null and not (c is BaseButton or c is LineEdit or c is TextEdit or c is Range
			or c is ItemList or c is TabBar or c is Tree or c.get("listname") != null):
		c = c.get_parent() as Control
	if c == null or not ui.window.is_ancestor_of(c):
		return
	var key := "%d" % c.get_instance_id()
	if key == _focus_name:
		return
	_focus_name = key
	# The focus a window opens with is read after its summary, not over it.
	say(describe(c), not _focus_queues)
	_focus_queues = false

# A control as a screen reader says it: its words, what it is, its state.
static func describe(c: Control) -> String:
	var tip := String(c.tooltip_text)
	if c is CheckBox:
		return "%s, checkbox, %s" % [(c as CheckBox).text, "checked" if (c as CheckBox).button_pressed else "not checked"]
	if c is OptionButton:
		var ob := c as OptionButton
		return "%s, dropdown" % (ob.get_item_text(ob.selected) if ob.selected >= 0 else "nothing chosen")
	if c.get("listname") != null:
		var item: Dictionary = c.get("item") if c.get("item") is Dictionary else {}
		var what := FormspecScript.strip_enriched(String(item.get("description",
			item.get("name", "")))).split("\n")[0]
		return "%s, %d" % [what, int(item.get("count", 1))] if what != "" else "Empty slot"
	if c is Button:
		var label := String(c.get_meta("label", (c as Button).text)).strip_edges()
		if label == "" and c.has_meta("formspec_name"):
			label = tip if tip != "" else String(c.get_meta("formspec_name"))
		return "%s, button%s" % [label, ", unavailable" if (c as Button).disabled else ""]
	if c is LineEdit:
		var le := c as LineEdit
		return "%s, %s" % ["password" if le.secret else "text field",
			"%d characters" % le.text.length() if le.secret else (le.text if le.text != "" else "empty")]
	if c is TextEdit:
		return "text area, %s" % ((c as TextEdit).text if (c as TextEdit).text != "" else "empty")
	if c is TabBar:
		var tb := c as TabBar
		return "%s, tab %d of %d" % [tb.get_tab_title(tb.current_tab), tb.current_tab + 1, tb.tab_count]
	if c is ItemList:
		var il := c as ItemList
		var picked := Array(il.get_selected_items())
		return "list, %s" % (il.get_item_text(int(picked[0])) if not picked.is_empty() else "%d items" % il.item_count)
	if c is Range:
		return "slider, %s" % str((c as Range).value)
	return c.get_class()
