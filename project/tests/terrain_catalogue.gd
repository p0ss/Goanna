extends SceneTree

const LocalServer := preload("res://local_server.gd")

# The world picker is only as good as this data: a wrong hash or a missing
# preview is not a crash, it is a download that fails or a blank panel.
func _fail(message: String) -> void:
	printerr("terrain catalogue: FAIL: ", message)
	quit(1)

func _init() -> void:
	var worlds := LocalServer.terrain_worlds()
	if worlds.is_empty():
		_fail("the catalogue lists no worlds")
		return
	var default_id := LocalServer.default_terrain_id()
	if LocalServer.terrain_world(default_id).is_empty():
		_fail("the default id %s is not one of the listed worlds" % [default_id])
		return
	var seen := {}
	for world in worlds:
		var id := str(world.get("id", ""))
		if id == "":
			_fail("a world has no id")
			return
		if seen.has(id):
			_fail("%s is listed twice" % [id])
			return
		seen[id] = true
		for field in ["label", "description", "url", "sha256"]:
			if str(world.get(field, "")) == "":
				_fail("%s has no %s" % [id, field])
				return
		if not str(world.get("url", "")).begins_with("https://"):
			_fail("%s has a url that is not https" % [id])
			return
		if str(world.get("sha256", "")).length() != 64:
			_fail("%s has no usable sha256" % [id])
			return
		if int(world.get("bytes", 0)) <= 0 or int(world.get("tiles", 0)) <= 0:
			_fail("%s has no size or no tiles" % [id])
			return
		if Array(world.get("spawn_px", [])).size() != 2:
			_fail("%s has no spawn pixel" % [id])
			return
		# Either form counts: the imported resource once Godot has seen the
		# project, or the source file on a fresh checkout, where .import files
		# do not exist yet because they are not tracked.
		var art := str(world.get("preview", ""))
		if art == "" or not (ResourceLoader.exists(art) or FileAccess.file_exists(art)):
			_fail("%s has no preview at %s" % [id, art])
			return
	# The picker is built from this list, so it must also parse.
	if load("res://menu.gd") == null:
		_fail("menu.gd did not load")
		return
	# Optional: point GOANNA_TEST_TERRAIN_ARCHIVE at a downloaded world to check
	# the archive itself unpacks to the tile window its catalogue entry claims.
	# Off by default, because it needs a file this repository does not carry.
	var archive := OS.get_environment("GOANNA_TEST_TERRAIN_ARCHIVE")
	if archive != "":
		var wanted := OS.get_environment("GOANNA_TEST_TERRAIN_ID")
		var entry := LocalServer.terrain_world(wanted)
		if entry.is_empty():
			_fail("GOANNA_TEST_TERRAIN_ID %s is not in the catalogue" % [wanted])
			return
		var zip := ZIPReader.new()
		if zip.open(archive) != OK:
			_fail("could not open %s" % [archive])
			return
		var staging := ProjectSettings.globalize_path(
				"user://terrain-archive-test-%d" % OS.get_process_id())
		for name in zip.get_files():
			if name.ends_with("/"):
				continue
			var target := staging.path_join(name)
			DirAccess.make_dir_recursive_absolute(target.get_base_dir())
			var out := FileAccess.open(target, FileAccess.WRITE)
			if out == null:
				_fail("could not write %s" % [target])
				return
			out.store_buffer(zip.read_file(name))
			out = null
		zip.close()
		if not LocalServer.terrain_dir_valid(staging, entry):
			_fail("%s did not unpack to the tile window the catalogue claims" % [wanted])
			return
		print("terrain archive: %s unpacked and matches its catalogue entry" % [wanted])
	print("terrain catalogue: PASS, %d worlds, default %s" % [worlds.size(), default_id])
	quit()
