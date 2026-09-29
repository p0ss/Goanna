# SPDX-License-Identifier: LGPL-2.1-or-later
extends SceneTree

const Layers := preload("res://cloud_layers.gd")
var failures := 0


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)


func _initialize() -> void:
	for style in 3:
		for thickness in [8.0, 16.0, 1000.0]:
			for ground in [-500.0, 0.0, 2500.0, 8000.0]:
				var layers := Layers.build(120.0, thickness, 0.55, 0.0, ground, style)
				check(layers[0].x == 120.0, "Server low cloud altitude survives high terrain")
				check(layers[1].x > ground and layers[2].x > layers[1].x,
						"Upper clouds remain above mountainous terrain")
				for i in 2:
					check(layers[i].x + layers[i].y * 1.75 <
							layers[i + 1].x - layers[i + 1].y * 0.75,
							"Jittered slabs cannot overlap or reverse compositing order")
		var clear := Layers.build(120.0, 16.0, 0.0, 0.8, 0.0, style)
		for deck in clear:
			check(deck.z == 0.0, "Server-hidden clouds suppress all layers even in rain")
		var fair := Layers.build(120.0, 16.0, 0.4, 0.0, 0.0, style)
		var wet := Layers.build(120.0, 16.0, 0.4, 0.8, 0.0, style)
		check(wet[1].z > fair[1].z and wet[2].z < fair[2].z,
				"Rain strengthens middle clouds and reduces high wisps")
	for style in 3:
		for ground in [0.0, 2500.0, 8000.0]:
			var full := Layers.build(120.0, 16.0, 0.55, 0.0, ground, style)
			for count in [-1, 1, 2, 3, 10]:
				var budget := Layers.build(120.0, 16.0, 0.55, 0.0, ground, style, count)
				var active := 0
				var overhead := false
				for i in 3:
					check(budget[i].x == full[i].x and budget[i].y == full[i].y,
							"Changing the budget preserves layer geometry")
					if budget[i].z > 0.0:
						active += 1
						overhead = overhead or budget[i].x > ground
				check(active == clampi(count, 1, 3), "Layer budget is enforced and clamped")
				check(overhead, "Every budget retains clouds above high terrain")
	var game := preload("res://main.gd").new()
	game.cloud_cov = 0.85
	game.atmosphere_quality = 1.0
	for style in 3:
		game.cloud_style = style
		game.cloud_layers = Layers.build(120.0, 16.0, 0.85, 0.8, 2500.0, style)
		for layer in 3:
			var deck: Vector4 = game.cloud_layers[layer]
			var occupied := false
			for x in range(-2048, 2048, 128):
				for z in range(-2048, 2048, 128):
					var scale := Layers.horizontal_scale(layer)
					var point := Vector3(x * scale, deck.x + deck.y * 0.5, z * scale)
					occupied = occupied or game._local_cloud_layer(point, layer) > 0.0
					point.y = deck.x - deck.y
					check(game._local_cloud_layer(point, layer) == 0.0,
							"No local cloud below its jittered slab")
					point.y = deck.x + deck.y * 2.0
					check(game._local_cloud_layer(point, layer) == 0.0,
							"No local cloud above its jittered slab")
			check(occupied, "Each elevated layer can contain local cloud fog")
	game.cloud_layer_count = 1
	game.atmosphere_ground = 2500.0
	game.atmosphere_ground_set = true
	game._update_cloud_layers()
	check(game.cloud_layers[0].z == 0.0 and game.cloud_layers[2].z == 0.0,
			"One-layer mountain budget disables the low and high fields")
	check(game._local_cloud_layer(Vector3(0, 140, 0), 0) == 0.0,
			"Disabled layers cannot create nearby cloud fog")
	game.cloud_cov = 0.0
	check(game._local_cloud_density(Vector3(0, 120, 0)) == 0.0,
			"Hidden clouds do not suppress shafts at the camera")
	game.free()
	print("cloud layers: %d failures" % failures)
	quit(1 if failures else 0)
