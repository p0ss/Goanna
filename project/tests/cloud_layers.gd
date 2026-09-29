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
	var game := preload("res://main.gd").new()
	game.cloud_cov = 0.85
	game.atmosphere_quality = 1.0
	for style in 3:
		game.cloud_style = style
		game.cloud_layers = Layers.build(120.0, 16.0, 0.85, 0.8, 2500.0, style)
		for layer in 3:
			var deck: Vector4 = game.cloud_layers[layer]
			var occupied := false
			for x in range(-512, 512, 64):
				for z in range(-512, 512, 64):
					var point := Vector3(x, deck.x + deck.y * 0.5, z)
					occupied = occupied or game._local_cloud_layer(point, layer) > 0.0
					point.y = deck.x - deck.y
					check(game._local_cloud_layer(point, layer) == 0.0,
							"No local cloud below its jittered slab")
					point.y = deck.x + deck.y * 2.0
					check(game._local_cloud_layer(point, layer) == 0.0,
							"No local cloud above its jittered slab")
			check(occupied, "Each elevated layer can contain local cloud fog")
	game.cloud_cov = 0.0
	check(game._local_cloud_density(Vector3(0, 120, 0)) == 0.0,
			"Hidden clouds do not suppress shafts at the camera")
	game.free()
	print("cloud layers: %d failures" % failures)
	quit(1 if failures else 0)
