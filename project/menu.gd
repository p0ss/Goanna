# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Connection menu. Collects host, port, player name and password, hands them
# to the game scene through the GOANNA_* environment variables main.gd
# already reads, and switches to main.tscn. Nothing else in the project
# needs to know the menu exists.
#
# The menu steps aside when the environment already says where to go:
# GOANNA_HOST or GOANNA_NAME set (the documented command line recipe), or
# any of the test modes. GOANNA_MENU=1 forces the menu regardless.
#
# Host, port and name are remembered in user://goanna.cfg. The password is
# not stored.
extends Control

const CFG_PATH := "user://goanna.cfg"
const SKIP_VARS := ["GOANNA_HOST", "GOANNA_NAME", "GOANNA_SHOT", "GOANNA_SMOKE",
	"GOANNA_WALKTEST", "GOANNA_TOGGLETEST"]

var host_edit: LineEdit
var port_edit: LineEdit
var name_edit: LineEdit
var pass_edit: LineEdit
var status_label: Label
var connect_button: Button

func _ready() -> void:
	if OS.get_environment("GOANNA_MENU") == "":
		for v in SKIP_VARS:
			if OS.get_environment(v) != "":
				_start_game()
				return
	_build()
	_load_saved()
	if OS.get_environment("GOANNA_MENU_SHOT") != "":
		# Development aid: render one frame, save it, quit.
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(OS.get_environment("GOANNA_MENU_SHOT"))
		get_tree().quit()
	if OS.get_environment("GOANNA_MENU_TEST") != "":
		# Development aid: "host:port:name:pass" fills the form and presses
		# Connect, so the menu to game hand-over can be exercised from a script.
		var f := OS.get_environment("GOANNA_MENU_TEST").split(":")
		host_edit.text = f[0]
		port_edit.text = f[1]
		name_edit.text = f[2]
		pass_edit.text = f[3] if f.size() > 3 else ""
		await get_tree().process_frame
		_on_connect()

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.11, 0.13)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(centre)

	var panel := PanelContainer.new()
	centre.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 24)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.custom_minimum_size = Vector2(420, 0)
	margin.add_child(box)

	var title := Label.new()
	title.text = "Goanna"
	title.add_theme_font_size_override("font_size", 28)
	box.add_child(title)
	var sub := Label.new()
	sub.text = "Connect to a Luanti server"
	sub.modulate = Color(1, 1, 1, 0.7)
	box.add_child(sub)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 8)
	box.add_child(grid)
	host_edit = _row(grid, "Server address", "127.0.0.1")
	port_edit = _row(grid, "Port", "30000")
	name_edit = _row(grid, "Player name", "")
	pass_edit = _row(grid, "Password", "")
	pass_edit.secret = true

	status_label = Label.new()
	status_label.text = "On a server that allows registration, a new name is registered with this password."
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.modulate = Color(1, 1, 1, 0.6)
	box.add_child(status_label)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	box.add_child(buttons)
	var quit_button := Button.new()
	quit_button.text = "Quit"
	quit_button.pressed.connect(func() -> void: get_tree().quit())
	buttons.add_child(quit_button)
	connect_button = Button.new()
	connect_button.text = "Connect"
	connect_button.pressed.connect(_on_connect)
	buttons.add_child(connect_button)

	for e in [host_edit, port_edit, name_edit, pass_edit]:
		e.text_submitted.connect(func(_t: String) -> void: _on_connect())
	name_edit.grab_focus()

func _row(grid: GridContainer, label_text: String, placeholder: String) -> LineEdit:
	var label := Label.new()
	label.text = label_text
	grid.add_child(label)
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.custom_minimum_size = Vector2(260, 0)
	grid.add_child(edit)
	return edit

func _load_saved() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) == OK:
		host_edit.text = str(cfg.get_value("server", "host", ""))
		port_edit.text = str(cfg.get_value("server", "port", ""))
		name_edit.text = str(cfg.get_value("player", "name", ""))
	# Environment values win over the saved ones, so a partially specified
	# command line still prefills the form.
	if OS.get_environment("GOANNA_PORT") != "":
		port_edit.text = OS.get_environment("GOANNA_PORT")
	if OS.get_environment("GOANNA_PASS") != "":
		pass_edit.text = OS.get_environment("GOANNA_PASS")

func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("server", "host", host_edit.text.strip_edges())
	cfg.set_value("server", "port", port_edit.text.strip_edges())
	cfg.set_value("player", "name", name_edit.text.strip_edges())
	cfg.save(CFG_PATH)

func _on_connect() -> void:
	var host := host_edit.text.strip_edges()
	if host == "":
		host = "127.0.0.1"
	var port_text := port_edit.text.strip_edges()
	if port_text == "":
		port_text = "30000"
	if not port_text.is_valid_int() or int(port_text) < 1 or int(port_text) > 65535:
		_fail("Port must be a number between 1 and 65535.")
		return
	var pname := name_edit.text.strip_edges()
	if pname == "":
		_fail("Enter a player name.")
		return
	# Luanti's own rule for player names (string_allowed with PLAYERNAME_ALLOWED_CHARS).
	var allowed := RegEx.new()
	allowed.compile("^[A-Za-z0-9_-]{1,20}$")
	if allowed.search(pname) == null:
		_fail("Player names are 1 to 20 characters: letters, digits, _ and -.")
		return
	_save()
	OS.set_environment("GOANNA_HOST", host)
	OS.set_environment("GOANNA_PORT", port_text)
	OS.set_environment("GOANNA_NAME", pname)
	OS.set_environment("GOANNA_PASS", pass_edit.text)
	connect_button.disabled = true
	status_label.text = "Connecting to %s:%s as %s" % [host, port_text, pname]
	_start_game()

func _fail(msg: String) -> void:
	status_label.text = msg
	status_label.modulate = Color(1, 0.6, 0.5)

func _start_game() -> void:
	get_tree().change_scene_to_file.call_deferred("res://main.tscn")
