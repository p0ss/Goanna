# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## The menu's layout against docs/systems/interface-layout.md, "Menus": the
## main screen's one accent is Continue (or New world with no last world),
## Your worlds is a table newest first with Play in the chosen world's
## detail, New world is four steps with Next and then Create, Join a game
## puts this network and recent servers first with the public list behind
## a button as a table, Settings keeps shader packs and render switches on
## Advanced graphics without dropping any setting, Content is one table
## filtered by kind, and every control is at least 40 px high. Headless, no
## server or GPU, against tests/menu_fixture.gd. It writes user://goanna.cfg:
## XDG_DATA_HOME=$(mktemp -d) godot --headless --path project --script res://tests/menu_layout.gd
extends SceneTree

const Fixture := preload("res://tests/menu_fixture.gd")
const GameUI := preload("res://ui/game_ui.gd")
const ShaderPackRow := preload("res://ui/shader_pack_row.gd")
const InfoIcon := preload("res://ui/info_icon.gd")

var failures := 0
var checks := 0
var menu: Control

func check(ok: bool, what: String) -> void:
	checks += 1
	if ok:
		print("  ok   ", what)
	else:
		failures += 1
		printerr("  FAIL ", what)

func _initialize() -> void:
	if preload("res://tests/scratch_profile.gd").refuse_real_profile():
		quit(2)
		return
	_run.call_deferred()

func _settle() -> void:
	await process_frame
	await process_frame

func _shown(node: Node, type: String) -> Array:
	var out: Array = []
	for c in node.find_children("*", type, true, false):
		if (c as Control).is_visible_in_tree():
			out.append(c)
	return out

func _accents() -> Array:
	return _shown(menu._panel_box, "Button").filter(func(b) -> bool: return b.has_meta("accent"))

func _texts(type := "Button") -> Array:
	return _shown(menu._panel_box, type).map(func(b) -> String: return str(b.text))

func _small_targets() -> Array:
	var out: Array = []
	for c in _shown(menu._panel_box, "Control"):
		if c is InfoIcon:
			continue
		if (c is BaseButton or c is LineEdit or c is SpinBox) and (c as Control).size.y < 39.5:
			out.append("%s %s (%.0f)" % [c.get_class(), str(c.get("text")), (c as Control).size.y])
	return out

func _one_accent(screen_name: String, label: String) -> void:
	var a := _accents()
	check(a.size() == 1, "%s has exactly one accent button (got %s)" % [screen_name, str(a.map(func(b): return b.text))])
	if a.size() == 1:
		check(str(a[0].text) == label, "%s's accent is %s (got %s)" % [screen_name, label, a[0].text])
	var small := _small_targets()
	check(small.is_empty(), "%s: every target is at least 40 px (short: %s)" % [screen_name, str(small)])

func _run() -> void:
	Fixture.build()
	root.size = Vector2i(1280, 720)
	menu = preload("res://menu/menu.tscn").instantiate()
	root.add_child(menu)
	await _settle()

	print("main screen")
	_one_accent("the main screen", "Continue: Barrelreach, Kindred Holdfast (preview)")
	var order: Array = _texts()
	var want := ["Continue: Barrelreach, Kindred Holdfast (preview)", "Your worlds", "New world",
		"Join a game", "Settings", "Content", "Local players", "About", "Quit"]
	check(order == want, "the main screen's buttons, in order (got %s)" % str(order))
	var quit_button: Button = _shown(menu._panel_box, "Button").filter(func(b): return b.text == "Quit")[0]
	check(quit_button.flat, "the last row is quieter than the rest")
	check(not order.has("Start Game") and not order.has("Join Game"), "the old labels are gone")

	print("worlds")
	menu._show_worlds()
	await _settle()
	var table = menu.worlds_table
	check(table != null and table.columns().map(func(c): return c.id) == ["world", "game", "played"],
		"Your worlds is a table of world, game and last played")
	check(table.shown_rows.map(func(r): return r.id) == ["Barrelreach", "Seaside test", "Old valley"],
		"sorted by last played, newest first (got %s)" % str(table.shown_rows.map(func(r): return r.id)))
	check(str(table.shown_rows[0].cells.game) == "Kindred Holdfast (preview)"
		and str(table.shown_rows[1].cells.game) == "VoxeLibre",
		"the game column shows titles, a modpack game by its own")
	check(str(table.shown_rows[2].cells.played) == "20 September 2026", "an old world shows its date")
	check(table.selected_id == "Barrelreach", "the last world played is chosen")
	_one_accent("Your worlds", "Play")
	var detail := _texts("Label")
	check(detail.has("Survival, damage on") and detail.has("kindred_holdfast"),
		"the detail shows play mode and mods")
	check(_texts().has("Delete world") and _texts().has("Change options"), "Delete and Change options are quiet beside Play")
	table.choose_id("Seaside test")
	await _settle()
	check(_texts("Label").has("Creative, damage off"), "choosing a row shows its detail")

	print("new world")
	menu._show_new_game()
	await _settle()
	check(menu._world_steps.size() == 4, "New world has four steps")
	check(menu._world_steps.filter(func(p): return p.visible).size() == 1, "one step at a time")
	_one_accent("step 1", "Next")
	check(menu._game_buttons.size() == 4, "step 1 lists the three games and the modpack game")
	check(menu.world_edit.text == "New world", "a free name is the default (got %s)" % menu.world_edit.text)
	check(not menu.host_check.button_pressed, "hosting is off by default")
	check(menu.generator_option.selected == 0 and not menu.creative_check.button_pressed
		and menu.damage_check.button_pressed, "options default to the game's generator, survival, damage on")
	menu._on_next()
	await _settle()
	check(menu._world_step == 1, "Next goes to Name and seed")
	check(menu.seed_edit != null and menu.seed_edit.is_visible_in_tree(), "Name and seed has a seed field")
	menu.world_edit.text = "Barrelreach"
	menu._on_next()
	check(menu._world_step == 1 and menu.status_label.text.contains("already exists"),
		"a taken name stops on that step with the reason")
	menu.world_edit.text = "New world"
	menu._on_next()
	menu._on_next()
	await _settle()
	check(menu._world_step == 3, "Next, Next, Next reaches Hosting")
	_one_accent("the last step", "Create")
	check(menu.start_button.pressed.is_connected(menu._on_start_local), "Create starts the world")
	menu._on_step_back()
	check(menu._world_step == 2, "Back goes back a step")

	print("an existing world")
	menu._world_back = menu._show_worlds
	menu._open_world("Barrelreach", false)
	await _settle()
	check(menu._screen_title == "Barrelreach", "a world's options screen is titled with the world")
	_one_accent("a world's options", "Play")
	check(menu.game_option.disabled and menu.generator_option.disabled, "its game and map are fixed")
	check(menu.mod_checks["kindred_holdfast"].button_pressed, "its modpack is ticked")

	print("main screen with no last world")
	Fixture.build("")
	menu._show_main()
	await _settle()
	_one_accent("the main screen without a last world", "New world")

	print("join a game")
	menu._show_join()
	await _settle()
	_one_accent("Join a game", "Connect")
	var labels := _texts("Label")
	check(labels.find("On this network") >= 0 and labels.find("On this network") < labels.find("Recent servers"),
		"this network comes first, then recent servers")
	check(menu.recent_tree != null and menu.recent_tree.get_root().get_child_count() == 2, "both recent servers are listed")
	check(_shown(menu._panel_box, "Tree").size() == 2, "no public list on the screen itself")
	check(_texts().has("Browse public servers"), "the public list is behind Browse public servers")
	check(not menu.host_edit.is_visible_in_tree(), "the typed address is folded away")
	menu.recent_tree.get_root().get_child(1).select(0)
	check(menu.host_edit.text == "play.example.org" and menu.join_target.text.contains("play.example.org"),
		"choosing a recent server fills the address and says so")

	print("public servers")
	menu._show_public_servers()
	await _settle()
	var st = menu.server_table
	check(st.columns().map(func(c): return c.id) == ["name", "game", "players", "ping"],
		"the public list is a table of name, game, players and ping")
	check(st.shown_rows.size() == 24, "all 24 saved servers are rows")
	check(str(st.shown_rows[0].cells.game) in ["Mineclonia", "VoxeLibre", "Minetest Game", "nodecore"],
		"games show installed titles where known")
	st.search.text = "skyblock"
	st.search.text_changed.emit("skyblock")
	check(st.shown_rows.size() == 4, "search filters the rows (got %d)" % st.shown_rows.size())
	_one_accent("Public servers", "Use this server")
	st.choose_index(0)
	menu._use_public_server()
	await _settle()
	check(menu._screen_title == "Join a game" and menu.host_edit.text.begins_with("server"),
		"Use this server returns to Join a game with its address")

	print("settings")
	menu._show_settings()
	await _settle()
	var front := _texts("Label")
	check(front.has("Graphics profile") and front.has("Interface scale") and front.has("Volume"),
		"the front page has the profile, text size and the main sliders")
	var picker_items := func() -> Array:
		var found: Array = []
		for p in _shown(menu._panel_box, "OptionButton"):
			if p.item_count > 0 and p.get_item_text(0) == ShaderPackRow.NONE_LABEL:
				found.append(p)
		return found
	check(picker_items.call().is_empty(), "no shader pack picker on the front page")
	check(not front.has("Shadow detail"), "no individual render switch on the front page")
	check(_accents().is_empty(), "Settings has no accent: it saves as you go")
	var seen := {}
	for t in front:
		seen[t] = true
	for p in menu.SETTINGS_PAGES:
		menu._show_settings_page(str(p[0]))
		await _settle()
		if str(p[0]) == "Advanced":
			check(picker_items.call().size() == 1, "Advanced graphics holds the shader pack picker")
			for header in _shown(menu._panel_box, "Button"):
				if str(header.text).contains("Shadows"):
					header.button_pressed = true
			await _settle()
		for t in _texts("Label"):
			seen[t] = true
		for t in _texts("CheckBox"):
			seen[t] = true
	var missing: Array = []
	for row in GameUI.SETTINGS:
		if not seen.has(str(row[3])) and str(row[3]) != "Shader pack":
			missing.append(str(row[3]))
	# Folded groups hide their rows from is_visible_in_tree; count them.
	menu._show_settings_page("Advanced")
	await _settle()
	for l in menu._panel_box.find_children("*", "Label", true, false):
		seen[str(l.text)] = true
	missing = missing.filter(func(m): return not seen.has(m))
	check(missing.is_empty(), "every setting is on some page (missing %s)" % str(missing))

	print("content")
	menu._show_content()
	await _settle()
	var ct = menu.content_table
	check(ct.columns().map(func(c): return c.id) == ["name", "kind", "used"], "Content is one table of name, kind and used by")
	check(ct.shown_rows.size() == 3 + 3 + 1, "games, mods and texture packs are all rows (got %d)" % ct.shown_rows.size())
	ct.filter_values["kind"] = "Mod"
	ct._refresh_rows()
	check(ct.shown_rows.size() == 3, "filtering by kind leaves the mods")
	var holdfast: Array = ct.shown_rows.filter(func(r): return r.id == "mod:kindred_holdfast")
	check(holdfast.size() == 1 and str(holdfast[0].cells.used) == "Barrelreach", "a mod shows the worlds using it")
	_one_accent("Content", "Install a game")

	print("200 percent")
	root.content_scale_factor = 2.0
	Fixture.build()
	menu._show_main()
	await _settle()
	await _settle()
	var sc: ScrollContainer = menu._compact_scroll
	check(sc != null and sc.size.y < menu.screen.get_combined_minimum_size().y,
		"at 200 percent the main screen scrolls rather than running off the window")
	root.content_scale_factor = 1.0

	menu.free()
	await process_frame
	print("menu layout: %d checks, %s" % [checks, "FAIL (%d)" % failures if failures else "PASS"])
	quit(1 if failures else 0)
