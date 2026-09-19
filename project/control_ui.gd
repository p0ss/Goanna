# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# The control channel's UI commands (docs/control-channel.md): read the open
# form or menu, and click, hover, type, scroll and press keys in it, without
# an OS pointer or keyboard anywhere near it.
#
# Why. Agents testing the client used to drive its window with xdotool and
# ydotool, on the owner's desktop, while the owner was using it. Everything
# here happens inside the client instead. Each action is an InputEvent handed
# to Input.parse_input_event, the same entry an OS event takes: it updates
# Input's own state (so a held key moves the player), then goes through the
# window, the viewport, the GUI and _unhandled_input exactly as a player's
# would. A formspec button pressed this way sends what a click sends.
#
# Every mouse event carries main.CONTROL_DEVICE, which is how main.gd tells a
# pointer a test pushed in from a real one crossing the window in test mode.
# Key events keep device 0: InputMap actions (Enter submitting a field, Ctrl+A
# selecting its text) only match the device they were defined for, which for
# Godot's built in ones is 0.
#
# Reading goes through formspec.gd's describe(), which only reads.
extends RefCounted

var main: Node
var tree: SceneTree

# The pointer as this driver last left it, for relative motion.
var _pointer := Vector2(-1.0, -1.0)

# Game actions by the name a test would use, as the keys Goanna binds them to
# (main.gd and ui/game_ui.gd). dig and place are mouse buttons at the centre
# of the screen, as with a captured pointer.
const ACTIONS := {
	"inventory": KEY_I, "menu": KEY_ESCAPE, "escape": KEY_ESCAPE, "chat": KEY_T,
	"command": KEY_SLASH, "forward": KEY_W, "backward": KEY_S, "left": KEY_A,
	"right": KEY_D, "jump": KEY_SPACE, "sneak": KEY_SHIFT, "aux1": KEY_E,
	"use": KEY_E, "enter": KEY_ENTER, "fly": KEY_F,
	"hotbar1": KEY_1, "hotbar2": KEY_2, "hotbar3": KEY_3, "hotbar4": KEY_4,
	"hotbar5": KEY_5, "hotbar6": KEY_6, "hotbar7": KEY_7, "hotbar8": KEY_8,
	"hotbar9": KEY_9, "hotbar10": KEY_0,
}
const MOUSE_ACTIONS := {"dig": MOUSE_BUTTON_LEFT, "place": MOUSE_BUTTON_RIGHT,
	"mouse_left": MOUSE_BUTTON_LEFT, "mouse_right": MOUSE_BUTTON_RIGHT,
	"mouse_middle": MOUSE_BUTTON_MIDDLE}
const BUTTONS := {"left": MOUSE_BUTTON_LEFT, "right": MOUSE_BUTTON_RIGHT,
	"middle": MOUSE_BUTTON_MIDDLE}

static func _err(what: String) -> Dictionary:
	return {"__error": what}

# --- reading -----------------------------------------------------------------

# What is open and what is in it: the form's named elements, its inventory
# slots and labels, or the controls of a Goanna menu, each with a rectangle in
# viewport pixels that ui_click accepts back as x and y.
func ui_tree(a: Dictionary) -> Variant:
	var ui = main.ui
	if ui == null:
		return _err("no UI")
	var out := {"window": _window_kind(), "chat_open": bool(ui.chat_open),
		"pointer_captured": main.pointer_captured(), "test_mode": main.test_mode,
		"viewport": _vec(main.get_viewport().get_visible_rect().size)}
	if ui.chat_open:
		out["chat_input"] = _describe_control(ui.chat_input, "")
	if ui.window == null:
		return out
	if ui.window == ui.form:
		out["form"] = _form_tree(a)
	else:
		out["controls"] = _generic_tree(ui.window, bool(a.get("hidden", false)))
	return out

func _window_kind() -> String:
	var ui = main.ui
	if ui.window == null:
		return "none"
	if ui.window == ui.form:
		return "inventory" if ui.form_is_inventory else "form"
	for kind in ["pause_menu", "death_screen", "settings_menu"]:
		if ui.get(kind) == ui.window:
			return kind
	return String(ui.window.name)

func _form_tree(a: Dictionary) -> Dictionary:
	var form = main.ui.form
	var d: Dictionary = form.describe()
	var hidden := bool(a.get("hidden", false))
	var elements := []
	for e in d["elements"]:
		if not e["visible"] and not hidden:
			continue
		var c: Control = e["control"]
		var desc := _describe_control(c, e["type"])
		desc["name"] = e["name"]
		desc["visible"] = e["visible"]
		desc["rect"] = _rect(form.shown_rect(c) if e["visible"] else c.get_global_rect())
		desc["hovered"] = e["name"] == d["hovered"]
		if String(e["tooltip"]) != "":
			desc["tooltip"] = form.strip_enriched(String(e["tooltip"]))
		elements.append(desc)
	# Slots grouped by list, so the creative inventory's thousand or so do not
	# drown everything else: the visible ones in full, the rest counted.
	var lists := {}
	var order := []
	for s in d["slots"]:
		var key := "%s|%s" % [s["location"], s["listname"]]
		if not lists.has(key):
			lists[key] = {"location": s["location"], "listname": s["listname"],
				"slots": [], "hidden": 0}
			order.append(key)
		var entry: Dictionary = lists[key]
		if not s["visible"] and not hidden:
			entry["hidden"] = int(entry["hidden"]) + 1
			continue
		var item: Dictionary = s["item"]
		var slot := {"index": s["index"], "rect": _rect(form.shown_rect(s["control"]))}
		if String(item.get("name", "")) != "":
			slot["item"] = String(item["name"])
			slot["count"] = int(item.get("count", 1))
			if String(item.get("description", "")) != "":
				slot["description"] = form.strip_enriched(String(item["description"])).split("\n")[0]
		(entry["slots"] as Array).append(slot)
	var list_out := []
	for key in order:
		list_out.append(lists[key])
	var out := {"formname": d["formname"], "formspec_version": d["formspec_version"],
		"allow_close": d["allow_close"], "rect": _rect(d["rect"]),
		"elements": elements, "lists": list_out, "hovered": d["hovered"],
		"tooltip": _tooltip_out(d["tooltip"])}
	if bool(a.get("labels", true)):
		out["labels"] = _labels(form)
	var focus: Control = main.get_viewport().gui_get_focus_owner()
	if focus != null and focus.has_meta("formspec_name"):
		out["focus"] = String(focus.get_meta("formspec_name"))
	return out

# Text on the form that belongs to no named element: label[], vertlabel[] and
# unnamed textareas. Button captions are reported with their buttons.
func _labels(form: Control) -> Array:
	var out := []
	var stack: Array = [form.root] if form.root != null else []
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for child in n.get_children():
			if child is BaseButton or child.has_meta("formspec_name"):
				continue
			stack.append(child)
			var text := ""
			if child is Label:
				text = (child as Label).text
			elif child is RichTextLabel:
				text = (child as RichTextLabel).get_parsed_text()
			if text.strip_edges() == "":
				continue
			var r: Rect2 = form.shown_rect(child)
			if r.has_area():
				out.append({"text": text, "rect": _rect(r)})
	return out

func _generic_tree(root: Control, hidden: bool) -> Array:
	var out := []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var children := n.get_children()
		children.reverse()
		for child in children:
			stack.append(child)
		if n == root or not (n is Control):
			continue
		var c := n as Control
		if not (c is BaseButton or c is LineEdit or c is TextEdit or c is Range \
				or c is TabBar or c is ItemList or (c is Label and (c as Label).text != "")):
			continue
		if not c.is_visible_in_tree() and not hidden:
			continue
		var desc := _describe_control(c, "")
		desc["rect"] = _rect(c.get_global_rect())
		out.append(desc)
	return out

# Type, text and state of one control, in terms a test can assert on.
func _describe_control(c: Control, type: String) -> Dictionary:
	var out := {"type": type if type != "" else c.get_class()}
	var state := {}
	if c is BaseButton:
		state["disabled"] = (c as BaseButton).disabled
		if (c as BaseButton).toggle_mode or c is CheckBox:
			state["pressed"] = (c as BaseButton).button_pressed
	if c is OptionButton:
		var ob := c as OptionButton
		var items := []
		for i in ob.item_count:
			items.append(ob.get_item_text(i))
		out["text"] = ob.get_item_text(ob.selected) if ob.selected >= 0 else ""
		state["items"] = items
		state["selected"] = ob.selected
	elif c is Button:
		out["text"] = String(c.get_meta("label", (c as Button).text))
	elif c is LineEdit:
		out["text"] = (c as LineEdit).text if not (c as LineEdit).secret else "(secret)"
		state["editable"] = (c as LineEdit).editable
	elif c is TextEdit:
		out["text"] = (c as TextEdit).text
		state["editable"] = (c as TextEdit).editable
	elif c is TabBar:
		var tb := c as TabBar
		var tabs := []
		for i in tb.tab_count:
			tabs.append(tb.get_tab_title(i))
		out["text"] = tb.get_tab_title(tb.current_tab) if tb.current_tab >= 0 else ""
		state["tabs"] = tabs
		state["current"] = tb.current_tab + 1
	elif c is ItemList:
		var il := c as ItemList
		var items := []
		for i in il.item_count:
			items.append(il.get_item_text(i))
		state["items"] = items
		state["selected"] = Array(il.get_selected_items()).map(func(i: int) -> int: return i + 1)
	elif c is Range:
		state["value"] = (c as Range).value
		state["min"] = (c as Range).min_value
		state["max"] = (c as Range).max_value
	elif c is Label:
		out["text"] = (c as Label).text
	elif c is RichTextLabel:
		out["text"] = (c as RichTextLabel).get_parsed_text()
	state["focused"] = c.has_focus()
	out["state"] = state
	return out

func _tooltip_out(tip: Dictionary) -> Variant:
	if tip.is_empty():
		return null
	var out := {"rect": _rect(tip.get("rect", Rect2()))}
	if tip.has("text"):
		out["text"] = main.ui.form.strip_enriched(String(tip["text"]))
	if tip.has("markup"):
		out["markup"] = String(tip["markup"])
	return out

# --- finding a target --------------------------------------------------------

# A point to act at, from one of: name (a formspec element, with tab for a
# tab header), slot ({list, index, location}), item (the first visible slot
# holding it), text (a caption, a tab, a checkbox or a label), or x and y.
# Returns {point, target} or an error, and never a point outside the part of
# the control a player could see.
func _find(a: Dictionary) -> Dictionary:
	var ui = main.ui
	var form = ui.form
	var in_form: bool = ui.window == form
	if a.has("x") and a.has("y"):
		return {"point": Vector2(float(a["x"]), float(a["y"])), "target": "point"}
	if a.get("pos") is Array and (a["pos"] as Array).size() == 2:
		return {"point": Vector2(float(a["pos"][0]), float(a["pos"][1])), "target": "point"}
	if a.has("name"):
		var n := String(a["name"])
		if not in_form:
			return _err("no form is open; name looks up formspec elements")
		var c: Control = form.named_controls.get(n)
		if c == null or not is_instance_valid(c):
			return _err("the form has no element named '%s'; ui_tree lists them" % n)
		if a.has("tab"):
			if not (c is TabBar):
				return _err("'%s' is not a tab header" % n)
			return _tab_point(c as TabBar, a["tab"], n)
		return _control_point(c, "%s '%s'" % [c.get_meta("formspec_type", "element"), n])
	if a.has("slot") or a.has("list"):
		if not in_form:
			return _err("no form is open")
		var spec: Dictionary = a["slot"] if a.get("slot") is Dictionary else a
		var lname := String(spec.get("list", spec.get("listname", "")))
		var index := int(spec.get("index", -1))
		var loc := String(spec.get("location", ""))
		var found := []
		for s in form.slots:
			if is_instance_valid(s) and s.listname == lname and s.index == index \
					and (loc == "" or s.location == loc):
				found.append(s)
		if found.is_empty():
			return _err("no slot %d in list '%s'%s" % [index, lname,
				(" at " + loc) if loc != "" else ""])
		if found.size() > 1:
			return _err("list '%s' is in the form more than once; give location: %s"
				% [lname, ", ".join(found.map(func(s) -> String: return s.location))])
		return _control_point(found[0], "slot %s %s %d" % [found[0].location, lname, index])
	if a.has("item"):
		if not in_form:
			return _err("no form is open")
		var want := String(a["item"])
		for s in form.slots:
			if is_instance_valid(s) and String(s.item.get("name", "")) == want \
					and form.shown_rect(s).has_area():
				return _control_point(s, "slot %s %s %d holding %s" % [s.location,
					s.listname, s.index, want])
		return _err("no visible slot holds '%s'; scroll, or read ui_tree" % want)
	if a.has("text"):
		return _find_text(String(a["text"]), int(a.get("nth", 0)))
	return _err("say where: name, slot, item, text, or x and y")

func _control_point(c: Control, what: String) -> Dictionary:
	var r: Rect2 = main.ui.form.shown_rect(c) if main.ui.window == main.ui.form \
			else (c.get_global_rect() if c.is_visible_in_tree() else Rect2())
	if not r.has_area():
		return _err("%s is hidden or scrolled out of view; scroll first" % what)
	return {"point": r.get_center().floor(), "target": what, "control": c}

func _tab_point(tb: TabBar, tab: Variant, n: String) -> Dictionary:
	var i := -1
	if tab is String and not (tab as String).is_valid_int():
		for k in tb.tab_count:
			if tb.get_tab_title(k) == tab:
				i = k
				break
	else:
		i = int(tab) - 1        # counted from 1, as the formspec counts tabs
	if i < 0 or i >= tb.tab_count:
		return _err("tab header '%s' has no tab %s" % [n, str(tab)])
	var r := tb.get_tab_rect(i)
	var point: Vector2 = tb.get_global_transform() * r.get_center()
	return {"point": point.floor(), "target": "tab %d of '%s'" % [i + 1, n], "control": tb}

# Buttons, tabs, checkboxes and labels whose text matches: exactly first, then
# ignoring case, then containing it, and a named element's tooltip after all
# of those (Mineclonia's creative tabs are captionless image buttons). More
# than one match is an error unless nth picks one, because a test that clicks
# the wrong "OK" passes silently.
func _find_text(want: String, nth: int) -> Dictionary:
	var ui = main.ui
	var root: Control = ui.window if ui.window != null else ui
	var cands := []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var children := n.get_children()
		children.reverse()
		for child in children:
			stack.append(child)
		if not (n is Control) or not (n as Control).is_visible_in_tree():
			continue
		var c := n as Control
		if c is TabBar:
			for k in (c as TabBar).tab_count:
				cands.append({"text": (c as TabBar).get_tab_title(k), "control": c, "tab": k + 1})
		elif c is Button:
			cands.append({"text": String(c.get_meta("label", (c as Button).text)), "control": c})
			if c.has_meta("formspec_name") and ui.window == ui.form:
				var tip: Dictionary = ui.form.tooltips.get(String(c.get_meta("formspec_name")), {})
				if String(tip.get("text", "")) != "":
					cands.append({"text": ui.form.strip_enriched(String(tip["text"])).split("\n")[0],
						"control": c, "tooltip": true})
		elif (c is Label or c is RichTextLabel) and not (c.get_parent() is BaseButton):
			var t: String = (c as Label).text if c is Label else (c as RichTextLabel).get_parsed_text()
			cands.append({"text": t, "control": c})
	for rule in ["exact", "nocase", "contains", "tip_exact", "tip_nocase", "tip_contains"]:
		var hits := []
		for cand in cands:
			if cand.has("tooltip") != rule.begins_with("tip_"):
				continue
			var t := String(cand["text"]).strip_edges()
			var ok := false
			match rule.trim_prefix("tip_"):
				"exact": ok = t == want
				"nocase": ok = t.to_lower() == want.to_lower()
				"contains": ok = want != "" and t.to_lower().contains(want.to_lower())
			if ok:
				hits.append(cand)
		if hits.is_empty():
			continue
		if hits.size() > 1 and nth <= 0:
			return _err("%d controls match '%s' (%s); pass nth, counting from 1" % [
				hits.size(), want, ", ".join(hits.map(func(h) -> String: return "'%s'" % h["text"]))])
		var hit: Dictionary = hits[clampi(nth - 1, 0, hits.size() - 1)] if nth > 0 else hits[0]
		if hit.has("tab"):
			return _tab_point(hit["control"], hit["tab"], String(hit["control"].get_meta("formspec_name", "tabs")))
		return _control_point(hit["control"], "%s '%s'" % [hit["control"].get_class(), hit["text"]])
	return _err("nothing on screen reads '%s'" % want)

# --- pushing events ----------------------------------------------------------

func _push(ev: InputEvent) -> void:
	if ev is InputEventMouse:
		ev.device = main.CONTROL_DEVICE
	Input.parse_input_event(ev)

func _mods(ev: InputEventWithModifiers, a: Dictionary) -> void:
	ev.shift_pressed = bool(a.get("shift", false))
	ev.ctrl_pressed = bool(a.get("ctrl", false))
	ev.alt_pressed = bool(a.get("alt", false))

func _move(point: Vector2, mask: int, a: Dictionary) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = point
	ev.global_position = point
	ev.relative = point - _pointer if _pointer.x >= 0.0 else Vector2.ZERO
	ev.button_mask = mask
	_mods(ev, a)
	_pointer = point
	_push(ev)

func _button(point: Vector2, button: int, pressed: bool, a: Dictionary, double := false) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = point
	ev.global_position = point
	ev.button_index = button
	ev.pressed = pressed
	ev.double_click = double
	ev.factor = 1.0
	var bit := 0
	match button:
		MOUSE_BUTTON_LEFT: bit = MOUSE_BUTTON_MASK_LEFT
		MOUSE_BUTTON_RIGHT: bit = MOUSE_BUTTON_MASK_RIGHT
		MOUSE_BUTTON_MIDDLE: bit = MOUSE_BUTTON_MASK_MIDDLE
	ev.button_mask = bit if pressed else 0
	_mods(ev, a)
	_push(ev)

func _key_event(keycode: int, pressed: bool, a: Dictionary, unicode := 0) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.key_label = keycode
	ev.unicode = unicode
	ev.pressed = pressed
	_mods(ev, a)
	_push(ev)

func _frames(n: int) -> void:
	for i in maxi(1, n):
		await tree.process_frame

func _wait_ms(ms: int) -> void:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		await tree.process_frame

# What the form told the server, and which slots it acted on, while `body`
# ran: listened to on formspec.gd's own signals, the ones game_ui sends from.
func _watch() -> Dictionary:
	var seen := {"fields": [], "slots": []}
	var form = main.ui.form
	seen["on_fields"] = func(f: Dictionary, quit: bool) -> void:
		(seen["fields"] as Array).append({"fields": f.duplicate(), "quit": quit})
	seen["on_slot"] = func(loc: String, lname: String, index: int, button: int, shift: bool) -> void:
		(seen["slots"] as Array).append({"location": loc, "list": lname, "index": index,
			"button": button, "shift": shift})
	form.fields_submitted.connect(seen["on_fields"])
	form.slot_clicked.connect(seen["on_slot"])
	seen["root"] = form.root.get_instance_id() if form.root != null else 0
	return seen

func _unwatch(seen: Dictionary, out: Dictionary) -> void:
	var form = main.ui.form
	form.fields_submitted.disconnect(seen["on_fields"])
	form.slot_clicked.disconnect(seen["on_slot"])
	if not (seen["fields"] as Array).is_empty():
		out["fields_sent"] = seen["fields"]
	if not (seen["slots"] as Array).is_empty():
		out["slots_clicked"] = seen["slots"]
	out["window_after"] = _window_kind()
	var now: int = form.root.get_instance_id() if form.root != null else 0
	out["form_rebuilt"] = now != int(seen["root"])
	if main.ui.window == form:
		out["formname_after"] = form.formname

func _hit() -> String:
	var c: Control = main.get_viewport().gui_get_hovered_control()
	if c == null:
		return ""
	if c.get("listname") != null:
		return "slot %s %s %d" % [c.get("location"), c.get("listname"), c.get("index")]
	var at := c
	while at != null:
		if at.has_meta("formspec_name"):
			return String(at.get_meta("formspec_name"))
		at = at.get_parent() as Control
	return c.get_class()

# --- actions -----------------------------------------------------------------

func ui_click(a: Dictionary) -> Variant:
	var where := _find(a)
	if where.has("__error"):
		return where
	var point: Vector2 = where["point"]
	var button: int = BUTTONS.get(String(a.get("button", "left")), MOUSE_BUTTON_LEFT)
	var seen := _watch()
	_move(point, 0, a)
	await _frames(2)
	var hit := _hit()
	for i in (2 if bool(a.get("double", false)) else 1):
		_button(point, button, true, a, i == 1)
		await _frames(int(a.get("hold_frames", 1)))
		_button(point, button, false, a)
		await _frames(1)
	await _wait_ms(int(a.get("settle_ms", 300)))
	var out := {"target": where["target"], "point": _vec(point), "hit": hit,
		"button": String(a.get("button", "left"))}
	_unwatch(seen, out)
	return out

func ui_hover(a: Dictionary) -> Variant:
	var where := _find(a)
	if where.has("__error"):
		return where
	var point: Vector2 = where["point"]
	_move(point, 0, a)
	# The form's own tooltip delay, and a little over for the frame it is
	# built on.
	await _wait_ms(int(a.get("ms", 600)))
	var out := {"target": where["target"], "point": _vec(point), "hit": _hit()}
	if main.ui.window == main.ui.form:
		out["tooltip"] = _tooltip_out(main.ui.form.describe()["tooltip"])
	else:
		var c: Control = main.get_viewport().gui_get_hovered_control()
		out["tooltip"] = {"text": c.tooltip_text} if c != null and c.tooltip_text != "" else null
	return out

# Click into a field (name, or x and y) so it takes the focus as it would for
# a player, then type text a key at a time. clear empties it first with
# Ctrl+A and Backspace; enter presses Enter afterwards, which is how a
# formspec field submits.
func ui_type(a: Dictionary) -> Variant:
	var out := {}
	var target := {}
	for k in ["name", "x", "y", "pos"]:
		if a.has(k):
			target[k] = a[k]
	var seen := _watch() if main.ui.window == main.ui.form else {}
	if not target.is_empty():
		var where := _find(target)
		if where.has("__error"):
			if not seen.is_empty():
				_unwatch(seen, {})
			return where
		_move(where["point"], 0, {})
		await _frames(1)
		_button(where["point"], MOUSE_BUTTON_LEFT, true, {})
		await _frames(1)
		_button(where["point"], MOUSE_BUTTON_LEFT, false, {})
		await _frames(2)
		out["target"] = where["target"]
	var focus: Control = main.get_viewport().gui_get_focus_owner()
	if focus == null or not (focus is LineEdit or focus is TextEdit):
		if not seen.is_empty():
			_unwatch(seen, out)
		return _err("nothing editable has the focus; pass name of a field")
	var fname := String(focus.get_meta("formspec_name", ""))
	if bool(a.get("clear", false)):
		_key_event(KEY_A, true, {"ctrl": true})
		_key_event(KEY_A, false, {"ctrl": true})
		_key_event(KEY_BACKSPACE, true, {})
		_key_event(KEY_BACKSPACE, false, {})
		await _frames(1)
	var text := String(a.get("text", ""))
	for ch in text:
		var code := ch.unicode_at(0)
		var keycode := KEY_NONE
		var upper := ch.to_upper()
		if upper.length() == 1 and ((upper >= "A" and upper <= "Z") or (upper >= "0" and upper <= "9")):
			keycode = OS.find_keycode_from_string(upper)
		elif ch == " ":
			keycode = KEY_SPACE
		var mods := {"shift": ch != ch.to_lower()}
		_key_event(keycode, true, mods, code)
		_key_event(keycode, false, mods, code)
		await _frames(1)
	if bool(a.get("enter", false)):
		_key_event(KEY_ENTER, true, {})
		_key_event(KEY_ENTER, false, {})
		await _wait_ms(int(a.get("settle_ms", 300)))
	else:
		await _frames(1)
	var now: Control = main.get_viewport().gui_get_focus_owner()
	if not is_instance_valid(focus) and fname != "" and main.ui.form.fields.has(fname):
		# The server answered with a new form, so the field is a new control.
		focus = main.ui.form.fields[fname]
	if is_instance_valid(focus):
		out["text"] = (focus as LineEdit).text if focus is LineEdit else (focus as TextEdit).text
		out["field"] = String(focus.get_meta("formspec_name", focus.get_class()))
	out["focus_after"] = String(now.get_meta("formspec_name", now.get_class())) if now != null else ""
	if not seen.is_empty():
		_unwatch(seen, out)
	return out

func ui_scroll(a: Dictionary) -> Variant:
	var where := _find(a)
	if where.has("__error"):
		return where
	var point: Vector2 = where["point"]
	var amount := int(a.get("amount", 1))
	var button := MOUSE_BUTTON_WHEEL_DOWN if amount > 0 else MOUSE_BUTTON_WHEEL_UP
	if bool(a.get("horizontal", false)):
		button = MOUSE_BUTTON_WHEEL_RIGHT if amount > 0 else MOUSE_BUTTON_WHEEL_LEFT
	_move(point, 0, a)
	await _frames(2)
	for i in absi(amount):
		_button(point, button, true, a)
		_button(point, button, false, a)
		await _frames(1)
	await _frames(2)
	var out := {"target": where["target"], "point": _vec(point), "hit": _hit(),
		"notches": amount}
	if main.ui.window == main.ui.form:
		var bars := {}
		for n in main.ui.form.scrollbars:
			var bar: ScrollBar = main.ui.form.scrollbars[n]
			if is_instance_valid(bar):
				bars[n] = bar.value
		out["scrollbars"] = bars
	return out

# A key or a game action: press, release, or both (tap, the default), with
# hold_ms between them for a held movement key. dig and place are mouse
# buttons at the centre of the screen, which is where a captured pointer is.
func key(a: Dictionary) -> Variant:
	var name := String(a.get("key", a.get("name", "")))
	if name == "":
		return _err("key wants key: a key name (Escape, I, 1, F5) or an action (%s)"
			% ", ".join(ACTIONS.keys() + MOUSE_ACTIONS.keys()))
	var action := String(a.get("action", "tap"))
	if not action in ["tap", "press", "release"]:
		return _err("action is tap, press or release")
	var before := _window_kind()
	var seen := _watch() if main.ui.window == main.ui.form else {}
	var out := {"key": name, "action": action}
	if MOUSE_ACTIONS.has(name):
		var button: int = MOUSE_ACTIONS[name]
		var centre: Vector2 = (main.get_viewport().get_visible_rect().size / 2.0).floor()
		if action != "release":
			_move(centre, 0, a)
			_button(centre, button, true, a)
		if action == "tap":
			await _wait_ms(int(a.get("hold_ms", 50)))
		if action != "press":
			_button(centre, button, false, a)
		out["mouse_button"] = button
	else:
		var keycode: int = ACTIONS.get(name, KEY_NONE)
		if keycode == KEY_NONE:
			keycode = OS.find_keycode_from_string(name)
		if keycode == KEY_NONE:
			return _err("no key called '%s'" % name)
		out["keycode"] = OS.get_keycode_string(keycode)
		if action != "release":
			_key_event(keycode, true, a)
		if action == "tap":
			await _wait_ms(int(a.get("hold_ms", 50)))
		if action != "press":
			_key_event(keycode, false, a)
	await _wait_ms(int(a.get("settle_ms", 150)))
	out["window_before"] = before
	out["pointer_captured"] = main.pointer_captured()
	if not seen.is_empty():
		_unwatch(seen, out)
	else:
		out["window_after"] = _window_kind()
	return out

# --- conversions -------------------------------------------------------------

static func _rect(r: Rect2) -> Array:
	return [roundi(r.position.x), roundi(r.position.y), roundi(r.size.x), roundi(r.size.y)]

static func _vec(v: Vector2) -> Array:
	return [roundi(v.x), roundi(v.y)]
