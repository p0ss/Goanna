# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Read aloud: speaks what is on the screen, for a player who cannot see it,
# through a voice provider (the system's text to speech by default, so the
# player's own voice, rate and screen reader set up apply). Off unless the
# player turns it on: Ctrl+B, as in Minecraft, the Read aloud setting, or
# GOANNA_READ_ALOUD=1 at launch. In game it watches game_ui (ui); in the main
# menu it watches a screen (screen_root) that menu.gd announces.
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
var screen_root: Control             # the main menu's panel, when ui is null
var settings_owner: Object            # whatever saves settings (_save_setting)
var enabled := false
var rate := 1.0                       # 1 is the voice's normal rate
var speech_volume := 1.0
var voice_id := ""                    # empty for the system's default voice
# What is read, each its own setting (game_ui.gd SETTINGS, Audio).
var read_chat := true
var read_hud := true
var read_pointed := true
var read_held := true
var read_health := true
var read_menus := true

const SETTINGS_CFG := "user://goanna.cfg"
# Settings key -> property, for the keys read aloud owns.
const SETTING_PROPERTIES := {"speech_rate": "rate", "speech_volume": "speech_volume",
	"read_chat": "read_chat", "read_hud": "read_hud", "read_pointed": "read_pointed",
	"read_held": "read_held", "read_health": "read_health", "read_menus": "read_menus"}
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
var _held_stack := ""                 # what is on the cursor in a form, as last read
var _form_root := 0                   # the open form's build, by instance id
var _last_summary := ""               # its summary, numbers taken out
static var _digits := RegEx.create_from_string("[0-9]+")
var _clock := 0.0

# The system's text to speech (speech-dispatcher on Linux), through Godot.
class SystemVoice extends RefCounted:
	var narrator
	func available() -> bool:
		return not DisplayServer.tts_get_voices().is_empty()
	func speak(text: String, interrupt: bool) -> void:
		var id: String = narrator.voice_id
		if id == "":
			var voices := DisplayServer.tts_get_voices_for_language(TranslationServer.get_locale())
			if voices.is_empty():
				voices = DisplayServer.tts_get_voices_for_language("en")
			id = voices[0] if not voices.is_empty() else ""
		DisplayServer.tts_speak(text, id, int(narrator.speech_volume * 100.0), 1.0,
			narrator.rate, 0, interrupt)
	func stop() -> void:
		DisplayServer.tts_stop()

func _ready() -> void:
	if voice == null:
		var system := SystemVoice.new()
		system.narrator = self
		voice = system
	load_settings()
	if launched_on():
		enabled = true

static func launched_on() -> bool:
	return OS.get_environment("GOANNA_READ_ALOUD") in ["1", "true", "yes"]

# What goanna.cfg says. In game, game_ui applies the numbers too; the menu has
# no game_ui, and the voice is text, which game_ui does not apply.
func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_CFG) != OK:
		return
	enabled = bool(float(cfg.get_value("settings", "read_aloud", 0.0)) > 0.5)
	for key in SETTING_PROPERTIES:
		if cfg.has_section_key("settings", key):
			var v = cfg.get_value("settings", key)
			set(SETTING_PROPERTIES[key], float(v) if key.begins_with("speech_") else float(v) > 0.5)
	voice_id = str(cfg.get_value("settings", "speech_voice", ""))

# The system's voices as the Voice setting offers them: the default first,
# then one of each voice, its variants (espeak-ng's +Adam, +Alex and the
# rest, over a thousand for English) left out.
static func voice_choices() -> Array:
	var out := [["", "System default"]]
	for v in DisplayServer.tts_get_voices():
		var name := str(v.get("name", ""))
		if name.contains("+"):
			continue
		out.append([str(v.get("id", "")), "%s (%s)" % [name, str(v.get("language", ""))]])
	return out

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
		var saver: Object = settings_owner if settings_owner != null else ui
		if saver != null and saver.has_method("_save_setting"):
			saver._save_setting("read_aloud", 1.0 if enabled else 0.0)
		get_viewport().set_input_as_handled()

func set_enabled(on: bool) -> void:
	enabled = on
	if voice != null and voice.has_method("stop"):
		voice.stop()
	voice.speak("Read aloud on" if on else "Read aloud off", true)
	if on:
		_window_key = ""   # read what is open now
		_focus_name = ""
		# Chat from before it was turned on is not read out.
		if ui != null and not ui.chat_lines.is_empty():
			_chat_seen = ui.chat_lines[ui.chat_lines.size() - 1]
		if voice.has_method("available") and not voice.available():
			push_warning("read aloud: the system has no text to speech voices "
				+ "(on Linux, install speech-dispatcher and a voice such as espeak-ng)")

func _process(delta: float) -> void:
	_clock += delta
	if not enabled:
		return
	if ui == null:
		if screen_root != null and is_instance_valid(screen_root):
			_focus_in(screen_root)
		return
	if client == null:
		return
	if read_chat:
		_chat()
	_window()
	if ui.window == null:
		if read_hud:
			_hud()
		if read_pointed:
			_pointed()
		if read_held:
			_wielded()
	if read_health:
		_health()

# A new screen of the main menu: its title and what it says, interrupting,
# then whatever takes the focus after it.
func announce(text: String) -> void:
	_focus_name = ""
	_focus_queues = true
	if enabled:
		say(text, true)

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
		_held_stack = ""
		if w != null:
			var summary := _summary(w)
			_last_summary = _digits.sub(summary, "", true)
			_form_root = ui.form.root.get_instance_id() if w == ui.form and ui.form.root != null else 0
			if read_menus:
				say(summary, true)
			_focus_queues = true
	elif w != null and w == ui.form and ui.form.root != null \
			and ui.form.root.get_instance_id() != _form_root:
		# The server sent the form again. Read it again only if what it says
		# changed beyond its numbers: a furnace's timer resends every second.
		_form_root = ui.form.root.get_instance_id()
		var summary := _summary(w)
		var gist := _digits.sub(summary, "", true)
		if gist != _last_summary:
			_last_summary = gist
			if read_menus:
				say(summary)
	if w != null:
		_focus_in(w)
		if w == ui.form:
			_cursor_stack()

# The stack on the cursor in a form, when it changes: what was picked up, or
# that the hand is empty again.
func _cursor_stack() -> void:
	var held: Dictionary = ui.get("selected") if ui.get("selected") is Dictionary else {}
	var now := ""
	if not held.is_empty():
		var desc := ""
		if client != null and client.has_method("item_description"):
			desc = String(client.item_description(String(held.get("name", ""))))
		var what := FormspecScript.strip_enriched(desc).split("\n")[0] if desc != "" else String(held.get("name", ""))
		now = "Holding %d %s" % [int(held.get("amount", 1)), what]
	if now == _held_stack:
		return
	var was := _held_stack
	_held_stack = now
	if now != "":
		say(now)
	elif was != "":
		say("Put down")

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

# The control under the keyboard focus, or failing that under the pointer,
# within root.
func _focus_in(root: Control) -> void:
	var c: Control = get_viewport().gui_get_focus_owner()
	if c == null or not root.is_ancestor_of(c):
		c = get_viewport().gui_get_hovered_control()
	while c != null and not (c is BaseButton or c is LineEdit or c is TextEdit or c is Range
			or c is ItemList or c is TabBar or c is Tree or c.get("listname") != null
			or (c is RichTextLabel and c.has_meta("kbd_action"))):
		c = c.get_parent() as Control
	if c == null or not root.is_ancestor_of(c) or _leaving(c):
		return
	# What it says is part of the key, so a change in the focused control (a
	# tab switched, a box ticked, a slot filled, the next link chosen) is read
	# as well as a move to another one.
	# A form element is known by its name, so the same element rebuilt by the
	# server's resend is not read again unless it changed.
	var who := String(c.get_meta("formspec_name", "")) if c.has_meta("formspec_name") \
		else ("slot %s %d" % [c.get("listname"), int(c.get("index"))] if c.get("listname") != null \
		else str(c.get_instance_id()))
	var key := "%s:%s" % [who, describe(c)]
	if key == _focus_name:
		return
	_focus_name = key
	# The focus a window opens with is read after its summary, not over it.
	say(describe(c), not _focus_queues)
	_focus_queues = false

# Text as it should be heard: the disclosure arrows Goanna's menus draw on a
# group's header said as words, and runs of spaces closed up, so a voice does
# not spell out "black right-pointing small triangle".
static func _spoken(text: String) -> String:
	text = text.replace("▸", "closed").replace("▾", "open").replace("▶", "closed").replace("▼", "open")
	while text.contains("  "):
		text = text.replace("  ", " ")
	return text.strip_edges()

# A control on its way out: a screen being replaced keeps its old controls,
# focus included, until the end of the frame.
static func _leaving(c: Node) -> bool:
	while c != null:
		if c.is_queued_for_deletion():
			return true
		c = c.get_parent()
	return false

# The words that name a control that has none of its own (a text field, a
# slider, a dropdown): the nearest label before it, beside it or in the row
# above, as a screen reader takes a field's label.
static func label_for(c: Control) -> String:
	var at: Node = c
	for level in 3:
		var parent := at.get_parent()
		if parent == null:
			return ""
		for i in range(at.get_index() - 1, -1, -1):
			var text := _label_text(parent.get_child(i))
			if text != "":
				return text
		at = parent
	return ""

static func _label_text(n: Node) -> String:
	if n is Label and (n as Label).is_visible_in_tree():
		return (n as Label).text.strip_edges()
	if n is RichTextLabel and (n as RichTextLabel).is_visible_in_tree():
		return (n as RichTextLabel).get_parsed_text().strip_edges()
	if n is Container and not (n is ScrollContainer):
		for child in n.get_children():
			var text := _label_text(child)
			if text != "":
				return text
	return ""

# A control as a screen reader says it: its words, what it is, its state.
static func describe(c: Control) -> String:
	var said := _describe(c)
	if c is LineEdit or c is TextEdit or c is Range or c is OptionButton or c is ItemList:
		var label := label_for(c)
		if label != "" and not said.begins_with(label):
			said = "%s, %s" % [label, said]
	return said

static func _describe(c: Control) -> String:
	var tip := String(c.tooltip_text)
	# A form keeps its tooltips itself (tooltip[], and an item image
	# button's item description), not in Godot's tooltip_text.
	if tip == "" and c.has_meta("formspec_name"):
		var form: Node = c.get_parent()
		while form != null and form.get("tooltips") == null:
			form = form.get_parent()
		if form != null:
			var spec: Dictionary = (form.get("tooltips") as Dictionary).get(String(c.get_meta("formspec_name")), {})
			tip = FormspecScript.strip_enriched(String(spec.get("text", ""))).split("\n")[0]
	if c is RichTextLabel and c.has_meta("kbd_action"):
		var links: Array = FormspecScript.hypertext_actions(c)
		var at := int(c.get_meta("kbd_action"))
		if links.is_empty():
			return (c as RichTextLabel).get_parsed_text()
		var link: Dictionary = links[clampi(at, 0, links.size() - 1)]
		var text := (c as RichTextLabel).get_parsed_text().strip_edges()
		# One link standing alone in its element is read with the element's
		# text (Kythen puts each choice in its own row); several are read one
		# at a time, with where the chosen one is.
		if links.size() == 1:
			return "%s, link" % (text if text != "" else str(link.text))
		return "%s, link %d of %d" % [str(link.text), at + 1, links.size()]
	if c is CheckBox:
		return "%s, checkbox, %s" % [(c as CheckBox).text, "checked" if (c as CheckBox).button_pressed else "not checked"]
	if c is CheckButton:
		var name := _spoken((c as CheckButton).text)
		return "%s, switch, %s" % [name if name != "" else label_for(c),
			"on" if (c as CheckButton).button_pressed else "off"]
	if c is OptionButton:
		var ob := c as OptionButton
		return "%s, dropdown" % (ob.get_item_text(ob.selected) if ob.selected >= 0 else "nothing chosen")
	if c.get("listname") != null:
		var item: Dictionary = c.get("item") if c.get("item") is Dictionary else {}
		var what := FormspecScript.strip_enriched(String(item.get("description",
			item.get("name", "")))).split("\n")[0]
		return "%s, %d" % [what, int(item.get("count", 1))] if what != "" else "Empty slot"
	if c is Button:
		var label := _spoken(String(c.get_meta("label", (c as Button).text)))
		if label == "" and tip != "":
			label = tip
		if label == "" and c.has_meta("formspec_name"):
			label = String(c.get_meta("formspec_name"))
		if label == "":
			label = label_for(c)
		if label == "":
			label = "unlabelled"
		return "%s, button%s" % [label, ", unavailable" if (c as Button).disabled else ""]
	if c is LineEdit:
		var le := c as LineEdit
		var empty := "empty" if le.placeholder_text == "" else "empty, %s" % le.placeholder_text
		return "%s, %s" % ["password" if le.secret else "text field",
			"%d characters" % le.text.length() if le.secret else (le.text if le.text != "" else empty)]
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
		return "slider, %s" % str(snappedf((c as Range).value, 0.01))
	return c.get_class()
