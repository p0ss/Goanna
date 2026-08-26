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
var world_option: OptionButton
var world_edit: LineEdit
var generator_option: OptionButton
var creative_check: CheckBox
var damage_check: CheckBox
var host_check: CheckBox
var hosting_box: VBoxContainer
var server_name_edit: LineEdit
var server_description_edit: LineEdit
var server_password_edit: LineEdit
var server_port_edit: LineEdit
var announce_check: CheckBox
var max_players_spin: SpinBox
var mod_checks := {}
var delete_button: Button
var _local_data_dir := ""
var _local_join_password := ""
var start_button: Button
var terrain_download_label: Label
var terrain_http: HTTPRequest
var _terrain_archive_path := ""
var _pending_terrain_start := false
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
		var want := OS.get_environment("GOANNA_MENU_SCREEN")
		if want == "new":
			_show_new_game()
		elif want == "join":
			_show_join()
		elif want == "content":
			_show_content()
		elif want == "settings":
			_show_settings()
		elif want == "about":
			_show_about()
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		if want == "join":
			# The public list is a network round trip; shooting the screen
			# before it lands photographs the "Fetching ..." placeholder.
			await get_tree().create_timer(6.0).timeout
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
	screen.add_child(_button("Start Game", _show_new_game))
	screen.add_child(_button("Join Game", _show_join))
	screen.add_child(_button("Content", _show_content))
	screen.add_child(_button("Settings", _show_settings))
	screen.add_child(_button("About", _show_about))
	screen.add_child(_button("Quit", func() -> void: get_tree().quit()))

# --- content -----------------------------------------------------------------

# Read only, on purpose. Goanna does not own any of this: it borrows the Luanti
# install it detected, and Start Game can only offer what that install carries.
# Installing content is Luanti's own menu's job, and writing into another
# application's data directories from here would be presumptuous.
func _show_content() -> void:
	_new_screen("Content", "What the Luanti install Goanna found already has. Goanna does not install content; use Luanti's own menu for that.")
	var data_dir := LocalServer.data_dir_or_empty()
	if data_dir == "":
		_fail("No Luanti install found. Install Luanti, or the org.luanti.luanti flatpak, or set GOANNA_SERVER_CMD.")
		screen.add_child(_button("Back", _show_main))
		return
	var sections := [
		["Games", LocalServer.list_games(data_dir)],
		["Mods", LocalServer.list_mods(data_dir)],
		["Texture packs", LocalServer.list_texture_packs(data_dir)],
	]
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 320)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	screen.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 4)
	scroll.add_child(box)
	for sec in sections:
		var head := Label.new()
		head.text = "%s (%d)" % [sec[0], (sec[1] as Array).size()]
		head.add_theme_font_size_override("font_size", 16)
		box.add_child(head)
		if (sec[1] as Array).is_empty():
			var none := Label.new()
			none.text = "    none"
			none.modulate = Color(1, 1, 1, 0.5)
			box.add_child(none)
			continue
		for item in sec[1]:
			var l := Label.new()
			l.text = "    " + str(item)
			l.modulate = Color(1, 1, 1, 0.8)
			box.add_child(l)
	status_label.text = data_dir
	screen.add_child(_button("Back", _show_main))

# --- settings ----------------------------------------------------------------

# The same table the in-game panel drives (ui/game_ui.gd, SETTINGS), so the two
# cannot drift apart. There is no client yet at this point, so nothing can be
# applied live: values are written to the settings section of goanna.cfg, which
# game_ui reloads and applies on the next connect. That is the same file and
# the same section it writes to itself.
const GameUI := preload("res://ui/game_ui.gd")

func _show_settings() -> void:
	_new_screen("Settings", "Applied when you next join a world. The pause menu has the same settings, and changes there take effect immediately.")
	var tabs := TabContainer.new()
	tabs.custom_minimum_size = Vector2(560, 360)
	screen.add_child(tabs)
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	var pages := {}
	for row in GameUI.SETTINGS:
		var tab := str(row[0])
		if not pages.has(tab):
			var scroll := ScrollContainer.new()
			scroll.name = tab
			scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			var box := VBoxContainer.new()
			box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			box.add_theme_constant_override("separation", 10)
			scroll.add_child(box)
			tabs.add_child(scroll)
			pages[tab] = box
		_settings_row(pages[tab], row, cfg)
	screen.add_child(_button("Back", _show_main))

func _settings_row(box: VBoxContainer, row: Array, cfg: ConfigFile) -> void:
	var key := str(row[1])
	var kind := str(row[2])
	var known: bool = cfg.has_section_key("settings", key)
	var label := Label.new()
	label.text = str(row[3])
	box.add_child(label)
	if kind == "path":
		# A folder, not a number: stored as a string, and the only setting in
		# the table that is. Empty means the server's own art, which is what
		# the client reports as "no texture pack set" when it starts.
		var pe := LineEdit.new()
		pe.text = str(cfg.get_value("settings", key, ""))
		pe.placeholder_text = "none: use the server's own textures"
		pe.text_changed.connect(func(t: String) -> void: _save_setting_text(key, t))
		box.add_child(pe)
		var pd := Label.new()
		pd.text = str(row[4])
		pd.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		pd.modulate = Color(1, 1, 1, 0.55)
		box.add_child(pd)
		return
	var current: float = float(cfg.get_value("settings", key, _settings_default(row)))
	if kind == "toggle":
		var cb := CheckBox.new()
		cb.text = "on"
		cb.button_pressed = current > 0.5
		cb.toggled.connect(func(on: bool) -> void: _save_setting(key, 1.0 if on else 0.0))
		box.add_child(cb)
	else:
		var h := HBoxContainer.new()
		var sl := HSlider.new()
		sl.min_value = float(row[5])
		sl.max_value = float(row[6])
		sl.step = float(row[7])
		sl.value = current
		sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var val := Label.new()
		val.text = str(current)
		val.custom_minimum_size = Vector2(56, 0)
		sl.value_changed.connect(func(v: float) -> void:
			val.text = str(snappedf(v, float(row[7])))
			_save_setting(key, v))
		h.add_child(sl)
		h.add_child(val)
		box.add_child(h)
	var desc := Label.new()
	desc.text = str(row[4])
	if not known:
		# The client records what it is actually running with the first time a
		# world is joined (ui/game_ui.gd, _load_apply_settings). Until then the
		# menu has nothing to read and is showing a placeholder, so say so
		# rather than presenting a guess as the current state.
		desc.text += "\n(not recorded yet: join a world once, or set it here)"
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.modulate = Color(1, 1, 1, 0.55)
	box.add_child(desc)

# Placeholder for a setting goanna.cfg has never carried, which happens only
# before the first world is joined: after that the in-game panel has recorded
# what the client is really running with. A slider sits at its own midpoint
# rather than at zero, and the row says it is not recorded yet, because a
# confident wrong number is worse than an obvious placeholder.
func _settings_default(row: Array) -> float:
	if str(row[2]) == "toggle":
		return 1.0
	return float(row[5]) + (float(row[6]) - float(row[5])) * 0.5

func _save_setting(key: String, value: float) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)  # keep the server and player sections
	cfg.set_value("settings", key, value)
	cfg.save(CFG_PATH)

func _save_setting_text(key: String, value: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value("settings", key, value)
	cfg.save(CFG_PATH)

# --- about -------------------------------------------------------------------

func _show_about() -> void:
	_new_screen("About", "")
	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.modulate = Color(1, 1, 1, 0.85)
	body.text = """Goanna is a second client for Luanti servers: the same worlds and the same games, drawn with Godot 4 instead of Luanti's own renderer. It carries Luanti's client logic for networking, movement and node meshing, and replaces only what Irrlicht used to provide.

Goanna is an independent project. It is not affiliated with, endorsed by or supported by the Luanti project. The name "Luanti" is used only to identify the software Goanna interoperates with.

It connects to unmodified servers over the ordinary protocol and asks for nothing a vanilla client does not ask for.

Licence: LGPL-2.1-or-later, matching the Luanti client code it carries. godot-cpp is MIT. See LICENSE and THIRD-PARTY.md."""
	screen.add_child(body)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	screen.add_child(grid)
	var data_dir := LocalServer.data_dir_or_empty()
	for row in [["Godot", Engine.get_version_info().get("string", "unknown")],
			["Luanti core", "5.16.1"],
			["Settings", CFG_PATH],
			["Luanti data", data_dir if data_dir != "" else "not found"]]:
		var k := Label.new()
		k.text = str(row[0])
		k.modulate = Color(1, 1, 1, 0.6)
		grid.add_child(k)
		var v := Label.new()
		v.text = str(row[1])
		grid.add_child(v)
	screen.add_child(_button("Back", _show_main))

# --- new local game ----------------------------------------------------------

func _show_new_game() -> void:
	_new_screen("Start Game", "Choose a world, its game and map generator, or host it for other players.")
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
	_local_data_dir = env["data_dir"]
	var tabs := TabContainer.new()
	tabs.custom_minimum_size = Vector2(650, 470)
	screen.add_child(tabs)
	var world_scroll := ScrollContainer.new()
	world_scroll.name = "World"
	world_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(world_scroll)
	var world_page := VBoxContainer.new()
	world_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	world_page.add_theme_constant_override("separation", 8)
	world_scroll.add_child(world_page)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 8)
	world_page.add_child(grid)
	var wlabel := Label.new()
	wlabel.text = "World"
	grid.add_child(wlabel)
	world_option = OptionButton.new()
	world_option.add_item("Create new world ...")
	world_option.set_item_metadata(0, {})
	for entry in LocalServer.list_worlds(_local_data_dir):
		world_option.add_item(str(entry["name"]))
		world_option.set_item_metadata(world_option.item_count - 1, entry)
	grid.add_child(world_option)
	world_edit = _labelled_edit(grid, "New world name", "my_world")
	var glabel := Label.new()
	glabel.text = "Game"
	grid.add_child(glabel)
	game_option = OptionButton.new()
	for g in games:
		game_option.add_item(g)
		game_option.set_item_metadata(game_option.item_count - 1, g)
	grid.add_child(game_option)
	var gen_label := Label.new()
	gen_label.text = "World generator"
	grid.add_child(gen_label)
	generator_option = OptionButton.new()
	generator_option.add_item("Game default")
	generator_option.set_item_metadata(0, "default")
	generator_option.add_item("Terrain Diffusion, default 1 m world")
	generator_option.set_item_metadata(1, "terrain_default")
	generator_option.add_item("Terrain Diffusion, generate new (setup required)")
	generator_option.set_item_metadata(2, "terrain_generate")
	generator_option.set_item_disabled(2, true)
	grid.add_child(generator_option)
	terrain_download_label = Label.new()
	terrain_download_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	terrain_download_label.modulate = Color(1, 1, 1, 0.6)
	world_page.add_child(terrain_download_label)
	creative_check = CheckBox.new()
	creative_check.text = "Creative mode"
	world_page.add_child(creative_check)
	damage_check = CheckBox.new()
	damage_check.text = "Enable damage"
	damage_check.button_pressed = true
	world_page.add_child(damage_check)
	var compatibility := Label.new()
	compatibility.text = "Terrain Diffusion uses any game's registered biomes. Mineclonia currently has the fullest vegetation support."
	compatibility.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	compatibility.modulate = Color(1, 1, 1, 0.55)
	world_page.add_child(compatibility)

	var mods_scroll := ScrollContainer.new()
	mods_scroll.name = "Mods"
	mods_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(mods_scroll)
	var mods_page := VBoxContainer.new()
	mods_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mods_page.add_theme_constant_override("separation", 5)
	mods_scroll.add_child(mods_page)
	var mods := LocalServer.list_mods(_local_data_dir)
	if mods.is_empty():
		var none := Label.new()
		none.text = "No separately installed mods were found. Game-bundled mods are managed by the game."
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		mods_page.add_child(none)
	else:
		for mod in mods:
			var check := CheckBox.new()
			check.text = str(mod)
			mods_page.add_child(check)
			mod_checks[str(mod)] = check

	var host_scroll := ScrollContainer.new()
	host_scroll.name = "Hosting"
	host_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(host_scroll)
	var host_page := VBoxContainer.new()
	host_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host_page.add_theme_constant_override("separation", 8)
	host_scroll.add_child(host_page)
	host_check = CheckBox.new()
	host_check.text = "Host this world for other players"
	host_page.add_child(host_check)
	hosting_box = VBoxContainer.new()
	hosting_box.add_theme_constant_override("separation", 8)
	host_page.add_child(hosting_box)
	var host_grid := GridContainer.new()
	host_grid.columns = 2
	host_grid.add_theme_constant_override("h_separation", 12)
	host_grid.add_theme_constant_override("v_separation", 8)
	hosting_box.add_child(host_grid)
	server_name_edit = _labelled_edit(host_grid, "Server name", "My Goanna server")
	server_description_edit = _labelled_edit(host_grid, "Description", "")
	server_password_edit = _labelled_edit(host_grid, "Server password", "")
	server_password_edit.secret = true
	server_port_edit = _labelled_edit(host_grid, "Port", "30000")
	var max_label := Label.new()
	max_label.text = "Maximum players"
	host_grid.add_child(max_label)
	max_players_spin = SpinBox.new()
	max_players_spin.min_value = 1
	max_players_spin.max_value = 100
	max_players_spin.value = 8
	host_grid.add_child(max_players_spin)
	announce_check = CheckBox.new()
	announce_check.text = "Announce on the public Luanti server list"
	hosting_box.add_child(announce_check)
	var warning := Label.new()
	warning.text = "Announcing exposes the server publicly. Your network may also require port forwarding."
	warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warning.modulate = Color(1, 0.8, 0.55, 0.8)
	hosting_box.add_child(warning)
	hosting_box.visible = false
	host_check.toggled.connect(func(on: bool) -> void: hosting_box.visible = on)

	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	world_edit.text = str(cfg.get_value("local", "world", "my_world"))
	var last_game := str(cfg.get_value("local", "game", ""))
	for i in game_option.item_count:
		if str(game_option.get_item_metadata(i)) == last_game:
			game_option.select(i)
	for i in world_option.item_count:
		if world_option.get_item_text(i) == world_edit.text:
			world_option.select(i)
			break
	host_check.button_pressed = bool(cfg.get_value("local_host", "enabled", false))
	hosting_box.visible = host_check.button_pressed
	server_name_edit.text = str(cfg.get_value("local_host", "name", "My Goanna server"))
	server_description_edit.text = str(cfg.get_value("local_host", "description", ""))
	server_port_edit.text = str(cfg.get_value("local_host", "port", "30000"))
	announce_check.button_pressed = bool(cfg.get_value("local_host", "announce", false))
	max_players_spin.value = int(cfg.get_value("local_host", "max_players", 8))
	world_option.item_selected.connect(_on_world_selected)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	screen.add_child(row)
	row.add_child(_button("Back", _show_main))
	delete_button = _button("Delete world", _confirm_delete_world)
	row.add_child(delete_button)
	start_button = _button("Start", _on_start_local)
	row.add_child(start_button)
	generator_option.item_selected.connect(func(_index: int) -> void:
		_refresh_terrain_download_state())
	_on_world_selected(world_option.selected)
	_refresh_terrain_download_state()
	world_edit.text_submitted.connect(func(_t): _on_start_local())

func _on_world_selected(index: int) -> void:
	var entry: Dictionary = world_option.get_item_metadata(index)
	var is_new := entry.is_empty()
	world_edit.editable = is_new
	world_edit.visible = is_new
	if delete_button:
		delete_button.visible = not is_new
	game_option.disabled = not is_new
	generator_option.disabled = not is_new
	if is_new:
		for check in mod_checks.values():
			(check as CheckBox).button_pressed = false
		_refresh_terrain_download_state()
		return
	var name := str(entry.get("name", ""))
	world_edit.text = name
	var options := LocalServer.world_options(_local_data_dir, name)
	var gid := str(options.get("gameid", ""))
	for i in game_option.item_count:
		if str(game_option.get_item_metadata(i)) == gid:
			game_option.select(i)
			break
	generator_option.select(1 if bool(options.get("terrain_diffusion", false)) else 0)
	creative_check.button_pressed = bool(options.get("creative", false))
	damage_check.button_pressed = bool(options.get("damage", true))
	var selected_mods: Array = options.get("mods", [])
	for mod in mod_checks:
		(mod_checks[mod] as CheckBox).button_pressed = selected_mods.has(mod)
	_refresh_terrain_download_state()

func _refresh_terrain_download_state() -> void:
	if not is_instance_valid(terrain_download_label) or not is_instance_valid(generator_option):
		return
	var wants_default := str(generator_option.get_item_metadata(generator_option.selected)) == "terrain_default"
	terrain_download_label.visible = wants_default and not generator_option.disabled
	if not wants_default:
		return
	if LocalServer.default_terrain_cached():
		terrain_download_label.text = "Default terrain is downloaded and ready."
		if is_instance_valid(start_button):
			start_button.text = "Start"
	else:
		terrain_download_label.text = "One-time download required: %.1f MB. It will be reused by future worlds." % (LocalServer.DEFAULT_TERRAIN_DOWNLOAD_BYTES / 1000000.0)
		if is_instance_valid(start_button):
			start_button.text = "Download & Start"

func _start_terrain_download() -> void:
	if terrain_http != null:
		return
	var downloads := ProjectSettings.globalize_path("user://content/downloads")
	DirAccess.make_dir_recursive_absolute(downloads)
	_terrain_archive_path = downloads.path_join(LocalServer.DEFAULT_TERRAIN_ID + ".zip.part")
	DirAccess.remove_absolute(_terrain_archive_path)
	terrain_http = HTTPRequest.new()
	terrain_http.download_file = _terrain_archive_path
	add_child(terrain_http)
	terrain_http.request_completed.connect(_on_terrain_download_completed)
	var err := terrain_http.request(LocalServer.DEFAULT_TERRAIN_URL)
	if err != OK:
		terrain_http.queue_free()
		terrain_http = null
		_pending_terrain_start = false
		_fail("Could not start the Terrain Diffusion download.")
		return
	start_button.disabled = true
	status_label.modulate = Color(1, 1, 1, 0.7)
	status_label.text = "Downloading Terrain Diffusion default world ..."
	set_process(true)

func _on_terrain_download_completed(result: int, code: int,
		_headers: PackedStringArray, _body: PackedByteArray) -> void:
	var request := terrain_http
	terrain_http = null
	if is_instance_valid(request):
		request.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		DirAccess.remove_absolute(_terrain_archive_path)
		_pending_terrain_start = false
		start_button.disabled = false
		_fail("Terrain download failed (HTTP %d). Check your connection and try again." % code)
		return
	var actual_hash := FileAccess.get_sha256(_terrain_archive_path)
	if actual_hash.to_lower() != LocalServer.DEFAULT_TERRAIN_SHA256:
		DirAccess.remove_absolute(_terrain_archive_path)
		_pending_terrain_start = false
		start_button.disabled = false
		_fail("Terrain download failed its integrity check and was discarded.")
		return
	var install_error := _extract_default_terrain(_terrain_archive_path)
	DirAccess.remove_absolute(_terrain_archive_path)
	if install_error != "":
		_pending_terrain_start = false
		start_button.disabled = false
		_fail(install_error)
		return
	_refresh_terrain_download_state()
	status_label.text = "Terrain Diffusion default world downloaded."
	start_button.disabled = false
	if _pending_terrain_start:
		_pending_terrain_start = false
		call_deferred("_on_start_local")

func _extract_default_terrain(archive_path: String) -> String:
	var zip := ZIPReader.new()
	if zip.open(archive_path) != OK:
		return "The downloaded terrain archive could not be opened."
	var parent := ProjectSettings.globalize_path("user://content")
	DirAccess.make_dir_recursive_absolute(parent)
	var staging := parent.path_join(".%s-install-%d" % [LocalServer.DEFAULT_TERRAIN_ID, OS.get_process_id()])
	DirAccess.make_dir_recursive_absolute(staging)
	for entry in zip.get_files():
		var clean := entry.replace("\\", "/").simplify_path()
		if clean == "." or clean.begins_with("../") or clean.begins_with("/"):
			zip.close()
			return "The downloaded terrain archive contains an unsafe path."
		var destination := staging.path_join(clean)
		if entry.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(destination)
			continue
		DirAccess.make_dir_recursive_absolute(destination.get_base_dir())
		var output := FileAccess.open(destination, FileAccess.WRITE)
		if output == null:
			zip.close()
			return "Could not write the downloaded terrain cache."
		output.store_buffer(zip.read_file(entry))
	zip.close()
	if not LocalServer.default_terrain_dir_valid(staging):
		return "The downloaded terrain archive is incomplete."
	var destination := LocalServer.default_terrain_cache_dir()
	if DirAccess.dir_exists_absolute(destination):
		var old := destination + ".invalid-%d" % int(Time.get_unix_time_from_system())
		if DirAccess.rename_absolute(destination, old) != OK:
			return "Could not replace the invalid terrain cache."
	if DirAccess.rename_absolute(staging, destination) != OK:
		return "Could not install the downloaded terrain cache."
	return ""

func _confirm_delete_world() -> void:
	var entry: Dictionary = world_option.get_item_metadata(world_option.selected)
	if entry.is_empty():
		return
	var dialog := ConfirmationDialog.new()
	dialog.title = "Delete world"
	dialog.dialog_text = "Move '%s' out of the world list? It will be kept in .goanna-trash for recovery." % entry["name"]
	dialog.ok_button_text = "Delete"
	dialog.confirmed.connect(func() -> void:
		var err := LocalServer.delete_world_recoverably(_local_data_dir, str(entry["name"]))
		if err != "":
			_fail(err)
		else:
			status_label.text = "World moved to .goanna-trash."
			_show_new_game())
	add_child(dialog)
	dialog.popup_centered()

func _on_start_local() -> void:
	var game := str(game_option.get_item_metadata(game_option.selected))
	var generator := str(generator_option.get_item_metadata(generator_option.selected))
	var terrain_diffusion := generator.begins_with("terrain_")
	var existing: Dictionary = world_option.get_item_metadata(world_option.selected)
	var world := str(existing.get("name", "")) if not existing.is_empty() else world_edit.text.strip_edges()
	# A world belongs to the game that made it. Loading it under another
	# game leaves every stored node unknown (a world of pink "unknown
	# node" blocks), so continue an existing world with its own game.
	if world == "":
		_fail("Enter a name for the new world.")
		return
	var allowed := RegEx.new()
	allowed.compile("^[A-Za-z0-9_ -]{1,40}$")
	if allowed.search(world) == null:
		_fail("World names are 1 to 40 characters: letters, digits, spaces, _ and -.")
		return
	if existing.is_empty() and DirAccess.dir_exists_absolute(_local_data_dir.path_join("worlds").path_join(world)):
		_fail("A world directory named '%s' already exists. Select it from the world list or choose a new name; it will not be overwritten." % world)
		return
	if host_check.button_pressed:
		var ptext := server_port_edit.text.strip_edges()
		if not ptext.is_valid_int() or int(ptext) < 1 or int(ptext) > 65535:
			_fail("Hosting port must be between 1 and 65535.")
			return
	if existing.is_empty() and generator == "terrain_default" and not LocalServer.default_terrain_cached():
		_pending_terrain_start = true
		_start_terrain_download()
		return
	var enabled_mods: Array = []
	for mod in mod_checks:
		if (mod_checks[mod] as CheckBox).button_pressed:
			enabled_mods.append(mod)
	# Scripted runs must not touch the player's remembered choices: a test
	# world would otherwise turn up prefilled the next time they open the menu.
	if OS.get_environment("GOANNA_LOCAL_TEST") == "":
		var cfg := ConfigFile.new()
		cfg.load(CFG_PATH)
		cfg.set_value("local", "game", game)
		cfg.set_value("local", "terrain_diffusion", terrain_diffusion)
		cfg.set_value("local", "world", world)
		cfg.set_value("local_host", "enabled", host_check.button_pressed)
		cfg.set_value("local_host", "name", server_name_edit.text)
		cfg.set_value("local_host", "description", server_description_edit.text)
		cfg.set_value("local_host", "port", server_port_edit.text)
		cfg.set_value("local_host", "announce", announce_check.button_pressed)
		cfg.set_value("local_host", "max_players", int(max_players_spin.value))
		cfg.save(CFG_PATH)
	server = LocalServer.new()
	var public_announce := host_check.button_pressed and announce_check.button_pressed
	var launch := {"gameid": game, "world": world, "player_name": _local_player_name(),
		"terrain_diffusion": terrain_diffusion, "creative": creative_check.button_pressed,
		"damage": damage_check.button_pressed, "mods": enabled_mods,
		"host": host_check.button_pressed, "server_name": server_name_edit.text.strip_edges(),
		"server_description": server_description_edit.text.strip_edges(),
		"password": server_password_edit.text, "announce": public_announce,
		"max_users": int(max_players_spin.value)}
	if host_check.button_pressed:
		launch["port"] = int(server_port_edit.text)
	_local_join_password = server_password_edit.text if host_check.button_pressed else ""
	var err: String = server.start_config(launch)
	if err != "":
		_fail(err)
		return
	start_button.disabled = true
	status_label.modulate = Color(1, 1, 1, 0.7)
	status_label.text = "Starting %s ..." % world
	server_deadline = _now() + 20.0
	set_process(true)

func _process(_delta: float) -> void:
	if terrain_http != null:
		var downloaded := terrain_http.get_downloaded_bytes()
		var total := terrain_http.get_body_size()
		if total > 0:
			status_label.text = "Downloading Terrain Diffusion default world: %.1f / %.1f MB" % [downloaded / 1000000.0, total / 1000000.0]
		else:
			status_label.text = "Downloading Terrain Diffusion default world: %.1f MB" % (downloaded / 1000000.0)
		return
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
		OS.set_environment("GOANNA_PASS", _local_join_password)
		# The game this world runs, so main.gd can pick per game defaults
		# (the bundled texture map today) without being told by the player.
		OS.set_environment("GOANNA_GAME", server.gameid)
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
	_new_screen("Join Game", "")
	_build_server_list()
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

# --- public server list ------------------------------------------------------

# The same list Luanti's own client shows, from the same place: serverlist_url
# defaults to https://servers.luanti.org (luanti/src/defaultsettings.cpp). This
# is the only request Goanna makes to anything other than the server the player
# chose, and it asks for nothing a vanilla client does not ask for. It is also
# entirely optional: the address fields below work with the list absent, which
# is what happens with no network.
const SERVER_LIST_URL := "https://servers.luanti.org/list"

var server_tree: Tree
var server_http: HTTPRequest
var _server_rows: Array = []

func _build_server_list() -> void:
	var head := Label.new()
	head.text = "Public servers"
	screen.add_child(head)
	server_tree = Tree.new()
	server_tree.custom_minimum_size = Vector2(560, 240)
	server_tree.columns = 4
	server_tree.column_titles_visible = true
	server_tree.set_column_title(0, "Server")
	server_tree.set_column_title(1, "Players")
	server_tree.set_column_title(2, "Version")
	server_tree.set_column_title(3, "Address")
	server_tree.set_column_expand(1, false)
	server_tree.set_column_expand(2, false)
	server_tree.set_column_custom_minimum_width(1, 70)
	server_tree.set_column_custom_minimum_width(2, 80)
	server_tree.hide_root = true
	server_tree.item_selected.connect(_on_server_picked)
	server_tree.item_activated.connect(func() -> void:
		_on_server_picked()
		_on_connect())
	screen.add_child(server_tree)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	screen.add_child(row)
	row.add_child(_button("Refresh list", _fetch_server_list))
	_fetch_server_list()

func _fetch_server_list() -> void:
	if server_http == null:
		server_http = HTTPRequest.new()
		add_child(server_http)
		server_http.request_completed.connect(_on_server_list)
	server_tree.clear()
	var root := server_tree.create_item()
	var loading := server_tree.create_item(root)
	loading.set_text(0, "Fetching " + SERVER_LIST_URL + " ...")
	var err := server_http.request(SERVER_LIST_URL)
	if err != OK:
		_server_list_message("Could not start the request. The address fields below still work.")

func _on_server_list(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	# The reply can arrive after the player has left this screen, which frees
	# the tree it would be written into.
	if not is_instance_valid(server_tree) or not server_tree.is_inside_tree():
		return
	if code != 200:
		_server_list_message("Server list unavailable (HTTP %d). The address fields below still work." % code)
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("list"):
		_server_list_message("Server list could not be read. The address fields below still work.")
		return
	_server_rows = parsed["list"]
	# Busiest first, which is the order that makes the list useful: a server
	# with nobody on it is rarely what someone opening this screen wants.
	_server_rows.sort_custom(func(a, b) -> bool:
		return int(a.get("clients", 0)) > int(b.get("clients", 0)))
	server_tree.clear()
	var root := server_tree.create_item()
	var shown := 0
	for e in _server_rows:
		if typeof(e) != TYPE_DICTIONARY or not e.has("address"):
			continue
		var it := server_tree.create_item(root)
		it.set_text(0, str(e.get("name", e.get("address", "?"))))
		it.set_text(1, "%d/%d" % [int(e.get("clients", 0)), int(e.get("clients_max", 0))])
		it.set_text(2, str(e.get("version", "")))
		it.set_text(3, "%s:%d" % [str(e.get("address", "")), int(e.get("port", 30000))])
		it.set_metadata(0, e)
		shown += 1
	status_label.text = "%d servers. Pick one to fill the fields below, or double click to join." % shown
	status_label.modulate = Color(1, 1, 1, 0.6)

func _server_list_message(msg: String) -> void:
	if not is_instance_valid(server_tree):
		return
	server_tree.clear()
	var root := server_tree.create_item()
	var it := server_tree.create_item(root)
	it.set_text(0, msg)

func _on_server_picked() -> void:
	var it := server_tree.get_selected()
	if it == null:
		return
	var e = it.get_metadata(0)
	if typeof(e) != TYPE_DICTIONARY:
		return
	host_edit.text = str(e.get("address", ""))
	port_edit.text = str(int(e.get("port", 30000)))
	# Said plainly rather than left to be discovered at the loading screen: a
	# large public server sends a great deal of media before it lets anyone in.
	status_label.text = "%s. Joining a large server can take a while at the media step." % str(e.get("name", ""))
	status_label.modulate = Color(1, 1, 1, 0.6)

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
	# A remote server's game is not known here; do not inherit a local one.
	OS.set_environment("GOANNA_GAME", "")
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
