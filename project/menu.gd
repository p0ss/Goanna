# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Goanna's main menu: start a local singleplayer game (Goanna launches an
# ordinary Luanti server in the background and joins it), or join a remote
# server. Both hand off to the game scene through the GOANNA_* environment
# variables main.gd reads. The menu steps aside when the environment already
# says where to go (GOANNA_HOST/GOANNA_NAME or a test mode); GOANNA_MENU=1
# forces it. Server address, port and name are remembered in user://goanna.cfg;
# the password is not.
extends Control

const CFG_PATH := "user://goanna.cfg"
const LocalServer := preload("res://local_server.gd")
const SKIP_VARS := ["GOANNA_HOST", "GOANNA_NAME", "GOANNA_SHOT", "GOANNA_SMOKE",
	"GOANNA_WALKTEST", "GOANNA_TOGGLETEST", "GOANNA_ANIMPROBE", "GOANNA_MOBTEST",
	"GOANNA_USETEST", "GOANNA_MINETEST", "GOANNA_DIGDOWNTEST", "GOANNA_MANTLETEST"]

var screen: VBoxContainer
var status_label: Label
# join form
var host_edit: LineEdit
var port_edit: LineEdit
var name_edit: LineEdit
var pass_edit: LineEdit
var connect_button: Button
# new game
var game_option: OptionButton
var world_edit: LineEdit
var start_button: Button
var server  # GoannaLocalServer (local_server.gd)
var server_deadline := 0.0

func _ready() -> void:
	set_process(false)
	if OS.get_environment("GOANNA_MENU") == "":
		for v in SKIP_VARS:
			if OS.get_environment(v) != "":
				_go_to_game()
				return
	_build_frame()
	_show_main()
	if OS.get_environment("GOANNA_LOCAL_TEST") != "":
		# Development aid: "game:world" starts a local game and joins it.
		var gw := OS.get_environment("GOANNA_LOCAL_TEST").split(":")
		_show_new_game()
		await get_tree().process_frame
		for i in game_option.item_count:
			if game_option.get_item_text(i) == gw[0]:
				game_option.select(i)
		world_edit.text = gw[1] if gw.size() > 1 else "sp_test"
		_on_start_local()
		return
	if OS.get_environment("GOANNA_MENU_SHOT") != "":
		if OS.get_environment("GOANNA_MENU_SCREEN") == "new":
			_show_new_game()
		elif OS.get_environment("GOANNA_MENU_SCREEN") == "join":
			_show_join()
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(OS.get_environment("GOANNA_MENU_SHOT"))
		get_tree().quit()

# --- frame shared by all screens ---------------------------------------------

var _panel_box: VBoxContainer

func _build_frame() -> void:
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
		margin.add_theme_constant_override(side, 28)
	panel.add_child(margin)
	_panel_box = VBoxContainer.new()
	_panel_box.add_theme_constant_override("separation", 12)
	_panel_box.custom_minimum_size = Vector2(440, 0)
	margin.add_child(_panel_box)

func _new_screen(title: String, subtitle: String) -> void:
	for c in _panel_box.get_children():
		c.queue_free()
	var t := Label.new()
	t.text = "Goanna"
	t.add_theme_font_size_override("font_size", 30)
	_panel_box.add_child(t)
	if title != "":
		var h := Label.new()
		h.text = title
		h.add_theme_font_size_override("font_size", 18)
		h.modulate = Color(1, 1, 1, 0.85)
		_panel_box.add_child(h)
	if subtitle != "":
		var s := Label.new()
		s.text = subtitle
		s.modulate = Color(1, 1, 1, 0.6)
		s.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_panel_box.add_child(s)
	screen = VBoxContainer.new()
	screen.add_theme_constant_override("separation", 8)
	_panel_box.add_child(screen)
	status_label = Label.new()
	status_label.modulate = Color(1, 1, 1, 0.6)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel_box.add_child(status_label)

func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	return b

func _fail(msg: String) -> void:
	status_label.text = msg
	status_label.modulate = Color(1, 0.6, 0.5)

# --- main screen -------------------------------------------------------------

func _show_main() -> void:
	_new_screen("", "A Godot client for Luanti worlds.")
	screen.add_child(_button("Start a local game", _show_new_game))
	screen.add_child(_button("Join a server", _show_join))
	screen.add_child(_button("Quit", func() -> void: get_tree().quit()))

# --- new local game ----------------------------------------------------------

func _show_new_game() -> void:
	_new_screen("Start a local game", "Goanna runs a Luanti server on your machine and joins it.")
	var env := LocalServer.detect()
	if env.is_empty():
		_fail("No Luanti server found. Install Luanti, or the org.luanti.luanti flatpak, or set GOANNA_SERVER_CMD.")
		screen.add_child(_button("Back", _show_main))
		return
	var games: Array = LocalServer.list_games(env["data_dir"])
	if games.is_empty():
		_fail("No games are installed for Luanti. Install a game (devtest, Mineclonia, ...) first.")
		screen.add_child(_button("Back", _show_main))
		return
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 8)
	screen.add_child(grid)
	var glabel := Label.new()
	glabel.text = "Game"
	grid.add_child(glabel)
	game_option = OptionButton.new()
	for g in games:
		game_option.add_item(g)
	grid.add_child(game_option)
	world_edit = _labelled_edit(grid, "World name", "my_world")
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	world_edit.text = str(cfg.get_value("local", "world", "my_world"))
	var last_game := str(cfg.get_value("local", "game", ""))
	for i in games.size():
		if games[i] == last_game:
			game_option.select(i)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	screen.add_child(row)
	row.add_child(_button("Back", _show_main))
	start_button = _button("Start", _on_start_local)
	row.add_child(start_button)
	world_edit.text_submitted.connect(func(_t): _on_start_local())

func _on_start_local() -> void:
	var game := game_option.get_item_text(game_option.selected)
	var world := world_edit.text.strip_edges()
	# A world belongs to the game that made it. Loading it under another
	# game leaves every stored node unknown (a world of pink "unknown
	# node" blocks), so continue an existing world with its own game.
	var data_dir: String = LocalServer.data_dir_or_empty()
	if data_dir != "" and world != "":
		var existing: String = LocalServer.world_gameid(data_dir, world)
		if existing != "" and existing != game:
			_fail("The world \"%s\" was created with %s, so it opens with %s."
				% [world, existing, existing])
			game = existing
			for i in game_option.item_count:
				if game_option.get_item_text(i) == existing:
					game_option.select(i)
	if world == "":
		world = "my_world"
	var allowed := RegEx.new()
	allowed.compile("^[A-Za-z0-9_ -]{1,40}$")
	if allowed.search(world) == null:
		_fail("World names are 1 to 40 characters: letters, digits, spaces, _ and -.")
		return
	# Scripted runs must not touch the player's remembered choices: a test
	# world would otherwise turn up prefilled the next time they open the menu.
	if OS.get_environment("GOANNA_LOCAL_TEST") == "":
		var cfg := ConfigFile.new()
		cfg.load(CFG_PATH)
		cfg.set_value("local", "game", game)
		cfg.set_value("local", "world", world)
		cfg.save(CFG_PATH)
	server = LocalServer.new()
	var err: String = server.start(game, world, _local_player_name())
	if err != "":
		_fail(err)
		return
	start_button.disabled = true
	status_label.modulate = Color(1, 1, 1, 0.7)
	status_label.text = "Starting %s ..." % game
	server_deadline = _now() + 20.0
	set_process(true)

func _process(_delta: float) -> void:
	if server == null:
		set_process(false)
		return
	var st: String = server.poll_ready()
	if st == "ready":
		set_process(false)
		status_label.text = "Joining ..."
		OS.set_environment("GOANNA_HOST", "127.0.0.1")
		OS.set_environment("GOANNA_PORT", str(server.port))
		OS.set_environment("GOANNA_NAME", _local_player_name())
		OS.set_environment("GOANNA_PASS", "")
		# the game scene stops this server on exit
		OS.set_environment("GOANNA_SP_PID", str(server.pid))
		OS.set_environment("GOANNA_SP_MATCH", server.world_path)
		_go_to_game()
	elif st != "starting":
		set_process(false)
		server.stop()
		server = null
		_fail(st)
		start_button.disabled = false
	elif _now() > server_deadline:
		set_process(false)
		server.stop()
		server = null
		_fail("The server did not start in time. See %s." % server.log_path if server else "the server log.")
		if start_button:
			start_button.disabled = false

func _local_player_name() -> String:
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	var n := str(cfg.get_value("player", "name", ""))
	return n if n != "" else "player"

# --- join a server -----------------------------------------------------------

func _show_join() -> void:
	_new_screen("Join a server", "")
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 8)
	screen.add_child(grid)
	host_edit = _labelled_edit(grid, "Server address", "127.0.0.1")
	port_edit = _labelled_edit(grid, "Port", "30000")
	name_edit = _labelled_edit(grid, "Player name", "")
	pass_edit = _labelled_edit(grid, "Password", "")
	pass_edit.secret = true
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) == OK:
		host_edit.text = str(cfg.get_value("server", "host", ""))
		port_edit.text = str(cfg.get_value("server", "port", ""))
		name_edit.text = str(cfg.get_value("player", "name", ""))
	if OS.get_environment("GOANNA_PORT") != "":
		port_edit.text = OS.get_environment("GOANNA_PORT")
	status_label.text = "On a server that allows registration, a new name is registered with this password."
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	screen.add_child(row)
	row.add_child(_button("Back", _show_main))
	connect_button = _button("Connect", _on_connect)
	row.add_child(connect_button)
	for e in [host_edit, port_edit, name_edit, pass_edit]:
		e.text_submitted.connect(func(_t): _on_connect())
	name_edit.grab_focus()

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
	var allowed := RegEx.new()
	allowed.compile("^[A-Za-z0-9_-]{1,20}$")
	if allowed.search(pname) == null:
		_fail("Player names are 1 to 20 characters: letters, digits, _ and -.")
		return
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value("server", "host", host)
	cfg.set_value("server", "port", port_text)
	cfg.set_value("player", "name", pname)
	cfg.save(CFG_PATH)
	OS.set_environment("GOANNA_HOST", host)
	OS.set_environment("GOANNA_PORT", port_text)
	OS.set_environment("GOANNA_NAME", pname)
	OS.set_environment("GOANNA_PASS", pass_edit.text)
	OS.set_environment("GOANNA_SP_PID", "")
	connect_button.disabled = true
	status_label.modulate = Color(1, 1, 1, 0.7)
	status_label.text = "Connecting to %s:%s as %s" % [host, port_text, pname]
	_go_to_game()

# --- helpers -----------------------------------------------------------------

func _labelled_edit(grid: GridContainer, label_text: String, placeholder: String) -> LineEdit:
	var label := Label.new()
	label.text = label_text
	grid.add_child(label)
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.custom_minimum_size = Vector2(260, 0)
	grid.add_child(edit)
	return edit

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _go_to_game() -> void:
	get_tree().change_scene_to_file.call_deferred("res://main.tscn")
