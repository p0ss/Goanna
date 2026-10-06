# SPDX-License-Identifier: LGPL-2.1-or-later
# Native planning and real worker execution with the camera kept open.
extends "res://tests/overseer_world.gd"
func order(kind: String, a: Vector3i, b: Vector3i, item := "", facing := 0) -> void:
	view.tool = kind
	view._update_materials(view.material_catalog)
	for i in view.build_materials.size():
		if view.build_materials[i].name == item: view.build_material.select(i)
	view.facing_picker.select(facing)
	view.select_cell({"x":a.x,"y":a.y,"z":a.z})
	view.select_cell({"x":b.x,"y":b.y,"z":b.z})
	view.submit_draft()
func completed(stage: String, seconds := 90.0) -> bool:
	phase = stage
	var end := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < end:
		client.send_chat("/overseer_loop " + stage)
		await create_timer(2.0).timeout
		if said("LOOP " + stage + " PASS"): return true
	print("Incomplete ", stage, " ", view.inspector.text)
	return false
func run() -> void:
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
	view = Overseer.new(); view.main = main; view.client = client; main.add_child(view)
	client.send_chat("/overseer")
	check(await until(func() -> bool: return view.session_ready and not view.snapshot.is_empty()), "planning camera opens")
	order("dig",Vector3i(3,0,0),Vector3i(6,0,0))
	check(await completed("tunnel"),"ordinary dig creates walkable two-high tunnel")
	order("dig",Vector3i(5,0,1),Vector3i(7,0,3))
	check(await completed("room",150),"workers excavate bedroom off the tunnel")
	for job in [
		["chop",Vector3i(-5,0,4),"",0],
		["harvest",Vector3i(-5,0,2),"",0],
		["wall",Vector3i(-3,0,4),"mcl_core:stonebrick",0],
		["floor",Vector3i(5,0,1),"mcl_core:stonebrick",0],
		["stairs",Vector3i(-2,0,4),"mcl_stairs:stair_stonebrick",2],
		["furniture",Vector3i(5,0,2),"mcl_beds:bed_red_bottom",1],
		["door",Vector3i(4,0,0),"mcl_doors:door_oak",1],
	]:
		order(job[0],job[1],job[1],job[2],job[3])
		check(await completed("bed" if job[0]=="furniture" else job[0]),"worker completes " + job[0])
	view.room_name.text = "Mountain bedroom"
	order("room:bedroom",Vector3i(5,0,1),Vector3i(7,0,3))
	check(await completed("bedroom",20),"furnished bedroom becomes usable")
	check(view.active and moved,"camera stays open with workers moving throughout")
	view.leave(); client.disconnect_from_server(); client=null; view=null; main.queue_free()
	await process_frame
	print("Overseer loop failures: ",failures)
	quit(1 if failures else 0)
