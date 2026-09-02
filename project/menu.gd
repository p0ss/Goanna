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
var join_pbr_option: OptionButton
# new game
var game_option: OptionButton
var world_option: OptionButton
var world_edit: LineEdit
var generator_option: OptionButton
var creative_check: CheckBox
var damage_check: CheckBox
var pbr_option: OptionButton
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
var showcase_launch := false
# The graphics benchmark's world and one of its own camera poses, so the menu
# backdrop and the calibration scene cannot drift apart: see
# tools/bench_plans/graphics.json, whose "close" scene is this position and
# aim, and whose "structures" entry is what put the village there.
# SHOWCASE_YAW is that scene's aim converted to main.gd's convention
# (main.gd:1209, yaw = atan2(-d.x, -d.z) in degrees).
#
# The "close" pose and not that plan's wider "vista" one, for the same reason
# the backdrop keeps a small view range: this stands in the village with its
# subject about nine nodes away, so it is worth looking at as soon as the
# nearest blocks arrive. Vista looks at the village from 54 up and 46 away,
# which needs most of the scene streamed and meshed before it is anything but
# fog, and a menu that takes that long to become presentable is worse than a
# plain one however good the eventual frame is.
const BACKGROUND_PATH := "res://menu_background.png"
const SHOWCASE_WORLD := "test_world"
const SHOWCASE_POS := Vector3(-100, 30.6, 340)
const SHOWCASE_YAW := -116.6

func _ready() -> void:
	set_process(false)
	# The real-world backdrop is the normal menu. Keep screenshot automation
	# and recovery on machines without Luanti deterministic, and allow an
	# explicit opt-out for low-power or offline launches.
	# The menu's backdrop is a still now (see _build_frame), so the live
	# showcase is off unless it is asked for. It stays in the code because it
	# is what takes the still: tools/menu-background.sh drives this same path
	# with GOANNA_SHOWCASE=1 to sit the camera at the village and capture it.
	showcase_launch = OS.get_environment("GOANNA_SHOWCASE_LIVE") != "" \
			and OS.get_environment("GOANNA_NO_SHOWCASE") == "" \
			and OS.get_environment("GOANNA_MENU_SHOT") == ""
	if OS.get_environment("GOANNA_MENU") == "":
		for v in SKIP_VARS:
			if OS.get_environment(v) != "":
				_go_to_game()
				return
	_build_frame()
	_show_main()
	if showcase_launch:
		_start_showcase()
		return
	if OS.get_environment("GOANNA_LOCAL_TEST") != "":
		# Development aid: "game:world" starts a local game and joins it.
		var gw := OS.get_environment("GOANNA_LOCAL_TEST").split(":")
		_show_new_game()
		await get_tree().process_frame
		var wanted_world: String = gw[1] if gw.size() > 1 else "sp_test"
		var existing_index := -1
		for i in world_option.item_count:
			if world_option.get_item_text(i) == wanted_world:
				existing_index = i
				break
		if existing_index >= 0:
			# Existing worlds own their game. Select through the same path as the
			# UI so an automated run cannot rewrite a world's gameid from gw[0].
			world_option.select(existing_index)
			_on_world_selected(existing_index)
		else:
			for i in game_option.item_count:
				if game_option.get_item_text(i) == gw[0]:
					game_option.select(i)
					break
			world_edit.text = wanted_world
		# Exercise the real Start Game texture-pack handoff. Previously the
		# local launch harness could only test Bundled/Standard: selecting an
		# existing world above deliberately restores that world's old boolean
		# PBR flag and overwrites every installed-pack selection. Accept the same
		# graphics id stored by the UI (for example
		# "pack:/path/to/craft_and_ruin_pbr") after that restoration.
		var test_graphics := OS.get_environment("GOANNA_LOCAL_TEST_GRAPHICS")
		if test_graphics != "":
			for i in pbr_option.item_count:
				var md: Dictionary = pbr_option.get_item_metadata(i)
				if str(md.get("id", "")) == test_graphics:
					pbr_option.select(i)
					break
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


# The still is loaded rather than preloaded so a missing or not yet imported
# file degrades to the plain background instead of failing the whole scene.
# Reading the png directly covers a source checkout whose import step has not
# run; load() covers an exported build, where only the imported form ships.
func _background_texture() -> Texture2D:
	# ResourceLoader.exists first: *.import is not committed (see .gitignore),
	# so on a checkout that has not been imported yet load() would print a "no
	# loader found" error every launch before the fallback below succeeds.
	if ResourceLoader.exists(BACKGROUND_PATH):
		var res := load(BACKGROUND_PATH) as Texture2D
		if res != null:
			return res
	var img := Image.new()
	if img.load(ProjectSettings.globalize_path(BACKGROUND_PATH)) != OK:
		return null
	return ImageTexture.create_from_image(img)

func _build_frame() -> void:
	# A still of the benchmark village, captured at full settings by
	# tools/menu-background.sh, rather than a live session behind the menu.
	#
	# The live backdrop could not be all three of the things it was for. It
	# booted a Luanti server and streamed a world, so it was never quick; it
	# was looked at long before the near mesh arrived, so it showed the far
	# tier, which draws no fences, lamps or flowers at all and renders leaves
	# as solid cubes; and it grabbed the mouse from the menu in front of it.
	# A picture of the settled scene has none of those problems and is the
	# same view, so this is the higher fidelity option as well as the faster
	# one. Retake it with the script when the scene or the art changes.
	var shot := _background_texture()
	if shot != null:
		var art := TextureRect.new()
		art.texture = shot
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		art.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(art)
	var bg := ColorRect.new()
	# Over the still, a wash dark enough to keep the panel legible; over
	# nothing, the plain background this always had.
	bg.color = Color(0.03, 0.04, 0.06, 0.12 if shot != null else 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(centre)
	var panel := PanelContainer.new()
	if shot != null:
		var panel_style := StyleBoxFlat.new()
		panel_style.bg_color = Color(0.035, 0.05, 0.08, 0.91)
		panel_style.border_color = Color(0.55, 0.68, 0.82, 0.42)
		panel_style.set_border_width_all(1)
		panel_style.set_corner_radius_all(8)
		panel.add_theme_stylebox_override("panel", panel_style)
	centre.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 28)
	panel.add_child(margin)
	_panel_box = VBoxContainer.new()
	_panel_box.add_theme_constant_override("separation", 12)
	_panel_box.custom_minimum_size = Vector2(440, 0)
	if shot != null:
		_panel_box.custom_minimum_size = Vector2(360, 0)
	margin.add_child(_panel_box)

func _start_showcase() -> void:
	var env := LocalServer.detect()
	if env.is_empty():
		_fail("Mineclonia showcase unavailable: no Luanti server was found.")
		return
	server = LocalServer.new()
	# The world the graphics benchmark calibrates against
	# (tools/bench_plans/graphics.json), rather than a scene kept only for this
	# backdrop: that plan is run often enough to notice when the village stops
	# looking right, which a menu backdrop nobody measures is not.
	#
	# creative and damage are deliberately test_world's own current world.mt
	# values rather than what a showcase would otherwise ask for. start_config
	# rewrites those two keys (_write_world_options in local_server.gd), so
	# asking for anything else would edit the benchmark's world every time
	# someone opened the menu, and the calibration would drift underneath it.
	var err: String = server.start_config({
		"gameid": "mineclonia", "world": SHOWCASE_WORLD,
		"player_name": _local_player_name(), "creative": false,
		"damage": true, "mods": [], "host": false,
		"server_name": "Goanna Showcase", "server_description": "",
		"password": "", "announce": false, "max_users": 1})
	if err != "":
		_fail(err)
		return
	status_label.text = "Preparing the village showcase ..."
	server_deadline = _now() + 30.0
	set_process(true)

func _stop_showcase() -> void:
	if not showcase_launch:
		return
	if server != null:
		server.stop()
		server = null
	var world := get_node_or_null("Main")
	if world:
		world.queue_free()
	# Everything the showcase set, not just its flag. These are process
	# environment, and the real session launches from this same process, so
	# a leftover GOANNA_TOD pinned the joined world's clock at the
	# showcase's dusk forever (server time marched on into night and spawned
	# monsters into a sunset that never moved), and the leftover
	# GOANNA_FAR_DISTANCE capped the horizon at the showcase's 384 whatever
	# the server granted.
	for k in ["GOANNA_SHOWCASE", "GOANNA_TOD", "GOANNA_VIEW_RANGE", "GOANNA_LOD",
			"GOANNA_FAR_DISTANCE", "GOANNA_SHOWCASE_X", "GOANNA_SHOWCASE_Y",
			"GOANNA_SHOWCASE_Z", "GOANNA_SHOWCASE_YAW"]:
		OS.set_environment(k, "")
	showcase_launch = false

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

var menu_advanced_open := false   # Advanced graphics, kept across reopens
const GraphicsProfiles := preload("res://graphics_profiles.gd")

func _show_settings() -> void:
	_new_screen("Settings", "Applied when you next join a world. The pause menu has the same settings, and changes there take effect immediately.")
	var tabs := TabContainer.new()
	tabs.custom_minimum_size = Vector2(560, 360)
	screen.add_child(tabs)
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	var pages := {}
	var new_page := func(name: String) -> VBoxContainer:
		var scroll := ScrollContainer.new()
		scroll.name = name
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		var box := VBoxContainer.new()
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_theme_constant_override("separation", 10)
		scroll.add_child(box)
		tabs.add_child(scroll)
		return box
	# The same shape as the in-game panel (ui/game_ui.gd): one Graphics tab
	# holding a profile and the few settings worth an opinion, with the rest
	# behind Advanced. The two screens claim to be the same settings, so they
	# had better be arranged the same way.
	pages["Graphics"] = new_page.call("Graphics")
	_menu_graphics_page(pages["Graphics"], cfg)
	for row in GameUI.SETTINGS:
		var tab := str(row[0])
		if not GameUI.PLAIN_TABS.has(tab):
			continue
		if not pages.has(tab):
			pages[tab] = new_page.call(tab)
		_settings_row(pages[tab], row, cfg)
	screen.add_child(_button("Back", _show_main))

# The menu has no client to ask, so everything here reads and writes
# goanna.cfg directly and takes effect on the next connect.
func _menu_graphics_page(box: VBoxContainer, cfg: ConfigFile) -> void:
	var head := Label.new()
	head.text = "Graphics profile"
	box.add_child(head)
	var picker := OptionButton.new()
	var blurb := Label.new()
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.modulate = Color(1, 1, 1, 0.72)
	var names: Array = GraphicsProfiles.ORDER.duplicate()
	names.append("custom")
	for i in names.size():
		picker.add_item(GraphicsProfiles.LABELS[names[i]], i)
	var stored := func() -> Dictionary:
		var have := {}
		for row in GameUI.SETTINGS:
			var k := str(row[1])
			if cfg.has_section_key("settings", k):
				have[k] = float(cfg.get_value("settings", k, 0.0))
		return have
	var show_current := func() -> void:
		var name: String = GraphicsProfiles.matches(stored.call())
		picker.select(maxi(0, names.find(name)))
		blurb.text = GraphicsProfiles.BLURBS[name]
	picker.item_selected.connect(func(i: int) -> void:
		var name: String = names[i]
		if name == "custom":
			show_current.call()
			return
		for key in GraphicsProfiles.PROFILES[name]:
			cfg.set_value("settings", key, float(GraphicsProfiles.PROFILES[name][key]))
		cfg.set_value("settings", "graphics_profile", name)
		cfg.save(CFG_PATH)
		_show_settings())
	box.add_child(picker)
	box.add_child(blurb)
	show_current.call()
	var adv := CheckButton.new()
	adv.text = "Advanced graphics settings"
	adv.button_pressed = menu_advanced_open
	box.add_child(adv)
	var rest := VBoxContainer.new()
	rest.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rest.add_theme_constant_override("separation", 10)
	rest.visible = menu_advanced_open
	box.add_child(rest)
	adv.toggled.connect(func(on: bool) -> void:
		menu_advanced_open = on
		rest.visible = on)
	var group := ""
	for row in GameUI.SETTINGS:
		var tab := str(row[0])
		if GameUI.PLAIN_TABS.has(tab):
			continue
		if GameUI.SIMPLE_KEYS.has(str(row[1])):
			_settings_row(box, row, cfg)
			continue
		if tab != group:
			group = tab
			var sub := Label.new()
			sub.text = tab
			sub.modulate = Color(1, 1, 1, 0.6)
			rest.add_child(sub)
		_settings_row(rest, row, cfg)

func _settings_row(box: VBoxContainer, row: Array, cfg: ConfigFile) -> void:
	var key := str(row[1])
	var kind := str(row[2])
	var known: bool = cfg.has_section_key("settings", key)
	var label := Label.new()
	label.text = str(row[3])
	box.add_child(label)
	if kind == "pack":
		# The same dropdown the in-game panel builds (ui/game_ui.gd): the packs
		# the detected Luanti install carries, by name, plus Other for a
		# directory outside it. Stored as the absolute path either way, which is
		# what main.gd hands to set_texture_path. Empty means the server's own
		# art, which is what the client reports as "no texture pack set".
		var picker := OptionButton.new()
		var pe := LineEdit.new()
		var data_dir: String = LocalServer.data_dir_or_empty()
		var packs_dir := data_dir.path_join("textures") if data_dir != "" else ""
		var packs: Array = LocalServer.list_texture_packs(data_dir) if data_dir != "" else []
		var current := str(cfg.get_value("settings", key, ""))
		picker.add_item("None")
		picker.set_item_metadata(0, "")
		for pack_name in packs:
			picker.add_item(str(pack_name))
			picker.set_item_metadata(picker.item_count - 1, packs_dir.path_join(str(pack_name)))
		picker.add_item("Other")
		picker.set_item_metadata(picker.item_count - 1, null)
		var other_index := picker.item_count - 1
		var want := current.simplify_path()
		var selected := other_index if want != "" else 0
		if want != "":
			for i in picker.item_count:
				var md = picker.get_item_metadata(i)
				if md != null and str(md) != "" and str(md).simplify_path() == want:
					selected = i
					break
		picker.select(selected)
		box.add_child(picker)
		pe.text = current
		pe.placeholder_text = "/path/to/pack"
		pe.visible = selected == other_index
		pe.text_changed.connect(func(t: String) -> void: _save_setting_text(key, t))
		box.add_child(pe)
		picker.item_selected.connect(func(i: int) -> void:
			var md = picker.get_item_metadata(i)
			pe.visible = md == null
			if md == null:
				# Keep whatever was typed; a stray click should not drop a path.
				pe.grab_focus()
				return
			pe.text = str(md)
			_save_setting_text(key, str(md)))
		var kd := Label.new()
		kd.text = str(row[4])
		kd.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		kd.modulate = Color(1, 1, 1, 0.55)
		box.add_child(kd)
		return
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
	_stop_showcase()
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
	var pbr_label := Label.new()
	pbr_label.text = "Materials"
	world_page.add_child(pbr_label)
	pbr_option = OptionButton.new()
	pbr_option.add_item("Bundled PBR (recommended)")
	pbr_option.set_item_metadata(0, {"id": "bundled", "path": "", "pbr": true})
	var local_packs_dir := _local_data_dir.path_join("textures")
	for pack_name in LocalServer.list_texture_packs(_local_data_dir):
		var pack_path := local_packs_dir.path_join(str(pack_name))
		pbr_option.add_item("PBR — " + str(pack_name))
		pbr_option.set_item_metadata(pbr_option.item_count - 1,
				{"id": "pack:" + pack_path, "path": pack_path, "pbr": true})
	pbr_option.add_item("Standard — no PBR")
	pbr_option.set_item_metadata(pbr_option.item_count - 1,
			{"id": "standard", "path": "", "pbr": false})
	pbr_option.tooltip_text = "Installed packs layer over the bundled game materials, filling uncovered textures from the bundled set."
	world_page.add_child(pbr_option)
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
	var remembered_graphics := str(cfg.get_value("local", "graphics",
			"bundled" if bool(cfg.get_value("local", "pbr_materials", true)) else "standard"))
	for i in pbr_option.item_count:
		var pbr_md: Dictionary = pbr_option.get_item_metadata(i)
		if str(pbr_md.get("id", "")) == remembered_graphics:
			pbr_option.select(i)
			break
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
	row.add_theme_constant_override("separation", 8)
	screen.add_child(row)
	# Delete sits at the far end, with the whole row between it and Start.
	# The two were adjacent, so the button that destroys a world was one
	# slip away from the button that opens it, and both are pressed from
	# the same screen in the same frame of mind.
	delete_button = _button("Delete world", _confirm_delete_world)
	row.add_child(delete_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	row.add_child(_button("Back", _show_main))
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
	var scripted_pbr := bool(options.get("pbr_materials", true))
	for i in pbr_option.item_count:
		var scripted_md: Dictionary = pbr_option.get_item_metadata(i)
		if str(scripted_md.get("id", "")) == ("bundled" if scripted_pbr else "standard"):
			pbr_option.select(i)
			break
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
		cfg.set_value("local", "pbr_materials", _local_pbr_enabled())
		cfg.set_value("local", "graphics", str(_local_pbr_selection().get("id", "bundled")))
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
		"damage": damage_check.button_pressed, "pbr_materials": _local_pbr_enabled(),
		"mods": enabled_mods,
		"host": host_check.button_pressed, "server_name": server_name_edit.text.strip_edges(),
		"server_description": server_description_edit.text.strip_edges(),
		"password": server_password_edit.text, "announce": public_announce,
		"max_users": int(max_players_spin.value)}
	if host_check.button_pressed:
		launch["port"] = int(server_port_edit.text)
	# The player's Far draw distance setting travels to the server as the
	# far rendering grant: on their own machine the slider is the one knob,
	# rather than silently stopping at the server's old fixed 1024.
	var far_cfg := ConfigFile.new()
	if far_cfg.load(CFG_PATH) == OK:
		launch["far_distance"] = int(far_cfg.get_value("settings", "far_distance", 1024))
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
		if showcase_launch:
			OS.set_environment("GOANNA_HOST", "127.0.0.1")
			OS.set_environment("GOANNA_PORT", str(server.port))
			OS.set_environment("GOANNA_NAME", _local_player_name())
			OS.set_environment("GOANNA_PASS", "")
			OS.set_environment("GOANNA_GAME", "mineclonia")
			OS.set_environment("GOANNA_SP_PID", str(server.pid))
			OS.set_environment("GOANNA_SP_MATCH", server.world_path)
			OS.set_environment("GOANNA_SHOWCASE", "1")
			OS.set_environment("GOANNA_SHOWCASE_X", str(SHOWCASE_POS.x))
			OS.set_environment("GOANNA_SHOWCASE_Y", str(SHOWCASE_POS.y))
			OS.set_environment("GOANNA_SHOWCASE_Z", str(SHOWCASE_POS.z))
			OS.set_environment("GOANNA_SHOWCASE_YAW", str(SHOWCASE_YAW))
			OS.set_environment("GOANNA_TOD", "0.24")
			# A small bubble, entirely near meshed, and no far field at all.
			#
			# What a village looks like is its fences, lanterns, flowers and grass,
			# and none of those exist in the far tier: goanna_lod.cpp only draws a
			# node it calls "filled", which is a solid, a cube-shaped thing like
			# leaves, or a liquid. A fence or a lantern is a nodebox with solidness
			# zero and fails that test, so it is not drawn at all, and leaves pass
			# it only as solid cubes. A backdrop served from far tiers is therefore
			# a bare frame of the village with blocky trees, which is exactly how
			# this looked: 219 blocks near meshed against 558 far, half a minute
			# in, with distant terrain still generating.
			#
			# So the three knobs are set for one job, getting the near mesh close
			# to the camera published quickly:
			#   view range decides what the server streams, so it is small;
			#   detail distance decides whether what arrived is near meshed rather
			#     than summarised, so it is above the view range, never below;
			#   far distance is off, because a far field the camera never looks at
			#     still competes for the same streaming and meshing budget.
			# Detail is forced upward here, unlike the values this replaces: the
			# failure was a backdrop quietly rendering below what the player asked
			# for, and a short horizon is free in a street where buildings occlude
			# the distance anyway.
			# Measured, so these are not a guess:
			#   far off entirely leaves the near bubble floating in void, with
			#     stray logs and sheep hanging in an empty sky, because the far
			#     field is what draws everything past the streamed radius;
			#   far on, at any distance, draws the village from summaries until
			#     the near mesh catches up, and a summary has no fences or lamps.
			# So the far field stays, at the modest distance this always used, and
			# only the detail radius is raised: that is the one change here that
			# is free, since it decides whether blocks already in hand are meshed
			# properly rather than how many are asked for.
			OS.set_environment("GOANNA_VIEW_RANGE", "18")
			OS.set_environment("GOANNA_LOD", "32")
			OS.set_environment("GOANNA_FAR_DISTANCE", "384")
			var world_scene := preload("res://main.tscn").instantiate()
			add_child(world_scene)
			return
		status_label.text = "Joining ..."
		OS.set_environment("GOANNA_HOST", "127.0.0.1")
		OS.set_environment("GOANNA_PORT", str(server.port))
		OS.set_environment("GOANNA_NAME", _local_player_name())
		OS.set_environment("GOANNA_PASS", _local_join_password)
		# The game this world runs, so main.gd can pick per game defaults
		# (the bundled texture map today) without being told by the player.
		OS.set_environment("GOANNA_GAME", server.gameid)
		# The bundled worldmod supplies the base game's fallback materials. An
		# installed style pack is a client-side overlay, so Craft and Ruin can
		# replace its own albedo/companions while uncovered nodes retain the
		# bundled Mineclonia set.
		var local_graphics := _local_pbr_selection()
		OS.set_environment("GOANNA_PACK", str(local_graphics.get("path", "")))
		OS.set_environment("GOANNA_PACK_SET", "1")
		OS.set_environment("GOANNA_NO_PBR", "" if bool(local_graphics.get("pbr", true)) else "1")
		OS.set_environment("GOANNA_PBR_SET", "1")
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
	_stop_showcase()
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
	var pbr_label := Label.new()
	pbr_label.text = "Graphics"
	grid.add_child(pbr_label)
	join_pbr_option = OptionButton.new()
	join_pbr_option.add_item("PBR — server materials (recommended)")
	join_pbr_option.set_item_metadata(0, {"id": "server", "path": "", "pbr": true})
	join_pbr_option.add_item("Standard — no PBR")
	join_pbr_option.set_item_metadata(1, {"id": "standard", "path": "", "pbr": false})
	join_pbr_option.add_item("Bundled Minetest Game PBR")
	join_pbr_option.set_item_metadata(2, {"id": "minetest_game",
		"path": LocalServer.bundled_pbr_texture_path("minetest_game"), "pbr": true})
	join_pbr_option.add_item("Bundled Mineclonia PBR")
	join_pbr_option.set_item_metadata(3, {"id": "mineclonia",
		"path": LocalServer.bundled_pbr_texture_path("mineclonia"), "pbr": true})
	var data_dir := LocalServer.data_dir_or_empty()
	var packs_dir := data_dir.path_join("textures") if data_dir != "" else ""
	var join_packs: Array = LocalServer.list_texture_packs(data_dir) if data_dir != "" else []
	for pack_name in join_packs:
		var pack_path := packs_dir.path_join(str(pack_name))
		join_pbr_option.add_item("PBR — " + str(pack_name))
		join_pbr_option.set_item_metadata(join_pbr_option.item_count - 1,
			{"id": "pack:" + pack_path, "path": pack_path, "pbr": true})
	grid.add_child(join_pbr_option)
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) == OK:
		host_edit.text = str(cfg.get_value("server", "host", ""))
		port_edit.text = str(cfg.get_value("server", "port", ""))
		name_edit.text = str(cfg.get_value("player", "name", ""))
		var remembered_pbr := str(cfg.get_value("server", "graphics", "server"))
		for i in join_pbr_option.item_count:
			var md: Dictionary = join_pbr_option.get_item_metadata(i)
			if str(md.get("id", "")) == remembered_pbr:
				join_pbr_option.select(i)
				break
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
	var graphics: Dictionary = join_pbr_option.get_item_metadata(join_pbr_option.selected)
	var graphics_id := str(graphics.get("id", "server"))
	var texture_path := str(graphics.get("path", ""))
	var use_pbr := bool(graphics.get("pbr", true))
	cfg.set_value("server", "graphics", graphics_id)
	cfg.save(CFG_PATH)
	OS.set_environment("GOANNA_HOST", host)
	OS.set_environment("GOANNA_PORT", port_text)
	OS.set_environment("GOANNA_NAME", pname)
	# A remote server's game is not known here; do not inherit a local one.
	OS.set_environment("GOANNA_GAME", "")
	OS.set_environment("GOANNA_PACK", texture_path)
	OS.set_environment("GOANNA_PACK_SET", "1")
	# A server may bundle companions itself. An empty texture-pack path alone
	# therefore cannot mean "off": explicitly prevent the renderer from using
	# server-supplied _n and _s maps for this choice.
	OS.set_environment("GOANNA_NO_PBR", "" if use_pbr else "1")
	OS.set_environment("GOANNA_PBR_SET", "1")
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

func _local_pbr_enabled() -> bool:
	return bool(_local_pbr_selection().get("pbr", true))

func _local_pbr_selection() -> Dictionary:
	if pbr_option == null or pbr_option.item_count == 0:
		return {"id": "bundled", "path": "", "pbr": true}
	return pbr_option.get_item_metadata(pbr_option.selected)

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _go_to_game() -> void:
	get_tree().change_scene_to_file.call_deferred("res://main.tscn")
