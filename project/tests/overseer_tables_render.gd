# SPDX-License-Identifier: LGPL-2.1-or-later
## Captures the overseer's table screens (People, Supplies, the workshop
## picker) from a live DorfCraft server, at the window's size and again
## at 200 percent text. A scene, not a --script test, and it renders: the
## DorfCraft runner mods/kindred/settlement/overseer/tests/tables_live/run.py
## starts the server and runs this through tools/goanna-headless fixture
## with TABLES_PORT, TABLES_NAME and TABLES_OUT set.
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
			"people": view.ui.overview.get("tables", {}).get("people", {}).get("rows", []).size() if view != null else 0,
			"supplies": view.ui.overview.get("tables", {}).get("supplies", {}).get("rows", []).size() if view != null else 0}, "  "))
	if view != null and view.active: view.leave()
	if client != null: client.disconnect_from_server()
	get_tree().quit(code)

func overview_arrived(kind: String) -> bool:
	var tables: Variant = view.ui.overview.get("tables")
	return tables is Dictionary and tables.get(kind) is Dictionary

func screens(suffix: String) -> void:
	var ui = view.ui
	ui.choose_family("People")
	await wait_for(func() -> bool: return ui.table_panel.visible, 20)
	await shot("people" + suffix)
	# A worker with a place, so the detail offers Show on map.
	var pick := 0
	for i in ui.table.shown_rows.size():
		if ui.table.shown_rows[i].get("pos") is Dictionary:
			pick = i
			break
	ui.table.choose_index(pick)
	await shot("people-row" + suffix)
	ui.choose_family("Supplies")
	await wait_for(func() -> bool: return ui.table_kind == "supplies", 20)
	view._send({"t": "overview"})
	await pause(1.0)
	ui.table.choose_index(0)
	await shot("supplies-row" + suffix)
	ui.choose_family("Build")
	view.choose_tool("workshop")
	await wait_for(func() -> bool: return ui.table_kind == "workshops", 10)
	var locked := -1
	for i in ui.table.shown_rows.size():
		if ui.table.row_locked(ui.table.shown_rows[i]):
			locked = i
			break
	ui.table.choose_index(locked if locked >= 0 else 0)
	await shot("workshops-locked" + suffix)
	ui.table.choose_index(0)
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
	# The probe founds the fortress a second after joining; retry until in.
	var opened := false
	for attempt in 12:
		await pause(3.0)
		client.send_chat("/overseer")
		if await wait_for(func() -> bool: return view.session_ready and not view.snapshot.is_empty(), 8):
			opened = true
			break
	if not opened:
		finish(1, "overseer did not open"); return
	await pause(3.0)
	view._send({"t": "overview"})
	await wait_for(func() -> bool: return overview_arrived("people"), 10)
	await screens("-1280")
	view.root_control.theme.default_font_size = 36
	await pause(1.0)
	await screens("-1280-200")
	view.root_control.theme.default_font_size = 18
	finish(0)
