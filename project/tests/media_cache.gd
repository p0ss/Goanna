# SPDX-License-Identifier: LGPL-2.1-or-later
## One real server join for tools/test/test-media-cache.py, without a GPU.
extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var client := GoannaClient.new()
	root.add_child(client)
	client.set_content_hold(true)
	client.set_mesh_threads(1)
	client.set_lod_distance(0)
	client.set_far_distance(0)
	client.connect_to("127.0.0.1", int(OS.get_environment("GOANNA_TEST_PORT")),
		"media_test_%d" % OS.get_process_id(), "")
	var deadline := Time.get_ticks_msec() + 90000
	var result := {}
	while Time.get_ticks_msec() < deadline:
		var status: Dictionary = client.status()
		if status.state in ["error", "denied", "disconnected"]:
			printerr("Media cache join failed: ", status)
			break
		if status.state == "content-ready":
			client.set_content_hold(false)
		if status.state == "ready":
			result = status
			break
		client.poll_blocks(1)
		await create_timer(0.02).timeout
	client.disconnect_from_server()
	client.queue_free()
	await process_frame
	if result.is_empty():
		printerr("Media cache: did not reach ready")
		quit(1)
		return
	var output := FileAccess.open(OS.get_environment("GOANNA_TEST_RESULT"), FileAccess.WRITE)
	output.store_string(JSON.stringify(result))
	output.close()
	print("Media cache join: ", result.media_cached, " cached, ",
		result.media_downloaded, " downloaded")
	quit()
