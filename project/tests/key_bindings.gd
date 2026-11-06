# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## The keyboard bindings (input/key_bindings.gd) and their screen
## (ui/key_bindings_page.gd): Luanti's defaults and key format, saving and
## reading goanna.cfg's [keymap], a key another control has being refused,
## a changed key taking effect in the game's own input handler (the drop
## key above all, whole stack and one item with sneak), the control
## channel's action names and the controller's stand in keys following the
## bindings, and the screen's table at 1280 by 720 and 640 by 360. Headless,
## no server or GPU. It writes user://goanna.cfg:
## XDG_DATA_HOME=$(mktemp -d) godot --headless --path project --script res://tests/key_bindings.gd
extends SceneTree

const KeyBindings := preload("res://input/key_bindings.gd")
const KeyBindingsPage := preload("res://ui/key_bindings_page.gd")
const ControlUI := preload("res://agents/control_ui.gd")
const Pad := preload("res://input/gamepad.gd")

class TestMain extends "res://game/main.gd":
	var drops: Array[String] = []
	func _ready() -> void:
		pass
	func _process(_delta: float) -> void:
		pass
	func pointer_captured(_event: InputEvent = null) -> bool:
		return true
	func _drop_wielded(single: bool) -> void:
		drops.append("Drop %d current_player main %d" % [1 if single else 0, wield])

class StubUI extends CanvasLayer:
	var statuses: Array[String] = []
	var blocked := false
	var inventory_toggles := 0
	func show_status_text(text: String) -> void:
		statuses.append(text)
	func blocks_input() -> bool:
		return blocked
	func toggle_inventory() -> void:
		inventory_toggles += 1

var failures := 0
var checks := 0

func check(ok: bool, what: String) -> void:
	checks += 1
	if ok:
		print("  ok   ", what)
	else:
		failures += 1
		printerr("  FAIL ", what)

func key(code: Key, pressed := true) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = pressed
	return e

func _initialize() -> void:
	if preload("res://tests/scratch_profile.gd").refuse_real_profile():
		quit(2)
		return
	_run.call_deferred()

func _cfg() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.load(KeyBindings.CFG_PATH)
	return cfg

func _run() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(KeyBindings.CFG_PATH))
	KeyBindings.reload()

	print("defaults")
	var want := {"forward": KEY_W, "backward": KEY_S, "left": KEY_A, "right": KEY_D,
		"jump": KEY_SPACE, "sneak": KEY_SHIFT, "aux1": KEY_E, "freemove": KEY_K,
		"inventory": KEY_I, "drop": KEY_Q, "chat": KEY_T, "cmd": KEY_SLASH,
		"camera_mode": KEY_F7, "slot1": KEY_1, "slot9": KEY_9, "slot10": KEY_0}
	for id in want:
		check(KeyBindings.key_of(id) == want[id], "%s defaults to %s" % [id, OS.get_keycode_string(want[id])])
	check(KeyBindings.clashes().is_empty(), "no two defaults share a key")
	var settings := KeyBindings.ACTIONS.map(func(a: Array) -> String: return a[1])
	check(settings.all(func(s: String) -> bool: return s.begins_with("keymap_")),
		"every action is saved under Luanti's keymap_ setting name")

	print("Luanti's key format")
	check(KeyBindings.parse_setting("SYSTEM_SCANCODE_20") == KEY_Q, "SYSTEM_SCANCODE_20 is Q, as Luanti's keymap_drop default")
	check(KeyBindings.parse_setting("KEY_KEY_Q") == KEY_Q, "the Irrlicht name KEY_KEY_Q is Q")
	check(KeyBindings.parse_setting("SYSTEM_SCANCODE_26|GAMEPAD_AXIS_MINUS_1") == KEY_W,
		"a key joined to a controller axis takes the key")
	check(KeyBindings.parse_setting("KEY_LSHIFT") == KEY_SHIFT and KeyBindings.parse_setting("SYSTEM_SCANCODE_229") == KEY_SHIFT,
		"left and right Shift are both Shift")
	check(KeyBindings.parse_setting("MOUSE_BUTTON_1") == -1, "a mouse button is no keyboard key")
	check(KeyBindings.parse_setting("") == KEY_NONE, "an empty value is unset")
	check(KeyBindings.to_setting(KEY_Q) == "SYSTEM_SCANCODE_20", "Q is written as Luanti writes it")
	check(KeyBindings.key_name(KEY_SHIFT) == "Shift" and KeyBindings.key_name(KEY_NONE) == "Not set",
		"key names are for people")

	print("saving")
	check(KeyBindings.set_key("drop", KEY_G) == "", "drop moves to G")
	check(str(_cfg().get_value("keymap", "keymap_drop", "")) == "SYSTEM_SCANCODE_10", "saved as keymap_drop = SYSTEM_SCANCODE_10")
	check(not _cfg().has_section_key("keymap", "keymap_forward"), "an unchanged key is not written")
	KeyBindings.reload()
	check(KeyBindings.key_of("drop") == KEY_G, "G survives a reload")
	var why := KeyBindings.set_key("drop", KEY_W)
	check(why.contains("Move forward") and KeyBindings.key_of("drop") == KEY_G,
		"a key Move forward has is refused, saying so: %s" % why)
	check(KeyBindings.set_key("jump", KEY_ESCAPE) != "" and KeyBindings.key_of("jump") == KEY_SPACE,
		"Escape is refused")
	var cfg := _cfg()
	cfg.set_value("keymap", "keymap_forward", "KEY_KEY_Z")
	cfg.set_value("keymap", "keymap_jump", "KEY_KEY_G")
	cfg.save(KeyBindings.CFG_PATH)
	KeyBindings.reload()
	check(KeyBindings.key_of("forward") == KEY_Z, "a line copied from an older minetest.conf is read")
	check(KeyBindings.clashes().has("jump") and KeyBindings.clashes().has("drop"),
		"a hand edited clash is found on both sides")
	KeyBindings.reset()
	check(not _cfg().has_section("keymap") and KeyBindings.key_of("forward") == KEY_W
		and KeyBindings.key_of("drop") == KEY_Q, "reset removes [keymap] and restores the defaults")

	print("in the game")
	var game := TestMain.new()
	root.add_child(game)
	game.client = GoannaClient.new()
	game.add_child(game.client)
	var ui := StubUI.new()
	game.ui = ui
	game.add_child(ui)
	game.wield = 2
	game._unhandled_input(key(KEY_Q))
	check(game.drops == ["Drop 0 current_player main 2"], "Q drops the wielded stack: %s" % str(game.drops))
	var echo := key(KEY_Q)
	echo.echo = true
	game._unhandled_input(echo)
	check(game.drops.size() == 1, "a held Q repeating drops nothing more, as upstream")
	Input.parse_input_event(key(KEY_SHIFT))
	Input.flush_buffered_events()
	game._unhandled_input(key(KEY_Q))
	check(game.drops.back() == "Drop 1 current_player main 2", "sneak with Q drops one item")
	Input.parse_input_event(key(KEY_SHIFT, false))
	Input.flush_buffered_events()
	ui.blocked = true
	game._unhandled_input(key(KEY_Q))
	check(game.drops.size() == 2, "nothing drops while a window or chat is open")
	ui.blocked = false
	KeyBindings.set_key("drop", KEY_G)
	game._unhandled_input(key(KEY_Q))
	check(game.drops.size() == 2, "Q no longer drops once drop is on G")
	game._unhandled_input(key(KEY_G))
	check(game.drops.size() == 3, "G drops")
	KeyBindings.set_key("camera_mode", KEY_C)
	game._unhandled_input(key(KEY_F7))
	check(game.camera_mode == game.CAMERA_FIRST, "F7 does nothing once the camera is on C")
	game._unhandled_input(key(KEY_C))
	check(game.camera_mode == game.CAMERA_BEHIND and ui.statuses.back().contains("Press C twice"),
		"C changes camera and the hint names C: %s" % ui.statuses.back())
	game._unhandled_input(key(KEY_C))
	game._unhandled_input(key(KEY_C))
	KeyBindings.set_key("slot3", KEY_U)
	game._unhandled_input(key(KEY_U))
	check(game.wield == 2, "U selects hotbar slot 3")
	game._unhandled_input(key(KEY_1))
	check(game.wield == 0, "1 still selects slot 1")
	KeyBindings.set_key("forward", KEY_Z)
	Input.parse_input_event(key(KEY_Z))
	Input.flush_buffered_events()
	check(game._action_held("forward"), "holding Z moves forward")
	Input.parse_input_event(key(KEY_Z, false))
	Input.parse_input_event(key(KEY_W))
	Input.flush_buffered_events()
	check(not game._action_held("forward"), "W no longer moves forward")
	Input.parse_input_event(key(KEY_W, false))
	Input.flush_buffered_events()
	KeyBindings.set_key("aux1", KEY_R)
	game._unhandled_input(key(KEY_R))
	check(ui.inventory_toggles == 1, "the aux1 key opens the inventory with nothing pointed at")

	print("control channel and controller")
	check(ControlUI.action_key("drop") == KEY_G, "the drop action presses the bound key")
	check(ControlUI.action_key("forward") == KEY_Z and ControlUI.action_key("hotbar3") == KEY_U,
		"test actions follow the bindings")
	KeyBindings.clear("drop")
	check(KeyBindings.key_of("drop") == KEY_NONE and ControlUI.action_key("drop") == KEY_Q,
		"an unset action presses its default")
	check(ControlUI.action_key("menu") == KEY_ESCAPE and ControlUI.action_key("F7") == KEY_F7,
		"fixed actions and key names still work")
	check(Pad.stand_in_key("inventory") == KEY_I and Pad.stand_in_key(KEY_ESCAPE) == KEY_ESCAPE,
		"the controller's stand in keys resolve")
	KeyBindings.set_key("inventory", KEY_TAB)
	check(Pad.stand_in_key("inventory") == KEY_TAB, "the controller's inventory button follows the inventory key")
	KeyBindings.set_key("chat", KEY_Y)
	check(Pad.label("talk", "keyboard", "xbox") == "Y", "the talk prompt names the chat key")
	game.free()

	print("the screen")
	KeyBindings.reset()
	for size in [Vector2i(1280, 720), Vector2i(640, 360)]:
		root.size = size
		var scroll := ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		# The width the settings panel gives its page (ui/panel_fit.gd).
		var fit := preload("res://ui/panel_fit.gd").size_for(Vector2(size), true)
		scroll.size = Vector2(fit.x - 56.0 - 38.0, fit.y)
		root.add_child(scroll)
		var page := KeyBindingsPage.new()
		page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(page)
		await process_frame
		await process_frame
		var bad: Array = []
		var keys := 0
		for b in page.find_children("*", "Button", true, false):
			var button := b as Button
			if button.size.y < 39.5:
				bad.append("%s is %.0f high" % [button.text, button.size.y])
			if button.get_global_rect().end.x > scroll.get_global_rect().end.x + 0.5:
				bad.append("%s runs off the side" % button.text)
			var row := button.get_parent()
			if row is HBoxContainer:
				keys += 1
				var label := row.get_child(0) as Label
				if label.get_global_rect().end.x > button.get_global_rect().position.x:
					bad.append("%s runs under its key" % label.text)
				var font := button.get_theme_font("font")
				var fs := button.get_theme_font_size("font_size")
				var text_w := font.get_string_size(button.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				if text_w > button.size.x - 8.0:
					bad.append("key %s is squashed" % button.text)
				if label.get_line_count() > 2:
					bad.append("%s wraps to %d lines" % [label.text, label.get_line_count()])
		check(keys == KeyBindings.ACTIONS.size() + KeyBindings.FIXED.size(),
			"%dx%d: one row per control (%d)" % [size.x, size.y, keys])
		check(bad.is_empty(), "%dx%d: rows fit, 40 px targets, nothing squashed %s" % [size.x, size.y, str(bad)])
		scroll.free()
	var page := KeyBindingsPage.new()
	root.add_child(page)
	await process_frame
	var labels := page.find_children("*", "Label", true, false).map(func(l) -> String: return l.text)
	check(not labels.any(func(t: String) -> bool: return t.begins_with("keymap_")), "no setting names on the screen")
	var drop_button: Button = page._buttons["drop"]
	drop_button.pressed.emit()
	check(page.capturing == "drop" and drop_button.text == "Press a key", "choosing a key waits for one")
	Input.parse_input_event(key(KEY_G))
	Input.flush_buffered_events()
	await process_frame
	check(KeyBindings.key_of("drop") == KEY_G and drop_button.text == "G", "pressing G puts drop on G")
	(page._buttons["jump"] as Button).pressed.emit()
	Input.parse_input_event(key(KEY_G))
	Input.flush_buffered_events()
	await process_frame
	check(KeyBindings.key_of("jump") == KEY_SPACE and page.status.visible and page.status.text.contains("Drop item"),
		"G for jump is refused, naming Drop item: %s" % page.status.text)
	(page._buttons["jump"] as Button).pressed.emit()
	Input.parse_input_event(key(KEY_ESCAPE))
	Input.flush_buffered_events()
	await process_frame
	check(page.capturing == "" and KeyBindings.key_of("jump") == KEY_SPACE, "Escape cancels")
	var fixed: Array = page.find_children("*", "Button", true, false).filter(func(b) -> bool: return b.has_meta("fixed"))
	check(fixed.size() == KeyBindings.FIXED.size(), "the fixed controls are listed")
	(fixed[0] as Button).pressed.emit()
	check(page.status.text == KeyBindings.FIXED[0][3], "pressing a fixed one says why")
	page.reset_button.pressed.emit()
	check(KeyBindings.key_of("drop") == KEY_Q and drop_button.text == "Q", "Reset to defaults puts drop back on Q")
	page.free()
	await process_frame

	print("the in-game settings")
	root.size = Vector2i(1280, 720)
	OS.set_environment("GOANNA_NO_POINTER_CAPTURE", "1")
	OS.set_environment("GOANNA_NO_STORE", "1")
	var real := preload("res://game/main.tscn").instantiate()
	real.connect_automatically = false
	root.add_child(real)
	await process_frame
	await process_frame
	var panel: Control = real.ui._build_settings()
	panel.visible = true
	await process_frame
	var titles: Array = []
	for tabs in panel.find_children("*", "TabContainer", true, false):
		for i in tabs.get_tab_count():
			titles.append(tabs.get_tab_title(i))
	var at := titles.find("Key bindings")
	check(at > 0 and titles[at - 1] == "Controls", "the pause menu's settings have a Key bindings tab after Controls: %s" % str(titles))
	check(panel.find_children("KeyBindings", "", true, false).size() == 1, "holding the key table")
	panel.queue_free()
	real.queue_free()
	await process_frame
	print("key bindings: %d checks, %s" % [checks, "FAIL (%d)" % failures if failures else "PASS"])
	quit(1 if failures else 0)
