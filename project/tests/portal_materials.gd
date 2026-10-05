# SPDX-License-Identifier: LGPL-2.1-or-later
# Real-server routing check, using Godot's dummy renderer. The server must
# provide both portals near (1024, 32, -1024), as portal-fixture.lua does.
extends SceneTree

var client: GoannaClient
var failures := 0
var portals: Dictionary = {}
var rim_vertices := 0
var wrong_faces := 0

func check(ok: bool, message: String) -> void:
	if not ok:
		push_error(message)
		failures += 1

func inspect_meshes(node: Node) -> void:
	if node is MeshInstance3D and node.mesh:
		for i in node.mesh.get_surface_count():
			var mat: Material = node.get_active_material(i)
			if mat is ShaderMaterial and mat.shader:
				var code: String = mat.shader.code
				if code.contains("Translucent Nether membrane"):
					portals["nether"] = mat
					var arrays: Array = node.mesh.surface_get_arrays(i)
					for uv in arrays[Mesh.ARRAY_TEX_UV2]:
						if uv.x > 0.5:
							rim_vertices += 1
					for normal in arrays[Mesh.ARRAY_NORMAL]:
						if absf(normal.y) > 0.5:
							wrong_faces += 1
				elif code.contains("eight virtual star planes"):
					portals["end"] = mat
					for normal in node.mesh.surface_get_arrays(i)[Mesh.ARRAY_NORMAL]:
						if absf(normal.y) < 0.5:
							wrong_faces += 1
	for child in node.get_children():
		inspect_meshes(child)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	client = GoannaClient.new()
	root.add_child(client)
	client.enable_render_scope()
	client.set_mesh_threads(2)
	client.set_poll_budget_ms(30.0)
	client.set_lod_distance(0)
	client.set_far_distance(0)
	var pack := OS.get_environment("GOANNA_PORTAL_PACK")
	if not pack.is_empty():
		client.set_texture_path(pack)
	client.connect_to("127.0.0.1", int(OS.get_environment("GOANNA_TEST_PORT")),
		"portal_test_%d" % OS.get_process_id(), "")
	var deadline := Time.get_ticks_msec() + 120000
	var next_report := 0
	while Time.get_ticks_msec() < deadline:
		if client.status().get("state") == "denied":
			break
		client.set_player_pose(Vector3(1024, 35, -1017), -15, 0)
		client.poll_blocks(64)
		client.update_lod(Vector3(1024, 35, -1017), 8)
		client.step_node_animation(0.05)
		inspect_meshes(client)
		if Time.get_ticks_msec() > next_report:
			print("Portal test: ", client.status().get("state"),
				" meshes=", client.block_mesh_count(), " found=", portals.keys(),
				" nodes=", client.node_name_at(Vector3(1021, 34, -1024)), ",",
				client.node_name_at(Vector3(1026, 32, -1024)))
			next_report = Time.get_ticks_msec() + 10000
		if portals.size() == 2:
			break
		await create_timer(0.05).timeout
	check(portals.has("nether"), "Nether faces reach their shader")
	check(portals.has("end"), "End faces leave the animation array for their shader")
	check(rim_vertices > 0, "Nether frame contacts reach the mesh without a lamp grid")
	check(wrong_faces == 0, "Blank sides do not acquire either portal shader")
	for kind in portals:
		var mat: ShaderMaterial = portals[kind]
		client.set_node_animation_time(0.0)
		var first: Texture2D = mat.get_shader_parameter("albedo_tex")
		client.set_node_animation_time(0.7)
		var later: Texture2D = mat.get_shader_parameter("albedo_tex")
		check(first != null and later != null and first != later,
			kind + " keeps the server's texture animation")
		check(mat.shader.code.contains("view_"), kind + " uses the player's scoped globals")
	print("Portal material routing: %d failures; %s" % [failures, portals.keys()])
	client.disconnect_from_server()
	client.queue_free()
	await process_frame
	quit(1 if failures else 0)
