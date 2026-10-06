# SPDX-License-Identifier: LGPL-2.1-or-later
# Capture the real planning UI and a live scratch-world observation stream.
extends Node
const Unit := preload("res://tests/overseer.gd")
var client: GoannaClient
var view: CanvasLayer
var main: Node3D
func _process(delta: float) -> void:
	if client != null: client.poll_blocks(0)
	if view != null: view.tick(delta)
func wait_for(predicate: Callable, seconds := 60.0) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < end:
		if predicate.call(): return true
		await get_tree().create_timer(0.1).timeout
	return false
func shot(name: String) -> void:
	await get_tree().create_timer(2).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("/tmp/overseer-ux/" + name + ".png")
func _ready() -> void:
	main = Unit.TestMain.new(); add_child(main)
	client = GoannaClient.new(); main.add_child(client)
	client.connect_to("127.0.0.1",30561,"overseertest","")
	if not await wait_for(func() -> bool: return client.status().get("state")=="ready"):
		client.disconnect_from_server();get_tree().quit(1);return
	client.send_chat("/overseer_fixture")
	await get_tree().create_timer(1).timeout
	view = preload("res://overseer.gd").new();view.main=main;view.client=client;main.add_child(view)
	client.send_chat("/overseer")
	if not await wait_for(func() -> bool: return view.session_ready and not view.snapshot.is_empty()):
		client.disconnect_from_server();get_tree().quit(1);return
	view.ui.choose_family("Terrain");view.choose_tool("dig")
	view.select_cell({"x":3,"y":0,"z":0});view.select_cell({"x":8,"y":0,"z":2})
	await shot("draft-1280")
	view.discard_draft();view.ui.choose_family("Plans")
	await shot("plans-1280")
	view.ui.choose_family("Build");view.choose_tool("furniture")
	view.root_control.theme.default_font_size=36
	await shot("large-text-1280")
	view.root_control.theme.default_font_size=18
	get_window().size=Vector2i(960,640)
	await shot("build-960")
	view.leave();client.disconnect_from_server()
	get_tree().quit()
