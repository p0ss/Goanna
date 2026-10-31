# SPDX-License-Identifier: LGPL-2.1-or-later
## Captures the overseer's second and third screens passes (the grouped
## rail, the View menu, Plans, Supplies, Houses and the workshop picker)
## from a live DorfCraft
## server, at the window's size and again at 200 percent text. A scene,
## not a --script test, and it renders: the DorfCraft runner
## mods/kindred/settlement/overseer/tests/screens_live/run.py starts the
## server and runs this through tools/goanna-headless fixture with
## TABLES_PORT, TABLES_NAME and TABLES_OUT set.
extends Node
const Unit := preload("res://tests/overseer.gd")
var client: GoannaClient
var view: CanvasLayer
var main: Node3D
var out := ""
var notes: Array = []

func _process(delta: float) -> void:
	if client != null: client.poll_blocks(0)
	if view != null: view.tick(delta)

func wait_for(predicate: Callable, seconds := 60.0) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < end:
		if predicate.call(): return true
		await get_tree().create_timer(0.1).timeout
	return false

func pause(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout

func shot(name: String) -> void:
	await pause(1.5)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out.path_join(name + ".png"))
	notes.append(name)

func finish(code: int, why := "") -> void:
	var file := FileAccess.open(out.path_join("goanna-shots.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"shots": notes, "result": code, "why": why,
			"plans": view.ui.plans_table.get("rows", []).size() if view != null else 0,
			"houses": view.ui.houses.page.get("table", {}).get("rows", []).size() if view != null else 0,
			"sections": view.ui.section_states.keys() if view != null else []}, "  "))
	if view != null and view.active: view.leave()
	if client != null: client.disconnect_from_server()
	get_tree().quit(code)

func screens(suffix: String) -> void:
	var ui = view.ui
	ui.choose_family("Select")
	await pause(2.0)
	await shot("map" + suffix)
	# The View menu, opened as a player would.
	ui.view_menu.show_popup()
	await shot("view-menu" + suffix)
	ui.view_menu.get_popup().hide()
	ui.choose_family("Plans")
	await wait_for(func() -> bool: return ui.table_kind == "plans", 20)
	await shot("plans" + suffix)
	ui.table.choose_index(0)
	await shot("plans-row" + suffix)
	# Supplies, opened by what runs low (third screens pass).
	ui.choose_family("Supplies")
	await wait_for(func() -> bool: return ui.table_kind == "supplies", 20)
	await shot("supplies" + suffix)
	ui.table.choose_index(0)
	await shot("supplies-row" + suffix)
	ui.choose_family("Houses")
	await wait_for(func() -> bool: return ui.table_kind == "houses", 20)
	await shot("houses" + suffix)
	ui.table.choose_index(1 if ui.table.shown_rows.size() > 1 else 0)
	await shot("houses-row" + suffix)
	ui.houses_manage.pressed.emit()
	await shot("houses-manage" + suffix)
	ui.houses_mode = ""
	ui.choose_family("Build")
	view.choose_tool("workshop")
	await wait_for(func() -> bool: return ui.table_kind == "workshops", 10)
	await shot("workshops" + suffix)
	var ready := 0
	for i in ui.table.shown_rows.size():
		if not ui.table.row_locked(ui.table.shown_rows[i]):
			ready = i
			break
	ui.table.choose_index(ready)
	await shot("workshop-row" + suffix)
	ui.detail_action()
	await shot("workshop-chosen" + suffix)
	view.choose_tool("inspect")
	ui.choose_family("Select")

func _ready() -> void:
	out = OS.get_environment("TABLES_OUT")
	if out.is_empty(): out = "/tmp"
	var port := int(OS.get_environment("TABLES_PORT"))
	var name := OS.get_environment("TABLES_NAME")
	if name.is_empty(): name = "tablestest"
	main = Unit.TestMain.new(); add_child(main)
	client = GoannaClient.new(); main.add_child(client)
	client.connect_to("127.0.0.1", port, name, "")
	if not await wait_for(func() -> bool: return client.status().get("state") == "ready"):
		finish(1, "no connection"); return
	view = preload("res://game/overseer.gd").new(); view.main = main; view.client = client; main.add_child(view)
	var opened := false
	for attempt in 12:
		await pause(3.0)
		client.send_chat("/overseer")
		if await wait_for(func() -> bool: return view.session_ready and not view.snapshot.is_empty(), 40):
			opened = true
			break
	if not opened:
		finish(1, "overseer did not open"); return
	# Let the workers take up the digging before the captures.
	await pause(20.0)
	await screens("-1280")
	view.root_control.theme.default_font_size = 36
	await pause(1.0)
	await screens("-1280-200")
	view.root_control.theme.default_font_size = 18
	finish(0)
