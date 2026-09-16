# Inspect actual rendered triangles within the target, excluding the adjacent
# blocks' boundary faces. This catches fallback materials even if PBR-looking
# textures make a screenshot appear plausible.
var target_materials = func():
	var found = {}
	var bounds = AABB(Vector3(6.5001,7.5001,-7.4999),Vector3(.9998,1.0,.9998))
	for mi in client.find_children("*", "MeshInstance3D", true, false):
		if not mi.is_visible_in_tree() or mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			continue
		if not mi.mesh is ArrayMesh or not (mi.global_transform * mi.get_aabb()).intersects(bounds):
			continue
		for surface in mi.mesh.get_surface_count():
			var arrays = mi.mesh.surface_get_arrays(surface)
			var vertices = arrays[Mesh.ARRAY_VERTEX]
			var indices = arrays[Mesh.ARRAY_INDEX]
			for i in range(0,indices.size(),3):
				var centre = (vertices[indices[i]]+vertices[indices[i+1]]+vertices[indices[i+2]])/3.0
				if not bounds.has_point(mi.to_global(centre)):
					continue
				var mat = mi.get_active_material(surface)
				assert(mat is ShaderMaterial, "Carved terrain must retain its PBR shader")
				assert(mat.get_shader_parameter("has_normal") == true)
				assert(mat.get_shader_parameter("has_spec") == true)
				var maps = []
				for channel in ["albedo_array", "normal_array", "spec_array"]:
					var tex = mat.get_shader_parameter(channel)
					assert(tex is Texture2DArray)
					maps.append(tex.get_instance_id())
				found[str(mat.get_instance_id())] = maps
				break
	assert(not found.is_empty(), "The target must have rendered faces to inspect")
	return found
var original_materials = target_materials.call()
var trace = []
var held = true
var particles = main.get_tree().get_first_node_in_group("goanna_particles")
# Release before the first contact: no sound, chips or delayed hit may escape.
client.step_player(0.0001, {}, main.pitch, main.yaw)
client.set_player_pose(cam.position, main.pitch, main.yaw)
client.step_interact(0.0, true, false, false, false)
var cancelled = client.step_interact(0.2, true, false, false, false)
assert(not cancelled["dig_impact"] and cancelled["impact_progress"] == 0)
client.step_interact(0.0, false, false, false, false)
assert(client.take_dug_nodes().is_empty())
client.take_sounds()
for frame in range(175):
	client.step_player(0.0001, {}, main.pitch, main.yaw)
	client.set_player_pose(cam.position, main.pitch, main.yaw)
	var state = client.step_interact(1.0/30.0, held, false, false, false)
	main.pointed = state
	var chips = client.take_dug_nodes()
	var sounds = client.take_sounds()
	state["chips"] = 0
	for chip in chips:
		state["chips"] += chip["count"]
		particles._node_pieces(chip)
	state["sounds"] = sounds.size()
	for sound in sounds:
		main.ui.audio.play(sound["name"], sound["gain"], sound["pitch"], false, sound.get("position"))
	state["frame"] = frame
	trace.append(state)
	if state.get("node_name", "") == "air":
		held = false
	await main.get_tree().create_timer(1.0/30.0).timeout
	await RenderingServer.frame_post_draw
	if state["dig_impact"] and state["impact_progress"] < 1:
		var materials = target_materials.call()
		assert(materials == original_materials, "Every cut must reuse the original PBR material and maps")
		state["pbr_retained"] = true
	# Sample the rendered arm, not just the requested swing clock.
	for sk in client.find_children("*", "Skeleton3D", true, false):
		var bone = sk.find_bone("Arm_Right_Pitch_Control")
		if bone >= 0:
			var pose = sk.get_bone_pose(bone)
			state["arm_pose"] = [pose.origin.x, pose.origin.y, pose.origin.z,
				pose.basis.x.x, pose.basis.x.y, pose.basis.x.z,
				pose.basis.y.x, pose.basis.y.y, pose.basis.y.z]
			break
	if frame % 2 == 0:
		main.get_viewport().get_texture().get_image().save_png(@OUTPUT@.path_join("%03d.png" % frame))
client.step_interact(0.0, false, false, false, false)
return trace
