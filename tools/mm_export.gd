# Batch export of Material Maker materials, run inside the Material Maker
# flatpak in place of its own start scene, whose --export-material path is
# broken in 1.7 (it tests a DirAccess it never opened). Not a project file:
# tools/mm_export.py hands it to the runner with --script.
#
#   godot-runner --main-pack material-maker.pck --script <this file> --
#       -o <dir> [--size N] [--target "Godot/Godot 4 Standard"] a.ptex b.ptex
extends SceneTree

var output_dir := ""
var target := "Godot/Godot 4 Standard"
var image_size := 0
var files: Array[String] = []
# A material whose graph no longer compiles never finishes its render, so
# each export gets this long before it is given up on.
var limit := 90.0
var status: FileAccess


func say(msg: String) -> void:
	print(msg)
	if status != null:
		status.store_line(msg)
		status.flush()


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		match args[i]:
			"-o", "--output-dir":
				i += 1
				output_dir = args[i]
			"-t", "--target":
				i += 1
				target = args[i]
			"--size":
				i += 1
				image_size = int(args[i])
			"--limit":
				i += 1
				limit = float(args[i])
			_:
				files.append(args[i])
		i += 1
	if output_dir == "" or not DirAccess.dir_exists_absolute(output_dir):
		printerr("mm_export: output directory '%s' does not exist" % output_dir)
		quit(2)
		return
	status = FileAccess.open(output_dir.path_join("mm_export.status"), FileAccess.WRITE)
	_run.call_deferred()


func _run() -> void:
	var loader := root.get_node_or_null("mm_loader")
	if loader == null:
		printerr("mm_export: no mm_loader autoload; is this the Material Maker pack?")
		quit(2)
		return
	var failed := 0
	for f in files:
		# Loading builds the graph's shaders; a graph that no longer
		# compiles can hang here as well as in the export.
		say("mm_export: loading %s" % f.get_file())
		var loading := {"done": false, "gen": null}
		_load_one(loader, f, loading)
		var waited_load := 0.0
		while not loading.done and waited_load < limit:
			await create_timer(0.25).timeout
			waited_load += 0.25
		if not loading.done:
			say("mm_export: %s did not finish in %.0f s (loading)" % [f.get_file(), limit])
			failed += 1
			continue
		var gen = loading.gen
		if gen == null:
			say("mm_export: could not load %s" % f)
			failed += 1
			continue
		root.add_child(gen)
		var exported := false
		for c in gen.get_children():
			if c.has_method("export_material"):
				var chosen := target
				if c.has_method("get_export_profiles"):
					chosen = pick_target(c.get_export_profiles())
					if chosen == "":
						say("mm_export: %s has no target like '%s'; it has %s" % [f, target, ", ".join(c.get_export_profiles())])
						continue
				var prefix: String = output_dir.path_join(f.get_file().get_basename())
				say("mm_export: %s -> %s" % [f.get_file(), prefix])
				var state := {"done": false}
				_export_one(c, prefix, chosen, state)
				var waited := 0.0
				while not state.done and waited < limit:
					await create_timer(0.25).timeout
					waited += 0.25
				if state.done:
					say("mm_export: %s exported" % f.get_file())
					exported = true
				else:
					say("mm_export: %s did not finish in %.0f s (a shader error above is the usual cause)" % [f.get_file(), limit])
		if not exported:
			say("mm_export: %s has no material node" % f)
			failed += 1
		gen.queue_free()
	say("mm_export: %d of %d exported" % [files.size() - failed, files.size()])
	say("mm_export: done")
	# A render left hanging blocks the engine's shutdown, so quit() may
	# never end the process; tools/mm_export.py kills the flatpak on "done".
	quit(1 if failed else 0)


func _load_one(loader: Node, f: String, loading: Dictionary) -> void:
	loading.gen = await loader.load_gen(f)
	loading.done = true


func _export_one(c: Node, prefix: String, chosen: String, state: Dictionary) -> void:
	await c.export_material(prefix, chosen, image_size)
	state.done = true


func pick_target(profiles: Array) -> String:
	"""The requested profile, or the one whose words it shares: materials
	saved by different Material Maker versions spell the same target
	differently ("Godot/Godot 4 Standard" and "Godot/G4 Standard")."""
	if profiles.find(target) != -1:
		return target
	var want := target.to_lower().replace("godot 4", "g4").replace("/", " ").split(" ", false)
	for p in profiles:
		var have := String(p).to_lower().replace("godot 4", "g4").replace("/", " ").split(" ", false)
		var all := true
		for w in want:
			if have.find(w) == -1:
				all = false
		if all:
			return p
	return ""
