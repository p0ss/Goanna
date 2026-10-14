# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## Draw the pack's sky programs on a camera-centred dome and celestial
## geometry. The translated vertex stage puts them at the far depth;
## terrain occludes them, and second-output cameras see the same sky.
extends Node3D

const NODE_LAYER := 1 << 14
const RADIUS := 128.0

var dome: MeshInstance3D
var stars: MeshInstance3D
var discs := {}
var star_count := -1
var gbuffers: GoannaIrisGbuffers


static func celestial_state(state: Dictionary, degrees: float) -> Dictionary:
	# Godot mirrors Luanti's Z. Rotate the orbit around its east/west axis,
	# keeping every pack consumer on the same sun and moon path.
	var out := state.duplicate()
	for key in ["sun_direction", "moon_direction"]:
		if state.has(key):
			out[key] = (state[key] as Vector3).rotated(Vector3.RIGHT, deg_to_rad(degrees))
	return out


func make_surface(mesh: Mesh, shader: Shader) -> MeshInstance3D:
	var surface := MeshInstance3D.new()
	surface.mesh = mesh
	surface.layers = 1 | NODE_LAYER
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := ShaderMaterial.new()
	material.shader = shader
	surface.material_override = material
	add_child(surface)
	return surface


func initialise(pack: GoannaIrisGbuffers) -> void:
	gbuffers = pack
	var sphere := SphereMesh.new()
	sphere.radius = RADIUS
	sphere.height = RADIUS * 2.0
	sphere.radial_segments = 32
	sphere.rings = 16
	dome = make_surface(sphere, pack.shader(4))
	stars = make_surface(ArrayMesh.new(), pack.shader(4))
	var shader: Shader = pack.shader(5)
	if shader != null:
		for name in ["sun", "moon"]:
			var quad := QuadMesh.new()
			quad.size = Vector2.ONE
			discs[name] = make_surface(quad, shader)


func update(camera: Camera3D, state: Dictionary, colour: Color, client: GoannaClient) -> void:
	global_position = camera.global_position
	(dome.material_override as ShaderMaterial).set_shader_parameter("goanna_sky_colour", colour)
	var star_state: Dictionary = state.get("stars", {})
	var count := clampi(int(star_state.get("count", 1000)), 0, 6000)
	if count != star_count:
		star_count = count
		stars.mesh = make_stars(count)
	var star_colour: Color = star_state.get("color", Color.WHITE)
	var day := clampf(state["sun_direction"].y * 4.0 + 0.5, 0.0, 1.0)
	star_colour *= float(star_state.get("day_opacity", 0.0)) * day + (1.0 - day)
	stars.visible = bool(star_state.get("visible", true)) and star_colour.r + star_colour.g + star_colour.b > 0.001
	var material := stars.material_override as ShaderMaterial
	material.set_shader_parameter("goanna_render_stage", 6)
	material.set_shader_parameter("goanna_sky_colour", star_colour)
	stars.basis = Basis(Vector3.RIGHT, float(state.get("time_of_day", 0.0)) * TAU)
	for name in discs:
		var disc: MeshInstance3D = discs[name]
		var spec: Dictionary = state[name]
		var texture: Texture2D = client.texture(str(spec.get("texture", "")))
		disc.visible = bool(spec.get("visible", true)) and texture != null
		if not disc.visible:
			continue
		var direction: Vector3 = state[name + "_direction"]
		direction = direction.normalized()
		disc.position = direction * RADIUS * 0.9
		var up := Vector3.UP if absf(direction.y) < 0.99 else Vector3.FORWARD
		disc.basis = Basis.looking_at(-direction, up)
		var size := RADIUS * 2.0 * (0.045 if name == "sun" else 0.028) * float(spec.get("scale", 1.0))
		disc.scale = Vector3(size, size, size)
		material = disc.material_override as ShaderMaterial
		material.set_shader_parameter("albedo_tex", texture)
		material.set_shader_parameter("goanna_render_stage", 4 if name == "sun" else 5)
		material.set_shader_parameter("goanna_sky_colour", Color.WHITE)


func make_stars(count: int) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	var random := RandomNumberGenerator.new()
	random.seed = 1417
	for _i in count:
		var direction := Vector3(random.randf_range(-1.0, 1.0), random.randf_range(-1.0, 1.0), random.randf_range(-1.0, 1.0))
		if direction.length_squared() < 0.01:
			continue
		direction = direction.normalized()
		var up := Vector3.UP if absf(direction.y) < 0.99 else Vector3.FORWARD
		var right := direction.cross(up).normalized() * random.randf_range(0.08, 0.16)
		up = right.cross(direction).normalized() * right.length()
		var centre := direction * RADIUS
		var base := vertices.size()
		vertices.append_array(PackedVector3Array([centre - right - up, centre + right - up,
				centre + right + up, centre - right + up]))
		indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	var mesh := ArrayMesh.new()
	if not vertices.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_INDEX] = indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
