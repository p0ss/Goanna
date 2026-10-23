# SPDX-License-Identifier: LGPL-2.1-or-later
## Terrain cache invalidation and bounded rectangle overlays, dummy renderer.
## godot --headless --path project --script res://tests/overseer_cache.gd
extends SceneTree
const Unit = preload("res://tests/overseer.gd")
const Overseer = preload("res://game/overseer.gd")
var checks := 0
var failures := 0
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures += 1
	print("PASS " if ok else "FAIL ", label)
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	var main = Unit.TestMain.new(); root.add_child(main)
	var client = Unit.TestClient.new(); main.add_child(client)
	var view = Overseer.new(); view.main = main; view.client = client; main.add_child(view)
	view._open()
	view.level = 0
	view.snapshot = {"y":0,"rect":{"x0":0,"x1":2,"z0":0,"z1":0},"cells":[1,1,0],"floors":[2,2,0],
		"states":[2,2,0],"dates":[1,1,-1],"palette":[{"name":"stone"}],"orders":[],"overlays":{}}
	view._draw_layer()
	var geometry = view.geometry_signature
	var mask = view.concealment.get_child(0)
	var pending = view.mesh_queue.duplicate()
	view.snapshot.dates = [2,2,-1]
	view.snapshot.overlays = {"workers":[{"id":"a","name":"Ada","x":0,"z":0,"here":true}]}
	view._draw_layer()
	check(view.geometry_signature == geometry and view.concealment.get_child(0) == mask,
		"new observation dates and actor updates retain identical terrain and masks")
	check(view.mesh_queue == pending, "unchanged replies preserve pending terrain mesh work")
	view.snapshot.states = [1,2,0]
	view._draw_layer()
	check(view.concealment.get_child(0) != mask and view.geometry_signature == geometry,
		"remembered visibility rebuilds masks without rebuilding identical geometry")
	mask = view.concealment.get_child(0)
	view.snapshot.cells = [0,1,0]; view.snapshot.floors = [0,2,0]; view.snapshot.states = [0,2,0]
	view._draw_layer()
	check(view.geometry_signature != geometry and view.concealment.get_child(0) != mask,
		"newly unknown cells replace terrain signatures and concealment immediately")
	geometry = view.geometry_signature
	view.snapshot.below = [{"cells":[0,2,0],"walls":[0,2,0],"states":[0,2,0]}]
	view._draw_layer()
	check(view.geometry_signature != geometry, "supplied lower walls invalidate geometry")
	geometry = view.geometry_signature
	mask = view.concealment.get_child(0)
	view.snapshot.below[0].states = [0,1,0]
	view._draw_layer()
	check(view.geometry_signature == geometry and view.concealment.get_child(0) != mask,
		"lower-level remembered states invalidate concealment")
	view.snapshot.palette[0].param2 = 3
	view._draw_layer()
	check(view.geometry_signature != geometry, "palette orientation changes invalidate geometry")
	geometry = view.geometry_signature
	view.level = 1; view.snapshot.y = 1
	view._draw_layer()
	check(view.geometry_signature != geometry and view.meshed_level == 1, "changing level selects and rebuilds the appropriate geometry")
	geometry = view.geometry_signature
	view.snapshot.rect = {"x0":3,"x1":5,"z0":0,"z1":0}
	view._draw_layer()
	check(view.geometry_signature != geometry, "changing the supplied rectangle invalidates terrain")
	mask = view.concealment.get_child(0)
	geometry = view.geometry_signature
	view.extent += 2
	view._draw_layer()
	check(view.geometry_signature == geometry and view.concealment.get_child(0) != mask,
		"zoom refreshes outer concealment caps without rebuilding terrain")
	view.snapshot = {"empty":true}
	view._draw_layer()
	check(view.geometry_signature == null and view.concealment_signature == null and view.mesh_queue.is_empty(),
		"empty server layer clears terrain cache signatures and pending work")
	view._clear_layer()
	check(view.geometry_signature == null and view.concealment_signature == null, "clearing a stale view resets caches")
	view._close(); view._open()
	check(view.geometry_signature == null and view.concealment_signature == null and view.snapshot.is_empty(),
		"a new session cannot reuse the previous session's visibility")
	var layer = {"rect":{"x0":0,"x1":2,"z0":0,"z1":0},"cells":[1,0,1],"overlays":{"areas":[],"zones":[]}}
	for n in 256:
		layer.overlays.areas.append({"rect":layer.rect,"reachability":"partial"})
		layer.overlays.zones.append({"rect":layer.rect})
	var zones = Overseer.zone_cells(layer)
	check(zones.area == [Vector2i(0,0),Vector2i(2,0)] and zones.forbid == zones.area,
		"256 overlapping designations allocate each known cell only once")
	check(Overseer.guard_cells(layer).partial == zones.area, "guard hatches share the bounded known-cell coverage")
	check(not Overseer.overlay_notes(layer,{"x":1,"y":0,"z":0}).contains("Protected area")
		and not Overseer.overlay_notes(layer,{"x":1,"y":0,"z":0}).contains("Forbidden area"),
		"point inspection preserves unknown-cell secrecy")
	view._close(); main.queue_free()
	await process_frame
	print("Overseer cache: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
