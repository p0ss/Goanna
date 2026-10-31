# SPDX-License-Identifier: LGPL-2.1-or-later
## Renders the overseer's house fills and access marks from a synthetic
## layer, with no server: one housed room per field pattern in DorfCraft's
## list (and one with an id this client does not know), order outlines over
## a fill, shared and locked marks, then the Houses ownership field with
## the owner's hall. Frames go to $GOANNA_OUT (default /tmp/overseer-houses/).
## It renders, so run it through the launcher, software preferred:
## tools/goanna-headless fixture res://tests/overseer_houses_render.tscn --software
extends Node
const Unit := preload("res://tests/overseer.gd")
const Overseer := preload("res://game/overseer.gd")
const COLOURS := ["#c03020", "#2060c0", "#30a050", "#d0a020", "#8040b0",
	"#c06090", "#20a0a0", "#a06030", "#e07020", "#e0e0f0", "#4080e0"]
var out := "/tmp/overseer-houses/"
var view: CanvasLayer

func shot(name: String) -> void:
	for i in 4: await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out + name + ".png")

func _ready() -> void:
	if OS.has_environment("GOANNA_OUT"): out = OS.get_environment("GOANNA_OUT").trim_suffix("/") + "/"
	DirAccess.make_dir_recursive_absolute(out)
	var main := Unit.TestMain.new(); add_child(main)
	var client := Unit.TestClient.new(); main.add_child(client)
	view = Overseer.new(); view.main = main; view.client = client; main.add_child(view)
	view._open()
	var bounds := {"min": {"x": -32, "y": -8, "z": -32}, "max": {"x": 32, "y": 8, "z": 32}}
	view._receive({"v": 1, "t": "hello", "claim": bounds, "y": 0,
		"body": {"x": 0, "y": 0, "z": 0}, "tools": [{"id": "inspect", "title": "Inspect"}]})
	var rect := {"x0": -18, "x1": 18, "z0": -7, "z1": 7}
	var count := 37 * 15
	var cells: Array = []; var floors: Array = []; var dates: Array = []
	for i in count:
		cells.append(2); floors.append(0); dates.append(1)
	var patterns: Array = Overseer.HOUSE_PATTERNS.slice(1) + ["plaid"]
	var houses := {}
	var rooms: Array = []
	var access: Array = []
	for i in patterns.size():
		var id := str(i + 2)
		houses[id] = {"surname": "House%d" % i, "head": "p%d" % i, "colour": COLOURS[i], "pattern": patterns[i]}
		var x0 := -17 + (i % 6) * 6
		var z0 := 1 if i < 6 else -5
		rooms.append({"rect": {"x0": x0, "x1": x0 + 4, "z0": z0, "z1": z0 + 3}, "title": "Room", "name": patterns[i], "house": id})
		access.append({"pos": {"x": x0, "y": 0, "z": z0}, "state": "shared", "house": id})
		access.append({"pos": {"x": x0 + 4, "y": 0, "z": z0}, "state": "locked", "house": id})
	houses["1"] = {"surname": "Owner", "head": "owner", "colour": "#e8d8a0", "pattern": "chequy", "owner": true}
	rooms.append({"rect": {"x0": -18, "x1": 18, "z0": -1, "z1": 0}, "title": "Hall", "name": "Great", "house": "1"})
	var orders: Array = []
	for x in range(-17, -12):
		orders.append({"pos": {"x": x, "y": 0, "z": 4}, "kind": "dig", "state": "accepted", "house": "2"})
		orders.append({"pos": {"x": x, "y": 0, "z": 6}, "kind": "dig", "state": "accepted", "house": "1"})
	var layer := {"v": 1, "t": "layer", "seq": view.sequence, "rev": 1, "y": 0, "rect": rect,
		"cells": cells, "floors": floors, "dates": dates,
		"palette": [{"name": "stone", "texture": "stone.png"}], "orders": orders, "houses": houses,
		"overlays": {"rooms": rooms, "access": access,
			"zones": [{"id": "z", "kind": "forbid", "rect": {"x0": 1, "x1": 5, "z0": 6, "z1": 6}, "house": "4"}],
			"locks": [{"x": 17, "z": 6, "house": "3"}]}}
	view.snapshot = layer
	view._draw_layer()
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new(); plane.size = Vector2(37, 15)
	var stone := StandardMaterial3D.new(); stone.albedo_color = Color(0.36, 0.34, 0.31)
	stone.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	plane.material = stone; ground.mesh = plane
	ground.position = Vector3(0, 29.9, 0)
	view.viewport.add_child(ground)
	view.extent = 18.0; view.centre = Vector2(0, 0); view._move_camera()
	await shot("houses-overview")
	view.toggle_overlay("access")
	await shot("houses-access")
	view.extent = 6.0; view.centre = Vector2(-15, 3); view._move_camera()
	await shot("houses-close")
	view.extent = 60.0; view.centre = Vector2(0, 0); view._move_camera()
	await shot("houses-far")
	view.toggle_overlay("ownership")
	await shot("ownership-far")
	view.extent = 18.0; view._move_camera()
	await shot("ownership-overview")
	view.extent = 6.0; view.centre = Vector2(-15, 0); view._move_camera()
	await shot("ownership-close")
	get_tree().quit()
