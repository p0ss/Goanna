# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## Luanti's cloud deck as geometry, drawn with the shader pack's
## gbuffers_clouds program (or Iris's fallbacks for it) while a pack owns
## the sky. Goanna's own clouds are marched in the sky shader, where no pack
## program can run; a pack expects the client's cloud boxes instead, as
## Minecraft hands its clouds to the pack under Iris.
##
## The deck is what a vanilla Luanti client draws from the server's cloud
## parameters: a square grid of 64 node cells, filled where a fractal noise
## falls under the density, each a box `thickness` nodes tall with its base
## at `height`, scrolled by `speed` nodes a second. Faces are shaded as
## Luanti shades them (top 1, sides along z and x and the bottom darkened by
## color_shadow), and the material colour is Luanti's: color_bright times
## the daylight, no darker than color_ambient, at color_bright's opacity.
## The noise is Goanna's own, seeded once; a vanilla client picks a random
## seed per run, so the cell pattern is not the server's to set.
##
## The pack's `clouds=fast` gives a flat deck at the base height; `off`
## leaves this node unmade (GoannaIrisGbuffers translates no program then).
extends Node3D

const NODE_LAYER := 1 << 14
# Luanti's cloud cell and its default cloud_radius, in cells.
const CELL := 64.0
const RADIUS := 12
const SEED := 1873
# GoannaIrisGbuffers::SURFACE_CLOUDS
const SURFACE_CLOUDS := 7

var surface: MeshInstance3D
var material: ShaderMaterial
var flat := false
# The noise origin in Luanti's x and z, moved by the cloud speed.
var origin := Vector2.ZERO
var built_centre := Vector2i(1 << 30, 0)
var built_key := []


func initialise(pack: GoannaIrisGbuffers) -> void:
	flat = pack.clouds_mode() == "fast"
	material = ShaderMaterial.new()
	material.shader = pack.shader(SURFACE_CLOUDS)
	material.set_shader_parameter("iris_alphaTestRef",
			pack.alpha_test_ref(SURFACE_CLOUDS, 0.1))
	# The clouds are untextured; a pack's texture lookup reads white.
	var white := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	white.fill(Color.WHITE)
	material.set_shader_parameter("albedo_tex", ImageTexture.create_from_image(white))
	material.set_shader_parameter("goanna_iris_entity_override", -1)
	surface = MeshInstance3D.new()
	# The second output cameras see NODE_LAYER, as they see the sky.
	surface.layers = 1 | NODE_LAYER
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	surface.material_override = material
	surface.extra_cull_margin = CELL * RADIUS
	add_child(surface)
	visible = false


# Every frame. `clouds` is the session's cloud parameters (density,
# height, thickness, speed, color_bright, color_ambient, color_shadow),
# `shown` whether the server's sky and the player's setting want clouds at
# all, and `daylight` the dimming Goanna gives its own deck at night.
func update(camera: Camera3D, clouds: Dictionary, shown: bool, daylight: float, delta: float) -> void:
	var density := float(clouds.get("density", 0.0))
	visible = shown and density > 0.0
	var speed: Vector2 = clouds.get("speed", Vector2.ZERO)
	origin += speed * delta
	if not visible:
		return
	var thickness := 0.0 if flat else maxf(float(clouds.get("thickness", 16.0)), 0.0)
	var shadow: Color = clouds.get("color_shadow", Color(0.8, 0.8, 0.8))
	# Godot mirrors Luanti's z.
	var eye := Vector2(camera.global_position.x, -camera.global_position.z)
	var centre := Vector2i(floori((eye.x - origin.x) / CELL), floori((eye.y - origin.y) / CELL))
	var key := [snappedf(density, 0.01), thickness, shadow]
	if centre != built_centre or key != built_key:
		built_centre = centre
		built_key = key
		surface.mesh = _build(centre, density, thickness, shadow)
	var base := origin + Vector2(centre) * CELL
	global_position = Vector3(base.x, float(clouds.get("height", 120.0)), -base.y)
	var bright: Color = clouds.get("color_bright", Color.WHITE)
	var ambient: Color = clouds.get("color_ambient", Color.BLACK)
	var colour := Color(clampf(bright.r * daylight, ambient.r, 1.0),
			clampf(bright.g * daylight, ambient.g, 1.0),
			clampf(bright.b * daylight, ambient.b, 1.0), bright.a)
	material.set_shader_parameter("goanna_cloud_colour", colour)


static func _hash(x: int, y: int) -> float:
	# Each product stays inside 63 bits, so nothing relies on overflow.
	var n := (x * 374761393 + y * 668265263 + SEED * 1442695041) & 0xffffffff
	n = ((n ^ (n >> 13)) * 1274126177) & 0xffffffff
	n ^= n >> 16
	return float(n) / 2147483648.0 - 1.0


static func _value_noise(p: Vector2) -> float:
	var i := Vector2i(floori(p.x), floori(p.y))
	var f := p - Vector2(i)
	f = f * f * (Vector2(3.0, 3.0) - 2.0 * f)
	var a := lerpf(_hash(i.x, i.y), _hash(i.x + 1, i.y), f.x)
	var b := lerpf(_hash(i.x, i.y + 1), _hash(i.x + 1, i.y + 1), f.x)
	return lerpf(a, b, f.y)


# Whether a cell is cloud: three octaves at Luanti's scale (a cell is 0.32
# of the noise's unit), normalised to 0..1 and compared with the density.
static func filled(cell: Vector2i, density: float) -> bool:
	var p := Vector2(cell) * (CELL / 200.0)
	var noise := 0.0
	var amplitude := 1.0
	for _octave in 3:
		noise += _value_noise(p) * amplitude
		p *= 2.0
		amplitude *= 0.5
	return noise / 1.75 * 0.5 + 0.5 < density


func _build(centre: Vector2i, density: float, thickness: float, shadow: Color) -> ArrayMesh:
	var side_z := Color(shadow.r * 0.25 + 0.75, shadow.g * 0.25 + 0.75, shadow.b * 0.25 + 0.75)
	var side_x := Color(shadow.r * 0.5 + 0.5, shadow.g * 0.5 + 0.5, shadow.b * 0.5 + 0.5)
	var bottom := Color(shadow.r, shadow.g, shadow.b)
	var grid := PackedByteArray()
	grid.resize(4 * RADIUS * RADIUS)
	for zi in range(-RADIUS, RADIUS):
		for xi in range(-RADIUS, RADIUS):
			grid[(zi + RADIUS) * 2 * RADIUS + xi + RADIUS] = \
					1 if filled(Vector2i(xi + centre.x, zi + centre.y), density) else 0
	var cell_at := func(xi: int, zi: int) -> bool:
		if xi < -RADIUS or xi >= RADIUS or zi < -RADIUS or zi >= RADIUS:
			return false
		return grid[(zi + RADIUS) * 2 * RADIUS + xi + RADIUS] != 0
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()
	var quad := func(corners: Array, normal: Vector3, colour: Color) -> void:
		var start := vertices.size()
		for c in corners:
			vertices.append(c)
			normals.append(normal)
			colours.append(colour)
		# Godot's front faces wind clockwise seen from outside.
		var a: Vector3 = corners[0]
		var b: Vector3 = corners[1]
		var c2: Vector3 = corners[2]
		if (b - a).cross(c2 - a).dot(normal) > 0.0:
			indices.append_array(PackedInt32Array([start, start + 2, start + 1, start, start + 3, start + 2]))
		else:
			indices.append_array(PackedInt32Array([start, start + 1, start + 2, start, start + 2, start + 3]))
	var h := CELL * 0.5
	var t := thickness
	# Back to front from the outside in, as Luanti orders them, so blended
	# faces of far cells go down before near ones.
	for zi0 in range(-RADIUS, RADIUS):
		for xi0 in range(-RADIUS, RADIUS):
			var zi := RADIUS - zi0 - 1 if zi0 >= 0 else zi0
			var xi := RADIUS - xi0 - 1 if xi0 >= 0 else xi0
			if not cell_at.call(xi, zi):
				continue
			# Godot space: Luanti x, and z negated.
			var x := xi * CELL
			var z := -zi * CELL
			quad.call([Vector3(x - h, t, z - h), Vector3(x + h, t, z - h),
					Vector3(x + h, t, z + h), Vector3(x - h, t, z + h)], Vector3.UP, Color.WHITE)
			if flat:
				# Luanti draws its flat deck unculled; seen from below it is
				# the same face.
				quad.call([Vector3(x - h, t, z - h), Vector3(x + h, t, z - h),
						Vector3(x + h, t, z + h), Vector3(x - h, t, z + h)], Vector3.DOWN, Color.WHITE)
				continue
			# Luanti's -z side is Godot's +z.
			if not cell_at.call(xi, zi - 1):
				quad.call([Vector3(x - h, 0, z + h), Vector3(x + h, 0, z + h),
						Vector3(x + h, t, z + h), Vector3(x - h, t, z + h)], Vector3.BACK, side_z)
			if not cell_at.call(xi, zi + 1):
				quad.call([Vector3(x - h, 0, z - h), Vector3(x + h, 0, z - h),
						Vector3(x + h, t, z - h), Vector3(x - h, t, z - h)], Vector3.FORWARD, side_z)
			if not cell_at.call(xi + 1, zi):
				quad.call([Vector3(x + h, 0, z - h), Vector3(x + h, 0, z + h),
						Vector3(x + h, t, z + h), Vector3(x + h, t, z - h)], Vector3.RIGHT, side_x)
			if not cell_at.call(xi - 1, zi):
				quad.call([Vector3(x - h, 0, z - h), Vector3(x - h, 0, z + h),
						Vector3(x - h, t, z + h), Vector3(x - h, t, z - h)], Vector3.LEFT, side_x)
			quad.call([Vector3(x - h, 0, z - h), Vector3(x + h, 0, z - h),
					Vector3(x + h, 0, z + h), Vector3(x - h, 0, z + h)], Vector3.DOWN, bottom)
	var mesh := ArrayMesh.new()
	if vertices.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
