# SPDX-License-Identifier: LGPL-2.1-or-later
# Inspect generated geometry after BLOCKDATA, without a GPU.
extends SceneTree
var client: GoannaClient
var ready = false
func _initialize():
	create_timer(180).timeout.connect(func(): print("FAIL timeout"); quit(1))
	call_deferred("run")
func _process(_dt):
	if client:
		client.poll_blocks(8)
		client.update_lod(Vector3(2,17.62,3),8)
		for line in client.take_chat():
			print("CHAT ",line.message)
			if line.message.contains("MESH READY"): ready=true
	return false
func floor_vertices(node):
	var found=0
	if node is MeshInstance3D and node.mesh:
		for i in node.mesh.get_surface_count():
			var arr=node.mesh.surface_get_arrays(i)
			var verts=arr[Mesh.ARRAY_VERTEX]
			var norms=arr[Mesh.ARRAY_NORMAL]
			for j in verts.size():
				var p=node.global_transform * verts[j]
				if absf(p.y-15.5)<0.01 and p.x>=0.5 and p.x<=4.5 and p.z<=-0.5 and p.z>=-4.5 and norms[j].y>0.9:
					found+=1
	for child in node.get_children(): found+=floor_vertices(child)
	return found
func run():
	client=GoannaClient.new();root.add_child(client)
	client.connect_to("127.0.0.1",int(OS.get_environment("GOANNA_TEST_PORT")),"meshtest","")
	while not ready or client.status().get("state")!="ready": await create_timer(0.5).timeout
	client.set_player_pose(Vector3(2,17.62,3),0,0)
	await create_timer(12).timeout
	if client.status().get("blocks_meshed",0)==0:
		print("FAIL fixture has no meshes");quit(2);return
	print("BEFORE vertices=",floor_vertices(client)," stats=",client.status())
	client.send_chat("/mesh_cut")
	await create_timer(12).timeout
	var vertices=floor_vertices(client)
	var cut=client.node_name_at(Vector3(1,16,-1))=="air"
	var floor_kept=client.node_name_at(Vector3(1,15,-1))=="mcl_core:stone"
	if not cut or not floor_kept:
		print("FAIL fixture node contents");client.disconnect_from_server();quit(2);return
	print("AFTER vertices=",vertices," stats=",client.status())
	print("PASS floor rebuilt after block replacement" if vertices>0 else "FAIL missing boundary floor after block replacement")
	client.disconnect_from_server();quit(0 if vertices>0 else 1)
