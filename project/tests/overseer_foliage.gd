# SPDX-License-Identifier: LGPL-2.1-or-later
# Known non-walkable vegetation must not hide live actors.
extends SceneTree
var client: GoannaClient
var failures := 0
func _initialize() -> void:
	call_deferred("run")
func _process(dt: float) -> bool:
	if client != null:
		client.poll_blocks(0)
		client.set_player_pose(Vector3(0,0.1,0),0,0)
		client.sync_entities(dt)
	return false
func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ",label)
	if not ok: failures+=1
func run() -> void:
	client=GoannaClient.new();root.add_child(client)
	client.connect_to("127.0.0.1",30561,"overseertest","")
	var deadline:=Time.get_ticks_msec()+90000
	while client.status().get("state")!="ready" and Time.get_ticks_msec()<deadline:
		await create_timer(0.1).timeout
	client.send_chat("/overseer_fixture")
	deadline=Time.get_ticks_msec()+30000
	while client.entity_list().is_empty() and Time.get_ticks_msec()<deadline:
		await create_timer(0.1).timeout
	check(not client.entity_list().is_empty(),"live worker available for vegetation visibility test")
	var actors:=Node3D.new();root.add_child(actors)
	var cells:Array=[];cells.resize(41*41);cells.fill(2)
	var layer:Dictionary={"y":0,"rect":{"x0":-12,"x1":28,"z0":-12,"z1":28},"cells":cells,"palette":[{"name":"mcl_flowers:tallgrass"}]}
	for node in ["mcl_flowers:tallgrass","mcl_flowers:wildflowers_4","mcl_core:stone","mcl_core:water_source","mcl_core:glass"]:
		layer.palette=[{"name":node}]
		client.overseer_entities(actors,layer)
		await create_timer(0.3).timeout
		check(client.entity_list().is_empty()==(not node.begins_with("mcl_flowers:")),"actor visibility in "+node)
	var states: Array = [];states.resize(cells.size());states.fill(1)
	cells.fill(1);layer.cells=cells;layer.states=states
	client.overseer_entities(actors,layer)
	await create_timer(0.3).timeout
	check(client.entity_list().is_empty(),"remembered air conceals live actors")
	states.fill(2);layer.states=states;client.overseer_entities(actors,layer)
	await create_timer(0.3).timeout
	check(not client.entity_list().is_empty(),"current sight restores live actors")
	layer.y=2;layer.below=[{"cells":cells,"states":states},{"cells":cells,"states":states}]
	client.overseer_entities(actors,layer)
	await create_timer(0.3).timeout
	check(not client.entity_list().is_empty(),"live actors visible down a currently visible open shaft")
	var wall: Array=cells.duplicate();wall.fill(2)
	layer.palette=[{"name":"mcl_core:stone"}];layer.below[0].cells=wall
	client.overseer_entities(actors,layer)
	await create_timer(0.3).timeout
	check(client.entity_list().is_empty(),"intervening known stone conceals lower actors")
	layer.y=0;layer.erase("below")
	var plant=client.overseer_mesh({"y":0,"rect":{"x0":0,"x1":0,"z0":0,"z1":0},
		"cells":[2],"floors":[0],"palette":[{"name":"mcl_flowers:tallgrass"}]},Vector3i.ZERO)
	check(plant != null and plant.get_surface_count()>0 and plant.get_aabb().size.y<0.01,
		"crossed plant sprites face the overhead camera")
	var deep=client.overseer_mesh({"y":2,"rect":{"x0":0,"x1":0,"z0":0,"z1":0},
		"cells":[1],"floors":[1],"below":[{"cells":[1]},{"cells":[1]},{"cells":[2]}],
		"palette":[{"name":"mcl_core:stonebrick"}]},Vector3i(0,-1,0))
	check(deep != null and deep.get_surface_count()>0 and absf(deep.get_aabb().position.y+1.5)<0.01,
		"world geometry survives three levels below the selected slice")
	var wall_layer={"y":2,"rect":{"x0":0,"x1":1,"z0":0,"z1":0},
		"cells":[1,2],"floors":[1,2],
		"below":[{"cells":[1,2]},{"cells":[1,0],"walls":[0,2]}],
		"palette":[{"name":"mcl_core:stonebrick"}]}
	var with_wall=client.overseer_mesh(wall_layer,Vector3i.ZERO)
	wall_layer.below[1].walls=[0,0]
	var without_wall=client.overseer_mesh(wall_layer,Vector3i.ZERO)
	check(with_wall.get_faces().size()>without_wall.get_faces().size(),
		"known lower side walls contribute real shadow-casting triangles")
	cells.fill(0);layer.cells=cells;client.overseer_entities(actors,layer)
	await create_timer(0.3).timeout
	check(client.entity_list().is_empty(),"unknown cells still hide cached actors")
	client.overseer_entities(null,{})
	await create_timer(0.3).timeout
	check(not client.entity_list().is_empty(),"ordinary actor ownership restored")
	client.disconnect_from_server();client.queue_free();client=null
	await process_frame
	quit(1 if failures else 0)
