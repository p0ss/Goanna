# SPDX-License-Identifier: LGPL-2.1-or-later
# Verify the generated local-server grant and its required transport.
extends SceneTree

const LocalServer := preload("res://local_server.gd")


func _initialize() -> void:
	if not FileAccess.file_exists("/bin/true"):
		print("local server rendering: skipped, requires /bin/true as process stub")
		quit(0)
		return
	var base := OS.get_temp_dir().path_join("goanna-rendering-config-%d" % OS.get_process_id())
	OS.set_environment("GOANNA_SERVER_CMD", "/bin/true")
	OS.set_environment("GOANNA_SERVER_DATA_DIR", base)
	var server := LocalServer.new()
	var error := server.start_config({"gameid": "devtest", "world": "rendering",
		"pbr_materials": false, "far_distance": 2048})
	var config := FileAccess.get_file_as_string(base.path_join("goanna_local_server.conf"))
	var ok := error == "" and config.contains("enable_mod_channels = true\n") \
		and config.contains("goanna_far_rendering = true\n") \
		and config.contains("goanna_far_rendering_distance = 2048\n")
	if not ok:
		push_error("local server rendering: missing grant or mod-channel transport: " + error)
	else:
		print("local server rendering: PASS")
	quit(0 if ok else 1)
