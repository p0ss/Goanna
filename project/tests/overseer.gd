# SPDX-License-Identifier: LGPL-2.1-or-later
## Contract tests for the overseer view (game/overseer.gd) with a stand in
## game and client: its isolated world, explicit bounds, unknown floors,
## stale replies, level changes and restoration. The other overseer tests
## reuse its TestMain and TestClient. Headless, no server or GPU:
## godot --headless --path project --script res://tests/overseer.gd
extends SceneTree
const Overseer := preload("res://game/overseer.gd")
var failures := 0
var checks := 0

class TestMain extends Node3D:
	var cam := Camera3D.new()
	var ui: CanvasLayer
	var env: WorldEnvironment
	var sun: DirectionalLight3D
	var moon: DirectionalLight3D
	var dig_down := false
	var place_down := false
	var place_pressed := false
	var captured := true
	func _init() -> void:
		add_child(cam)
	func pointer_captured() -> bool:
		return captured
	func set_pointer_captured(value: bool) -> void:
		captured = value
	func _key_pressed(_key: Key) -> bool:
		return false

class TestClient extends Node:
	var sent: Array = []
	var meshed: Array = []
	var entity_layer: Dictionary = {}
	var entity_parent: Node3D
	func overseer_entities(parent: Node3D, layer: Dictionary) -> void:
		entity_layer = layer
		entity_parent = parent
	func overseer_mesh(layer: Dictionary, _block: Vector3i) -> ArrayMesh:
		meshed.append(layer)
		return null
	func overseer_send(message: String) -> void:
		sent.append(JSON.parse_string(message))
	func overseer_channel(_channel: String) -> bool:
		return true
	func texture(_name: String) -> Texture2D:
		return null

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(label)
	print("PASS " if ok else "FAIL ", label)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var main := TestMain.new()
	root.add_child(main)
	var client := TestClient.new()
	main.add_child(client)
	var view := Overseer.new()
	view.main = main
	view.client = client
	main.add_child(view)
	view._open()
	var bounds := {"min": {"x": -16, "y": -8, "z": -16}, "max": {"x": 16, "y": 8, "z": 16}}
	view._receive({"v": 1, "t": "hello", "claim": bounds, "y": 0,
		"body": {"x": 0, "y": -0.4, "z": 0}, "tools": [{"id": "inspect", "title": "Inspect"}]})
	check(view.session_ready and view.active, "hello enters the camera")
	check(view.viewport.own_world_3d, "camera has its own world")
	check(view.viewport.world_3d != main.get_world_3d(), "cached world cannot share the overseer scene")
	check(main.cam.cull_mask == 0, "ordinary camera draws no world while planning")
	check(view.camera.projection == Camera3D.PROJECTION_ORTHOGONAL, "camera is orthographic")
	view.tool = "furniture"
	view._update_materials([{ "name": "stone", "title": "Stone", "kind": "block" },
		{ "name": "bed", "title": "Bed", "kind": "furniture" }])
	check(view.build_materials.size() == 1 and view.build_materials[0].name == "bed"
		and view.facing_picker.visible, "furniture picker offers beds with a facing control")
	view.tool = "wall"
	view._update_materials(view.material_catalog)
	check(view.build_materials.size() == 1 and view.build_materials[0].name == "stone"
		and not view.facing_picker.visible, "wall picker offers full blocks without furniture facing")
	var layer := {"v": 1, "t": "layer", "seq": view.sequence, "rev": 1, "y": 0,
		"rect": {"x0": 0, "x1": 2, "z0": 0, "z1": 0},
		"cells": [1, 2, 0], "floors": [2, 0, 0], "dates": [1, 1, -1],
		"palette": [{"name": "stone", "texture": "stone.png"}], "orders": []}
	check(Overseer.valid_layer(layer, view.sequence, 0, view.requested, bounds), "bounded layer accepted")
	view._receive(layer)
	check(not view.snapshot.is_empty() and not view.mesh_queue.is_empty(), "authorised layer queues the world mesher")
	view._build_next_mesh()
	check(client.meshed.size() >= 1 and client.meshed[0].cells == [1, 2, 0], "world mesher receives observations, including explicit unknowns")
	check(client.entity_layer.cells == [1, 2, 0], "live entities use the same observation boundary")
	var bad := layer.duplicate(true)
	bad.floors[2] = 2
	check(not Overseer.valid_layer(bad, view.sequence, 0, view.requested, bounds), "unknown cell cannot carry a floor")
	bad = layer.duplicate(true)
	bad.rect.x1 = 100
	check(not Overseer.valid_layer(bad, view.sequence, 0, view.requested, bounds), "out-of-bounds rectangle rejected")
	bad = layer.duplicate(true)
	bad.cells[1] = 1234
	check(not Overseer.valid_layer(bad, view.sequence, 0, view.requested, bounds), "invalid palette index rejected")
	var shaft := layer.duplicate(true)
	shaft.states = [2, 1, 0]
	shaft.floors = [1, 0, 0]
	shaft.below = [{"cells": [1, 0, 0], "states": [2, 0, 4]}, {"cells": [2, 0, 0], "states": [1, 4, 4]}]
	check(Overseer.valid_layer(shaft, view.sequence, 0, view.requested, bounds), "bounded shaft states accepted")
	bad = shaft.duplicate(true);bad.below[1].cells[2] = 2;bad.below[1].states[2] = 2
	check(not Overseer.valid_layer(bad, view.sequence, 0, view.requested, bounds), "lower terrain cannot reappear below unexplored cells")
	bad = shaft.duplicate(true);bad.states[0] = 3
	check(not Overseer.valid_layer(bad, view.sequence, 0, view.requested, bounds), "unavailable state cannot carry terrain")
	view.snapshot = shaft;view._draw_layer()
	var mask: ImageTexture = view.memory_material.get_shader_parameter("memory_mask")
	check(mask.get_image().get_pixel(0,0).r > 0.99 and mask.get_image().get_pixel(2,0).r < 0.01,
		"remembered lower surface has memory treatment, unexplored does not")
	bad = shaft.duplicate(true);bad.below[1].walls = [0, 2, 0]
	check(Overseer.valid_layer(bad, view.sequence, 0, view.requested, bounds), "known side-wall geometry accepted below suppressed columns")
	bad.below[1].walls[0] = 2
	check(not Overseer.valid_layer(bad, view.sequence, 0, view.requested, bounds), "side walls cannot overwrite supplied shaft cells")
	main.env = WorldEnvironment.new();main.env.environment = Environment.new();main.add_child(main.env)
	main.sun = DirectionalLight3D.new();main.add_child(main.sun)
	main.moon = DirectionalLight3D.new();main.add_child(main.moon)
	main.sun.rotation_degrees = Vector3(-44, 90, 0)
	main.moon.rotation_degrees = Vector3(44, -90, 0)
	main.sun.shadow_enabled = true;main.moon.shadow_enabled = true
	main.sun.light_energy = 1.3;main.env.environment.tonemap_exposure = 0.7
	view._sync_lighting()
	var day_haze: Color = view.depth_material.albedo_color
	var morning_direction := view.slice_sun.global_basis.z
	main.sun.rotation_degrees = Vector3(-44, -90, 0)
	main.moon.rotation_degrees = Vector3(44, 90, 0)
	view._sync_lighting()
	check(view.slice_sun.global_basis.z.is_equal_approx(main.sun.global_basis.z)
		and morning_direction.x * view.slice_sun.global_basis.z.x < 0.0,
		"sun crosses the sky while the view stays open")
	check(view.slice_moon.global_basis.z.is_equal_approx(main.moon.global_basis.z)
		and view.slice_sun.shadow_enabled and view.slice_moon.shadow_enabled,
		"moon direction and both cast-shadow flags follow the ordinary scene")
	main.sun.light_energy = 0.0;main.env.environment.tonemap_exposure = 0.3
	view._sync_lighting()
	check(view.slice_environment.tonemap_exposure == main.env.environment.tonemap_exposure,
		"exposure follows time of day while the view stays open")
	check(view.depth_material.albedo_color.b < day_haze.b * 0.5 and is_equal_approx(day_haze.a, 0.045),
		"gentler depth haze dims at night")
	var large := layer.duplicate(true)
	large.rev = 2
	large.padding = "é漢".repeat(16000)
	var bytes := JSON.stringify(large).to_utf8_buffer()
	# Force a final partial base64 quartet, as Luanti emits without '='.
	if bytes.size() % 3 == 0: bytes.append(32)
	var count := int(ceil(bytes.size() / 30000.0))
	for part in range(count, 0, -1):
		view._receive({"v": 1, "t": "part", "id": 10, "i": part, "n": count,
			"data": Marshalls.raw_to_base64(bytes.slice((part - 1) * 30000, part * 30000)).trim_suffix("=").trim_suffix("=")})
	check(view.revision == 2, "unpadded Luanti chunks reassemble UTF-8 out of order")
	view._receive({"v": 1, "t": "part", "id": 11, "i": 1, "n": 36, "data": ""})
	check(not view.parts.has(11), "oversized chunk count rejected")
	# Overlays: room quality by tier, unsurveyed rooms grey, miasma bands.
	var marked := layer.duplicate(true)
	marked.overlays = {"rooms": [
		{"rect": {"x0": 0, "x1": 1, "z0": 0, "z1": 0}, "surveyed": true, "tier": 2, "title": "Bedroom",
			"name": "Urist", "tier_name": "decorated", "points": 11, "day": 3},
		{"rect": {"x0": 2, "x1": 9, "z0": 0, "z1": 0}, "surveyed": false, "tier": 3, "title": "Office", "name": "Books"}],
		"miasma": [{"x": 0, "y": 0, "z": 0, "scent": 2, "stage": "rotten", "kind": "carcass", "day": 4},
			{"x": 2, "y": 5, "z": 0, "scent": 2, "stage": "fresh", "kind": "gore", "day": 4}]}
	var tiers := Overseer.room_cells(marked)
	check(tiers.get(2) == [Vector2i(0, 0), Vector2i(1, 0)] and tiers.get(-1) == [Vector2i(2, 0)],
		"surveyed rooms tint by tier, an unsurveyed one stays grey, clipped to the layer")
	var smell := Overseer.miasma_strength(marked)
	check(is_equal_approx(smell[0], 1.0) and is_equal_approx(smell[1], 0.5) and smell[2] == 0.0,
		"miasma fades with distance, and a source beyond its scent's height adds nothing")
	var bands := Overseer.miasma_cells(marked)
	check(bands.get(3) == [Vector2i(0, 0)] and bands.get(2) == [Vector2i(1, 0)] and bands.size() == 2,
		"miasma shades only known cells, in bands")
	var notes := Overseer.overlay_notes(marked, {"x": 0, "y": 0, "z": 0})
	check(notes.contains("decorated, 11 points, as of day 3") and notes.contains("rotten carcass, seen day 4"),
		"inspect names the room's tier and the miasma's source")
	check(Overseer.overlay_notes(marked, {"x": 2, "y": 0, "z": 0}).contains("not yet surveyed"),
		"inspect says when a room is not yet surveyed")
	check(Overseer.room_cells({"rect": layer.rect, "overlays": {"rooms": "nonsense"}}).is_empty()
		and Overseer.miasma_strength({"rect": layer.rect, "cells": [1], "overlays": {}}).is_empty(),
		"malformed overlays draw nothing")
	view.snapshot = marked
	view._draw_overlays()
	check(view.overlay_sheets != null and view.overlay_sheets.get_child_count() == 0, "overlays start hidden")
	view.toggle_overlay("rooms");view.toggle_overlay("miasma")
	check(view.overlay_sheets.get_child_count() == 4, "toggled overlays draw one sheet per colour")
	view.toggle_overlay("rooms");view.toggle_overlay("miasma")
	view.snapshot = layer
	# A level sent ahead for the same request is kept, never drawn early.
	var ahead := layer.duplicate(true)
	ahead.y = 1
	ahead.rev = 3
	ahead.states = [2, 2, 0]
	ahead.below = [{"cells": [2, 0, 0], "states": [2, 0, 4]}]
	view._receive(ahead)
	check(view.level == 0 and view.snapshot.y == 0 and view.layer_cache.has(1), "neighbouring level is kept without being drawn")
	var stale := ahead.duplicate(true)
	stale.seq = view.sequence - 1
	stale.y = 2
	view._receive(stale)
	check(not view.layer_cache.has(2), "a level sent for an earlier request is not kept")
	view.change_level(1)
	check(view.level == 1 and not view.snapshot.is_empty() and view.snapshot.y == 1, "stepping to a kept level draws it at once")
	check(view.snapshot.states == [1, 1, 0] and view.snapshot.below[0].states == [1, 0, 4]
		and view.status.text.contains("Remembered"), "a kept level is shown as memory until confirmed")
	check(client.entity_layer.states == [1, 1, 0], "a kept level shows no live entities")
	var fresh := ahead.duplicate(true)
	fresh.seq = view.sequence
	fresh.rev = 4
	view._receive(fresh)
	check(view.snapshot.states == [2, 2, 0] and view.revision == 4, "the fresh observation replaces the kept level")
	view.change_level(-1)
	check(view.level == 0 and not view.snapshot.is_empty() and view.snapshot.y == 0, "returning to the previous level draws it from the cache")
	var moved := view.requested.duplicate()
	view.centre.x += 40.0
	view._request_view()
	check(view.requested != moved and view.snapshot.is_empty() and view.layer_cache.is_empty(), "a new rectangle drops every kept level")
	view.change_level(-1)
	check(view.level == -1 and view.snapshot.is_empty() and view.visible_meshes() == 0, "level change clears geometry before request")
	view._receive(layer)
	check(view.snapshot.is_empty(), "delayed previous level cannot reappear")
	var empty := {"v": 1, "t": "layer", "seq": view.sequence, "rev": 5, "y": -1, "empty": true}
	view._receive(empty)
	check(view.visible_meshes() == 0, "empty or unserved layer clears geometry")
	view._close()
	check(main.cam.cull_mask == 1048575 and main.captured, "leaving restores ordinary view and pointer")
	view._open()
	view.free()
	check(main.cam.cull_mask == 1048575 and main.captured, "destroying an active viewport restores the camera")
	check(client.entity_parent == null, "destroying an active viewport returns live entity ownership")
	main.queue_free()
	print("Overseer: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
