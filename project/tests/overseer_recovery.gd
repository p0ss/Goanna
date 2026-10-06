# SPDX-License-Identifier: LGPL-2.1-or-later
# Live session recovery and worker execution in the opt-in scratch fixture.
extends SceneTree
const Overseer := preload("res://overseer.gd")
const Unit := preload("res://tests/overseer.gd")
var client: GoannaClient
var main: Node3D
var view: CanvasLayer
var chat: Array = []
var failures := 0
var phase := "connect"
func _initialize() -> void:
	call_deferred("run")
func _process(delta: float) -> bool:
	if client != null:
		client.poll_blocks(0)
		for line in client.take_chat():
			chat.append(str(line.get("message", "")))
	if view != null:
		view.tick(delta)
	return false
func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures += 1
func until(predicate: Callable, seconds := 20.0) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < end:
		if predicate.call(): return true
		await create_timer(0.1).timeout
	print("Timeout: ", phase, " chat=", chat)
	return false
func said(text: String) -> bool:
	for line in chat:
		if text in line: return true
	return false
func run() -> void:
	main = Unit.TestMain.new()
	root.add_child(main)
	client = GoannaClient.new()
	main.add_child(client)
	client.connect_to("127.0.0.1", 30561, "overseertest", "")
	if not await until(func() -> bool: return client.status().get("state") == "ready", 90.0):
		client.disconnect_from_server(); quit(1); return
	client.send_chat("/overseer_fixture")
	await create_timer(1.0).timeout
	view = Overseer.new()
	view.main = main
	view.client = client
	main.add_child(view)
	client.send_chat("/overseer")
	phase = "freeze"
	await until(func() -> bool: return view.session_ready)
	client.send_chat("/overseer_check frozen")
	check(await until(func() -> bool: return said("CHECK frozen PASS")), "server suspends movement, gravity and interaction")
	client.send_chat("/overseer_check damage")
	phase = "damage exit"
	check(await until(func() -> bool: return not view.active), "damage ends the camera view")
	client.send_chat("/overseer_check restored")
	check(await until(func() -> bool: return said("CHECK restored PASS")), "damage exit restores physics and interaction")
	# Keep a real player near the fortress while its worker excavates.
	chat.clear()
	client.send_chat("/overseer_check work")
	await until(func() -> bool: return said("Excavation planned"))
	phase = "worker tunnel"
	var end := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < end and not said("CHECK dug PASS"):
		client.send_chat("/overseer_check dug")
		await create_timer(2.0).timeout
	check(said("CHECK dug PASS"), "worker completes a two-high tunnel into initially unknown rock")
	client.disconnect_from_server()
	client = null
	main.queue_free()
	view = null
	await process_frame
	print("Overseer recovery failures: ", failures)
	quit(1 if failures else 0)
