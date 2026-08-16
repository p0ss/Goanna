# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# The in-game user interface: HUD (crosshair, hotbar, statbars and the
# server's HUD elements), chat, the inventory and server formspecs, and the
# pause menu. It reads everything from GoannaClient and owns mouse capture
# while a window is open; main.gd only asks blocks_input() to know when to
# stop reading movement keys.
#
# HUD drawing follows luanti/src/client/hud.cpp (element types, alignment,
# offset and scale rules); formspecs are rendered by ui/formspec.gd.
extends CanvasLayer

const FormspecScript := preload("res://ui/formspec.gd")

const HUD_ELEM_IMAGE := 0
const HUD_ELEM_TEXT := 1
const HUD_ELEM_STATBAR := 2
const HUD_ELEM_INVENTORY := 3
const HUD_ELEM_WAYPOINT := 4
const HUD_ELEM_IMAGE_WAYPOINT := 5
const HUD_ELEM_COMPASS := 6
const HUD_ELEM_MINIMAP := 7
const HUD_ELEM_HOTBAR := 8

const HUD_FLAG_HOTBAR := 1 << 0
const HUD_FLAG_HEALTHBAR := 1 << 1
const HUD_FLAG_CROSSHAIR := 1 << 2
const HUD_FLAG_BREATHBAR := 1 << 4
const HUD_FLAG_CHAT := 1 << 8

const HUD_DIR_LEFT_RIGHT := 0
const HUD_DIR_RIGHT_LEFT := 1
const HUD_DIR_TOP_BOTTOM := 2
const HUD_DIR_BOTTOM_TOP := 3

const HOTBAR_IMAGE_SIZE := 48
const CHAT_LINES := 12
const CHAT_FADE_SECONDS := 10.0

var client: Node                       # GoannaClient, set by main.gd

var hud: Control
var chat_box: VBoxContainer
var chat_input: LineEdit
var chat_history: Array[String] = []
var chat_history_pos := -1
var chat_lines: Array = []             # [{text, time}]
var chat_open := false

var window: Control                    # current modal: formspec, pause menu or death screen
var form: Control                      # ui/formspec.gd
var form_is_inventory := false
var pause_menu: Control
var death_screen: Control
var fullscreen_tint: ColorRect

var inv_cache := {}                    # inventory_state() of this frame
var other_inv_cache := {}              # location -> inventory_state_at(location), for open forms
var form_context := ""                 # what "context" means in the open form (nodemeta:x,y,z)
var inv_version := -1
var item_defs := {}                    # item name -> {inventory_image, description, ...}
var icon_cache := {}                   # item name -> Texture2D
var tex_cache := {}                    # texture string -> Texture2D
var selected := {}                     # cursor stack: {location, listname, index, amount}
var pending_craft := false
var chat_printed := 0
var hud_scale := 1.0
var t := 0.0
var last_hp := -1

func _ready() -> void:
	layer = 10
	hud = Control.new()
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.draw.connect(_draw_hud)
	add_child(hud)

	fullscreen_tint = ColorRect.new()
	fullscreen_tint.set_anchors_preset(Control.PRESET_FULL_RECT)
	fullscreen_tint.color = Color(0, 0, 0, 0)
	fullscreen_tint.mouse_filter = Control.MOUSE_FILTER_STOP
	fullscreen_tint.visible = false
	fullscreen_tint.gui_input.connect(_on_outside_click)
	add_child(fullscreen_tint)

	chat_box = VBoxContainer.new()
	chat_box.position = Vector2(12, 12)
	chat_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(chat_box)
	chat_input = LineEdit.new()
	chat_input.visible = false
	chat_input.placeholder_text = "Chat, or / for a command"
	chat_input.text_submitted.connect(_on_chat_submit)
	add_child(chat_input)

	form = FormspecScript.new()
	form.item_source = self
	form.visible = false
	form.set_anchors_preset(Control.PRESET_FULL_RECT)
	form.mouse_filter = Control.MOUSE_FILTER_IGNORE
	form.fields_submitted.connect(_on_form_fields)
	form.slot_clicked.connect(_on_slot_clicked)
	add_child(form)

	get_viewport().size_changed.connect(_on_resize)
	_on_resize()

func _on_resize() -> void:
	var vs := get_viewport().get_visible_rect().size
	hud_scale = clampf(vs.y / 900.0, 0.75, 2.0)
	chat_input.size = Vector2(minf(vs.x * 0.5, 700), 34)
	if window == form and form.visible:
		_reopen_form()

# --- what main.gd needs ------------------------------------------------------

func blocks_input() -> bool:
	return window != null or chat_open

# --- per frame ---------------------------------------------------------------

func _process(delta: float) -> void:
	t += delta
	if client == null:
		return
	# chat
	for line in client.take_chat():
		_add_chat_line(_chat_text(line))
	_update_chat_fade()
	if chat_open:
		chat_input.position = Vector2(12, chat_box.position.y + chat_box.size.y + 6)
	# inventory
	var st: Dictionary = client.inventory_state()
	if int(st.get("version", 0)) != inv_version:
		inv_version = int(st.get("version", 0))
		inv_cache = st
		_learn_item_defs(st)
		if form.visible:
			form.refresh_lists()
			_after_inventory_update()
	_poll_other_inventories()
	# server-shown formspecs
	for f in client.take_shown_formspecs():
		form_context = str(f.get("context", ""))
		_show_server_formspec(str(f.get("formspec", "")), str(f.get("formname", "")))
	# death
	var hp: int = client.hp()
	if hp == 0 and last_hp > 0 and client.status().get("state") == "ready":
		_show_death_screen()
	last_hp = hp
	hud.queue_redraw()
	_ui_shot_hook(delta)
	_ui_move_test(delta)
	_ui_chest_test(delta)
	_ui_chat_hook(delta)

# Development aid: GOANNA_UI_SHOT=<dir> saves the HUD, the inventory, chat
# and the pause menu at fixed times, then quits.
func _ui_shot_hook(delta: float) -> void:
	var dir := OS.get_environment("GOANNA_UI_SHOT")
	if dir == "" or OS.get_environment("GOANNA_UI_TEST") != "":
		return
	var steps := [[4.0, "ui_hud", func() -> void: pass],
		[5.0, "ui_inventory", func() -> void: _open_inventory()],
		[6.0, "ui_chat", func() -> void: _close_window(); _open_chat("hello from the goanna ui")],
		[7.0, "ui_pause", func() -> void: _close_chat(); _open_pause_menu()]]
	for st in steps:
		if absf(t - st[0]) < delta * 0.6:
			st[2].call()
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(dir.path_join(st[1] + ".png"))
			print("saved ", st[1])
	if t > 8.0:
		client.disconnect_from_server()
		get_tree().quit()

# Development aid: GOANNA_UI_TEST=move opens the inventory and moves the
# stack in main slot 0 to slot 10 and back through the same path a mouse
# would take, printing the main list before and after.
func _ui_move_test(delta: float) -> void:
	if OS.get_environment("GOANNA_UI_TEST") != "move":
		return
	if absf(t - 4.0) < delta * 0.6:
		_open_inventory()
		print("ui test: main before: ", _main_names())
		_on_slot_clicked("current_player", "main", 0, MOUSE_BUTTON_LEFT, false)
		_on_slot_clicked("current_player", "main", 10, MOUSE_BUTTON_LEFT, false)
	if absf(t - 5.5) < delta * 0.6:
		print("ui test: main after move: ", _main_names())
		_on_slot_clicked("current_player", "main", 10, MOUSE_BUTTON_RIGHT, false)
		_on_slot_clicked("current_player", "main", 11, MOUSE_BUTTON_LEFT, false)
	if absf(t - 7.0) < delta * 0.6:
		print("ui test: main after half split: ", _main_names())
		if OS.get_environment("GOANNA_UI_SHOT") != "":
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(OS.get_environment("GOANNA_UI_SHOT").path_join("ui_move.png"))
		_close_window()

# Development aid: GOANNA_UI_CHAT="line|line|..." sends the lines as chat,
# one per second from t=3, and prints what comes back.
func _ui_chat_hook(delta: float) -> void:
	var lines := OS.get_environment("GOANNA_UI_CHAT")
	if lines == "":
		return
	var parts := lines.split("|", false)
	for i in parts.size():
		if absf(t - (3.0 + i)) < delta * 0.6:
			print("ui chat: sending ", parts[i])
			client.send_chat(parts[i])
	while chat_printed < chat_lines.size():
		print("ui chat: got: ", chat_lines[chat_printed]["text"])
		chat_printed += 1
	# GOANNA_UI_WIELD=<n> selects a hotbar slot once the world is ready.
	if OS.get_environment("GOANNA_UI_WIELD") != "" and absf(t - 2.5) < delta * 0.6:
		client.set_wield_index(int(OS.get_environment("GOANNA_UI_WIELD")))

# Development aid: GOANNA_UI_TEST=chest:<x,y,z> opens a chest style form
# listing nodemeta:x,y,z and prints what the slots resolve to.
func _ui_chest_test(delta: float) -> void:
	var spec := OS.get_environment("GOANNA_UI_TEST")
	if not spec.begins_with("chest:"):
		return
	var pos := spec.substr(6)
	if absf(t - 4.0) < delta * 0.6:
		form_context = "nodemeta:" + pos
		other_inv_cache.clear()
		form_is_inventory = false
		form.show_formspec("size[8,9]list[context;main;0,0.3;8,4;]list[current_player;main;0,4.85;8,1;]list[current_player;main;0,6.08;8,3;8]listring[context;main]listring[current_player;main]",
			"", get_viewport().get_visible_rect().size)
		fullscreen_tint.color = form.fullscreen_bg
		_open_window(form)
	if absf(t - 5.5) < delta * 0.6:
		var found := []
		for i in 32:
			var it := get_list_item("context", "main", i)
			if it.get("name", "") != "":
				found.append("%d:%s x%d" % [i, it["name"], it.get("count", 0)])
		print("ui test: chest ", pos, " -> ", found, " raw: ", client.inventory_state_at("nodemeta:" + pos), " detached: ", client.detached_inventory_names())
		if OS.get_environment("GOANNA_UI_SHOT") != "":
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(OS.get_environment("GOANNA_UI_SHOT").path_join("ui_chest.png"))
		_close_window()

func _main_names() -> Array:
	var out := []
	var items: Array = (inv_cache.get("lists", {}) as Dictionary).get("main", [])
	for i in items.size():
		var it: Dictionary = items[i]
		if it.get("name", "") != "":
			out.append("%d:%s x%d" % [i, it["name"], it.get("count", 0)])
	return out

func _unhandled_input(event: InputEvent) -> void:
	if client == null:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if window != null:
			if event.keycode == KEY_ESCAPE:
				_close_window()
			elif event.keycode == KEY_I and window == form and form_is_inventory:
				_close_window()
			get_viewport().set_input_as_handled()
			return
		if chat_open:
			if event.keycode == KEY_ESCAPE:
				_close_chat()
			elif event.keycode == KEY_UP:
				_chat_history(-1)
			elif event.keycode == KEY_DOWN:
				_chat_history(1)
			get_viewport().set_input_as_handled()
			return
		match event.keycode:
			KEY_I:
				_open_inventory()
				get_viewport().set_input_as_handled()
			KEY_T:
				_open_chat("")
				get_viewport().set_input_as_handled()
			KEY_SLASH:
				_open_chat("/")
				get_viewport().set_input_as_handled()
			KEY_ESCAPE:
				_open_pause_menu()
				get_viewport().set_input_as_handled()
	elif window != null and (event is InputEventMouseButton or event is InputEventKey):
		get_viewport().set_input_as_handled()

# --- chat --------------------------------------------------------------------

# take_chat() yields {type, sender, message, raw_message}; the server has
# already formatted player chat as "<name> text".
static func _chat_text(line: Variant) -> String:
	if line is Dictionary:
		var d: Dictionary = line
		var msg := str(d.get("message", ""))
		var sender := str(d.get("sender", ""))
		if sender != "" and not msg.begins_with("<"):
			return "<%s> %s" % [sender, msg]
		return msg
	return str(line)

func _add_chat_line(text: String) -> void:
	chat_lines.append({"text": text, "time": t})
	while chat_lines.size() > CHAT_LINES:
		chat_lines.pop_front()
	_rebuild_chat()

func _rebuild_chat() -> void:
	for c in chat_box.get_children():
		c.queue_free()
	for line in chat_lines:
		var l := Label.new()
		l.text = line["text"]
		l.add_theme_font_size_override("font_size", int(15 * hud_scale))
		l.add_theme_color_override("font_outline_color", Color.BLACK)
		l.add_theme_constant_override("outline_size", 3)
		l.set_meta("time", line["time"])
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chat_box.add_child(l)

func _update_chat_fade() -> void:
	for l in chat_box.get_children():
		var age: float = t - float(l.get_meta("time", 0.0))
		l.modulate.a = 1.0 if chat_open else clampf(1.0 - (age - CHAT_FADE_SECONDS) / 2.0, 0.0, 1.0)

func _open_chat(prefix: String) -> void:
	if window != null:
		return
	chat_open = true
	chat_input.text = prefix
	chat_input.visible = true
	chat_input.grab_focus()
	chat_input.caret_column = prefix.length()
	chat_history_pos = chat_history.size()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_rebuild_chat()

func _close_chat() -> void:
	chat_open = false
	chat_input.visible = false
	chat_input.release_focus()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _on_chat_submit(text: String) -> void:
	if text.strip_edges() != "":
		client.send_chat(text)
		chat_history.append(text)
	_close_chat()

func _chat_history(dir: int) -> void:
	if chat_history.is_empty():
		return
	chat_history_pos = clampi(chat_history_pos + dir, 0, chat_history.size())
	chat_input.text = chat_history[chat_history_pos] if chat_history_pos < chat_history.size() else ""
	chat_input.caret_column = chat_input.text.length()

# --- windows -----------------------------------------------------------------

func _open_window(c: Control) -> void:
	if chat_open:
		_close_chat()
	if window != null and window != c:
		window.visible = false
	window = c
	fullscreen_tint.visible = true
	c.visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _close_window() -> void:
	if window == null or window == death_screen:
		return  # only the respawn button closes the death screen
	if window == form:
		# tell the server the form was closed (vanilla sends quit=true)
		_send_fields({"quit": "true"})
		selected = {}
	_hide_window()

func _hide_window() -> void:
	if window != null:
		window.visible = false
	window = null
	fullscreen_tint.visible = false
	fullscreen_tint.color = Color(0, 0, 0, 0)
	if OS.get_environment("GOANNA_SHOT") == "":
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _open_inventory() -> void:
	var spec: String = client.inventory_formspec()
	if OS.get_environment("GOANNA_DUMP_FORMSPEC") != "":
		print("FORMSPEC>>>", spec, "<<<FORMSPEC")

	if spec.strip_edges() == "":
		spec = "size[8,7.5]list[current_player;main;0,3.5;8,4;]list[current_player;craft;3,0;3,3;]list[current_player;craftpreview;7,1;1,1;]listring[]"
	form_is_inventory = true
	other_inv_cache.clear()
	form_context = ""
	form.show_formspec(spec, "", get_viewport().get_visible_rect().size)
	fullscreen_tint.color = form.fullscreen_bg
	_open_window(form)

func _show_server_formspec(spec: String, formname: String) -> void:
	if spec.strip_edges() == "":
		# an empty formspec closes the current one
		if window == form:
			_hide_window()
		return
	form_is_inventory = false
	other_inv_cache.clear()
	form.show_formspec(spec, formname, get_viewport().get_visible_rect().size)
	fullscreen_tint.color = form.fullscreen_bg
	_open_window(form)

func _reopen_form() -> void:
	# re-layout after a resize, keeping the same spec
	pass

# Fields go to TOSERVER_NODEMETA_FIELDS for a node's own formspec (one
# opened with a nodemeta context) and to TOSERVER_INVENTORY_FIELDS otherwise,
# as vanilla's TextDestNodeMetadata and TextDestPlayerInventory do.
func _send_fields(fields: Dictionary) -> void:
	if form_context != "" and client.has_method("send_nodemeta_fields"):
		client.send_nodemeta_fields(form_context, form.formname, fields)
	else:
		client.send_inventory_fields(form.formname, fields)

func _on_form_fields(fields: Dictionary, quit: bool) -> void:
	_send_fields(fields)
	if quit:
		selected = {}
		_hide_window()

func _on_outside_click(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and window == form:
		# dropping the cursor stack outside the form
		if not selected.is_empty() and client.has_method("inventory_action"):
			var amt: int = selected["amount"] if event.button_index == MOUSE_BUTTON_LEFT else 1
			client.inventory_action("Drop %d %s %s %d" % [amt, selected["location"], selected["listname"], selected["index"]])
			selected["amount"] -= amt
			if selected["amount"] <= 0:
				selected = {}
			hud.queue_redraw()

func _open_pause_menu() -> void:
	if pause_menu == null:
		pause_menu = _build_menu("Goanna", [
			["Continue", func() -> void: _close_window()],
			["Disconnect", func() -> void: _disconnect()],
			["Quit", func() -> void: get_tree().quit()],
		])
	_open_window(pause_menu)

func _show_death_screen() -> void:
	if death_screen == null:
		death_screen = _build_menu("You died", [
			["Respawn", func() -> void: _respawn()],
			["Disconnect", func() -> void: _disconnect()],
		])
	_open_window(death_screen)

func _respawn() -> void:
	if client.has_method("respawn"):
		client.respawn()
	_hide_window()

func _disconnect() -> void:
	client.disconnect_from_server()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	OS.set_environment("GOANNA_MENU", "1")
	get_tree().change_scene_to_file.call_deferred("res://menu.tscn")

func _build_menu(title: String, entries: Array) -> Control:
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel := PanelContainer.new()
	centre.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 24)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.custom_minimum_size = Vector2(260, 0)
	margin.add_child(box)
	var l := Label.new()
	l.text = title
	l.add_theme_font_size_override("font_size", 24)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(l)
	for e in entries:
		var b := Button.new()
		b.text = e[0]
		b.pressed.connect(e[1])
		box.add_child(b)
	centre.visible = false
	add_child(centre)
	return centre

# --- inventory interaction ---------------------------------------------------

func _learn_item_defs(st: Dictionary) -> void:
	var lists: Dictionary = st.get("lists", {})
	for lname in lists:
		for it in lists[lname]:
			var n: String = it.get("name", "")
			if n != "" and not item_defs.has(n):
				item_defs[n] = it

# Formspec item source: an item dictionary for one slot, or {} if unknown.
func get_list_item(location: String, listname: String, index: int) -> Dictionary:
	if location == "current_player":
		var lists: Dictionary = inv_cache.get("lists", {})
		var items: Array = lists.get(listname, [])
		if index >= 0 and index < items.size():
			return items[index]
		return {}
	if location == "context":
		location = form_context
		if location == "":
			return {}
	var st: Dictionary = other_inv_cache.get(location, {})
	if st.is_empty() and client.has_method("inventory_state_at"):
		st = client.inventory_state_at(location)
		other_inv_cache[location] = st
	var items: Array = (st.get("lists", {}) as Dictionary).get(listname, [])
	if index >= 0 and index < items.size():
		return items[index]
	return {}

# Node and detached inventories used by the open form: re-read when their
# version changes and refresh the slots.
func _poll_other_inventories() -> void:
	if not form.visible or not client.has_method("inventory_state_at"):
		return
	var changed := false
	for loc in other_inv_cache.keys():
		var st: Dictionary = client.inventory_state_at(loc)
		if int(st.get("version", -1)) != int(other_inv_cache[loc].get("version", -2)):
			other_inv_cache[loc] = st
			changed = true
	if changed:
		form.refresh_lists()
		_after_inventory_update()

func ui_texture(name: String) -> Texture2D:
	if name.strip_edges() == "":
		return null
	if tex_cache.has(name):
		return tex_cache[name]
	var tex: Texture2D = client.texture(name)
	tex_cache[name] = tex
	return tex

func item_icon(item_name: String) -> Texture2D:
	if item_name == "":
		return null
	if icon_cache.has(item_name):
		return icon_cache[item_name]
	var tex: Texture2D = null
	if client.has_method("item_icon"):
		tex = client.item_icon(item_name)
	if tex == null:
		var d: Dictionary = item_defs.get(item_name, {})
		var img: String = d.get("inventory_image", "")
		if img != "":
			tex = ui_texture(img)
	if tex == null:
		tex = _placeholder_icon(item_name)
	icon_cache[item_name] = tex
	return tex

# Nodes without an inventory image are drawn as a cube in vanilla; until the
# wield mesh renderer exists, a coloured tile with the item's short name.
func _placeholder_icon(item_name: String) -> Texture2D:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var h := hash(item_name)
	var col := Color.from_hsv(float(h % 360) / 360.0, 0.45, 0.65)
	img.fill(col)
	for i in 32:
		img.set_pixel(i, 0, col.darkened(0.4))
		img.set_pixel(i, 31, col.darkened(0.4))
		img.set_pixel(0, i, col.lightened(0.3))
		img.set_pixel(31, i, col.darkened(0.4))
	return ImageTexture.create_from_image(img)

func _on_slot_clicked(location: String, listname: String, index: int, button: int, shift: bool) -> void:
	if not client.has_method("inventory_action"):
		print("inventory: inventory_action not available yet")
		return
	if location == "context":
		if form_context == "":
			return
		location = form_context
	var item := get_list_item(location, listname, index)
	var count: int = item.get("count", 0)
	if shift and button == MOUSE_BUTTON_LEFT and count > 0 and selected.is_empty():
		var nxt: Dictionary = form.next_in_ring(location if form_context == "" else location, listname)
		if nxt.is_empty():
			nxt = form.next_in_ring("context", listname) if location == form_context else {}
		if not nxt.is_empty():
			var dst: String = form_context if nxt["location"] == "context" else nxt["location"]
			client.inventory_action("MoveSomewhere %d %s %s %d %s %s" % [count, location, listname, index, dst, nxt["listname"]])
		return
	if listname == "craftpreview":
		if count > 0 and selected.is_empty():
			client.inventory_action("Craft 1 %s craft" % location)
			pending_craft = true
		return
	if selected.is_empty():
		if count == 0:
			return
		var amt := count
		if button == MOUSE_BUTTON_RIGHT:
			amt = int(ceil(count / 2.0))
		elif button == MOUSE_BUTTON_MIDDLE:
			amt = mini(10, count)
		selected = {"location": location, "listname": listname, "index": index, "amount": amt, "name": item.get("name", "")}
		hud.queue_redraw()
		return
	# something is on the cursor
	if selected["location"] == location and selected["listname"] == listname and selected["index"] == index:
		selected = {}
		hud.queue_redraw()
		return
	var amt: int = selected["amount"]
	if button == MOUSE_BUTTON_RIGHT:
		amt = 1
	client.inventory_action("Move %d %s %s %d %s %s %d" % [amt, selected["location"], selected["listname"], selected["index"], location, listname, index])
	if selected["listname"] == "craftresult":
		selected = {}
	else:
		selected["amount"] -= amt
		if selected["amount"] <= 0:
			selected = {}
	hud.queue_redraw()

func _after_inventory_update() -> void:
	# after a craft the result sits in craftresult: pick it up, as vanilla does
	if pending_craft:
		pending_craft = false
		var res := get_list_item("current_player", "craftresult", 0)
		if res.get("count", 0) > 0:
			selected = {"location": "current_player", "listname": "craftresult", "index": 0,
				"amount": res["count"], "name": res.get("name", "")}
	elif not selected.is_empty():
		var cur := get_list_item(selected["location"], selected["listname"], selected["index"])
		if cur.get("count", 0) == 0 or cur.get("name", "") != selected.get("name", ""):
			selected = {}
		else:
			selected["amount"] = mini(selected["amount"], cur["count"])

# --- HUD ---------------------------------------------------------------------

func _draw_hud() -> void:
	if client == null:
		return
	var vs := hud.size
	var st: Dictionary = client.hud_state()
	var flags: int = st.get("flags", 0xffff)
	# crosshair
	if flags & HUD_FLAG_CROSSHAIR and window == null:
		var c := vs / 2.0
		var l := 8.0 * hud_scale
		hud.draw_line(c - Vector2(l, 0), c + Vector2(l, 0), Color(1, 1, 1, 0.8), 2.0)
		hud.draw_line(c - Vector2(0, l), c + Vector2(0, l), Color(1, 1, 1, 0.8), 2.0)
	var elems: Array = st.get("elements", [])
	elems.sort_custom(func(a, b) -> bool: return int(a.get("z_index", 0)) < int(b.get("z_index", 0)))
	var hotbar_drawn := false
	for e in elems:
		var pos: Vector2 = (e["pos"] as Vector2) * vs
		pos = pos.floor()
		match int(e["type"]):
			HUD_ELEM_HOTBAR:
				if flags & HUD_FLAG_HOTBAR:
					_draw_hotbar(st, pos, e["offset"], int(e["dir"]), e["align"])
					hotbar_drawn = true
			HUD_ELEM_STATBAR:
				var nm: String = e["name"]
				if nm == "health" and not (flags & HUD_FLAG_HEALTHBAR):
					continue
				if nm == "breath" and not (flags & HUD_FLAG_BREATHBAR):
					continue
				_draw_statbar(pos, e)
			HUD_ELEM_IMAGE:
				_draw_hud_image(pos, e)
			HUD_ELEM_TEXT:
				_draw_hud_text(pos, e)
			HUD_ELEM_INVENTORY:
				_draw_hud_inventory(pos, e)
			HUD_ELEM_WAYPOINT, HUD_ELEM_IMAGE_WAYPOINT:
				_draw_waypoint(e)
			_:
				pass
	if not hotbar_drawn and flags & HUD_FLAG_HOTBAR and st.get("version", 0) == 0:
		# very old servers do not send a hotbar element
		_draw_hotbar(st, Vector2(vs.x / 2.0, vs.y), Vector2.ZERO, HUD_DIR_LEFT_RIGHT, Vector2(0, -1))
	# cursor stack while a form is open
	if not selected.is_empty() and window == form:
		var icon := item_icon(selected.get("name", ""))
		var m := hud.get_local_mouse_position()
		var s: float = form.imgsize * 0.8
		if icon:
			hud.draw_texture_rect(icon, Rect2(m - Vector2(s, s) / 2.0, Vector2(s, s)), false)
		if selected["amount"] > 1:
			hud.draw_string(hud.get_theme_default_font(), m + Vector2(s * 0.15, s * 0.5), str(selected["amount"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, int(s * 0.35), Color.WHITE)

func _hotbar_list() -> Array:
	var lists: Dictionary = inv_cache.get("lists", {})
	return lists.get("main", [])

func _draw_hotbar(st: Dictionary, pos: Vector2, offset: Vector2, dir: int, align: Vector2) -> void:
	var itemcount: int = st.get("hotbar_itemcount", 8)
	var main := _hotbar_list()
	var wield := int(client.wield_index()) if client.has_method("wield_index") else -1
	var imgsz := floorf(HOTBAR_IMAGE_SIZE * hud_scale)
	var pad := floorf(imgsz / 12.0)
	var full := imgsz + pad * 2
	var count := mini(itemcount, main.size())
	var width := count * full
	var height := full
	if dir == HUD_DIR_TOP_BOTTOM or dir == HUD_DIR_BOTTOM_TOP:
		var tmp := width
		width = height
		height = tmp
	var p := pos + offset * hud_scale
	p.x += (align.x - 1.0) * width * 0.5
	p.y += (align.y - 1.0) * height * 0.5
	p = p.floor()
	var hb_img := ui_texture(st.get("hotbar_image", ""))
	if hb_img:
		hud.draw_texture_rect(hb_img, Rect2(p - Vector2(pad, pad) / 2.0, Vector2(width, height) + Vector2(pad, pad)), false)
	var sel_img := ui_texture(st.get("hotbar_selected_image", ""))
	for i in count:
		var step: Vector2
		match dir:
			HUD_DIR_RIGHT_LEFT: step = Vector2(pad + (count - 1 - i) * full, pad)
			HUD_DIR_TOP_BOTTOM: step = Vector2(pad, pad + i * full)
			HUD_DIR_BOTTOM_TOP: step = Vector2(pad, pad + (count - 1 - i) * full)
			_: step = Vector2(pad + i * full, pad)
		var r := Rect2(p + step, Vector2(imgsz, imgsz))
		if not hb_img:
			hud.draw_rect(r, Color(0, 0, 0, 0.5))
		if i == wield:
			if sel_img:
				hud.draw_texture_rect(sel_img, r.grow(pad), false)
			else:
				hud.draw_rect(r.grow(pad * 0.5), Color(1, 1, 1, 0.9), false, 2.0)
		var it: Dictionary = main[i]
		var nm: String = it.get("name", "")
		if nm != "":
			var icon := item_icon(nm)
			if icon:
				hud.draw_texture_rect(icon, r.grow(-imgsz * 0.08), false)
			var c: int = it.get("count", 0)
			if c > 1:
				var fs := int(imgsz * 0.32)
				var f := hud.get_theme_default_font()
				var txt := str(c)
				var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_RIGHT, -1, fs).x
				hud.draw_string(f, Vector2(r.end.x - w - 2, r.end.y - 3), txt, HORIZONTAL_ALIGNMENT_RIGHT, -1, fs, Color.WHITE)
			var wear: int = it.get("wear", 0)
			if wear > 0:
				var frac := 1.0 - wear / 65535.0
				hud.draw_rect(Rect2(r.position + Vector2(imgsz * 0.1, imgsz * 0.85), Vector2(imgsz * 0.8 * frac, imgsz * 0.08)), Color(1.0 - frac, frac, 0.1))

# Hud::drawStatbar: `number` half-icons of `text`, `item` half-icons of `text2` behind.
func _draw_statbar(pos: Vector2, e: Dictionary) -> void:
	var tex := ui_texture(e["text"])
	if tex == null:
		return
	var bg := ui_texture(e["text2"])
	var count := int(e["number"])
	var maxcount := int(e["item"])
	var size: Vector2 = e["size"]
	var dst: Vector2 = (Vector2(tex.get_width(), tex.get_height()) if size == Vector2.ZERO else size) * hud_scale
	var offset: Vector2 = (e["offset"] as Vector2) * hud_scale
	var p := pos
	if e["align"].y > 0.5:   # HUD_CORNER_LOWER analogue: statbars anchor by their bottom-left
		pass
	p += offset
	var dir := int(e["dir"])
	var step := Vector2(1, 0)
	match dir:
		HUD_DIR_RIGHT_LEFT: step = Vector2(-1, 0)
		HUD_DIR_TOP_BOTTOM: step = Vector2(0, 1)
		HUD_DIR_BOTTOM_TOP: step = Vector2(0, -1)
	var full := count / 2
	var half := count % 2 == 1
	var maxfull := maxcount / 2
	var maxhalf := maxcount % 2 == 1
	var draw_one := func(idx: int, texture: Texture2D, halfw: bool) -> void:
		var d := Vector2(dst.x * (0.5 if halfw and step.x != 0 else 1.0), dst.y * (0.5 if halfw and step.y != 0 else 1.0))
		var q := p + Vector2(step.x * dst.x * idx, step.y * dst.y * idx)
		if step.x < 0:
			q.x -= dst.x
		if step.y < 0:
			q.y -= dst.y
		var src := Rect2(0, 0, texture.get_width(), texture.get_height())
		if halfw:
			if step.x != 0:
				src.size.x /= 2
				if step.x < 0:
					src.position.x = src.size.x
					q.x += dst.x / 2
			else:
				src.size.y /= 2
				if step.y < 0:
					src.position.y = src.size.y
					q.y += dst.y / 2
		hud.draw_texture_rect_region(texture, Rect2(q, d), src)
	if bg and maxcount > 0:
		for i in maxfull:
			draw_one.call(i, bg, false)
		if maxhalf:
			draw_one.call(maxfull, bg, true)
	for i in full:
		draw_one.call(i, tex, false)
	if half:
		draw_one.call(full, tex, true)

func _draw_hud_image(pos: Vector2, e: Dictionary) -> void:
	var tex := ui_texture(e["text"])
	if tex == null:
		return
	var vs := hud.size
	var scale: Vector2 = e["scale"]
	var dst := Vector2(tex.get_width() * scale.x * hud_scale, tex.get_height() * scale.y * hud_scale)
	if scale.x < 0:
		dst.x = vs.x * (scale.x * -0.01)
	if scale.y < 0:
		dst.y = vs.y * (scale.y * -0.01)
	var align: Vector2 = e["align"]
	var off := Vector2((align.x - 1.0) * dst.x / 2.0, (align.y - 1.0) * dst.y / 2.0)
	var r := Rect2(pos + off + (e["offset"] as Vector2) * hud_scale, dst)
	hud.draw_texture_rect(tex, r, false)

func _draw_hud_text(pos: Vector2, e: Dictionary) -> void:
	var text: String = e["text"]
	if text == "":
		return
	var f := hud.get_theme_default_font()
	var fs := int(16 * hud_scale)
	var size: Vector2 = e["size"]
	if size.x > 0:
		fs = int(fs * size.x)
	var n := int(e["number"])
	var col := Color((n >> 16 & 0xff) / 255.0, (n >> 8 & 0xff) / 255.0, (n & 0xff) / 255.0)
	var align: Vector2 = e["align"]
	var lines := text.split("\n")
	var line_h := f.get_height(fs)
	var total_h := line_h * lines.size()
	var y := pos.y + (align.y - 1.0) * total_h / 2.0 + (e["offset"] as Vector2).y * hud_scale + f.get_ascent(fs)
	for line in lines:
		var w := f.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var x := pos.x + (align.x - 1.0) * w / 2.0 + (e["offset"] as Vector2).x * hud_scale
		hud.draw_string_outline(f, Vector2(x, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, Color(0, 0, 0, 0.7))
		hud.draw_string(f, Vector2(x, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
		y += line_h

func _draw_hud_inventory(pos: Vector2, e: Dictionary) -> void:
	# HUD inventory element: `number` items of list `text`
	var lists: Dictionary = inv_cache.get("lists", {})
	var items: Array = lists.get(e["text"], [])
	var n := mini(int(e["number"]), items.size())
	var imgsz := floorf(HOTBAR_IMAGE_SIZE * hud_scale)
	var pad := floorf(imgsz / 12.0)
	var full := imgsz + pad * 2
	var align: Vector2 = e["align"]
	var p := pos + (e["offset"] as Vector2) * hud_scale
	p.x += (align.x - 1.0) * n * full * 0.5
	p.y += (align.y - 1.0) * full * 0.5
	for i in n:
		var r := Rect2(p + Vector2(pad + i * full, pad), Vector2(imgsz, imgsz))
		hud.draw_rect(r, Color(0, 0, 0, 0.5))
		var nm: String = items[i].get("name", "")
		if nm != "":
			var icon := item_icon(nm)
			if icon:
				hud.draw_texture_rect(icon, r.grow(-imgsz * 0.08), false)

func _draw_waypoint(e: Dictionary) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var wp: Vector3 = e["world_pos"]
	if cam.is_position_behind(wp):
		return
	var sp := cam.unproject_position(wp) + (e["offset"] as Vector2) * hud_scale
	var n := int(e["number"])
	var col := Color((n >> 16 & 0xff) / 255.0, (n >> 8 & 0xff) / 255.0, (n & 0xff) / 255.0)
	var f := hud.get_theme_default_font()
	var fs := int(16 * hud_scale)
	if int(e["type"]) == HUD_ELEM_IMAGE_WAYPOINT:
		var tex := ui_texture(e["text"])
		if tex:
			var scale: Vector2 = e["scale"]
			var dst := Vector2(tex.get_width() * scale.x, tex.get_height() * scale.y) * hud_scale
			hud.draw_texture_rect(tex, Rect2(sp - dst / 2.0, dst), false)
		return
	var text: String = e["name"]
	var dist := cam.global_position.distance_to(wp)
	var unit: String = e["text"]
	if unit != "-":
		text += " %d%s" % [int(dist), (" " + unit) if unit != "" else " m"]
	var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	hud.draw_string_outline(f, sp - Vector2(w / 2.0, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, Color(0, 0, 0, 0.7))
	hud.draw_string(f, sp - Vector2(w / 2.0, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
