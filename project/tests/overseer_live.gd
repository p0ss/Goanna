# SPDX-License-Identifier: LGPL-2.1-or-later
# End-to-end private channel, camera and order checks against the scratch server.
extends SceneTree
const Overseer := preload("res://overseer.gd")
const Unit := preload("res://tests/overseer.gd")
var client: GoannaClient
var main: Node3D
var view: CanvasLayer
var failures := 0
var running := false
var phase := "connecting"

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

func _initialize() -> void:
	call_deferred("run")

func _process(delta: float) -> bool:
	if client != null:
		client.poll_blocks(0)
	if view != null and running:
		view.tick(delta)
	return false

func until(predicate: Callable, seconds := 20.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < deadline:
		if predicate.call(): return true
		await create_timer(0.1).timeout
	print("Timeout during ", phase)
	return false

func run() -> void:
	main = Unit.TestMain.new()
	root.add_child(main)
	client = GoannaClient.new()
	main.add_child(client)
	client.connect_to("127.0.0.1", 30561, "overseertest", "")
	if not await until(func() -> bool: return client.status().get("state") == "ready", 90.0):
		print(client.status())
		client.disconnect_from_server()
		quit(1)
		return
	check(true, "connected to Luanti 5.17 Mineclonia")
	client.send_chat("/overseer_fixture")
	await create_timer(1.0).timeout
	client.send_chat("/overseer")
	view = Overseer.new()
	view.main = main
	view.client = client
	main.add_child(view)
	running = true
	phase = "private hello and layer"
	check(await until(func() -> bool: return view.session_ready and not view.snapshot.is_empty()), "HUD delivery, private join, ready, hello and layer")
	print("Camera snapshot: ", JSON.stringify(view.snapshot).left(200))
	if view.session_ready:
		check(view.snapshot.get("y", -100) == 0, "camera opens at the body's level")
		check(not client.overseer_channel("dorfcraft:o:" + "0".repeat(32)), "native bridge refuses a channel without a HUD grant")
		view.change_level(-1)
		check(view.snapshot.is_empty(), "changing level immediately hides old geometry")
		phase = "lower layer"
		check(await until(func() -> bool: return view.snapshot.get("y", -100) == -1), "server supplies the selected lower level")
		view.change_level(-100)
		phase = "outside claim"
		check(await until(func() -> bool: return view.snapshot.get("empty", false)), "level outside claim has an explicit empty reply")
		check(view.geometry.get_child_count() == 0, "out-of-bounds view contains no terrain")
		view.change_level(101)
		phase = "return to level zero"
		await until(func() -> bool: return view.snapshot.get("y", -100) == 0)
		view.tool = "dig"
		view.select_cell({"x": 4, "y": 0, "z": 0})
		view.select_cell({"x": 8, "y": 0, "z": 0})
		view.submit_draft()
		phase = "dig reply"
		check(await until(func() -> bool: return "Excavation planned" in view.inspector.text), "camera submits a dig plan through the server")
		view.leave()
		check(not view.active and main.cam.cull_mask != 0, "leaving restores first person rendering")
		await create_timer(1.0).timeout
		var grants := 0
		for h in client.hud_state().get("elements", []):
			if h.get("name", "") == "dorfcraft:overseer": grants += 1
		check(grants == 0, "server removes the capability HUD on leave")
	for line in client.take_chat(): print("CHAT ", line.get("message", ""))
	running = false
	client.disconnect_from_server()
	main.queue_free()
	await process_frame
	print("Overseer live failures: ", failures)
	quit(1 if failures else 0)
