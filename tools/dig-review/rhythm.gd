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
