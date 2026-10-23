# SPDX-License-Identifier: LGPL-2.1-or-later
## Live noun-first check: a planner fells a tree from a selection without
## opening the tool rail, once with the mouse and once with the keyboard
## only, and real workers carry it out. Every event goes through this
## client's own input pipeline (Viewport.push_input), never the desktop.
## Extends tests/overseer_world.gd. Needs the scratch overseer server in
## docs/systems/overseer.md, "Tests"; dummy renderer, no GPU:
## godot --headless --path project --script res://tests/overseer_verbs_live.gd
extends "res://tests/overseer_world.gd"
func push(event: InputEvent) -> void:
	root.push_input(event)
	await process_frame
func key(code: Key, shift := false) -> void:
	var down := InputEventKey.new()
	down.keycode = code; down.physical_keycode = code; down.pressed = true; down.shift_pressed = shift
	await push(down)
	var up := down.duplicate(); up.pressed = false
	await push(up)
func click(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new(); motion.position = point; motion.global_position = point
	await push(motion)
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT; down.pressed = true; down.position = point; down.global_position = point
	await push(down)
	var up := down.duplicate(); up.pressed = false
	await push(up)
func cell_point(x: int, z: int) -> Vector2:
	return view.camera.unproject_position(Vector3(x, view.level + 30.1, -z))
func strip_says(text: String) -> bool:
	var b: Button = view.ui.first_verb()
	return view.ui.verb_strip.visible and b != null and text in b.text
func state() -> String:
	return "selection=%s answered=%s verbs=%d heading=%s strip=%s tool=%s inspector=%s hovered=%s" % [view.selection,
		view.verbs_answered, view.verbs.size(), view.ui.verb_heading.text, view.ui.verb_strip.visible, view.tool,
		view.inspector.text.replace("\n", " / "), root.gui_get_hovered_control()]
func give_up() -> void:
	print("Gave up in ", phase, ": ", state())
	print("Overseer verbs live failures: ", failures)
	view.leave(); client.disconnect_from_server()
	quit(1)
func completed(stage: String, seconds := 120.0) -> bool:
	phase = stage
	var end := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < end:
		client.send_chat("/overseer_loop " + stage)
		await create_timer(2.0).timeout
		if said("LOOP " + stage + " PASS"): return true
	print("Incomplete ", stage, " ", view.inspector.text)
	return false
func run() -> void:
	# The headless window starts at 64 by 64, too small for the panels and a
	# map between them. Give it an ordinary screen before the view opens.
	root.size = Vector2i(1280, 720)
	main = Unit.TestMain.new(); root.add_child(main)
	client = GoannaClient.new(); main.add_child(client)
	client.connect_to("127.0.0.1",30561,"overseertest","")
	if not await until(func() -> bool: return client.status().get("state") == "ready",90):
		client.disconnect_from_server(); quit(1); return
	client.send_chat("/overseer_fixture")
	await create_timer(1).timeout
	client.send_chat("/overseer_loop prepare")
	if not await until(func() -> bool: return said("LOOP prepared")):
		client.disconnect_from_server(); quit(1); return
	client.send_chat("/overseer_loop verb_tree")
	view = Overseer.new(); view.main = main; view.client = client; main.add_child(view)
	client.send_chat("/overseer")
	check(await until(func() -> bool: return view.session_ready and not view.snapshot.is_empty() and cell_name(-5,4) != ""),
		"planning camera opens with the tree observed")
	# Mouse: click the trunk, then the strip's Fell, then Submit plan.
	phase = "mouse"
	print("Window ", root.get_visible_rect().size, " trunk at ", cell_point(-5, 4))
	await click(cell_point(-5, 4))
	var offered: bool = await until(func() -> bool: return strip_says("Fell"))
	check(offered, "clicking an observed trunk offers Fell")
	print("After click: ", state())
	if not offered:
		give_up(); return
	var fell: Button = view.ui.first_verb()
	await click(fell.get_global_rect().get_center())
	check(view.tool == "chop" and view.ui.submit.visible, "clicking Fell opens the felling draft")
	await click(view.ui.submit.get_global_rect().get_center())
	check(await until(func() -> bool: return view.first_corner == null and view.pending.is_empty()), "the server accepts the plan")
	print("Mouse reply: ", view.inspector.text)
	check(await completed("chop"), "a worker fells the tree chosen by mouse")
	# Keyboard only: map focus, arrows to the second trunk, Enter, 1, then
	# Tab to Submit plan and Enter.
	phase = "keyboard"
	await key(KEY_ESCAPE)
	view.ui.focus_map()
	view.cursor = {"x": 0, "y": view.level, "z": 0}
	for i in 9: await key(KEY_LEFT)
	for i in 8: await key(KEY_DOWN)
	await key(KEY_ENTER)
	offered = await until(func() -> bool: return strip_says("Fell"))
	check(offered, "Enter on an observed trunk offers Fell")
	print("After Enter: ", state())
	if not offered:
		give_up(); return
	await key(KEY_1)
	check(view.tool == "chop" and view.last_corner != null and int(view.last_corner.x) == -9 and int(view.last_corner.z) == -8, "1 opens the felling draft on that trunk")
	for i in 60:
		if view.ui.submit.has_focus(): break
		await key(KEY_TAB)
	check(view.ui.submit.has_focus(), "Tab reaches Submit plan")
	await key(KEY_ENTER)
	check(await until(func() -> bool: return view.first_corner == null and view.pending.is_empty()), "the server accepts the keyboard plan")
	print("Keyboard reply: ", view.inspector.text)
	check(await completed("verb_chop"), "a worker fells the tree chosen by keyboard")
	view.leave(); client.disconnect_from_server(); client=null; view=null; main.queue_free()
	await process_frame
	print("Overseer verbs live failures: ",failures)
	quit(1 if failures else 0)
