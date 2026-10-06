# SPDX-License-Identifier: LGPL-2.1-or-later
# Observation-only lava attributes must not depend on cached hidden terrain.
extends SceneTree
var client: GoannaClient
func _initialize() -> void:
	call_deferred("run")
func _process(_delta: float) -> bool:
	if client != null:
		client.poll_blocks(0)
		client.set_player_pose(Vector3(0,0.1,0),0,0)
	return false
func mesh_at(x: int, z: int) -> ArrayMesh:
	return client.overseer_mesh({"y":0,"rect":{"x0":x,"x1":x,"z0":z,"z1":z},
		"cells":[2],"floors":[0],"palette":[{"name":"mcl_core:lava_source","param2":0}]},
		Vector3i(floori(x/16.0),0,floori(z/16.0)))
func run() -> void:
	client = GoannaClient.new(); root.add_child(client)
	client.connect_to("127.0.0.1",30561,"overseertest","")
	var deadline := Time.get_ticks_msec()+90000
	while client.status().get("state") != "ready" and Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout
	if client.status().get("state") != "ready": quit(1); return
	client.send_chat("/overseer_fixture")
	deadline = Time.get_ticks_msec()+30000
	while client.node_name_at(Vector3(18,0,-18)) == "ignore" and Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout
	var cached := client.node_name_at(Vector3(18,0,-18)) == "mcl_core:lava_source"
	print("PASS " if cached else "FAIL ","fixture has concealed lava in the ordinary cache")
	var open := mesh_at(0,0)
	var hidden := mesh_at(18,18)
	var valid := cached and open != null and hidden != null and open.get_surface_count() > 0 and open.get_surface_count() == hidden.get_surface_count()
	if valid:
		for i in open.get_surface_count():
			var a := open.surface_get_arrays(i)
			var b := hidden.surface_get_arrays(i)
			valid = valid and a[Mesh.ARRAY_CUSTOM1] == b[Mesh.ARRAY_CUSTOM1] and a[Mesh.ARRAY_TEX_UV] == b[Mesh.ARRAY_TEX_UV]
	print("PASS " if valid else "FAIL ","lava flow and shoreline direction ignore cached hidden neighbours")
	client.disconnect_from_server(); client.queue_free(); client=null
	await process_frame
	quit(0 if valid else 1)
