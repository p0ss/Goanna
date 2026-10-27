# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## The heat shimmer and mirage over hot ground (shaders/heat_shimmer.gdshader):
## a full screen quad on the camera, shown only while the climate field has
## heat somewhere round the player and the render_fire_shimmer switch is on.
## Made by game/main.gd, which calls update() each frame; reads the field
## through GoannaClient.climate_at. docs/systems/climate.md, "Heat".
#
# The pass reads the screen, and Godot copies the screen for it whenever it
# is drawn, so it is hidden rather than left to discard every pixel: in most
# of the world nothing is hot, and then it costs nothing.
extends RefCounted

# Seconds between looks round for heat.
const LOOK_INTERVAL := 0.5
# Hot enough to show, C: the shader's shimmer starts at 24.
const HOT := 23.0
# Where to look: the eye, and rings round it this far out, nodes.
const RINGS := [24.0, 64.0, 120.0]
const AROUND := 8

var quad: MeshInstance3D
var material: ShaderMaterial
var hot := false
var _since := LOOK_INTERVAL


func _init(cam: Camera3D, client: Node) -> void:
	quad = MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(2, 2)
	quad.mesh = mesh
	material = ShaderMaterial.new()
	material.shader = client.load_view_shader("res://shaders/heat_shimmer.gdshader") \
			if client.has_method("load_view_shader") else load("res://shaders/heat_shimmer.gdshader")
	# Under the light shafts (100), which should not shimmer twice.
	material.render_priority = 99
	quad.material_override = material
	quad.custom_aabb = AABB(Vector3(-5e8, -5e8, -5e8), Vector3(1e9, 1e9, 1e9))
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	quad.layers = 8
	quad.visible = false
	cam.add_child(quad)


# The hottest the field is at the eye and round it, or -INF if none of it
# is known.
static func hottest(client: Node, eye: Vector3) -> float:
	var best := -INF
	var points := [eye]
	for r in RINGS:
		for i in AROUND:
			var a := TAU * float(i) / AROUND
			points.append(eye + Vector3(cos(a) * r, -2.0, sin(a) * r))
	for p in points:
		var c: Dictionary = client.climate_at(p)
		if not c.is_empty() and float(c.get("known", 0.0)) > 0.1:
			best = maxf(best, float(c["temp"]))
	return best


func update(delta: float, client: Node, eye: Vector3, enabled: bool) -> void:
	_since += delta
	if _since >= LOOK_INTERVAL:
		_since = 0.0
		# While the field is being rebuilt nothing is known: keep what was.
		if client != null and client.has_method("climate_at"):
			var t := hottest(client, eye)
			if t > -INF:
				hot = t >= HOT
	quad.visible = enabled and hot
