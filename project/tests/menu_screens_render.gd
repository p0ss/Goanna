# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## Captures every menu screen against tests/menu_fixture.gd (no Luanti, no
## server), at the window's size and again at 200 percent text, for the
## review of the menu layout (docs/perf/menu-layout-2026-11-01). A scene,
## not a --script test, because it renders; run it headless through
## tools/goanna-headless fixture with MENU_OUT set to an absolute folder and
## XDG_DATA_HOME to a scratch one:
##   tools/goanna-headless fixture res://tests/menu_screens_render.tscn \
##     --size 1280x720 --software --env MENU_OUT=/tmp/shots --env XDG_DATA_HOME=/tmp/x
extends Node

const Fixture := preload("res://tests/menu_fixture.gd")

var out := ""
var menu: Control
var notes := {}

func _ready() -> void:
	out = OS.get_environment("MENU_OUT")
	if out == "" or OS.get_environment("XDG_DATA_HOME") == "":
		push_error("Set MENU_OUT and a scratch XDG_DATA_HOME.")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out)
	Fixture.build()
	OS.set_environment("GOANNA_MENU_BACKDROP",
			ProjectSettings.globalize_path("res://menu_backgrounds/headland.jpg"))
	_run.call_deferred()

func _shot(name: String) -> void:
	for i in 4:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out.path_join(name + ".png"))
	var accents: Array = []
	for b in menu._panel_box.find_children("*", "Button", true, false):
		if b.has_meta("accent") and (b as Control).is_visible_in_tree():
			accents.append(str(b.text))
	notes[name] = {"accents": accents}
	print("shot ", name, " accents ", accents)

func _screens() -> Array:
	return [
		["main", func() -> void: menu._show_main()],
		["main-no-last", func() -> void:
			Fixture.build("")
			menu._show_main()],
		["worlds", func() -> void:
			Fixture.build()
			menu._show_worlds()],
		["world-options", func() -> void:
			menu._world_back = menu._show_worlds
			menu._open_world("Barrelreach", false)],
		["new-1-game", func() -> void: menu._show_new_game()],
		["new-2-name", func() -> void: menu._go_step(1)],
		["new-3-options", func() -> void: menu._go_step(2)],
		["new-4-hosting", func() -> void: menu._go_step(3)],
		["join", func() -> void: menu._show_join()],
		["public-servers", func() -> void: menu._show_public_servers()],
		["settings", func() -> void: menu._show_settings()],
		["settings-advanced", func() -> void:
			menu.menu_groups_open = {"Shadows": true}
			menu._show_settings_page("Advanced")],
		["content", func() -> void: menu._show_content()],
		["local-players", func() -> void: menu._show_local_players()],
	]

func _run() -> void:
	menu = preload("res://menu/menu.tscn").instantiate()
	add_child(menu)
	for scale in [1.0, 2.0]:
		get_tree().root.content_scale_factor = scale
		await RenderingServer.frame_post_draw
		for s in _screens():
			(s[1] as Callable).call()
			await _shot("%s%s" % [s[0], "" if scale == 1.0 else "-200"])
	var f := FileAccess.open(out.path_join("shots.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(notes, "  "))
	f.close()
	get_tree().quit(0)
