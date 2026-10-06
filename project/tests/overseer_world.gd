# SPDX-License-Identifier: LGPL-2.1-or-later
# Real node meshing and simulation continuing inside the overseer camera.
extends SceneTree
const Overseer := preload("res://overseer.gd")
const Unit := preload("res://tests/overseer.gd")
var client: GoannaClient
var main: Node3D
var view: CanvasLayer
var failures := 0
var chat: Array = []
var positions: Dictionary = {}
var frames: Dictionary = {}
var moved := false
var animated := false
var phase := "connect"
func _initialize() -> void:
	call_deferred("run")
func _process(delta: float) -> bool:
	if client != null:
		client.poll_blocks(0)
		client.sync_entities(delta)
		for line in client.take_chat(): chat.append(str(line.get("message", "")))
		if view != null and view.active:
			for entity in client.entity_list():
				if entity.get("local", false): continue
				var id: int = entity.id
				if positions.has(id) and positions[id].distance_to(entity.position) > 0.3: moved = true
				if not positions.has(id): positions[id] = entity.position
				if frames.has(id) and entity.frame >= 0 and absf(frames[id] - entity.frame) > 0.1: animated = true
				if not frames.has(id): frames[id] = entity.frame
	if view != null: view.tick(delta)
	return false
func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures += 1
func until(predicate: Callable, seconds := 20.0) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < end:
		if predicate.call(): return true
		await create_timer(0.1).timeout
	print("Timeout ", phase, " chat=", chat)
	return false
func said(value: String) -> bool:
	for line in chat:
		if value in line: return true
	return false
func cell_name(x: int, z: int) -> String:
	var s: Dictionary = view.snapshot
	if not s.has("rect"): return ""
	var r: Dictionary = s.rect
	if x < r.x0 or x > r.x1 or z < r.z0 or z > r.z1: return ""
	var code := int(s.cells[int((z-r.z0)*(r.x1-r.x0+1)+x-r.x0)])
	return "air" if code == 1 else str(s.palette[code-2].name) if code >= 2 else ""
func sample_mesh(name: String, param2 := 0) -> ArrayMesh:
	return client.overseer_mesh({"y":0,"rect":{"x0":0,"x1":0,"z0":0,"z1":0},
		"cells":[2],"floors":[0],"palette":[{"name":name,"param2":param2}]},Vector3i.ZERO)
func run() -> void:
	main = Unit.TestMain.new(); root.add_child(main)
	client = GoannaClient.new(); main.add_child(client)
	client.connect_to("127.0.0.1",30561,"overseertest","")
	if not await until(func() -> bool: return client.status().get("state") == "ready",90):
		client.disconnect_from_server(); quit(1); return
	client.send_chat("/overseer_fixture")
	await create_timer(1).timeout
	client.send_chat("/overseer_world")
	phase = "world fixture"
	if not await until(func() -> bool: return said("World geometry fixture ready")):
		client.disconnect_from_server(); quit(1); return
	var cube := sample_mesh("mcl_core:stonebrick")
	var slab := sample_mesh("mcl_stairs:slab_stonebrick")
	var stair := sample_mesh("mcl_stairs:stair_stonebrick")
	var turned := sample_mesh("mcl_stairs:stair_stonebrick",1)
	check(cube != null and cube.get_surface_count() > 0, "normal node uses real world mesh")
	check(slab != null and absf(slab.get_aabb().size.y - 0.5) < 0.01, "slab retains its half-height geometry")
	check(stair != null and stair.get_faces().size() > cube.get_faces().size(), "stairs retain their shaped triangles")
	check(stair.get_faces() != turned.get_faces(), "facedir rotates actual stair geometry")
	check(cube.surface_get_material(0) is ShaderMaterial, "world shader material, not an unshaded tile")
	var unknown := client.overseer_mesh({"y":0,"rect":{"x0":8,"x1":8,"z0":3,"z1":3},
		"cells":[0],"floors":[0],"palette":[]},Vector3i.ZERO)
	check(unknown == null or unknown.get_surface_count() == 0, "cached concealed ore cannot enter observation mesh")
	view = Overseer.new(); view.main = main; view.client = client; main.add_child(view)
	client.send_chat("/overseer")
	phase = "world camera"
	check(await until(func() -> bool: return view.session_ready and not view.snapshot.is_empty()), "native camera receives world observations")
	check(await until(func() -> bool: return view.geometry.get_child_count() > 0), "world meshes appear in the isolated viewport")
	view.tool = "wall"
	view._update_materials(view.material_catalog)
	check(view.build_materials.size() > 0, "fortress stock supplies build material choices")
	view.tool = "wall"
	view.select_cell({"x":-2,"y":0,"z":-3})
	view.select_cell({"x":-1,"y":0,"z":-3})
	view.submit_draft()
	phase = "construction reply"
	check(await until(func() -> bool: return "Construction planned" in view.inspector.text), "camera submits construction through labour")
	phase = "worker builds while camera remains open"
	check(await until(func() -> bool: return cell_name(-2,-3)=="mcl_core:stonebrick" and cell_name(-1,-3)=="mcl_core:stonebrick",120), "worker-built blocks reach the open camera")
	client.send_chat("/overseer_check work")
	phase = "worker mines while camera remains open"
	check(await until(func() -> bool: return cell_name(8,0)=="air",120), "worker excavation updates the open camera")
	check(view.active, "world was never paused or camera closed for work")
	check(moved, "live non-player models move in the overseer world")
	check(animated, "live non-player animation frames advance")
	view.change_level(-100)
	phase = "entity masking"
	await until(func() -> bool: return view.snapshot.get("empty",false))
	await process_frame
	check(client.entity_list().is_empty(), "unserved level hides cached entities too")
	view.leave()
	await create_timer(0.2).timeout
	check(not client.entity_list().is_empty(), "leaving restores ordinary entity visibility")
	client.disconnect_from_server();client=null;view=null;main.queue_free()
	await process_frame
	print("Overseer world failures: ",failures)
	quit(1 if failures else 0)
