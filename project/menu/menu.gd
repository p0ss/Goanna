# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## Goanna's main menu, and the project's main scene (menu/menu.tscn, named by
## run/main_scene in project.godot). Continue, Your worlds and New world
## launch an ordinary Luanti server in the background (net/local_server.gd)
## and join it; Join a game joins a remote server. Both hand off to
## game/main.tscn, or to game/local_play.tscn for split screen, through
## _go_to_game and the GOANNA_* environment variables main.gd reads. There is
## no GoannaClient here.
#
# The screens follow docs/systems/interface-layout.md, "Menus": one accent
# button per screen (Continue on the main screen, maintainer 2026-11-01),
# lists as tables (ui/data_table.gd), New world as steps with defaults, and
# the rarely changed settings one page further in.
#
# The menu steps aside when the environment already says where to go
# (GOANNA_HOST/GOANNA_NAME or a test mode, SKIP_VARS); GOANNA_MENU=1 forces
# it. user://goanna.cfg remembers the join form's address, port and player
# name, the last local world and its game, the hosting options, the chosen
# Luanti and the local player roster; never a password.
extends Control

const CFG_PATH := "user://goanna.cfg"
const Narrator := preload("res://ui/narrator.gd")
# Read aloud (ui/narrator.gd): announces each screen and reads the control
# the keyboard or pointer is on, when the player has it on.
var narrator: Node
const LocalLaunch := preload("res://game/local_launch.gd")
var local_roster: Array = []
var local_layout := "grid"
var local_graphics_profile := "low"

const LocalServer := preload("res://net/local_server.gd")
const AssetUpdater := preload("res://update/asset_updater.gd")
const GlassStyle := preload("res://ui/glass_style.gd")
const PanelFit := preload("res://ui/panel_fit.gd")
const InfoIcon := preload("res://ui/info_icon.gd")
const DataTable := preload("res://ui/data_table.gd")
# interface-layout.md: four text levels, 8 and 24 px spacing, 40 px targets.
const TITLE_SIZE := 26
const HEADING_SIZE := 19
const QUIET_SIZE := 14
const QUIET := Color(1, 1, 1, 0.6)
const NEAR := 8
const FAR := 24
const TARGET := 40.0
const SKIP_VARS := ["GOANNA_LOCAL_PLAY", "GOANNA_HOST", "GOANNA_NAME", "GOANNA_SHOT", "GOANNA_SMOKE",
	"GOANNA_WALKTEST", "GOANNA_TOGGLETEST", "GOANNA_ANIMPROBE", "GOANNA_MOBTEST",
	"GOANNA_USETEST", "GOANNA_MINETEST", "GOANNA_DIGDOWNTEST", "GOANNA_MANTLETEST"]

var screen: VBoxContainer
# The screen's buttons (Back, Start, Connect), below the scrolling body so
# they stay in reach however small the window (ui/panel_fit.gd).
var _footer: VBoxContainer
var _panel_margin: MarginContainer
var _wide := false
var status_label: RichTextLabel
# join form
var host_edit: LineEdit
var port_edit: LineEdit
var name_edit: LineEdit
var pass_edit: LineEdit
var connect_button: Button
var join_pbr_option: OptionButton
# The shader pack picker on Join a game (ui/shader_pack_row.gd): the same
# saved setting as Settings, Advanced graphics, Shader pack.
var join_shader_option: OptionButton
# new game
var game_option: OptionButton
var lan_hint: Label
var world_option: OptionButton
var world_edit: LineEdit
var generator_option: OptionButton
var terrain_preview: TextureRect
# The (i) beside World generator: what Terrain Diffusion supports, and the
# chosen terrain world's own description.
var generator_info: Button
var _world_edit_label: Label
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
var _local_data_dir := ""
var _local_join_password := ""
var start_button: Button
var terrain_download_label: Label
var terrain_http: HTTPRequest
var _terrain_archive_path := ""
# Which world the in-flight download is for. The selection can change
# while it runs, and the hash must be checked against what was asked for.
var _terrain_downloading := ""
var _pending_terrain_start := false
# The newest materials for the game being started (_fetch_latest_materials):
# the menu's own background upgrade, the check for one game, and the games
# already checked this time the menu is open.
var _background_materials: Node
var _material_check: Node
var _material_wait_game := ""
var _materials_current := {}
var server  # net/local_server.gd
# Large mod sets and first-world preparation can take minutes.
const SERVER_START_TIMEOUT_SECONDS := 300.0
var server_deadline := 0.0
var showcase_launch := false
# The graphics benchmark's world and one of its own camera poses, so the menu
# backdrop and the calibration scene cannot drift apart: see
# tools/bench/bench_plans/graphics.json, whose "close" scene is this position and
# aim, and whose "structures" entry is what put the village there.
# SHOWCASE_YAW is that scene's aim converted to main.gd's convention
# (main.gd's _aim_at, yaw = atan2(-d.x, -d.z) in degrees).
#
# The "close" pose and not that plan's wider "vista" one, for the same reason
# the backdrop keeps a small view range: this stands in the village with its
# subject about nine nodes away, so it is worth looking at as soon as the
# nearest blocks arrive. Vista looks at the village from 54 up and 46 away,
# which needs most of the scene streamed and meshed before it is anything but
# fog, and a menu that takes that long to become presentable is worse than a
# plain one however good the eventual frame is.
const SHOWCASE_WORLD := "test_world"
const SHOWCASE_POS := Vector3(-100, 30.6, 340)
const SHOWCASE_YAW := -116.6
# The stills behind the menu, one chosen at random on each launch. Taken by
# tools/dev/menu-background.sh, which says where each is and why it is framed with
# its subject to one side: the panel covers the middle of the screen.
const BACKGROUNDS := [
	"res://menu_backgrounds/headland.jpg",
	"res://menu_backgrounds/lantern.jpg",
	"res://menu_backgrounds/lava.jpg",
]

const Updater := preload("res://update/updater.gd")
var updater: Node

func _ready() -> void:
	narrator = Narrator.new()
	narrator.settings_owner = self
	add_child(narrator)
	AssetUpdater.install_bootstrap()
	# Goanna's own updates (updater.gd). Only a packaged release checks, and
	# the offer appears on the main screen when one is ready.
	updater = Updater.new()
	add_child(updater)
	updater.state_changed.connect(_on_update_state)
	# Newer versions of the material bundles already installed, fetched now
	# so the next game started uses them (asset_updater.gd).
	var materials := AssetUpdater.new()
	materials.upgrade_installed = true
	add_child(materials)
	_background_materials = materials
	var local_cfg := ConfigFile.new()
	if local_cfg.load(CFG_PATH) == OK:
		local_roster = local_cfg.get_value("local_play", "players", [])
		local_layout = str(local_cfg.get_value("local_play", "layout", "grid"))
		local_graphics_profile = str(local_cfg.get_value("local_play", "graphics_profile", "low"))
	set_process(false)
	# The real-world backdrop is the normal menu. Keep screenshot automation
	# and recovery on machines without Luanti deterministic, and allow an
	# explicit opt-out for low-power or offline launches.
	# The menu's backdrop is a still now (see _build_frame), so the live
	# showcase is off unless it is asked for with GOANNA_SHOWCASE_LIVE. The
	# stills are taken by tools/dev/menu-background.sh, which drives a headless
	# client through the control channel rather than this path.
	showcase_launch = OS.get_environment("GOANNA_SHOWCASE_LIVE") != "" \
			and OS.get_environment("GOANNA_NO_SHOWCASE") == "" \
			and OS.get_environment("GOANNA_MENU_SHOT") == ""
	if OS.get_environment("GOANNA_MENU") == "":
		for v in SKIP_VARS:
			if OS.get_environment(v) != "":
				_go_to_game()
				return
	add_to_group(GlassStyle.GROUP)
	_build_frame()
	_show_main()
	# Back from a failed or dropped join: Join a game again, with the reason,
	# rather than the main menu (2026-10-31).
	if OS.get_environment("GOANNA_MENU") != "" and OS.get_environment("GOANNA_MENU_RETURN") == "join":
		var reason := OS.get_environment("GOANNA_MENU_REASON")
		OS.set_environment("GOANNA_MENU_RETURN", "")
		OS.set_environment("GOANNA_MENU_REASON", "")
		_show_join()
		if reason != "":
			_fail(reason)
			_join_reason_shown = true
			if reason.to_lower().contains("password"):
				pass_edit.grab_focus()
	# Join a game stops the showcase (_show_join); do not start it behind it.
	if showcase_launch and _screen_title != JOIN_TITLE:
		_start_showcase()
		return
	if OS.get_environment("GOANNA_JOIN_SCAN") != "":
		# Development aid: "host:port" opens Join a game, presses Scan local
		# network, picks that server from what the scan found and connects
		# as GOANNA_JOIN_SCAN_NAME, as a friend joining a LAN world would.
		var want := OS.get_environment("GOANNA_JOIN_SCAN")
		_show_join()
		_scan_lan()
		while lan_scan.running:
			await get_tree().create_timer(0.25).timeout
		var picked := false
		var item := lan_tree.get_root().get_first_child() if lan_tree.get_root() else null
		while item != null:
			var e = item.get_metadata(0)
			if typeof(e) == TYPE_DICTIONARY:
				print("join scan: found %s:%d" % [str(e.address), int(e.port)])
				if not picked and "%s:%d" % [str(e.address), int(e.port)] == want:
					item.select(0)
					_on_lan_picked()
					picked = true
			item = item.get_next()
		if not picked:
			print("join scan: %s was not found" % want)
			get_tree().quit(1)
			return
		name_edit.text = OS.get_environment("GOANNA_JOIN_SCAN_NAME")
		print("join scan: connecting to %s:%s" % [host_edit.text, port_edit.text])
		_on_connect()
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
			# Create new world, first: the remembered last world is
			# preselected, and Start would otherwise start that one with
			# the new name ignored (it started a playtest world, 2026-10-31).
			world_option.select(0)
			_on_world_selected(0)
			for i in game_option.item_count:
				if game_option.get_item_text(i) == gw[0]:
					game_option.select(i)
					break
			world_edit.text = wanted_world
		# Exercise the real New world texture-pack handoff. Previously the
		# local launch harness could only test Bundled/Standard: selecting an
		# existing world above deliberately restores that world's old boolean
		# PBR flag and overwrites every installed-pack selection. Accept the same
		# graphics id stored by the UI (for example
		# "pack:/path/to/craft_and_ruin_pbr") after that restoration.
		# GOANNA_LOCAL_TEST_LAN=<port> ticks Open to LAN on that port.
		var test_lan := OS.get_environment("GOANNA_LOCAL_TEST_LAN")
		if test_lan != "":
			host_check.button_pressed = true
			server_port_edit.text = test_lan
		var test_graphics := OS.get_environment("GOANNA_LOCAL_TEST_GRAPHICS")
		if test_graphics != "":
			for i in pbr_option.item_count:
				var md: Dictionary = pbr_option.get_item_metadata(i)
				if str(md.get("id", "")) == test_graphics:
					pbr_option.select(i)
					break
		# GOANNA_LOCAL_TEST_GAME_MASTER=1 presses Copy Claude Code command,
		# which prints what it copied.
		if OS.get_environment("GOANNA_LOCAL_TEST_GAME_MASTER") != "":
			_copy_game_master("claude")
		_on_start_local()
		return
	if OS.get_environment("GOANNA_MENU_SHOT") != "":
		# GOANNA_MENU_SCALE=2 lays the menu out as a 200 percent display
		# scale would, for checking it stays legible and fits.
		var scale := float(OS.get_environment("GOANNA_MENU_SCALE"))
		if scale > 0.0:
			get_tree().root.content_scale_factor = scale
			await get_tree().process_frame
		var want := OS.get_environment("GOANNA_MENU_SCREEN")
		if want == "new" or want.begins_with("new-"):
			# new-2 to new-4: that step of New world, with its defaults.
			_show_new_game()
			if want.begins_with("new-"):
				_go_step(int(want.trim_prefix("new-")) - 1)
		elif want == "worlds":
			_show_worlds()
		elif want == "world":
			# The last world's options, as Continue opens them, unstarted.
			var last := _last_world()
			if not last.is_empty():
				_open_world(str(last["name"]), false)
		elif want == "join":
			_show_join()
		elif want == "public":
			_show_public_servers()
		elif want == "content":
			_show_content()
		elif want == "settings":
			_show_settings()
		elif want == "settings-advanced":
			# Advanced graphics with the Shadows group open.
			menu_groups_open = {"Shadows": true}
			_show_settings_page("Advanced")
		elif want.begins_with("settings-tab-"):
			# settings-tab-Controls and the like: that page, for a screenshot.
			_show_settings_page(want.trim_prefix("settings-tab-"))
		elif want == "local-players":
			_show_local_players()
		elif want == "join-scan":
			# Join a game after Scan local network has finished.
			_show_join()
			_scan_lan()
			while lan_scan.running:
				await get_tree().create_timer(0.25).timeout
		elif want == "about":
			_show_about()
		elif want == "luanti":
			_show_luanti()
		elif want == "setup":
			_show_setup()
		elif want == "update-offer":
			# The main screen as a player sees it when an update is ready.
			await updater.check(true)
			_show_main()
		elif want == "update-run":
			# Check, install without restarting, and wait for where it lands.
			_show_main()
			await updater.check(true)
			if updater.state == "available":
				updater.install(false)
			var until := Time.get_ticks_msec() + 300000
			while updater.state in ["checking", "available", "downloading", "installing"] \
					and Time.get_ticks_msec() < until:
				await get_tree().create_timer(0.5).timeout
			print("updater: ", updater.state, ": ", updater.message)
			_show_main()
		elif want == "setup-run":
			# Press Set it up and wait for where it lands: Start Game, or
			# the setup screen again with what went wrong.
			_show_setup()
			_run_setup()
			var deadline := Time.get_ticks_msec() + 180000
			while _setup_running and Time.get_ticks_msec() < deadline:
				await get_tree().create_timer(0.5).timeout
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		# GOANNA_MENU_INFO=1 opens every (i) on the screen, to see their text.
		if OS.get_environment("GOANNA_MENU_INFO") != "":
			for b in _panel_box.find_children("*", "Button", true, false):
				if b.has_method("set_info"):
					(b as Button).button_pressed = true
			await RenderingServer.frame_post_draw
		# GOANNA_MENU_SCROLL=<pixels> scrolls the screen's visible scrolling
		# bodies, so a shot can show what sits below the fold.
		var scroll_to := OS.get_environment("GOANNA_MENU_SCROLL")
		if scroll_to != "":
			for sc in _panel_box.find_children("*", "ScrollContainer", true, false):
				if (sc as ScrollContainer).is_visible_in_tree():
					(sc as ScrollContainer).scroll_vertical = int(scroll_to)
			await RenderingServer.frame_post_draw
		if want == "public" and OS.get_environment("GOANNA_SERVER_LIST_FILE") == "":
			# The public list is a network round trip; shooting the screen
			# before it lands photographs the "Fetching ..." placeholder.
			await get_tree().create_timer(6.0).timeout
			await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(OS.get_environment("GOANNA_MENU_SHOT"))
		get_tree().quit()

# --- frame shared by all screens ---------------------------------------------

var _panel_box: VBoxContainer
# The main screen's scroll, sized to its buttons by _fit_panel.
var _compact_scroll: ScrollContainer
var _screen_title := ""
# The (i) beside the screen's title, when it has an explanation.
var screen_info: Button


# The still is loaded rather than preloaded so a missing or not yet imported
# file degrades to the plain background instead of failing the whole scene.
# Reading the png directly covers a source checkout whose import step has not
# run; load() covers an exported build, where only the imported form ships.
func _background_texture() -> Texture2D:
	# Development aid: GOANNA_MENU_BACKDROP=<png> puts another picture behind
	# the menu, so screenshots can show the panel over more than one scene.
	var other := OS.get_environment("GOANNA_MENU_BACKDROP")
	if other != "":
		var picked := Image.new()
		if picked.load(other) == OK:
			return ImageTexture.create_from_image(picked)
	# ResourceLoader.exists first: *.import is not committed (see .gitignore),
	# so on a checkout that has not been imported yet load() would print a "no
	# loader found" error every launch before the fallback below succeeds.
	var path: String = BACKGROUNDS[randi() % BACKGROUNDS.size()]
	if ResourceLoader.exists(path):
		var res := load(path) as Texture2D
		if res != null:
			return res
	var img := Image.new()
	if img.load(ProjectSettings.globalize_path(path)) != OK:
		return null
	return ImageTexture.create_from_image(img)

func _build_frame() -> void:
	# A still, one of BACKGROUNDS, captured at full settings by
	# tools/dev/menu-background.sh, rather than a live session behind the menu.
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
	# Dark glass: the shared Theme dresses every control on every screen, and
	# the panel is a pane of glass over the still.
	theme = GlassStyle.theme() if GlassStyle.is_glass() else null
	if GlassStyle.is_glass():
		GlassStyle.back(panel)
	elif shot != null:
		var panel_style := StyleBoxFlat.new()
		panel_style.bg_color = Color(0.035, 0.05, 0.08, 0.91)
		panel_style.border_color = Color(0.55, 0.68, 0.82, 0.42)
		panel_style.set_border_width_all(1)
		panel_style.set_corner_radius_all(8)
		panel.add_theme_stylebox_override("panel", panel_style)
	centre.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 24)
	panel.add_child(margin)
	_panel_margin = margin
	_panel_box = VBoxContainer.new()
	_panel_box.add_theme_constant_override("separation", 12)
	margin.add_child(_panel_box)
	if not get_viewport().size_changed.is_connected(_fit_panel):
		get_viewport().size_changed.connect(_fit_panel)
	_fit_panel()

# The panel's size for this window: see ui/panel_fit.gd.
func _fit_panel() -> void:
	if _panel_box == null or not is_instance_valid(_panel_box):
		return
	var window := get_viewport().get_visible_rect().size
	var size := PanelFit.size_for(window, _wide)
	var inner := 48.0   # the margin above, both sides
	_panel_box.custom_minimum_size = Vector2(maxf(size.x - inner, 240.0),
			maxf(size.y - inner, 0.0) if _wide else 0.0)
	if not _wide and is_instance_valid(_compact_scroll) and is_instance_valid(screen):
		# The compact screen's scroll is its content's height, or what the
		# window leaves once the title and footer are placed.
		var room := window.y - 2.0 * PanelFit.outer_margin(window) - inner
		for c in _panel_box.get_children():
			if c != _compact_scroll and c is Control and (c as Control).visible:
				room -= (c as Control).get_combined_minimum_size().y + 12.0
		_compact_scroll.custom_minimum_size.y = clampf(
				screen.get_combined_minimum_size().y, 0.0, maxf(room, 80.0))

## Every control a player presses or types in is at least TARGET high, so
## controller focus and touch both work (interface-layout.md, Hierarchy).
## The (i) icons are left at their own size: each also opens when its
## control takes focus. Run after a screen is built.
func _fit_targets(root: Node = null) -> void:
	if root == null:
		root = _panel_box
	if root == null or not is_instance_valid(root):
		return
	for c in root.find_children("*", "Control", true, false):
		if c is InfoIcon:
			continue
		if c is BaseButton or c is LineEdit or c is SpinBox:
			var ctl := c as Control
			ctl.custom_minimum_size.y = maxf(ctl.custom_minimum_size.y, TARGET)

## The interface style changed (Settings, Appearance): rebuild the frame in the
## new style and come back to the settings screen, where the change was made.
## Called through the GlassStyle.GROUP group by ui/glass_style.gd's set_mode.
func interface_style_changed() -> void:
	for c in get_children():
		if c is CanvasItem and c != server:
			remove_child(c)
			c.queue_free()
	_build_frame()
	_show_settings()

func _start_showcase() -> void:
	var env := LocalServer.detect()
	if env.is_empty():
		_fail("Mineclonia showcase unavailable: no Luanti server was found.")
		return
	server = LocalServer.new()
	# The world the graphics benchmark calibrates against
	# (tools/bench/bench_plans/graphics.json), rather than a scene kept only for this
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
	server_deadline = _now() + SERVER_START_TIMEOUT_SECONDS
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

# Every screen but the main menu is wide: it takes most of the window and its
# body scrolls. A screen with its own scrolling tabs passes fill, and lays
# them out to fill the body instead.
func _new_screen(title: String, subtitle: String, fill := false) -> void:
	_screen_title = title
	_wide = title != ""
	screen_info = null
	_compact_scroll = null
	for c in _panel_box.get_children():
		# Hidden at once, freed at the end of the frame: the button that
		# opened this screen may still be in its own pressed signal.
		if c is CanvasItem:
			(c as CanvasItem).visible = false
		c.queue_free()
	if title == "":
		# The main screen names the program; every other screen names
		# itself, in the same title size (four text levels only).
		var t := Label.new()
		t.text = "Goanna"
		t.add_theme_font_size_override("font_size", TITLE_SIZE)
		_panel_box.add_child(t)
	if title != "":
		# The title, and what the screen is for behind an (i) beside it
		# (ui/info_icon.gd) rather than as a paragraph above every screen.
		var head := VBoxContainer.new()
		head.add_theme_constant_override("separation", 6)
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 10)
		head.add_child(line)
		var h := Label.new()
		h.text = title
		h.add_theme_font_size_override("font_size", TITLE_SIZE)
		line.add_child(h)
		_panel_box.add_child(head)
		if subtitle != "":
			var about := PanelFit.info(head, line, subtitle, head, -1, 0.6)
			about.label.add_theme_font_size_override("font_size", QUIET_SIZE)
			screen_info = about
	elif subtitle != "":
		# The main menu's one line, which says what Goanna is.
		var s := Label.new()
		s.text = subtitle
		GlassStyle.tint_text(s, QUIET)
		s.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_panel_box.add_child(s)
	screen = VBoxContainer.new()
	screen.add_theme_constant_override("separation", NEAR)
	screen.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not _wide:
		# The main screen is as tall as its buttons, and scrolls when the
		# window (or 200 percent text) leaves less room than that.
		_compact_scroll = ScrollContainer.new()
		_compact_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_compact_scroll.add_child(screen)
		_panel_box.add_child(_compact_scroll)
		# A flow row's height is known only once it has a width, after the
		# first layout, so fit again whenever the content's size settles.
		screen.minimum_size_changed.connect(func() -> void: _fit_panel.call_deferred())
		screen.resized.connect(func() -> void: _fit_panel.call_deferred())
	elif fill:
		screen.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_panel_box.add_child(screen)
	else:
		var body := ScrollContainer.new()
		body.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		body.size_flags_vertical = Control.SIZE_EXPAND_FILL
		var pad := MarginContainer.new()
		pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pad.add_theme_constant_override("margin_right", 16)
		pad.add_child(screen)
		body.add_child(pad)
		_panel_box.add_child(body)
	# A RichTextLabel rather than a Label so the text can be SELECTED. This line
	# is where a failed start reports why, and a message you cannot copy is one
	# you have to transcribe by hand into a bug report. Label offers no
	# selection at all in Godot 4.
	#
	# bbcode stays off: an error message is arbitrary text and may contain
	# square brackets (a mod name, a node position, a Lua table), which bbcode
	# would eat or mangle. Off means it is shown exactly as it arrived.
	status_label = RichTextLabel.new()
	status_label.bbcode_enabled = false
	status_label.selection_enabled = true
	status_label.fit_content = true
	status_label.scroll_active = false
	GlassStyle.tint_text(status_label, Color(1, 1, 1, 0.6))
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel_box.add_child(status_label)
	_footer = VBoxContainer.new()
	_footer.add_theme_constant_override("separation", NEAR)
	_panel_box.add_child(_footer)
	_fit_panel()
	_fit_targets.call_deferred()
	_fit_panel.call_deferred()
	if narrator != null:
		narrator.screen_root = _panel_box
		var heard := ["Goanna", title if title != "" else "Main menu"]
		if subtitle != "":
			heard.append(subtitle)
		narrator.announce(". ".join(heard))

# The first Tab or arrow with nothing focused focuses the screen's first
# control, so the menu can be worked from the keyboard (game_ui.gd does the
# same for windows in game).
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode in [KEY_TAB, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT] \
			and _panel_box != null:
		var focused := get_viewport().gui_get_focus_owner()
		if focused == null or not _panel_box.is_ancestor_of(focused):
			GameUI.focus_first(_panel_box)
			get_viewport().set_input_as_handled()

# Back, in the footer, where it stays in reach.
func _footer_back(cb: Callable = _show_main) -> void:
	_footer_row([_button("Back", cb)])

func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size.y = TARGET
	b.pressed.connect(cb)
	return b

## The screen's one primary action, in the accent fill. Every other button
## is quiet glass. Marked with the "accent" meta so tests can count them.
func _accent(b: Button) -> Button:
	b.set_meta("accent", true)
	var fill := GlassStyle.ACCENT_FILL
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var box := StyleBoxFlat.new()
		box.bg_color = fill.lightened(0.12) if state == "hover" else (
				fill.darkened(0.15) if state.contains("pressed") else fill)
		if state == "disabled":
			box.bg_color = Color(fill, 0.35)
		box.set_corner_radius_all(int(GlassStyle.RADIUS_SMALL))
		box.content_margin_left = 16
		box.content_margin_right = 16
		box.content_margin_top = 6
		box.content_margin_bottom = 6
		b.add_theme_stylebox_override(state, box)
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.55))
	return b

## A quieter button than the rest, for the main screen's last row: no pane,
## quiet text, the same 40 px target.
func _quieter(b: Button) -> Button:
	b.flat = true
	b.add_theme_color_override("font_color", GlassStyle.TEXT_DIM)
	return b

## A section heading on a page (the second of the four text levels).
func _heading(parent: Control, text: String) -> Label:
	var h := Label.new()
	h.text = text
	h.add_theme_font_size_override("font_size", HEADING_SIZE)
	if parent.get_child_count() > 0:
		var gap := Control.new()
		gap.custom_minimum_size = Vector2(0, FAR - NEAR)
		parent.add_child(gap)
	parent.add_child(h)
	return h

## A line of quiet text (the fourth text level).
func _quiet(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", QUIET_SIZE)
	GlassStyle.tint_text(l, QUIET)
	parent.add_child(l)
	return l

## A folded group: a 40 px header that opens the body under it. `open`
## remembers which are open, by title, across rebuilds of the screen.
func _fold(parent: Control, title: String, open: Dictionary) -> VBoxContainer:
	var header := Button.new()
	header.toggle_mode = true
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.custom_minimum_size.y = TARGET
	header.button_pressed = bool(open.get(title, false))
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", NEAR)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.visible = header.button_pressed
	header.text = ("\u25BE  " if header.button_pressed else "\u25B8  ") + title
	header.toggled.connect(func(on: bool) -> void:
		open[title] = on
		body.visible = on
		header.text = ("\u25BE  " if on else "\u25B8  ") + title
		_fit_targets(body))
	parent.add_child(header)
	parent.add_child(body)
	return body

## A footer row: quiet buttons on the left, the accent last on the right.
func _footer_row(quiet: Array, primary: Button = null) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", NEAR)
	for b in quiet:
		row.add_child(b)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	if primary != null:
		row.add_child(primary)
	_footer.add_child(row)
	return row

func _fail(msg: String, log_path := "") -> void:
	status_label.text = msg
	# In the client's own log too, where a headless or scripted run sees it.
	print("menu: ", msg)
	if log_path != "":
		if not FileAccess.file_exists(log_path) or FileAccess.get_file_as_string(log_path).strip_edges() == "":
			status_label.text += "\nThe server wrote nothing to its log."
		# The path itself is the button, straight under the message, so the
		# log is one press away rather than a path to retype (2026-10-31).
		var link := LinkButton.new()
		link.text = "Server log: " + log_path
		link.tooltip_text = "Open the server log"
		link.pressed.connect(func(): OS.shell_open(log_path))
		_footer.add_child(link)
		_footer.move_child(link, 0)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.add_child(_button("Open logs folder", func(): OS.shell_open(log_path.get_base_dir())))
		row.add_child(_button("Copy log path", func(): DisplayServer.clipboard_set(log_path)))
		_footer.add_child(row)
		_footer.move_child(row, 1)
	if narrator != null and narrator.enabled:
		narrator.say(msg)
	GlassStyle.tint_text(status_label, Color(1, 0.6, 0.5))

# --- main screen -------------------------------------------------------------

func _show_main() -> void:
	_new_screen("", "A Godot client for Luanti worlds.")
	if updater != null and updater.state in ["available", "downloading", "installing", "installed"]:
		var offer := Label.new()
		offer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		offer.text = updater.message
		var notes := str(updater.available.get("notes", ""))
		if updater.state == "available" and notes != "":
			offer.text += " " + notes
		screen.add_child(offer)
		if updater.state == "available":
			screen.add_child(_button("Update and restart", func() -> void: updater.install()))
	elif updater != null and updater.state == "failed" and updater.available.size() > 0:
		var why := Label.new()
		why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		GlassStyle.tint_text(why, Color(1, 0.7, 0.6))
		why.text = updater.message
		screen.add_child(why)
	# One accent: Continue the last world played, named with its game, or
	# New world when there is none (maintainer, 2026-11-01). No game is
	# featured: Continue is whatever this player played last.
	var last := _last_world()
	var worlds: Array = _known_worlds()
	if not last.is_empty():
		var go := _accent(_button("Continue: %s, %s" % [str(last["name"]), str(last["game"])],
				_continue_last_world))
		go.name = "Continue"
		go.tooltip_text = "Start %s again with the same game and settings." % str(last["name"])
		screen.add_child(go)
	else:
		var first := _accent(_button("New world", _show_new_game))
		first.name = "NewWorld"
		screen.add_child(first)
	if not worlds.is_empty():
		screen.add_child(_button("Your worlds", _show_worlds))
	if not last.is_empty():
		screen.add_child(_button("New world", _show_new_game))
	screen.add_child(_button("Join a game", _show_join))
	screen.add_child(_button("Settings", _show_settings))
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, FAR - NEAR)
	screen.add_child(gap)
	var more := HFlowContainer.new()
	more.add_theme_constant_override("h_separation", NEAR)
	more.add_theme_constant_override("v_separation", NEAR)
	screen.add_child(more)
	more.add_child(_quieter(_button("Content", _show_content)))
	more.add_child(_quieter(_button("Local players", _show_local_players)))
	more.add_child(_quieter(_button("About", _show_about)))
	more.add_child(_quieter(_button("Quit", func() -> void: get_tree().quit())))
	if updater != null and updater.state == "idle":
		updater.check.call_deferred()

# The worlds of the Luanti in use, or [] when there is none. Read, never
# created: the main screen must not start an install.
func _known_worlds() -> Array:
	var env := LocalServer.detect()
	if env.is_empty():
		return []
	return LocalServer.list_worlds(str(env["data_dir"]))

## The world Continue starts: the one last started, if it still exists in
## the Luanti in use. {name, game (its title), gameid} or {}.
func _last_world() -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return {}
	var name := str(cfg.get_value("local", "world", ""))
	if name == "":
		return {}
	var env := LocalServer.detect()
	if env.is_empty():
		return {}
	var data_dir := str(env["data_dir"])
	for entry in LocalServer.list_worlds(data_dir):
		if str(entry["name"]) == name:
			return {"name": name, "game": _world_game_title(data_dir, name)}
	return {}

## A world's game as the player knows it: a game published as a modpack
## (Kindred Holdfast on Mineclonia) by its own title, else the game's.
func _world_game_title(data_dir: String, world: String) -> String:
	var options := LocalServer.world_options(data_dir, world)
	var gid := str(options.get("gameid", ""))
	var mods: Array = options.get("mods", [])
	for entry in LocalServer.INSTALLABLE_GAMES:
		if str(entry.get("kind", "game")) != "modpack" or str(entry.get("requires", "")) != gid:
			continue
		var marker := str((entry.get("members", [entry["id"]]) as Array)[0])
		if mods.has(marker) or mods.has(str(entry["id"])):
			return str(entry["title"])
	return LocalServer.game_title(data_dir, gid) if gid != "" else "Unknown game"

func _continue_last_world() -> void:
	var last := _last_world()
	if last.is_empty():
		_show_main()
		return
	_open_world(str(last["name"]), true)

func _on_update_state() -> void:
	if _screen_title == "":
		_show_main()
	elif _screen_title == "About":
		_show_about()

# --- content -----------------------------------------------------------------

# Installed content for the chosen Luanti: one table of games, mods and
# texture packs, with the worlds that use each, filtered by kind.
func _show_content() -> void:
	var inst := LocalServer.detect()
	if inst.is_empty():
		_show_luanti("No Luanti install was found, so there is no content to show.")
		return
	_new_screen("Content", "Installed content for the chosen Luanti. Install a game here, or use Luanti for the full content catalogue.", true)
	_luanti_row(inst)
	var data_dir := str(inst["data_dir"])
	content_table = DataTable.new()
	screen.add_child(content_table)
	content_table.set_table(_content_table(data_dir))
	_quiet(screen, "Luanti's data folder: " + data_dir)
	_footer_row([_button("Back", _show_main)], _accent(_button("Install a game", _show_setup)))

var content_table: VBoxContainer

## The Content table's shape: a row per game, mod and texture pack, with
## the worlds using each. Texture packs are chosen per session, not per
## world, so their Used by is empty and the note says why.
func _content_table(data_dir: String) -> Dictionary:
	var worlds: Array = LocalServer.list_worlds(data_dir)
	var options := {}
	for w in worlds:
		options[str(w["name"])] = LocalServer.world_options(data_dir, str(w["name"]))
	var rows: Array = []
	for g in LocalServer.list_games(data_dir):
		var users: Array = []
		for w in options:
			if str(options[w].get("gameid", "")) == str(g):
				users.append(w)
		rows.append({"id": "game:" + str(g), "kind": "Game",
			"cells": {"kind": "Game", "name": LocalServer.game_title(data_dir, str(g)),
				"used": ", ".join(PackedStringArray(users))}})
	for m in LocalServer.list_mods(data_dir):
		var users: Array = []
		for w in options:
			if (options[w].get("mods", []) as Array).has(str(m)):
				users.append(w)
		rows.append({"id": "mod:" + str(m), "kind": "Mod",
			"cells": {"kind": "Mod", "name": str(m), "used": ", ".join(PackedStringArray(users))}})
	for t in LocalServer.list_texture_packs(data_dir):
		rows.append({"id": "pack:" + str(t), "kind": "Texture pack",
			"cells": {"kind": "Texture pack", "name": str(t), "used": ""}})
	return {"title": "", "columns": [
			{"id": "name", "label": "Name"},
			{"id": "kind", "label": "Kind"},
			{"id": "used", "label": "Used by"}],
		"rows": rows, "sort": {"column": "kind"},
		"filters": [{"id": "kind", "label": "Kind", "options": ["Game", "Mod", "Texture pack"]}],
		"empty": {"why": "Nothing is installed in this Luanti yet",
			"what": "Choose Install a game to add one."},
		"note": "Used by lists the worlds that load each game or mod. Texture packs are chosen when you play, not per world."}

# --- Luanti ------------------------------------------------------------------

# Goanna is not a standalone game: a local world runs Luanti's own server and
# joins it. This screen is where the player says which Luanti that is, points
# at one the scan missed, or installs one. New world and Content open it by
# themselves when there is nothing to run, instead of stopping at an error.
#
# Get ready to play installs pinned games into the chosen Luanti's data
# directory. Open Luanti offers the full upstream content manager.
var luanti_http: HTTPRequest
var _luanti_archive_path := ""
var _luanti_install_pid := -1
var _luanti_install_started := 0.0
var _luanti_install_log := ""
var _luanti_install_status := ""
var _luanti_install_scope := ""

func _show_luanti(reason := "", rescan := false) -> void:
	_stop_showcase()
	_new_screen("Luanti", "Your worlds and New world run Luanti's own server and join it, so they need Luanti installed. Join a game does not.")
	var all: Array = LocalServer.installs(rescan)
	var chosen := LocalServer.detect()
	if str(chosen.get("kind", "")) == "custom":
		var note := Label.new()
		note.text = "GOANNA_SERVER_CMD is set, so your worlds run that and the choice below is not used."
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		screen.add_child(note)
	if all.is_empty():
		var none := Label.new()
		none.text = "No Luanti install was found on this computer."
		screen.add_child(none)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 220)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.visible = not all.is_empty()
	screen.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	var group := ButtonGroup.new()
	for inst in all:
		var pick := CheckBox.new()
		pick.button_group = group
		pick.text = _install_title(inst)
		pick.button_pressed = str(inst["key"]) == str(chosen.get("key", ""))
		pick.toggled.connect(func(on: bool) -> void:
			if on:
				LocalServer.choose(inst)
				_show_luanti())
		list.add_child(pick)
		var detail := Label.new()
		detail.text = _install_detail(inst)
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		GlassStyle.tint_text(detail, Color(1, 1, 1, 0.55))
		list.add_child(detail)
	var actions := HFlowContainer.new()
	actions.add_theme_constant_override("h_separation", 8)
	actions.add_theme_constant_override("v_separation", 8)
	screen.add_child(actions)
	if chosen.is_empty() or (chosen["games"] as Array).is_empty():
		actions.add_child(_button("Get ready to play", _show_setup))
	actions.add_child(_button("Locate Luanti ...", _locate_luanti))
	var install_text := _install_luanti_text(all)
	if install_text != "":
		actions.add_child(_button(install_text, _confirm_install_luanti))
	if not chosen.is_empty() and not (chosen["client_argv"] as PackedStringArray).is_empty():
		actions.add_child(_button("Open Luanti", _open_luanti))
	actions.add_child(_button("Rescan", func() -> void: _show_luanti("", true)))
	actions.add_child(_button("Download page",
		func() -> void: OS.shell_open(LocalServer.DOWNLOAD_PAGE)))
	# Selectable, so a player whose Luanti is still not found can paste the
	# list into a bug report.
	var places := RichTextLabel.new()
	places.bbcode_enabled = false
	places.selection_enabled = true
	places.custom_minimum_size = Vector2(0, 150)
	places.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	GlassStyle.tint_text(places, Color(1, 1, 1, 0.55))
	places.text = "\n".join(LocalServer.search_places())
	places.visible = all.is_empty()
	var show_places := CheckButton.new()
	show_places.text = "Show where Goanna looked"
	show_places.button_pressed = places.visible
	show_places.toggled.connect(func(on: bool) -> void: places.visible = on)
	screen.add_child(show_places)
	screen.add_child(places)
	_footer_back()
	if reason != "":
		_fail(reason)
	elif chosen.is_empty():
		_fail("Locate Luanti if it is installed somewhere Goanna does not look, or install it.")
	elif (chosen["games"] as Array).is_empty():
		_fail("%s has no games. Open Luanti, install a game from its Content tab, then Rescan." % _install_name(chosen))
	else:
		status_label.text = "Your worlds use %s." % _install_name(chosen)

func _install_name(inst: Dictionary) -> String:
	var version := str(inst.get("version", ""))
	return str(inst.get("product", "Luanti")) + (" " + version if version != "" else "")

func _install_title(inst: Dictionary) -> String:
	var kinds := {"package": "installed program", "portable": "portable folder",
		"appimage": "AppImage", "snap": "Snap", "flatpak": "Flatpak",
		"goanna": "installed by Goanna", "custom": "GOANNA_SERVER_CMD"}
	var kind := str(kinds.get(str(inst["kind"]), inst["kind"]))
	if str(inst["kind"]) == "flatpak":
		kind += ", " + str(inst["key"]).get_slice(":", 2)
	var count := (inst["games"] as Array).size()
	return "%s (%s), %s" % [_install_name(inst), kind,
		"no games" if count == 0 else "%d game%s" % [count, "" if count == 1 else "s"]]

func _install_detail(inst: Dictionary) -> String:
	var lines: PackedStringArray = [str(inst["location"]), "Worlds and data: " + str(inst["data_dir"])]
	if LocalServer.too_old(inst):
		lines.append("Too old: this is %s %s, and Goanna needs %s or newer. Goanna will not use it." % [str(inst["product"]), str(inst["version"]), LocalServer.MIN_LUANTI])
	var games: Array = inst["games"]
	if not games.is_empty():
		lines.append("Games: " + ", ".join(PackedStringArray(games)))
	return "\n".join(lines)

# One line naming the Luanti in use, and the way to change it.
func _luanti_row(inst: Dictionary, parent: Control = null) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", NEAR)
	var label := Label.new()
	label.text = "Using " + _install_title(inst)
	GlassStyle.tint_text(label, Color(1, 1, 1, 0.7))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(label)
	row.add_child(_button("Change", _show_luanti))
	(parent if parent != null else screen).add_child(row)

func _locate_luanti() -> void:
	var dialog := FileDialog.new()
	dialog.title = "Locate Luanti: its folder, or the luanti program"
	# Godot's own file picker, because a native one cannot offer "a file or a
	# folder": the Windows zip is naturally pointed at as a folder, an
	# AppImage only as a file.
	dialog.use_native_dialog = false
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_ANY
	var start := OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	if start != "":
		dialog.current_dir = start
	dialog.file_selected.connect(_on_luanti_located)
	dialog.dir_selected.connect(_on_luanti_located)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.7)

func _on_luanti_located(path: String) -> void:
	var inst := LocalServer.install_at(path)
	if inst.is_empty():
		_show_luanti("There is no Luanti program at %s. Choose the folder Luanti was unpacked into, its bin folder, or the luanti program itself." % path)
		return
	LocalServer.choose(inst)
	_show_luanti()

func _open_luanti() -> void:
	var argv: PackedStringArray = LocalServer.detect()["client_argv"]
	if OS.create_process(argv[0], argv.slice(1)) <= 0:
		_fail("Could not start %s." % argv[0])
		return
	GlassStyle.tint_text(status_label, Color(1, 1, 1, 0.7))
	status_label.text = "Luanti is starting. Install a game from its Content tab, then come back and press Rescan."

# What Install Luanti does here, as its button says it, or "" where Goanna
# cannot do it and the download page is the answer (macOS, and Linux without
# flatpak, where the distribution's own packages are the better route anyway),
# or where what it would install is already in `all`.
func _install_luanti_text(all: Array) -> String:
	var windows := OS.get_name() == "Windows"
	for inst in all:
		var key := str(inst["key"])
		if (windows and str(inst["kind"]) == "goanna") \
				or (not windows and key.begins_with("flatpak:%s:" % LocalServer.FLATPAK_IDS[0])):
			return ""
	if windows:
		return "Install Luanti %s (%.0f MB)" % [str(LocalServer.LUANTI_WINDOWS["version"]),
			int(LocalServer.LUANTI_WINDOWS["bytes"]) / 1000000.0]
	if OS.get_name() == "macOS":
		return ""
	return "Install Luanti from Flathub" if LocalServer.flatpak_available() else ""

func _confirm_install_luanti() -> void:
	if luanti_http != null or _luanti_install_pid > 0:
		return
	var dialog := ConfirmationDialog.new()
	dialog.title = "Install Luanti"
	dialog.ok_button_text = "Install"
	var own := ProjectSettings.globalize_path(LocalServer.OWN_LUANTI_DIR)
	if OS.get_name() == "Windows":
		dialog.dialog_text = "Download the official Luanti %s for Windows from GitHub (%.1f MB), check it against the hash Goanna carries, and unpack it into:\n\n%s\n\nIt is a portable build, so its worlds are kept in that folder too." % [
			str(LocalServer.LUANTI_WINDOWS["version"]),
			int(LocalServer.LUANTI_WINDOWS["bytes"]) / 1000000.0, own]
		dialog.confirmed.connect(_start_luanti_download)
	else:
		var plan := LocalServer.flatpak_install_plan()
		if plan.is_empty():
			_fail("The flatpak command was not found.")
			return
		var commands: PackedStringArray = []
		for step in plan["steps"]:
			commands.append(" ".join(PackedStringArray(step)))
		var why := "Flathub is already set up for the whole system, so Luanti goes there and shares its runtime with your other Flatpak apps. Flatpak may ask for your password." \
			if str(plan["scope"]) == "system" else \
			"Flathub is not set up for the whole system, so Luanti goes into your own Flatpak installation. No password is needed, but the first install downloads the runtime Luanti needs, which is several hundred MB."
		dialog.dialog_text = "Goanna will run:\n\n%s\n\n%s" % ["\n".join(commands), why]
		dialog.confirmed.connect(func() -> void: _start_flatpak_install(plan))
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()

func _start_flatpak_install(plan: Dictionary) -> void:
	var dir := ProjectSettings.globalize_path(LocalServer.OWN_LUANTI_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	_luanti_install_log = dir.path_join("flatpak-install.log")
	_luanti_install_status = dir.path_join("flatpak-install.status")
	DirAccess.remove_absolute(_luanti_install_status)
	_luanti_install_scope = str(plan["scope"])
	_luanti_install_pid = LocalServer.run_steps_in_background(plan["steps"],
		_luanti_install_log, _luanti_install_status)
	if _luanti_install_pid <= 0:
		_luanti_install_pid = -1
		_fail("Could not start flatpak.")
		return
	_luanti_install_started = _now()
	set_process(true)

# The Flathub install or the Windows download, whichever is running, and true
# while it still is. Progress is shown on the Luanti screen only, so it does
# not talk over a world the player went on to start meanwhile.
func _poll_luanti_install() -> bool:
	var here := _screen_title == "Luanti" or _screen_title == SETUP_TITLE
	if _luanti_install_pid > 0:
		if FileAccess.file_exists(_luanti_install_status):
			_finish_flatpak_install()
			return false
		if here:
			GlassStyle.tint_text(status_label, Color(1, 1, 1, 0.7))
			status_label.text = "Installing Luanti from Flathub, %d s so far. A first Flatpak install also downloads the runtime Luanti needs, which can take several minutes." % int(_now() - _luanti_install_started)
		return true
	if luanti_http != null:
		if here:
			GlassStyle.tint_text(status_label, Color(1, 1, 1, 0.7))
			status_label.text = "Downloading Luanti: %.1f / %.1f MB" % [
				luanti_http.get_downloaded_bytes() / 1000000.0,
				int(LocalServer.LUANTI_WINDOWS["bytes"]) / 1000000.0]
		return true
	return false

# The result is shown on the Luanti screen, unless the player has meanwhile
# started a world, which is not interrupted for it.
func _show_luanti_result(reason := "", rescan := false) -> void:
	if _setup_running:
		_setup_after_server(reason)
		return
	if server == null:
		_show_luanti(reason, rescan)
	elif rescan:
		LocalServer.installs(true)

func _finish_flatpak_install() -> void:
	var code := FileAccess.get_file_as_string(_luanti_install_status).strip_edges()
	_luanti_install_pid = -1
	if code != "0":
		var output := FileAccess.get_file_as_string(_luanti_install_log).strip_edges().split("\n")
		var tail := "\n".join(output.slice(maxi(0, output.size() - 6)))
		_show_luanti_result("The Flathub install failed (exit status %s). The end of its output:\n%s\nThe whole log is %s." % [code, tail, _luanti_install_log], true)
		return
	for inst in LocalServer.installs(true):
		if str(inst["key"]) == "flatpak:%s:%s" % [LocalServer.FLATPAK_IDS[0], _luanti_install_scope]:
			LocalServer.choose(inst)
			break
	_show_luanti_result()

func _start_luanti_download() -> void:
	var dir := ProjectSettings.globalize_path(LocalServer.OWN_LUANTI_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	_luanti_archive_path = dir.path_join("download.zip.part")
	DirAccess.remove_absolute(_luanti_archive_path)
	luanti_http = HTTPRequest.new()
	luanti_http.download_file = _luanti_archive_path
	add_child(luanti_http)
	luanti_http.request_completed.connect(_on_luanti_downloaded)
	if luanti_http.request(str(LocalServer.LUANTI_WINDOWS["url"])) != OK:
		luanti_http.queue_free()
		luanti_http = null
		_fail("Could not start the Luanti download.")
		return
	set_process(true)

func _on_luanti_downloaded(result: int, code: int, _headers: PackedStringArray,
		_body: PackedByteArray) -> void:
	var request := luanti_http
	luanti_http = null
	if is_instance_valid(request):
		request.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		DirAccess.remove_absolute(_luanti_archive_path)
		_show_luanti_result("The Luanti download failed (HTTP %d). Check your connection and try again." % code)
		return
	var dir := ProjectSettings.globalize_path(LocalServer.OWN_LUANTI_DIR)
	var error := LocalServer.install_portable_archive(_luanti_archive_path,
		str(LocalServer.LUANTI_WINDOWS["sha256"]), dir)
	DirAccess.remove_absolute(_luanti_archive_path)
	if error != "":
		_show_luanti_result(error)
		return
	var folder := str(LocalServer.LUANTI_WINDOWS["url"]).get_file().get_basename()
	var inst := LocalServer.install_at(dir.path_join(folder))
	if not inst.is_empty():
		LocalServer.choose(inst)
	_show_luanti_result("", true)

# --- get ready to play ------------------------------------------------------

# One button between a fresh computer and a world, for a child who should not
# have to meet Luanti's content tab, a package manager or a password prompt:
# a Luanti server (one already installed, else the server the Linux release
# carries, else the official Windows build, else Flathub), then a game
# (a pinned upstream game, or Mineclonia with Kindred), then New world.
const SETUP_TITLE := "Get ready to play"
var _setup_running := false
var game_http: HTTPRequest
var _game_archive_path := ""
var _setup_selection := 0
var _setup_queue: Array = []
var _downloading_game: Dictionary = {}

func _setup_plan() -> Dictionary:
	var chosen := LocalServer.detect()
	var how := "have"
	if chosen.is_empty():
		if LocalServer.bundled_server() != "":
			how = "bundled"
		elif OS.get_name() == "Windows":
			how = "windows"
		elif LocalServer.flatpak_available():
			how = "flatpak"
		else:
			how = "none"
	return {"server": how}

func _show_setup(reason := "") -> void:
	_stop_showcase()
	var plan := _setup_plan()
	_new_screen(SETUP_TITLE, "To start a world on this computer, Goanna needs Luanti and a game. It can set both up for you.")
	var steps: PackedStringArray = []
	match str(plan["server"]):
		"bundled":
			steps.append("Set up the Luanti server that came with Goanna. Nothing to download.")
		"windows":
			steps.append("Download Luanti %s for Windows (%.0f MB)." % [str(LocalServer.LUANTI_WINDOWS["version"]),
				int(LocalServer.LUANTI_WINDOWS["bytes"]) / 1000000.0])
		"flatpak":
			steps.append("Install Luanti from Flathub. The first Flatpak install also downloads the runtime it needs, a few hundred MB, and may ask for a password.")
	var picker := OptionButton.new()
	for game in LocalServer.INSTALLABLE_GAMES:
		picker.add_item("%s %s (%.0f MB)" % [str(game["title"]), str(game["version"]), int(game["bytes"]) / 1000000.0])
	picker.select(_setup_selection)
	picker.item_selected.connect(func(index: int) -> void:
		_setup_selection = index
		_show_setup())
	screen.add_child(picker)
	var selected: Dictionary = LocalServer.INSTALLABLE_GAMES[_setup_selection]
	if str(selected.get("kind", "game")) == "modpack":
		steps.append("Install Mineclonia if needed, then add Kindred Holdfast. Preview: use a fresh world; saved worlds may not migrate between previews.")
	else:
		steps.append("Install this game if it is missing. Existing games are kept.")
	var what := Label.new()
	what.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	what.text = "\n".join(steps)
	screen.add_child(what)
	if str(plan["server"]) == "none":
		what.text = "Goanna cannot install Luanti on this computer by itself. Install Luanti from its download page, then come back and choose New world."
		screen.add_child(_accent(_button("Open the download page",
			func() -> void: OS.shell_open(LocalServer.DOWNLOAD_PAGE))))
	else:
		var go := _accent(_button("Set it up", _run_setup))
		go.custom_minimum_size = Vector2(240, 44)
		screen.add_child(go)
	screen.add_child(_button("Choose Luanti myself", func() -> void: _show_luanti()))
	_footer_back()
	if reason != "":
		_fail(reason)

func _run_setup() -> void:
	if _setup_running:
		return
	_setup_running = true
	for control in screen.find_children("*", "BaseButton", true, false):
		(control as BaseButton).disabled = true
	for control in _footer.find_children("*", "BaseButton", true, false):
		(control as BaseButton).disabled = true
	GlassStyle.tint_text(status_label, Color(1, 1, 1, 0.7))
	match str(_setup_plan()["server"]):
		"bundled":
			status_label.text = "Setting up the Luanti server ..."
			var inst := LocalServer.install_bundled_server(LocalServer.bundled_server())
			if inst.has("error"):
				_setup_failed(str(inst["error"]))
				return
			LocalServer.choose(inst)
			LocalServer.installs(true)
		"windows":
			_start_luanti_download()   # continues in _setup_after_server
			return
		"flatpak":
			var plan := LocalServer.flatpak_install_plan()
			if plan.is_empty():
				_setup_failed("The flatpak command was not found.")
				return
			_start_flatpak_install(plan)   # continues in _setup_after_server
			return
	_setup_game()

func _setup_after_server(reason: String) -> void:
	if reason != "":
		_setup_failed(reason)
		return
	LocalServer.installs(true)
	_setup_game()

func _setup_game() -> void:
	_setup_queue.clear()
	var selected: Dictionary = LocalServer.INSTALLABLE_GAMES[_setup_selection]
	if selected.get("kind", "game") == "modpack":
		var chosen := LocalServer.detect()
		if not chosen.is_empty():
			var mods_dir := str(chosen["data_dir"]).path_join("mods")
			for installed in LocalServer.list_mods(str(chosen["data_dir"])):
				if installed == "kindred_holdfast":
					continue
				var members := LocalServer.mod_members(mods_dir.path_join(str(installed)))
				for name in ["kindred", "kindred_creatures", "kindred_cultures", "kindred_world"]:
					if members.has(name):
						_setup_failed("Kindred packages are already installed separately. Enable those under New world, Options, Mods, or move them out of Luanti's mods folder before installing this preview.")
						return
	if selected.get("requires", "") == "mineclonia":
		_setup_queue.append(LocalServer.STARTER_GAME)
	_setup_queue.append(selected)
	_download_next_game()

func _download_next_game() -> void:
	var chosen := LocalServer.detect()
	if chosen.is_empty():
		_setup_failed("Luanti was installed, but Goanna cannot find it. Choose it yourself under Choose Luanti myself.")
		return
	if _setup_queue.is_empty():
		_setup_done()
		return
	_downloading_game = _setup_queue.pop_front()
	var is_modpack := str(_downloading_game.get("kind", "game")) == "modpack"
	var marker := "modpack.conf" if is_modpack else "game.conf"
	var games_dir := str(chosen["data_dir"]).path_join("mods" if is_modpack else "games")
	var id := str(_downloading_game["id"])
	if (not is_modpack and (chosen["games"] as Array).has(id)) \
			or FileAccess.file_exists(games_dir.path_join(id).path_join(marker)):
		_download_next_game()
		return
	DirAccess.make_dir_recursive_absolute(games_dir)
	_game_archive_path = games_dir.path_join(".%s.zip.part" % id)
	DirAccess.remove_absolute(_game_archive_path)
	game_http = HTTPRequest.new()
	game_http.timeout = 600.0
	game_http.download_file = _game_archive_path
	add_child(game_http)
	game_http.request_completed.connect(_on_game_downloaded.bind(games_dir))
	if game_http.request(str(_downloading_game["url"])) != OK:
		game_http.queue_free()
		game_http = null
		_setup_failed("Could not start the game download.")
		return
	set_process(true)

func _on_game_downloaded(result: int, code: int, _headers: PackedStringArray,
		_body: PackedByteArray, games_dir: String) -> void:
	var request := game_http
	game_http = null
	if is_instance_valid(request):
		request.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		DirAccess.remove_absolute(_game_archive_path)
		_setup_failed("The game download failed (HTTP %d). Check your connection and try again." % code)
		return
	status_label.text = "Unpacking %s ..." % str(_downloading_game["title"])
	# Archives contain thousands of files. Only file work runs on this
	# thread; the menu and its progress label stay on the main thread.
	var archive_path := _game_archive_path
	var game := _downloading_game.duplicate()
	var worker := Thread.new()
	var started := worker.start(func() -> String:
		return LocalServer.install_game_archive(archive_path,
			str(game["sha256"]), games_dir, str(game["id"]),
			"modpack.conf" if game.get("kind", "game") == "modpack" else "game.conf"))
	if started != OK:
		DirAccess.remove_absolute(archive_path)
		_setup_failed("Could not start unpacking the game. Please try again.")
		return
	while worker.is_alive():
		await get_tree().create_timer(0.1).timeout
	var error := str(worker.wait_to_finish())
	DirAccess.remove_absolute(_game_archive_path)
	if error != "":
		_setup_failed(error)
		return
	LocalServer.installs(true)
	_download_next_game()

func _setup_done() -> void:
	_setup_running = false
	LocalServer.installs(true)
	_show_new_game()
	world_option.select(0)
	_on_world_selected(0)
	var selected: Dictionary = LocalServer.INSTALLABLE_GAMES[_setup_selection]
	var game_id := str(selected.get("requires", selected["id"]))
	for i in game_option.item_count:
		if str(game_option.get_item_metadata(i)) == game_id:
			game_option.select(i)
	for i in game_option.item_count:
		if str(game_option.get_item_metadata(i)) == "%s|%s" % [game_id, str(selected["id"])]:
			game_option.select(i)
	if selected.get("kind", "game") == "modpack":
		if mod_checks.has("kindred_holdfast"):
			(mod_checks["kindred_holdfast"] as CheckBox).button_pressed = true
		world_edit.text = "kindred_preview"
		status_label.text = "Kindred Holdfast preview is ready. Choose a new world name before starting."
	# The game was the choice just made; go on to naming the world.
	_go_step(1)


func _setup_failed(reason: String) -> void:
	_setup_running = false
	_show_setup(reason)

# --- settings ----------------------------------------------------------------

# The same table the in-game panel drives (ui/game_ui.gd, SETTINGS), so the two
# cannot drift apart. There is no client yet at this point, so nothing can be
# applied live: values are written to the settings section of goanna.cfg, which
# game_ui reloads and applies on the next connect. That is the same file and
# the same section it writes to itself.
const GameUI := preload("res://ui/game_ui.gd")
const ShaderPackRow := preload("res://ui/shader_pack_row.gd")

var menu_groups_open := {}   # which Graphics groups are open, kept across reopens
const GraphicsProfiles := preload("res://game/graphics_profiles.gd")

# Settings front page: the graphics profile, the few settings most players
# change, and accessibility. Everything else is one quiet page further in:
# Advanced graphics holds the shader pack and every individual render
# switch; the other pages hold their whole tab. Nothing is dropped: every
# row of GameUI.SETTINGS is on one of the pages.
const SETTINGS_FRONT := {
	"Sound": ["volume", "muted"],
	"Controls": ["mouse_sensitivity", "invert_mouse", "pad_enabled"],
	"Accessibility": ["gui_scale", "read_aloud", "interface_style"],
}
# The pages behind the front page: GameUI's tab and the button's label.
const SETTINGS_PAGES := [["Advanced", "Advanced graphics"], ["Controls", "Controls"],
	["Appearance", "Appearance"], ["Audio", "Sound and speech"], ["Display", "Display"],
	["Updates", "Updates"]]

func _show_settings() -> void:
	_new_screen("Settings", "Applied when you next join a world. The pause menu has the same settings, and changes there take effect immediately.")
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	var page := screen
	PanelFit.heading(page, "Graphics")
	_menu_graphics_page(page, cfg, false)
	var advanced := _button("Advanced graphics: shader pack and render switches",
			func() -> void: _show_settings_page("Advanced"))
	advanced.name = "PageAdvanced"
	advanced.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	page.add_child(advanced)
	var rows := {}
	for row in GameUI.SETTINGS:
		rows[str(row[1])] = row
	for section in SETTINGS_FRONT:
		PanelFit.heading(page, section)
		for key in SETTINGS_FRONT[section]:
			if rows.has(key):
				_settings_row(page, rows[key], cfg)
	PanelFit.heading(page, "More settings")
	var more := HFlowContainer.new()
	more.add_theme_constant_override("h_separation", NEAR)
	more.add_theme_constant_override("v_separation", NEAR)
	page.add_child(more)
	for p in SETTINGS_PAGES:
		var tab: String = p[0]
		if tab == "Advanced":
			continue
		var b := _button(str(p[1]), func() -> void: _show_settings_page(tab))
		b.name = "Page" + tab
		more.add_child(b)
	_footer_back()

## One page behind Settings: Advanced (the shader pack and the grouped
## render switches) or one of GameUI's plain tabs, whole.
func _show_settings_page(tab: String) -> void:
	var title := tab
	for p in SETTINGS_PAGES:
		if str(p[0]) == tab:
			title = str(p[1])
	_new_screen(title, "Applied when you next join a world.")
	_settings_page = tab
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	if tab == "Advanced":
		for row in GameUI.SETTINGS:
			if PanelFit.tab_of(row) == "Shader packs":
				_settings_row(screen, row, cfg)
		PanelFit.heading(screen, "Render switches")
		_menu_graphics_page(screen, cfg, true)
	else:
		var last_group := ""
		for row in GameUI.SETTINGS:
			if PanelFit.tab_of(row) != tab:
				continue
			var group := PanelFit.group_of(row)
			if group != "" and group != last_group:
				last_group = group
				PanelFit.heading(screen, group)
			_settings_row(screen, row, cfg)
	_footer_back(_show_settings)

var _settings_page := ""

# The menu has no client to ask, so everything here reads and writes
# goanna.cfg directly and takes effect on the next connect.
# The front page gets the profile and the ungrouped Graphics rows; the
# Advanced page (`groups`) gets every grouped row, folded by group.
func _menu_graphics_page(box: VBoxContainer, cfg: ConfigFile, groups_only: bool) -> void:
	if groups_only:
		_menu_graphics_groups(box, cfg)
		return
	# The profile's name, its picker, and what the profile is about behind
	# an (i) beside the name.
	var profile := VBoxContainer.new()
	profile.add_theme_constant_override("separation", 8)
	box.add_child(profile)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	profile.add_child(line)
	var head := Label.new()
	head.text = "Graphics profile"
	line.add_child(head)
	var picker := OptionButton.new()
	profile.add_child(picker)
	var blurb := PanelFit.info(profile, line, "", profile, -1, 0.72)
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
		blurb.set_info(GraphicsProfiles.BLURBS[name])
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
	show_current.call()
	for row in GameUI.SETTINGS:
		if PanelFit.tab_of(row) == "Graphics" and PanelFit.group_of(row) == "":
			_settings_row(box, row, cfg)

func _menu_graphics_groups(box: VBoxContainer, cfg: ConfigFile) -> void:
	var groups := {}
	var order: Array = []
	for row in GameUI.SETTINGS:
		if PanelFit.tab_of(row) != "Graphics":
			continue
		var group := PanelFit.group_of(row)
		if group == "":
			continue
		if not groups.has(group):
			groups[group] = []
			order.append(group)
		groups[group].append(row)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 6)
	box.add_child(gap)
	for group in order:
		var body := PanelFit.accordion(box, group, (groups[group] as Array).size(), menu_groups_open)
		for row in groups[group]:
			_settings_row(body, row, cfg)

func _settings_row(box: VBoxContainer, row: Array, cfg: ConfigFile) -> void:
	var key := str(row[1])
	var kind := str(row[2])
	var known: bool = cfg.has_section_key("settings", key)
	# The same row as the in-game panel (ui/panel_fit.gd): the name, with a
	# switch or a slider's value beside it, and wider controls below.
	var shell: Array = PanelFit.row(box, str(row[3]))
	var head: HBoxContainer = shell[1]
	box = shell[0]
	if kind == "shaderpack":
		# The same row the in-game panel builds; it reads and writes goanna.cfg
		# itself and applies at the next join either way.
		ShaderPackRow.build(box, str(row[4]))
		return
	if kind == "choice":
		# One of a few named values, stored as text. The interface style is the
		# only one, and it applies straight away, here as in game.
		var picker := OptionButton.new()
		var choices: Array = GameUI.setting_choices(row)
		var current := str(cfg.get_value("settings", key, choices[0][0]))
		for choice in choices:
			picker.add_item(str(choice[1]))
			picker.set_item_metadata(picker.item_count - 1, str(choice[0]))
			if str(choice[0]) == current:
				picker.select(picker.item_count - 1)
		picker.item_selected.connect(func(i: int) -> void:
			var value := str(picker.get_item_metadata(i))
			if key == GlassStyle.KEY:
				GlassStyle.set_mode(value)
			else:
				_save_setting_text(key, value)
			if key == "speech_voice" and narrator != null:
				narrator.voice_id = value)
		box.add_child(picker)
		PanelFit.describe(box, str(row[4]))
		return
	if kind == "steps":
		# One of a few numbers (the texture resolution), stored as a number
		# like a slider's value, which a profile sets.
		var steps := OptionButton.new()
		var have := float(cfg.get_value("settings", key, _settings_default(row)))
		for choice in row[5]:
			steps.add_item(str(choice[1]))
			steps.set_item_metadata(steps.item_count - 1, float(choice[0]))
			if is_equal_approx(float(choice[0]), have):
				steps.select(steps.item_count - 1)
		steps.item_selected.connect(func(i: int) -> void:
			_save_setting(key, float(steps.get_item_metadata(i))))
		box.add_child(steps)
		if not known:
			PanelFit.note(box, NOT_RECORDED)
		PanelFit.describe(box, str(row[4]))
		return
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
		PanelFit.describe(box, str(row[4]))
		return
	if kind == "path":
		# A folder, not a number: stored as a string, as the choice and pack
		# rows are. Empty means the server's own art, which is what the client
		# reports as "no texture pack set" when it starts.
		var pe := LineEdit.new()
		pe.text = str(cfg.get_value("settings", key, ""))
		pe.placeholder_text = "none: use the server's own textures"
		pe.text_changed.connect(func(t: String) -> void: _save_setting_text(key, t))
		box.add_child(pe)
		PanelFit.describe(box, str(row[4]))
		return
	var current: float = float(cfg.get_value("settings", key, _settings_default(row)))
	if kind == "toggle":
		var cb := CheckButton.new()
		cb.button_pressed = current > 0.5
		cb.toggled.connect(func(on: bool) -> void: _save_setting(key, 1.0 if on else 0.0))
		head.add_child(cb)
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
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		sl.value_changed.connect(func(v: float) -> void:
			val.text = str(snappedf(v, float(row[7])))
			_save_setting(key, v))
		h.add_child(sl)
		head.add_child(val)
		box.add_child(h)
	if not known:
		# The client records what it is actually running with the first time a
		# world is joined (ui/game_ui.gd, _load_apply_settings). Until then the
		# menu has nothing to read and is showing a placeholder, so say so,
		# in view rather than behind the (i), since it is state and not
		# explanation.
		PanelFit.note(box, NOT_RECORDED)
	PanelFit.describe(box, str(row[4]))

const NOT_RECORDED := "Not recorded yet: join a world once, or set it here."

# What a setting is before anything was saved, for the rows whose default is
# not "on" or the middle of the slider.
const SETTING_DEFAULTS := {"procedural_grass": 0.0, "read_aloud": 0.0, "speech_rate": 1.0,
	"speech_volume": 1.0, "volume": 0.8}

# Placeholder for a setting goanna.cfg has never carried, which happens only
# before the first world is joined: after that the in-game panel has recorded
# what the client is really running with. A slider sits at its own midpoint
# rather than at zero, and the row says it is not recorded yet, because a
# confident wrong number is worse than an obvious placeholder.
func _settings_default(row: Array) -> float:
	if SETTING_DEFAULTS.has(str(row[1])):
		return float(SETTING_DEFAULTS[str(row[1])])
	if str(row[2]) == "toggle":
		return 1.0
	if str(row[2]) == "steps":
		# The middle step, as a slider sits at its midpoint.
		return float(row[5][(row[5] as Array).size() >> 1][0])
	return float(row[5]) + (float(row[6]) - float(row[5])) * 0.5

func _save_setting(key: String, value: float) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)  # keep the server and player sections
	cfg.set_value("settings", key, value)
	cfg.save(CFG_PATH)
	# The controller already drives this menu, so its settings apply here
	# rather than waiting for the next connect like the rest.
	var pad := get_node_or_null("/root/Gamepad")
	if pad != null and key.begins_with("pad_"):
		pad.load_settings()
	# Read aloud works in this menu too, so its settings apply here at once.
	if narrator != null:
		if key == "read_aloud" and narrator.enabled != (value > 0.5):
			narrator.set_enabled(value > 0.5)
		elif Narrator.SETTING_PROPERTIES.has(key):
			narrator.set(Narrator.SETTING_PROPERTIES[key],
				value if key.begins_with("speech_") else value > 0.5)

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
	GlassStyle.tint_text(body, Color(1, 1, 1, 0.85))
	body.text = """Goanna is a second client for Luanti servers: the same worlds and the same games, drawn with Godot 4 instead of Luanti's own renderer. It carries Luanti's client logic for networking, movement and node meshing, and replaces only what Irrlicht used to provide.

Goanna is an independent project. It is not affiliated with, endorsed by or supported by the Luanti project. The name "Luanti" is used only to identify the software Goanna interoperates with.

It connects to unmodified servers over the ordinary protocol and asks for nothing a vanilla client does not ask for.

Licence: LGPL-2.1-or-later, matching the Luanti client code it carries. godot-cpp is MIT. See LICENSE and THIRD-PARTY.md."""
	screen.add_child(body)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	screen.add_child(grid)
	var luanti := LocalServer.detect()
	var data_dir := str(luanti.get("data_dir", ""))
	var own := Updater.installed_version()
	for row in [["Goanna", own if own != "" else "source checkout"],
			["Godot", Engine.get_version_info().get("string", "unknown")],
			["Luanti core", "5.17.0"],
			["Settings", CFG_PATH],
			["Luanti", _install_title(luanti) if not luanti.is_empty() else "not found"],
			["Luanti data", data_dir if data_dir != "" else "not found"]]:
		var k := Label.new()
		k.text = str(row[0])
		GlassStyle.tint_text(k, Color(1, 1, 1, 0.6))
		grid.add_child(k)
		var v := Label.new()
		v.text = str(row[1])
		grid.add_child(v)
	if own != "":
		# Whether it checks by itself is under Settings, Updates.
		if updater.state == "available":
			screen.add_child(_button("Update and restart", func() -> void: updater.install()))
		else:
			screen.add_child(_button("Check for updates now", func() -> void: updater.check(true)))
		if updater.message != "":
			var said := Label.new()
			said.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			said.text = updater.message
			screen.add_child(said)
	_footer_back()

# --- your worlds ---------------------------------------------------------------

# Where Back goes from New world's first step, or from a world's options.
var _world_back: Callable
# New world's pages (WORLD_STEPS), one shown at a time; [] on an existing
# world's options, where the options and hosting pages show together.
var _world_steps: Array = []
var _world_step := 0
var _step_label: Label
var next_button: Button
var seed_edit: LineEdit
var _game_buttons: Array = []
var worlds_table: VBoxContainer
var play_button: Button
var _world_detail: VBoxContainer
var _world_folds := {}
# The accent's word on the world form: Create on New world, Play on an
# existing world. A terrain download puts "Download and" before it.
var _start_word := "Create"

const WORLD_STEPS := ["Choose a game", "Name and seed", "Options", "Hosting"]
const MONTHS := ["January", "February", "March", "April", "May", "June", "July",
	"August", "September", "October", "November", "December"]

## Your worlds: a table of the worlds on this computer (world, game, last
## played), newest first, and the chosen one's detail beside it with Play.
func _show_worlds(chosen := "") -> void:
	_stop_showcase()
	var env := LocalServer.detect()
	if env.is_empty() or (env["games"] as Array).is_empty():
		_show_setup()
		return
	_local_data_dir = str(env["data_dir"])
	# The detail beside the table when there is room; under it, with the
	# whole screen scrolling, at large text.
	var narrow := PanelFit.size_for(get_viewport().get_visible_rect().size, true).x < 760.0
	_new_screen("Your worlds", "The worlds on this computer, most recently played first. Choose one to see its game and settings, then Play.", not narrow)
	var split: BoxContainer = VBoxContainer.new() if narrow else HBoxContainer.new()
	split.add_theme_constant_override("separation", FAR)
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	screen.add_child(split)
	worlds_table = DataTable.new()
	worlds_table.custom_minimum_size = Vector2(0, 240 if narrow else 0)
	split.add_child(worlds_table)
	var side := ScrollContainer.new() if not narrow else null
	_world_detail = VBoxContainer.new()
	_world_detail.add_theme_constant_override("separation", NEAR)
	if side != null:
		side.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		side.custom_minimum_size.x = 280.0
		_world_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		side.add_child(_world_detail)
		split.add_child(side)
	else:
		split.add_child(_world_detail)
	# Play is in the footer, where it is in reach at any text size, and
	# acts on the chosen row.
	play_button = _accent(_button("Play", func() -> void:
		var id := str(worlds_table.selected_id)
		if id != "":
			_world_back = _show_worlds.bind(id)
			_open_world(id, true)))
	play_button.name = "Play"
	play_button.disabled = true
	play_button.tooltip_text = "Choose a world first."
	worlds_table.set_table(_worlds_table())
	worlds_table.row_chosen.connect(_show_world_detail)
	worlds_table.row_activated.connect(func(r: Dictionary) -> void:
		_world_back = _show_worlds.bind(str(r["id"]))
		_open_world(str(r["id"]), true))
	_footer_row([_button("Back", _show_main),
		_button("New world", func() -> void: _show_new_game(_show_worlds))], play_button)
	var want := chosen if chosen != "" else str(_last_world().get("name", ""))
	worlds_table.choose_id(want)
	if worlds_table.selected_id == "":
		worlds_table.choose_index(0)

func _worlds_table() -> Dictionary:
	var rows: Array = []
	var now := int(Time.get_unix_time_from_system())
	for entry in LocalServer.list_worlds(_local_data_dir):
		var name := str(entry["name"])
		var t := _world_played(name)
		rows.append({"id": name, "keys": {"played": t}, "cells": {"world": name,
			"game": _world_game_title(_local_data_dir, name),
			"played": when_text(t, now) if t > 0 else "Never"}})
	return {"title": "", "columns": [
			{"id": "world", "label": "World", "wide": true},
			{"id": "game", "label": "Game"},
			{"id": "played", "label": "Last played"}],
		"rows": rows, "sort": {"column": "played", "order": "desc"},
		"empty": {"why": "No worlds yet", "what": "Choose New world to make one."}}

## When a world was last played: the newest of the files its server writes
## as it runs (world.mt is rewritten at every start).
func _world_played(name: String) -> int:
	var dir := _local_data_dir.path_join("worlds").path_join(name)
	var newest := 0
	for f in ["world.mt", "env_meta.txt", "map_meta.txt", "map.sqlite", "players.sqlite"]:
		var path := dir.path_join(f)
		if FileAccess.file_exists(path):
			newest = maxi(newest, int(FileAccess.get_modified_time(path)))
	return newest

## "Today, 14:05", "Yesterday, 09:30", "3 days ago" or "1 November 2026", in
## the computer's own time zone.
static func when_text(t: int, now: int) -> String:
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var d := Time.get_datetime_dict_from_unix_time(t + bias)
	var days := floori((now + bias) / 86400.0) - floori((t + bias) / 86400.0)
	if days <= 0:
		return "Today, %02d:%02d" % [int(d.hour), int(d.minute)]
	if days == 1:
		return "Yesterday, %02d:%02d" % [int(d.hour), int(d.minute)]
	if days < 7:
		return "%d days ago" % days
	return "%d %s %d" % [int(d.day), MONTHS[int(d.month) - 1], int(d.year)]

## The chosen world's detail: its game, mods, play mode and hosting, with
## Change options and Delete, both quiet, under it. Play is the footer's
## accent.
func _show_world_detail(r: Dictionary) -> void:
	if not is_instance_valid(_world_detail):
		return
	for c in _world_detail.get_children():
		c.visible = false
		c.queue_free()
	if is_instance_valid(play_button):
		play_button.disabled = r.is_empty()
		play_button.tooltip_text = "" if not r.is_empty() else "Choose a world first."
	if r.is_empty():
		return
	var name := str(r["id"])
	var options := LocalServer.world_options(_local_data_dir, name)
	var title := Label.new()
	title.text = name
	title.add_theme_font_size_override("font_size", HEADING_SIZE)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_world_detail.add_child(title)
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	# A modpack whose members are all on shows as the pack, not its parts.
	var mods: Array = (options.get("mods", []) as Array).duplicate()
	for m in mods.duplicate():
		for member in LocalServer.mod_members(_local_data_dir.path_join("mods").path_join(str(m))):
			if str(member) != str(m):
				mods.erase(member)
	var hosting := "Only on this computer"
	if bool(cfg.get_value("local_host", "enabled", false)):
		hosting = "Open to LAN on port %s, as last time" % str(cfg.get_value("local_host", "port", "30000"))
	var facts := [
		["Game", _world_game_title(_local_data_dir, name)],
		["Mods", ", ".join(PackedStringArray(mods)) if not mods.is_empty() else "None besides the game's own"],
		["Play", "%s, damage %s" % ["Creative" if bool(options.get("creative", false)) else "Survival",
			"on" if bool(options.get("damage", true)) else "off"]],
		["Map", "Terrain Diffusion" if bool(options.get("terrain_diffusion", false)) else "Game default generator"],
		["Hosting", hosting],
		["Last played", str(r.get("cells", {}).get("played", ""))],
	]
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 4)
	_world_detail.add_child(grid)
	for fact in facts:
		var k := _quiet(grid, str(fact[0]))
		k.autowrap_mode = TextServer.AUTOWRAP_OFF
		var v := Label.new()
		v.text = str(fact[1])
		v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.custom_minimum_size.x = 120
		grid.add_child(v)
	var gap := Control.new()
	gap.custom_minimum_size.y = FAR - NEAR
	_world_detail.add_child(gap)
	_world_detail.add_child(_button("Change options", func() -> void:
		_world_back = _show_worlds.bind(name)
		_open_world(name, false)))
	var gap2 := Control.new()
	gap2.custom_minimum_size.y = FAR - NEAR
	_world_detail.add_child(gap2)
	# Delete stays quiet and apart from Play, with its confirmation.
	_world_detail.add_child(_button("Delete world", func() -> void: _confirm_delete(name)))
	_fit_targets(_world_detail)

## An existing world's options screen, and Play from it at once when
## `start` (Continue, and Play in Your worlds).
func _open_world(name: String, start: bool) -> void:
	if not _world_back.is_valid():
		_world_back = _show_main
	_show_world_form(name)
	if start and is_instance_valid(start_button) and start_button.is_inside_tree():
		_on_start_local()

## New world, as steps: game, name and seed, options, hosting.
func _show_new_game(back: Callable = Callable()) -> void:
	_world_back = back if back.is_valid() else _show_main
	_show_world_form("")

# The world form. Every control Start used to show is built here, whether
# New world's steps or an existing world's options show it, so
# _on_start_local reads one set of controls either way. world_option, the
# old world picker, stays as the hidden record of which world this is.
func _show_world_form(existing: String) -> void:
	mod_checks.clear()
	_game_buttons.clear()
	_world_steps = []
	_stop_showcase()
	var env := LocalServer.detect()
	if env.is_empty() or (env["games"] as Array).is_empty():
		_show_setup()
		return
	var is_new := existing == ""
	if is_new:
		_new_screen("New world", "Four steps, each with a default, so Next, Next, Next and Create makes a world. Its game and map are fixed once it is made.")
		_start_word = "Create"
	else:
		_new_screen(existing, "This world's options. Its game and map were fixed when it was made; play mode, mods, materials and hosting can change.")
		_start_word = "Play"
	var games: Array = env["games"]
	_local_data_dir = env["data_dir"]
	_step_label = _quiet(screen, "" if is_new else "%s. %s." % [
		_world_game_title(str(env["data_dir"]), existing),
		"Terrain Diffusion map" if bool(LocalServer.world_options(str(env["data_dir"]), existing).get("terrain_diffusion", false))
			else "The game's own map generator"])
	world_option = OptionButton.new()
	world_option.visible = false
	world_option.add_item("Create new world ...")
	world_option.set_item_metadata(0, {})
	for entry in LocalServer.list_worlds(_local_data_dir):
		world_option.add_item(str(entry["name"]))
		world_option.set_item_metadata(world_option.item_count - 1, entry)
	screen.add_child(world_option)
	var pages: Array = []
	for i in WORLD_STEPS.size():
		var page := VBoxContainer.new()
		page.add_theme_constant_override("separation", NEAR)
		page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		screen.add_child(page)
		pages.append(page)
		if not is_new and i == 3:
			# The options and hosting pages stand together here, a group apart.
			var apart := Control.new()
			apart.custom_minimum_size.y = FAR - 2 * NEAR
			page.add_child(apart)
		if is_new or i >= 2:
			_heading(page, WORLD_STEPS[i])

	# Step 1: the game, as a list of choices rather than a dropdown.
	var game_page: VBoxContainer = pages[0]
	game_option = OptionButton.new()
	game_option.visible = false
	for g in games:
		# Shown by title, because the directory name is the game id and the two
		# can differ (VoxeLibre lives in mineclone2). The metadata stays the id,
		# which is what the server is told.
		game_option.add_item(LocalServer.game_title(_local_data_dir, g))
		game_option.set_item_metadata(game_option.item_count - 1, g)
	for pack in _modpack_games(games):
		game_option.add_item(str(pack["title"]))
		game_option.set_item_metadata(game_option.item_count - 1, str(pack["meta"]))
	game_page.add_child(game_option)
	var choices := ButtonGroup.new()
	for i in game_option.item_count:
		# Radio buttons: which one is chosen shows plainly, and none of
		# them looks like the screen's accent.
		var pick := CheckBox.new()
		pick.button_group = choices
		pick.text = game_option.get_item_text(i)
		pick.custom_minimum_size.y = TARGET
		pick.set_meta("game_index", i)
		pick.pressed.connect(func() -> void:
			game_option.select(i)
			game_option.item_selected.emit(i))
		game_page.add_child(pick)
		_game_buttons.append(pick)
	var gap := Control.new()
	gap.custom_minimum_size.y = FAR - NEAR
	game_page.add_child(gap)
	_luanti_row(env, game_page)
	game_page.add_child(_button("Install another game", _show_setup))

	# Step 2: the name, and a seed for the map.
	var name_page: VBoxContainer = pages[1]
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", NEAR)
	name_page.add_child(grid)
	world_edit = _labelled_edit(grid, "World name", "my_world")
	_world_edit_label = grid.get_child(world_edit.get_index() - 1) as Label
	seed_edit = _labelled_edit(grid, "Seed", "Random",
		"Leave empty for a new map each time. The same seed and game make the same land, so a friend can share one. Terrain Diffusion worlds ignore it.")

	# Step 3: options, each with a default.
	var world_page: VBoxContainer = pages[2]
	var ogrid := GridContainer.new()
	ogrid.columns = 2
	ogrid.add_theme_constant_override("h_separation", 12)
	ogrid.add_theme_constant_override("v_separation", NEAR)
	world_page.add_child(ogrid)
	var gen_line := _grid_label(ogrid, "World generator")
	generator_option = OptionButton.new()
	generator_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	generator_option.add_item("Game default")
	generator_option.set_item_metadata(0, "default")
	# One entry per catalogued world. Each is a whole 62 km world at a metre a
	# node; they differ in where they are, not in how detailed they are.
	for world in LocalServer.terrain_worlds():
		generator_option.add_item("Terrain Diffusion: %s" % str(world.get("label", world.get("id", ""))))
		generator_option.set_item_metadata(generator_option.item_count - 1,
				"terrain:" + str(world.get("id", "")))
	generator_option.add_item("Terrain Diffusion, generate new (setup required)")
	generator_option.set_item_metadata(generator_option.item_count - 1, "terrain_generate")
	generator_option.set_item_disabled(generator_option.item_count - 1, true)
	ogrid.add_child(generator_option)
	_level(gen_line, generator_option)
	generator_info = PanelFit.info(generator_option, gen_line, TERRAIN_SUPPORT, world_page)
	var pbr_line := _grid_label(ogrid, "Materials")
	pbr_option = OptionButton.new()
	pbr_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pbr_option.add_item("PBR materials (recommended)")
	pbr_option.set_item_metadata(0, {"id": "bundled", "path": "", "pbr": true})
	var local_packs_dir := _local_data_dir.path_join("textures")
	for pack_name in LocalServer.list_texture_packs(_local_data_dir):
		var pack_path := local_packs_dir.path_join(str(pack_name))
		pbr_option.add_item("PBR: " + str(pack_name))
		pbr_option.set_item_metadata(pbr_option.item_count - 1,
				{"id": "pack:" + pack_path, "path": pack_path, "pbr": true})
	pbr_option.add_item("Standard, no PBR")
	pbr_option.set_item_metadata(pbr_option.item_count - 1,
			{"id": "standard", "path": "", "pbr": false})
	ogrid.add_child(pbr_option)
	_level(pbr_line, pbr_option)
	PanelFit.info(pbr_option, pbr_line, "Installed packs layer over the bundled game materials, filling uncovered textures from the bundled set. Shader packs are under Settings, Advanced graphics.", world_page)
	terrain_preview = TextureRect.new()
	terrain_preview.custom_minimum_size = Vector2(288, 288)
	terrain_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	terrain_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	terrain_preview.visible = false
	world_page.add_child(terrain_preview)
	terrain_download_label = _quiet(world_page, "")
	creative_check = CheckBox.new()
	creative_check.text = "Creative mode"
	world_page.add_child(creative_check)
	damage_check = CheckBox.new()
	damage_check.text = "Enable damage"
	damage_check.button_pressed = true
	world_page.add_child(damage_check)
	var mods := LocalServer.list_mods(_local_data_dir)
	var mods_page := _fold(world_page, "Mods (%d installed)" % mods.size(), _world_folds)
	if mods.is_empty():
		_quiet(mods_page, "No separately installed mods were found. Game-bundled mods are managed by the game.")
	else:
		for mod in mods:
			var check := CheckBox.new()
			check.text = str(mod)
			mods_page.add_child(check)
			mod_checks[str(mod)] = check
	_add_game_master_row(world_page)

	# Step 4: hosting, off unless asked for.
	var host_page: VBoxContainer = pages[3]
	host_check = CheckBox.new()
	host_check.text = "Open to LAN: friends on this network can join"
	host_page.add_child(host_check)
	lan_hint = _quiet(host_page, "")
	hosting_box = VBoxContainer.new()
	hosting_box.add_theme_constant_override("separation", NEAR)
	host_page.add_child(hosting_box)
	var host_grid := GridContainer.new()
	host_grid.columns = 2
	host_grid.add_theme_constant_override("h_separation", 12)
	host_grid.add_theme_constant_override("v_separation", NEAR)
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
	GlassStyle.tint_text(warning, Color(1, 0.8, 0.55, 0.8))
	hosting_box.add_child(warning)
	hosting_box.visible = false
	host_check.toggled.connect(func(on: bool) -> void:
		hosting_box.visible = on
		_refresh_lan_hint()
		_fit_targets(hosting_box))
	server_port_edit.text_changed.connect(func(_t: String) -> void: _refresh_lan_hint())

	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	world_edit.text = existing if not is_new else _free_world_name()
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
	world_option.select(0)
	for i in world_option.item_count:
		if not is_new and world_option.get_item_text(i) == existing:
			world_option.select(i)
			break
	# Hosting is off on a new world (maintainer, 2026-11-01); an existing
	# world opens as it was last started.
	host_check.button_pressed = false if is_new else bool(cfg.get_value("local_host", "enabled", false))
	hosting_box.visible = host_check.button_pressed
	server_name_edit.text = str(cfg.get_value("local_host", "name", "My Goanna server"))
	server_description_edit.text = str(cfg.get_value("local_host", "description", ""))
	server_port_edit.text = str(cfg.get_value("local_host", "port", "30000"))
	announce_check.button_pressed = bool(cfg.get_value("local_host", "announce", false))
	max_players_spin.value = int(cfg.get_value("local_host", "max_players", 8))
	_refresh_lan_hint()
	world_option.item_selected.connect(_on_world_selected)
	game_option.item_selected.connect(func(_i: int) -> void: _sync_game_buttons())
	start_button = _accent(_button(_start_word, _on_start_local))
	start_button.name = "Start"
	if is_new:
		next_button = _accent(_button("Next", _on_next))
		next_button.name = "Next"
		var row := _footer_row([_button("Back", _on_step_back)], next_button)
		row.add_child(start_button)
		_world_steps = pages
		world_edit.text_submitted.connect(func(_t): _on_next())
		seed_edit.text_submitted.connect(func(_t): _on_next())
	else:
		next_button = null
		(pages[0] as Control).visible = false
		(pages[1] as Control).visible = false
		_footer_row([_button("Back", func() -> void: _world_back.call())], start_button)
	generator_option.item_selected.connect(func(_index: int) -> void:
		_refresh_terrain_download_state())
	_on_world_selected(world_option.selected)
	_refresh_terrain_download_state()
	if is_new:
		_go_step(0)

## A name no world has yet: "New world", else "New world 2" and so on.
func _free_world_name() -> String:
	var base := "New world"
	var worlds := _local_data_dir.path_join("worlds")
	var name := base
	var n := 2
	while DirAccess.dir_exists_absolute(worlds.path_join(name)):
		name = "%s %d" % [base, n]
		n += 1
	return name

func _sync_game_buttons() -> void:
	for b in _game_buttons:
		if not is_instance_valid(b):
			continue
		(b as Button).set_pressed_no_signal(int(b.get_meta("game_index")) == game_option.selected)
		(b as Button).disabled = game_option.disabled

## Shows step `i` of New world, with Next as the accent, or Create on the
## last step.
func _go_step(i: int) -> void:
	if _world_steps.is_empty():
		return
	var had_focus := get_viewport().gui_get_focus_owner() != null
	_world_step = clampi(i, 0, _world_steps.size() - 1)
	for k in _world_steps.size():
		(_world_steps[k] as Control).visible = k == _world_step
	var last := _world_step == _world_steps.size() - 1
	if is_instance_valid(next_button):
		next_button.visible = not last
	start_button.visible = last
	_step_label.text = "Step %d of %d" % [_world_step + 1, _world_steps.size()]
	_sync_game_buttons()
	if narrator != null:
		narrator.announce("%s. %s" % [_step_label.text, WORLD_STEPS[_world_step]])
	if had_focus:
		GameUI.focus_first(_world_steps[_world_step])
	_fit_targets()

func _on_next() -> void:
	if _world_steps.is_empty():
		_on_start_local()
		return
	if _world_step == 1:
		var err := _world_name_error(world_edit.text.strip_edges(), {})
		if err != "":
			_fail(err)
			return
	status_label.text = ""
	if _world_step >= _world_steps.size() - 1:
		_on_start_local()
		return
	_go_step(_world_step + 1)

func _on_step_back() -> void:
	if not _world_steps.is_empty() and _world_step > 0:
		_go_step(_world_step - 1)
	else:
		_world_back.call()

## Why `world` cannot be a new world's name, or "". `existing` is the world
## picker's entry: {} for a new world.
func _world_name_error(world: String, existing: Dictionary) -> String:
	if world == "":
		return "Enter a name for the new world."
	var allowed := RegEx.new()
	allowed.compile("^[A-Za-z0-9_ -]{1,40}$")
	if allowed.search(world) == null:
		return "World names are 1 to 40 characters: letters, digits, spaces, _ and -."
	if existing.is_empty() and DirAccess.dir_exists_absolute(_local_data_dir.path_join("worlds").path_join(world)):
		return "A world named '%s' already exists. Choose it from Your worlds, or choose another name; it will not be overwritten." % world
	return ""

# The AI game master: how the host attaches a language model app to the
# world, copied ready to paste. Goanna starts no director service itself:
# the join notice tells players a language model is acting as game master,
# so the service runs only when a model app starts it, and lives as long as
# that app (LocalServer.director_attach, 2026-10-31). Hidden when this copy
# has no director folder.
func _add_game_master_row(page: VBoxContainer) -> void:
	if LocalServer.director_tool("goanna-director-mcp") == "":
		return
	var note := Label.new()
	note.text = "AI game master: off until you connect a language model app, such as Claude Code, to this world. Goanna runs none itself. Players are told when one connects and can opt out."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	GlassStyle.tint_text(note, Color(1, 1, 1, 0.6))
	page.add_child(note)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var claude := _button("Copy Claude Code command", func(): _copy_game_master("claude"))
	claude.tooltip_text = "Run the copied command once in a terminal, then start Claude Code: it runs the game master for this world while it is open."
	row.add_child(claude)
	var json := _button("Copy MCP settings", func(): _copy_game_master("json"))
	json.tooltip_text = "For another MCP app: paste into its server settings."
	row.add_child(json)
	page.add_child(row)

# The world the Start button would start, as a folder, or "" before it has
# a name.
func _chosen_world_path() -> String:
	var existing: Dictionary = world_option.get_item_metadata(world_option.selected) \
		if is_instance_valid(world_option) and world_option.selected >= 0 else {}
	var world := str(existing.get("name", "")) if not existing.is_empty() \
		else (world_edit.text.strip_edges() if is_instance_valid(world_edit) else "")
	return "" if world == "" else _local_data_dir.path_join("worlds").path_join(world)

func _copy_game_master(kind: String) -> void:
	var world := _chosen_world_path()
	if world == "":
		_fail("Name or choose the world first: the game master is connected to one world.")
		return
	var text := str(LocalServer.director_attach(world).get(kind, ""))
	DisplayServer.clipboard_set(text)
	print("menu: game master %s copied: %s" % [kind, text])
	GlassStyle.tint_text(status_label, Color(1, 1, 1, 0.7))
	status_label.text = "Copied. " + ("Run it once in a terminal, then start Claude Code; ask it to be the game master once you are in the world." \
		if kind == "claude" else "Paste it into your MCP app's server settings.")

# Games published as a modpack on another game (Kindred Holdfast on
# Mineclonia), offered in the Game list when installed and their game is
# too. A copy installed under another folder name is found by its first
# member. Each is {title, meta}, meta being "<gameid>|<mod folder>".
func _modpack_games(games: Array) -> Array:
	var out: Array = []
	var mods_dir := _local_data_dir.path_join("mods")
	var installed_mods := LocalServer.list_mods(_local_data_dir)
	for entry in LocalServer.INSTALLABLE_GAMES:
		var requires := str(entry.get("requires", ""))
		if str(entry.get("kind", "game")) != "modpack" or not games.has(requires):
			continue
		var marker := str((entry.get("members", [entry["id"]]) as Array)[0])
		for installed in installed_mods:
			var name := str(installed)
			if name == str(entry["id"]):
				out.append({"title": str(entry["title"]), "meta": "%s|%s" % [requires, name]})
				break
			if LocalServer.mod_members(mods_dir.path_join(name)).has(marker):
				out.append({"title": "%s from mods/%s" % [str(entry["title"]), name],
						"meta": "%s|%s" % [requires, name]})
				break
	return out

# What a host tells friends: how Scan finds this world, and the address to
# type when it does not.
func _lan_notice(port: int) -> String:
	var addresses := LocalServer.lan_addresses()
	if addresses.is_empty():
		return "Open to LAN on port %d, but this computer has no local network address." % port
	var text := "Open to LAN: friends choose Join a game, then Scan local network, or type %s port %d." % [
		" or ".join(addresses), port]
	if port < 30000 or port > 30005:
		text += " Scan looks only at ports 30000 to 30005, so on port %d they must type it." % port
	return text

func _refresh_lan_hint() -> void:
	if not is_instance_valid(lan_hint) or not is_instance_valid(host_check):
		return
	lan_hint.visible = host_check.button_pressed
	var ptext := server_port_edit.text.strip_edges() if is_instance_valid(server_port_edit) else "30000"
	var port := int(ptext) if ptext.is_valid_int() else 30000
	lan_hint.text = _lan_notice(port) + " If they cannot find it, allow UDP port %d through this computer's firewall." % port

func _on_world_selected(index: int) -> void:
	var entry: Dictionary = world_option.get_item_metadata(index)
	var is_new := entry.is_empty()
	world_edit.editable = is_new
	world_edit.visible = is_new
	# Its label goes with it: a grid cell left behind shifted every row
	# below it a column, so Game sat beside World generator's picker.
	if is_instance_valid(_world_edit_label):
		_world_edit_label.visible = is_new
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
	# A world made with a game modpack (Kindred) shows as that game.
	for i in game_option.item_count:
		var meta := str(game_option.get_item_metadata(i))
		if meta.get_slice("|", 0) == gid and meta.contains("|") \
				and (options.get("mods", []) as Array).has(meta.get_slice("|", 1)):
			game_option.select(i)
			break
	var saved_terrain := str(options.get("terrain_world", ""))
	if saved_terrain == "" and bool(options.get("terrain_diffusion", false)):
		saved_terrain = LocalServer.default_terrain_id()
	generator_option.select(0)
	if saved_terrain != "":
		for i in range(generator_option.item_count):
			if str(generator_option.get_item_metadata(i)) == "terrain:" + saved_terrain:
				generator_option.select(i)
				break
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

const TERRAIN_SUPPORT := "Terrain Diffusion uses any game's registered biomes. Mineclonia currently has the fullest vegetation support."

# The catalogue id behind the current selection, or "" when the selection is
# not one of the downloadable worlds.
func _selected_terrain_id() -> String:
	if not is_instance_valid(generator_option) or generator_option.selected < 0:
		return ""
	var meta := str(generator_option.get_item_metadata(generator_option.selected))
	return meta.substr(8) if meta.begins_with("terrain:") else ""

func _refresh_terrain_download_state() -> void:
	if not is_instance_valid(terrain_download_label) or not is_instance_valid(generator_option):
		return
	var id := _selected_terrain_id()
	var world := LocalServer.terrain_world(id) if id != "" else {}
	var shown := not world.is_empty() and not generator_option.disabled
	terrain_download_label.visible = shown
	if is_instance_valid(terrain_preview):
		terrain_preview.visible = shown
	if is_instance_valid(generator_info):
		var about := str(world.get("description", "")) if shown else ""
		generator_info.set_info(TERRAIN_SUPPORT if about == "" else about + "\n\n" + TERRAIN_SUPPORT)
	if not shown:
		return
	if is_instance_valid(terrain_preview):
		var art := str(world.get("preview", ""))
		terrain_preview.texture = load(art) if art != "" and ResourceLoader.exists(art) else null
	if LocalServer.terrain_cached(id):
		terrain_download_label.text = "%s is downloaded and ready." % str(world.get("label", id))
		if is_instance_valid(start_button):
			start_button.text = _start_word
	else:
		terrain_download_label.text = "One-time download: %.1f MB. It is kept for later worlds." % (
				int(world.get("bytes", 0)) / 1000000.0)
		if is_instance_valid(start_button):
			start_button.text = "Download and " + _start_word.to_lower()

func _start_terrain_download() -> void:
	if terrain_http != null:
		return
	var downloads := ProjectSettings.globalize_path("user://content/downloads")
	DirAccess.make_dir_recursive_absolute(downloads)
	var id := _selected_terrain_id()
	var world := LocalServer.terrain_world(id)
	if world.is_empty():
		_pending_terrain_start = false
		_fail("No terrain world is selected.")
		return
	_terrain_downloading = id
	_terrain_archive_path = downloads.path_join(id + ".zip.part")
	DirAccess.remove_absolute(_terrain_archive_path)
	terrain_http = HTTPRequest.new()
	terrain_http.download_file = _terrain_archive_path
	add_child(terrain_http)
	terrain_http.request_completed.connect(_on_terrain_download_completed)
	var err := terrain_http.request(str(world.get("url", "")))
	if err != OK:
		terrain_http.queue_free()
		terrain_http = null
		_pending_terrain_start = false
		_fail("Could not start the Terrain Diffusion download.")
		return
	start_button.disabled = true
	GlassStyle.tint_text(status_label, Color(1, 1, 1, 0.7))
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
	var world := LocalServer.terrain_world(_terrain_downloading)
	var actual_hash := FileAccess.get_sha256(_terrain_archive_path)
	if actual_hash.to_lower() != str(world.get("sha256", "")):
		DirAccess.remove_absolute(_terrain_archive_path)
		_pending_terrain_start = false
		start_button.disabled = false
		_fail("Terrain download failed its integrity check and was discarded.")
		return
	var install_error := _extract_terrain_world(_terrain_archive_path, _terrain_downloading)
	DirAccess.remove_absolute(_terrain_archive_path)
	if install_error != "":
		_pending_terrain_start = false
		start_button.disabled = false
		_fail(install_error)
		return
	_refresh_terrain_download_state()
	status_label.text = "%s downloaded." % str(world.get("label", _terrain_downloading))
	start_button.disabled = false
	if _pending_terrain_start:
		_pending_terrain_start = false
		call_deferred("_on_start_local")

# Before a world starts with the recommended materials: install the newest
# version of every material bundle for its game that the catalogue offers,
# then start it. Pressing Create or Play again while this runs starts with what
# is installed. A failed or slow catalogue starts with what is installed
# too; the updater gives up on the catalogue after 15 seconds.
func _fetch_latest_materials(game: String) -> void:
	if _material_check != null or _material_wait_game != "":
		_material_check_done(game)
		return
	start_button.disabled = false
	GlassStyle.tint_text(status_label, Color(1, 1, 1, 0.7))
	status_label.text = "Checking for the latest materials ..."
	# The menu's background upgrade may be fetching the same bundle; two
	# downloads of one file would collide, so let it finish first.
	if is_instance_valid(_background_materials) and not _background_materials.is_settled():
		_material_wait_game = game
		_background_materials.settled.connect(func() -> void:
			if _material_wait_game == game:
				_material_wait_game = ""
				_fetch_latest_materials(game), CONNECT_ONE_SHOT)
		set_process(true)
		return
	_material_check = AssetUpdater.new()
	_material_check.for_game = game
	_material_check.settled.connect(_material_check_done.bind(game), CONNECT_ONE_SHOT)
	add_child(_material_check)
	set_process(true)

func _material_check_done(game: String) -> void:
	_material_wait_game = ""
	if is_instance_valid(_material_check):
		_material_check.queue_free()
	_material_check = null
	_materials_current[game] = true
	status_label.text = ""
	_on_start_local.call_deferred()

func _material_progress_text() -> String:
	if _material_wait_game != "":
		var bg: Dictionary = _background_materials.progress() \
			if is_instance_valid(_background_materials) else {}
		if not bg.is_empty() and int(bg.get("size", -1)) > 0:
			return "Updating materials: %.0f / %.0f MB. Press it again to play with the installed ones." % [
				int(bg.bytes) / 1000000.0, int(bg.size) / 1000000.0]
		return "Checking for the latest materials ..."
	var p: Dictionary = _material_check.progress()
	if p.is_empty():
		return "Checking for the latest materials ..."
	if int(p.get("size", -1)) > 0:
		return "Downloading the latest materials: %.0f / %.0f MB. Press it again to play with the installed ones." % [
			int(p.bytes) / 1000000.0, int(p.size) / 1000000.0]
	return "Downloading the latest materials ..."

func _extract_terrain_world(archive_path: String, id: String) -> String:
	var zip := ZIPReader.new()
	if zip.open(archive_path) != OK:
		return "The downloaded terrain archive could not be opened."
	var parent := ProjectSettings.globalize_path("user://content")
	DirAccess.make_dir_recursive_absolute(parent)
	var staging := parent.path_join(".%s-install-%d" % [id, OS.get_process_id()])
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
	if not LocalServer.terrain_dir_valid(staging, LocalServer.terrain_world(id)):
		return "The downloaded terrain archive is incomplete."
	var destination := LocalServer.terrain_cache_dir(id)
	if DirAccess.dir_exists_absolute(destination):
		var old := destination + ".invalid-%d" % int(Time.get_unix_time_from_system())
		if DirAccess.rename_absolute(destination, old) != OK:
			return "Could not replace the invalid terrain cache."
	if DirAccess.rename_absolute(staging, destination) != OK:
		return "Could not install the downloaded terrain cache."
	return ""

## Delete, from Your worlds: asks first, then moves the world aside.
func _confirm_delete(name: String) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Delete world"
	dialog.dialog_text = "Move '%s' out of the world list? It will be kept in .goanna-trash for recovery." % name
	dialog.ok_button_text = "Delete"
	for b in [dialog.get_ok_button(), dialog.get_cancel_button()]:
		b.custom_minimum_size = Vector2(96, TARGET)
	dialog.confirmed.connect(func() -> void:
		var err := LocalServer.delete_world_recoverably(_local_data_dir, name)
		if err != "":
			_fail(err)
		else:
			_show_worlds()
			status_label.text = "World moved to .goanna-trash.")
	add_child(dialog)
	dialog.popup_centered()

func _on_start_local() -> void:
	# "<gameid>|<mod>" for a game published as a modpack: the server runs
	# the game and the world loads the modpack (_modpack_games).
	var game_choice := str(game_option.get_item_metadata(game_option.selected))
	var game := game_choice.get_slice("|", 0)
	var game_pack := game_choice.get_slice("|", 1) if game_choice.contains("|") else ""
	var generator := str(generator_option.get_item_metadata(generator_option.selected))
	var terrain_world_id := generator.substr(8) if generator.begins_with("terrain:") else ""
	var terrain_diffusion := terrain_world_id != ""
	var existing: Dictionary = world_option.get_item_metadata(world_option.selected)
	var world := str(existing.get("name", "")) if not existing.is_empty() else world_edit.text.strip_edges()
	# A world belongs to the game that made it. Loading it under another
	# game leaves every stored node unknown (a world of pink "unknown
	# node" blocks), so continue an existing world with its own game.
	var name_error := _world_name_error(world, existing)
	if name_error != "":
		_go_step(1)
		_fail(name_error)
		return
	if host_check.button_pressed:
		var ptext := server_port_edit.text.strip_edges()
		if not ptext.is_valid_int() or int(ptext) < 1 or int(ptext) > 65535:
			_go_step(3)
			_fail("Hosting port must be between 1 and 65535.")
			return
	if existing.is_empty() and terrain_world_id != "" and not LocalServer.terrain_cached(terrain_world_id):
		_pending_terrain_start = true
		_start_terrain_download()
		return
	# Recommended materials means the newest: the world gets a copy of the
	# installed pack as it starts, so fetch a newer one first.
	if _local_pbr_enabled() and str(_local_pbr_selection().get("id", "")) == "bundled" \
			and not _materials_current.get(game, false) \
			and (OS.get_environment("GOANNA_LOCAL_TEST") == ""
				or OS.get_environment("GOANNA_ASSET_CATALOGUE_URL") != ""):
		_fetch_latest_materials(game)
		return
	var enabled_mods: Array = []
	for mod in mod_checks:
		if (mod_checks[mod] as CheckBox).button_pressed:
			enabled_mods.append(mod)
	if game_pack != "" and not enabled_mods.has(game_pack):
		enabled_mods.append(game_pack)
	# Scripted runs must not touch the player's remembered choices: a test
	# world would otherwise turn up prefilled the next time they open the menu.
	if OS.get_environment("GOANNA_LOCAL_TEST") == "":
		var cfg := ConfigFile.new()
		cfg.load(CFG_PATH)
		cfg.set_value("local", "game", game_choice)
		cfg.set_value("local", "terrain_diffusion", terrain_diffusion)
		cfg.set_value("local", "terrain_world", terrain_world_id)
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
		"terrain_diffusion": terrain_diffusion, "terrain_world": terrain_world_id,
		"creative": creative_check.button_pressed,
		"damage": damage_check.button_pressed, "pbr_materials": _local_pbr_enabled(),
		"mods": enabled_mods,
		"host": host_check.button_pressed, "server_name": server_name_edit.text.strip_edges(),
		"server_description": server_description_edit.text.strip_edges(),
		"password": server_password_edit.text, "announce": public_announce,
		"max_users": maxi(int(max_players_spin.value), local_roster.size())}
	# A seed only means anything to a world being made.
	if existing.is_empty() and is_instance_valid(seed_edit) and seed_edit.text.strip_edges() != "":
		launch["seed"] = seed_edit.text.strip_edges()
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
	GlassStyle.tint_text(status_label, Color(1, 1, 1, 0.7))
	status_label.text = "Starting %s ..." % world
	# Said again in chat once the host is in the world (game_ui.gd), where
	# the friends asking for the address are.
	OS.set_environment("GOANNA_LAN_NOTICE", _lan_notice(server.port) if host_check.button_pressed else "")
	if host_check.button_pressed:
		status_label.text += " " + _lan_notice(server.port)
	server_deadline = _now() + SERVER_START_TIMEOUT_SECONDS
	set_process(true)

# Runs only while something is in flight (set_process(true) where each one
# starts): a Luanti install, a game, terrain or material download, or a local
# server coming up. The first of those running owns the status line. When the
# server answers ready, the GOANNA_* variables are set and the game scene
# takes over.
func _process(_delta: float) -> void:
	var installing := _poll_luanti_install()
	if game_http != null:
		GlassStyle.tint_text(status_label, Color(1, 1, 1, 0.7))
		status_label.text = "Downloading %s: %.1f / %.1f MB" % [str(_downloading_game["title"]),
			game_http.get_downloaded_bytes() / 1000000.0, int(_downloading_game["bytes"]) / 1000000.0]
		return
	if terrain_http != null:
		var downloaded := terrain_http.get_downloaded_bytes()
		var total := terrain_http.get_body_size()
		if total > 0:
			status_label.text = "Downloading Terrain Diffusion default world: %.1f / %.1f MB" % [downloaded / 1000000.0, total / 1000000.0]
		else:
			status_label.text = "Downloading Terrain Diffusion default world: %.1f MB" % (downloaded / 1000000.0)
		return
	if is_instance_valid(_material_check) or _material_wait_game != "":
		status_label.text = _material_progress_text()
		return
	if server == null:
		if not installing:
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
			var world_scene := preload("res://game/main.tscn").instantiate()
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
		# Marks a server this client started: main.gd reports a server that
		# died while connecting.
		# GOANNA_SP_MATCH gives each local world its own block store. The
		# server itself is stopped through LocalLaunch.server (_go_to_game).
		OS.set_environment("GOANNA_SP_PID", str(server.pid))
		OS.set_environment("GOANNA_SP_MATCH", server.world_path)
		_go_to_game()
	elif st != "starting":
		set_process(false)
		var startup_log: String = server.log_path
		server.stop()
		server = null
		_fail(st, startup_log)
		start_button.disabled = false
	elif _now() > server_deadline:
		set_process(false)
		var startup_log: String = server.log_path
		server.stop()
		server = null
		_fail("The server did not start within five minutes.", startup_log)
		if start_button:
			start_button.disabled = false

	else:
		var elapsed := maxi(0, int(SERVER_START_TIMEOUT_SECONDS - (server_deadline - _now())))
		status_label.text = "Starting world: loading server mods and generating spawn. %d seconds elapsed." % elapsed

func _local_player_name() -> String:
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	var n := str(cfg.get_value("player", "name", ""))
	return n if n != "" else "player"

# --- join a server -----------------------------------------------------------

const JOIN_TITLE := "Join a game"
# Which folds on Join a game are open, kept while the menu is open.
var _join_folds := {}
# An address chosen on another screen (Browse public servers), filled in
# when Join a game is built again.
var _pending_join := {}
var recent_tree: Tree
# The address Connect will use, said in a line above the footer.
var join_target: Label

# Join a game: the games near you first (this network, servers joined
# before), then who you are, then Connect. The public list and a typed
# address are quiet ways in, not the first thing on the screen.
func _show_join() -> void:
	_stop_showcase()
	_new_screen(JOIN_TITLE, "Join a world a friend is hosting on this network, a server you joined before, or a public server.")
	_heading(screen, "On this network")
	_build_lan_list()
	_heading(screen, "Recent servers")
	_build_recent_list()
	_heading(screen, "You")
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", NEAR)
	screen.add_child(grid)
	name_edit = _labelled_edit(grid, "Player name", "")
	pass_edit = _labelled_edit(grid, "Password", "",
		"On a server that allows registration, a new name is registered with this password.")
	pass_edit.secret = true
	var gap := Control.new()
	gap.custom_minimum_size.y = FAR - NEAR
	screen.add_child(gap)
	var address := _fold(screen, "Type an address", _join_folds)
	var agrid := GridContainer.new()
	agrid.columns = 2
	agrid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	agrid.add_theme_constant_override("h_separation", 12)
	agrid.add_theme_constant_override("v_separation", NEAR)
	address.add_child(agrid)
	host_edit = _labelled_edit(agrid, "Server address", "127.0.0.1")
	port_edit = _labelled_edit(agrid, "Port", "30000")
	var look := _fold(screen, "Materials and shaders", _join_folds)
	var lgrid := GridContainer.new()
	lgrid.columns = 2
	lgrid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lgrid.add_theme_constant_override("h_separation", 12)
	lgrid.add_theme_constant_override("v_separation", NEAR)
	look.add_child(lgrid)
	var pbr_label := Label.new()
	pbr_label.text = "Materials"
	lgrid.add_child(pbr_label)
	join_pbr_option = OptionButton.new()
	join_pbr_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_pbr_option.add_item("PBR: server materials (recommended)")
	join_pbr_option.set_item_metadata(0, {"id": "server", "path": "", "pbr": true})
	join_pbr_option.add_item("Standard, no PBR")
	join_pbr_option.set_item_metadata(1, {"id": "standard", "path": "", "pbr": false})
	for game_pack in [["minetest_game", "Installed Minetest Game PBR"],
			["mineclonia", "Installed Mineclonia PBR"]]:
		var asset_path := LocalServer.bundled_pbr_texture_path(str(game_pack[0]))
		if asset_path != "":
			join_pbr_option.add_item(str(game_pack[1]))
			join_pbr_option.set_item_metadata(join_pbr_option.item_count - 1,
				{"id": game_pack[0], "path": asset_path, "pbr": true})
	var data_dir := LocalServer.data_dir_or_empty()
	var packs_dir := data_dir.path_join("textures") if data_dir != "" else ""
	var join_packs: Array = LocalServer.list_texture_packs(data_dir) if data_dir != "" else []
	for pack_name in join_packs:
		var pack_path := packs_dir.path_join(str(pack_name))
		join_pbr_option.add_item("PBR: " + str(pack_name))
		join_pbr_option.set_item_metadata(join_pbr_option.item_count - 1,
			{"id": "pack:" + pack_path, "path": pack_path, "pbr": true})
	lgrid.add_child(join_pbr_option)
	var shader_line := _grid_label(lgrid, "Shaders")
	join_shader_option = ShaderPackRow.build_join_picker(lgrid, shader_line)
	_level(shader_line, join_shader_option.get_parent() as Control)
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
	join_target = _quiet(_footer, "")
	connect_button = _accent(_button("Connect", _on_connect))
	connect_button.name = "Connect"
	_footer_row([_button("Back", _show_main),
		_button("Browse public servers", _show_public_servers)], connect_button)
	for e in [host_edit, port_edit, name_edit, pass_edit]:
		e.text_submitted.connect(func(_t): _on_connect())
	for e in [host_edit, port_edit]:
		e.text_changed.connect(func(_t: String) -> void: _show_join_target())
	if not _pending_join.is_empty():
		host_edit.text = str(_pending_join.get("address", ""))
		port_edit.text = str(_pending_join.get("port", 30000))
		status_label.text = str(_pending_join.get("said", ""))
		GlassStyle.tint_text(status_label, QUIET)
		_pending_join = {}
	_show_join_target()
	name_edit.grab_focus()

## The line above Connect saying where it will go, so an address filled in
## by a list (or remembered) is never hidden in a folded field.
func _show_join_target() -> void:
	if not is_instance_valid(join_target):
		return
	var host := host_edit.text.strip_edges()
	var port := port_edit.text.strip_edges()
	join_target.text = "Connect goes to %s port %s." % [host if host != "" else "127.0.0.1",
		port if port != "" else "30000"]

const RECENT_MAX := 8

# Servers joined before, newest first, from goanna.cfg. An older goanna.cfg
# has only the last address, which counts as one.
func _recent_servers() -> Array:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return []
	var recent: Array = cfg.get_value("server", "recent", [])
	if recent.is_empty() and str(cfg.get_value("server", "host", "")) != "":
		recent = [{"address": str(cfg.get_value("server", "host", "")),
			"port": int(str(cfg.get_value("server", "port", "30000"))) if str(cfg.get_value("server", "port", "")).is_valid_int() else 30000,
			"name": ""}]
	return recent

func _remember_recent(cfg: ConfigFile, address: String, port: int, label: String) -> void:
	var recent: Array = cfg.get_value("server", "recent", [])
	var kept: Array = []
	var old_name := ""
	for e in recent:
		if typeof(e) == TYPE_DICTIONARY and (str(e.get("address", "")) != address or int(e.get("port", 0)) != port):
			kept.append(e)
		elif typeof(e) == TYPE_DICTIONARY:
			old_name = str(e.get("name", ""))
	kept.push_front({"address": address, "port": port, "name": label if label != "" else old_name})
	cfg.set_value("server", "recent", kept.slice(0, RECENT_MAX))

func _build_recent_list() -> void:
	var recent := _recent_servers()
	if recent.is_empty():
		_quiet(screen, "Servers you join are listed here, so the next time is one press.")
		recent_tree = null
		return
	recent_tree = Tree.new()
	recent_tree.columns = 1
	recent_tree.hide_root = true
	recent_tree.custom_minimum_size = Vector2(0, mini(recent.size(), 4) * 36 + 16)
	recent_tree.focus_mode = Control.FOCUS_ALL
	recent_tree.item_selected.connect(func() -> void: _on_list_picked(recent_tree))
	recent_tree.item_activated.connect(func() -> void:
		_on_list_picked(recent_tree)
		_on_connect())
	screen.add_child(recent_tree)
	var root := recent_tree.create_item()
	for e in recent:
		var it := recent_tree.create_item(root)
		var where := "%s port %d" % [str(e.get("address", "")), int(e.get("port", 30000))]
		var label := str(e.get("name", ""))
		it.set_text(0, where if label == "" else "%s, %s" % [label, where])
		it.set_metadata(0, {"address": str(e.get("address", "")), "port": int(e.get("port", 30000))})

# --- servers on this network ------------------------------------------------

# Luanti servers do not announce themselves on a LAN, so Scan asks each
# address on this machine's private /24 networks (net/lan_scan.gd). It runs
# only when pressed.
const LanScan := preload("res://net/lan_scan.gd")

var lan_tree: Tree
var lan_scan: Node
var lan_button: Button

func _build_lan_list() -> void:
	lan_tree = Tree.new()
	lan_tree.custom_minimum_size = Vector2(0, 96)
	lan_tree.columns = 1
	lan_tree.hide_root = true
	lan_tree.item_selected.connect(_on_lan_picked)
	lan_tree.focus_mode = Control.FOCUS_ALL
	lan_tree.item_activated.connect(func() -> void:
		_on_lan_picked()
		_on_connect())
	screen.add_child(lan_tree)
	var root := lan_tree.create_item()
	var hint := lan_tree.create_item(root)
	hint.set_text(0, "Press Scan local network to look for Luanti servers here.")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	screen.add_child(row)
	lan_button = _button("Scan local network", _scan_lan)
	row.add_child(lan_button)

func _scan_lan() -> void:
	if lan_scan == null:
		lan_scan = LanScan.new()
		add_child(lan_scan)
		lan_scan.found.connect(_on_lan_found)
		lan_scan.finished.connect(_on_lan_finished)
	lan_tree.clear()
	var root := lan_tree.create_item()
	var nets: Array = LanScan.local_prefixes()
	if not lan_scan.start():
		var it := lan_tree.create_item(root)
		it.set_text(0, "No local network was found to scan. Open Type an address below instead.")
		return
	lan_button.disabled = true
	var it := lan_tree.create_item(root)
	it.set_text(0, "Scanning %s ..." % ", ".join(nets.map(func(n): return str(n) + ".x")))
	it.set_metadata(0, "scanning")

func _on_lan_found(host: String, port: int) -> void:
	if not is_instance_valid(lan_tree):
		return
	var root := lan_tree.get_root()
	var first := root.get_first_child()
	if first != null and str(first.get_metadata(0)) == "scanning":
		first.free()
	var it := lan_tree.create_item(root)
	it.set_text(0, "Luanti server at %s:%d" % [host, port])
	it.set_metadata(0, {"address": host, "port": port})
	# The only one found: fill the fields, so Connect is the next press.
	if root.get_child_count() == 1:
		it.select(0)

func _on_lan_finished(count: int) -> void:
	if not is_instance_valid(lan_tree):
		return
	lan_button.disabled = false
	if count == 0:
		lan_tree.clear()
		var it := lan_tree.create_item(lan_tree.create_item())
		it.set_text(0, "No Luanti servers answered on ports 30000 to 30005. Check the host is running and its firewall allows UDP 30000.")

func _on_lan_picked() -> void:
	_on_list_picked(lan_tree)

# A row of the network or recent list fills the address Connect uses.
func _on_list_picked(tree: Tree) -> void:
	if not is_instance_valid(tree):
		return
	var it := tree.get_selected()
	if it == null:
		return
	var e = it.get_metadata(0)
	if typeof(e) != TYPE_DICTIONARY:
		return
	host_edit.text = str(e.address)
	port_edit.text = str(e.port)
	_show_join_target()

# --- public server list ------------------------------------------------------

# The same list Luanti's own client shows, from the same place: serverlist_url
# defaults to https://servers.luanti.org (luanti/src/defaultsettings.cpp). This
# is the only request Goanna makes to anything other than the server the player
# chose, and it asks for nothing a vanilla client does not ask for. It is also
# entirely optional: Join a game works with the list absent, which is what
# happens with no network. It is fetched only when Browse public servers is
# pressed.
const SERVER_LIST_URL := "https://servers.luanti.org/list"

var server_table: VBoxContainer
var server_http: HTTPRequest
# Why the last join ended, on the status line until the player acts: the
# list's server count must not replace it when the list arrives.
var _join_reason_shown := false
var _server_rows: Array = []
var _server_chosen := {}
var use_server_button: Button

## Browse public servers: the public list as a table (name, game, players,
## ping) with search. Use this server fills Join a game's address.
func _show_public_servers() -> void:
	_new_screen("Public servers", "The public Luanti server list, the one Luanti's own client shows. A large server sends a great deal of media before it lets anyone in.", true)
	server_table = DataTable.new()
	screen.add_child(server_table)
	server_table.host_tools.add_child(_button("Refresh list", _fetch_server_list))
	server_table.row_chosen.connect(_on_server_picked)
	server_table.row_activated.connect(func(r: Dictionary) -> void:
		_on_server_picked(r)
		_use_public_server())
	use_server_button = _accent(_button("Use this server", _use_public_server))
	use_server_button.name = "UseServer"
	use_server_button.disabled = true
	use_server_button.tooltip_text = "Choose a server in the list first."
	_footer_row([_button("Back", _show_join)], use_server_button)
	_server_chosen = {}
	_set_server_rows([], "Fetching the server list", "It comes from " + SERVER_LIST_URL + ".")
	_fetch_server_list()

func _fetch_server_list() -> void:
	# Development aid: GOANNA_SERVER_LIST_FILE=<json> reads a saved list, so
	# captures and tests show the table without the network.
	var saved := OS.get_environment("GOANNA_SERVER_LIST_FILE")
	if saved != "":
		_on_server_list(0, 200, PackedStringArray(),
				FileAccess.get_file_as_bytes(saved))
		return
	if server_http == null:
		server_http = HTTPRequest.new()
		add_child(server_http)
		server_http.request_completed.connect(_on_server_list)
	# Back out and in again before the last fetch answered: ask afresh.
	server_http.cancel_request()
	var err := server_http.request(SERVER_LIST_URL)
	if err != OK:
		_set_server_rows([], "The server list could not be fetched",
				"Go back and use Type an address, or try Refresh list.")

func _on_server_list(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	# The reply can arrive after the player has left this screen, which frees
	# the table it would be written into.
	if not is_instance_valid(server_table) or not server_table.is_inside_tree():
		return
	if code != 200:
		_set_server_rows([], "The server list is unavailable (HTTP %d)" % code,
				"Go back and use Type an address, or try Refresh list.")
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("list"):
		_set_server_rows([], "The server list could not be read",
				"Go back and use Type an address, or try Refresh list.")
		return
	_server_rows = parsed["list"]
	var rows: Array = []
	var seen := {}
	for e in _server_rows:
		if typeof(e) != TYPE_DICTIONARY or not e.has("address"):
			continue
		var id := "%s:%d" % [str(e.get("address", "")), int(e.get("port", 30000))]
		if seen.has(id):
			continue
		seen[id] = true
		var ping := float(e.get("ping", -1.0))
		var cells := {"name": str(e.get("name", e.get("address", ""))),
			"game": _public_game_title(str(e.get("gameid", ""))),
			"players": "%d/%d" % [int(e.get("clients", 0)), int(e.get("clients_max", 0))]}
		if ping >= 0.0:
			cells["ping"] = int(round(ping * 1000.0))
		rows.append({"id": id, "server": e, "cells": cells,
			"keys": {"players": int(e.get("clients", 0))},
			"detail": [str(e.get("description", ""))]})
	_set_server_rows(rows, "No servers are listed", "Try Refresh list in a minute.")
	if not _join_reason_shown:
		status_label.text = "%d servers. Choose one, then Use this server." % rows.size()
		GlassStyle.tint_text(status_label, QUIET)

# A game's title for the public list, which sends only the game's id: the
# installed game's own title, else a game Goanna knows, else the id as sent.
func _public_game_title(gameid: String) -> String:
	if gameid == "":
		return ""
	var data_dir := LocalServer.data_dir_or_empty()
	if data_dir != "" and LocalServer.list_games(data_dir).has(gameid):
		return LocalServer.game_title(data_dir, gameid)
	for entry in LocalServer.INSTALLABLE_GAMES:
		if str(entry["id"]) == gameid:
			return str(entry["title"])
	return gameid

func _set_server_rows(rows: Array, why: String, what: String) -> void:
	if not is_instance_valid(server_table):
		return
	# Busiest first, which is the order that makes the list useful: a server
	# with nobody on it is rarely what someone opening this screen wants.
	server_table.set_table({"title": "", "columns": [
			{"id": "name", "label": "Server", "wide": true},
			{"id": "game", "label": "Game"},
			{"id": "players", "label": "Players", "kind": "number"},
			{"id": "ping", "label": "Ping, ms", "kind": "number"}],
		"rows": rows, "sort": {"column": "players", "order": "desc"},
		"empty": {"why": why, "what": what}})
	_fit_targets(server_table)

func _on_server_picked(r: Dictionary) -> void:
	_server_chosen = r
	if is_instance_valid(use_server_button):
		use_server_button.disabled = r.is_empty()
	var e: Dictionary = r.get("server", {})
	_join_reason_shown = false
	var about := str(e.get("description", "")).strip_edges()
	status_label.text = str(e.get("name", "")) + (": " + about if about != "" else "")
	GlassStyle.tint_text(status_label, QUIET)

## Back to Join a game with the chosen server's address filled in.
func _use_public_server() -> void:
	var e: Dictionary = _server_chosen.get("server", {})
	if e.is_empty():
		return
	var address := str(e.get("address", ""))
	var port := int(e.get("port", 30000))
	# The public list says which game a server runs, which a direct address
	# does not; kept so the first join there can already use its materials.
	if str(e.get("gameid", "")) != "":
		AssetUpdater.remember_game("%s:%d" % [address, port], str(e.gameid))
	# Said plainly rather than left to be discovered at the loading screen: a
	# large public server sends a great deal of media before it lets anyone in.
	_pending_join = {"address": address, "port": port, "name": str(e.get("name", "")),
		"said": "%s. Joining a large server can take a while at the media step." % str(e.get("name", ""))}
	_show_join()

func _on_connect() -> void:
	# Not a world this client opened, so no Open to LAN notice in its chat.
	OS.set_environment("GOANNA_LAN_NOTICE", "")
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
	_remember_recent(cfg, host, int(port_text), _recent_label(host, int(port_text)))
	var graphics: Dictionary = join_pbr_option.get_item_metadata(join_pbr_option.selected)
	var graphics_id := str(graphics.get("id", "server"))
	var texture_path := str(graphics.get("path", ""))
	var use_pbr := bool(graphics.get("pbr", true))
	# The default choice has no pack of its own. When this server's game is
	# known, from the public list or from a previous session's media, its
	# installed materials are used, as a world hosted in Goanna already does.
	if graphics_id == "server" and texture_path == "":
		var game := AssetUpdater.remembered_game("%s:%s" % [host, port_text])
		if game != "":
			texture_path = LocalServer.bundled_pbr_texture_path(game)
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
	OS.set_environment("GOANNA_MENU_RETURN", "join")
	connect_button.disabled = true
	GlassStyle.tint_text(status_label, Color(1, 1, 1, 0.7))
	status_label.text = "Connecting to %s:%s as %s" % [host, port_text, pname]
	_go_to_game()

# A name for a recent server: the public list's name for it, if it came
# from there this time the menu was open.
func _recent_label(host: String, port: int) -> String:
	for e in _server_rows:
		if typeof(e) == TYPE_DICTIONARY and str(e.get("address", "")) == host and int(e.get("port", 30000)) == port:
			return str(e.get("name", ""))
	return ""

# --- helpers -----------------------------------------------------------------

# A label and a text field, in two cells of `grid`. With `info`, an (i)
# beside the label explains the field, under it in its own cell.
func _labelled_edit(grid: GridContainer, label_text: String, placeholder: String,
		info := "") -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.custom_minimum_size = Vector2(260, 0)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if info == "":
		var label := Label.new()
		label.text = label_text
		grid.add_child(label)
		grid.add_child(edit)
		return edit
	var line := _grid_label(grid, label_text)
	var cell := VBoxContainer.new()
	cell.add_theme_constant_override("separation", 4)
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.add_child(edit)
	grid.add_child(cell)
	_level(line, edit)
	PanelFit.info(edit, line, info, cell)
	return edit

# A grid's label cell with room for an (i) beside the label: a line at the
# top of the cell, so the label and icon stay beside the control when the
# (i) text opens under it and the row grows. _level makes it the control's
# height, so the label sits level with the other rows' labels.
func _grid_label(grid: GridContainer, text: String) -> HBoxContainer:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	line.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var label := Label.new()
	label.text = text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(label)
	grid.add_child(line)
	return line

func _level(line: Control, beside: Control) -> void:
	line.custom_minimum_size.y = beside.get_combined_minimum_size().y

func _local_pbr_enabled() -> bool:
	return bool(_local_pbr_selection().get("pbr", true))

func _local_pbr_selection() -> Dictionary:
	if pbr_option == null or pbr_option.item_count == 0:
		return {"id": "bundled", "path": "", "pbr": true}
	return pbr_option.get_item_metadata(pbr_option.selected)

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

# Change to the game scene. A local server travels in LocalLaunch.server,
# not in this scene, because the scene change frees the menu; the game scene
# (ui/game_ui.gd, or game/local_play.gd for split screen) stops it on exit.
func _go_to_game() -> void:
	# Without the GDExtension the world scene cannot even parse (main.gd
	# names GoannaClient), and the player got a grey screen with nothing to
	# go on: on a Steam Deck on 2026-10-03 the library asked for a newer glibc
	# than SteamOS has. Say so here, where there is a menu to say it in.
	if not ClassDB.class_exists("GoannaClient"):
		if server != null:
			server.stop()
			server = null
		if is_instance_valid(start_button): start_button.disabled = false
		if is_instance_valid(connect_button): connect_button.disabled = false
		var logs := OS.get_environment("GOANNA_LOG_DIR")
		_fail("Goanna's game engine library did not load on this system, so no world can open. This is a fault in this build, not your setup. Its log is in %s." % (logs if logs != "" else OS.get_user_data_dir().path_join("logs")))
		return
	var roster := LocalLaunch.from_environment() if OS.get_environment("GOANNA_LOCAL_PLAY") != "" else local_roster.duplicate(true)
	if roster.is_empty() and OS.get_environment("GOANNA_LOCAL_PLAY") != "":
		push_error("GOANNA_LOCAL_PLAY needs a positive count or a player array")
		get_tree().quit(1)
		return
	if roster.size() > 1:
		# The existing launch form supplies the first player's identity.
		if not OS.get_environment("GOANNA_NAME").is_empty():
			roster[0]["name"] = OS.get_environment("GOANNA_NAME")
		roster[0]["password"] = OS.get_environment("GOANNA_PASS")
		var error := LocalLaunch.validate(roster)
		if error != "":
			if server != null:
				server.stop()
				server = null
				OS.set_environment("GOANNA_SP_PID", "")
				OS.set_environment("GOANNA_SP_MATCH", "")
			if is_instance_valid(start_button): start_button.disabled = false
			if is_instance_valid(connect_button): connect_button.disabled = false
			if status_label != null:
				_fail(error)
			else:
				push_error(error)
				get_tree().quit(1)
			return
		if server != null:
			for player in roster:
				if str(player.get("password", "")).is_empty():
					player["password"] = _local_join_password
		LocalLaunch.players = roster
		LocalLaunch.layout = local_layout
		LocalLaunch.graphics_profile = local_graphics_profile
		LocalLaunch.server = server
		server = null
		get_tree().change_scene_to_file.call_deferred("res://game/local_play.tscn")
	else:
		LocalLaunch.server = server
		server = null
		get_tree().change_scene_to_file.call_deferred("res://game/main.tscn")

# Local player slots are configured once, then used by a local world or Join a game.
# Each extra player authenticates normally, including on remote servers.
func _show_local_players() -> void:
	_new_screen("Local players", "Experimental splitscreen. Player 1 uses the name and password on Join a game, or your own name on a local world.")
	var roster := local_roster.duplicate(true)
	if roster.is_empty():
		roster.append({"name": _local_player_name(), "device": -1})
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 260)
	screen.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rows)
	var controls: Array = []
	for i in roster.size():
		var row := HBoxContainer.new()
		rows.add_child(row)
		var label := Label.new()
		label.text = "Player %d" % (i + 1)
		row.add_child(label)
		var player_name := LineEdit.new()
		player_name.text = str(roster[i].get("name", "player_%d" % (i + 1)))
		player_name.editable = i != 0
		player_name.custom_minimum_size.x = 160
		row.add_child(player_name)
		var device := OptionButton.new()
		device.add_item("Press Start to join")
		device.set_item_metadata(0, -2)
		device.add_item("Keyboard and mouse")
		device.set_item_metadata(1, -1)
		for id in Input.get_connected_joypads():
			device.add_item("%d: %s" % [id, Input.get_joy_name(id)])
			device.set_item_metadata(device.item_count - 1, id)
		var wanted := int(roster[i].get("device", -2))
		for j in device.item_count:
			if int(device.get_item_metadata(j)) == wanted: device.select(j)
		row.add_child(device)
		var password := LineEdit.new()
		password.secret = true
		password.placeholder_text = "Server password"
		password.custom_minimum_size.x = 180
		password.text = str(roster[i].get("password", ""))
		password.editable = i != 0
		row.add_child(password)
		controls.append([player_name, device, password])
	var collect := func() -> Array:
		var result: Array = []
		for c in controls:
			result.append({"name": c[0].text.strip_edges(), "device": c[1].get_item_metadata(c[1].selected), "password": c[2].text})
		return result
	var split := OptionButton.new()
	split.add_item("Two players: side by side")
	split.add_item("Two players: top and bottom")
	split.select(1 if local_layout == "horizontal" else 0)
	split.item_selected.connect(func(index: int) -> void: local_layout = "horizontal" if index == 1 else "grid")
	screen.add_child(split)
	var quality := OptionButton.new()
	var profiles := GraphicsProfiles.ORDER
	for profile in profiles:
		quality.add_item("Local graphics: " + profile.capitalize())
	quality.select(maxi(0, profiles.find(local_graphics_profile)))
	quality.item_selected.connect(func(index: int) -> void: local_graphics_profile = profiles[index])
	screen.add_child(quality)
	screen.add_child(_button("Add player", func() -> void:
		local_roster = collect.call()
		local_roster.append({"name": "player_%d" % (local_roster.size() + 1), "device": -2})
		_show_local_players()))
	if roster.size() > 1:
		screen.add_child(_button("Remove last player", func() -> void:
			local_roster = collect.call()
			local_roster.pop_back()
			_show_local_players()))
	_footer_row([_button("Back", _show_main)], _accent(_button("Save and back", func() -> void:
		var result: Array = collect.call()
		var error := LocalLaunch.validate(result)
		if error != "":
			_fail(error)
			return
		local_roster = result
		var saved := result.duplicate(true)
		for player in saved: player.erase("password")
		var cfg := ConfigFile.new()
		cfg.load(CFG_PATH)
		cfg.set_value("local_play", "players", saved)
		cfg.set_value("local_play", "layout", local_layout)
		cfg.set_value("local_play", "graphics_profile", local_graphics_profile)
		cfg.save(CFG_PATH)
		_show_main())))
