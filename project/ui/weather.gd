# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Rain and snow drawn by shader instead of by the server's particle spawners.
# Luanti has no weather in the protocol: a game that rains attaches particle
# spawners to the player, and particles.gd recognises those by texture name.
# With shader weather on, particles.gd hands each such spawner here instead
# of building an emitter for it, and this draws the weather the spawners
# describe: its kind (the texture), how hard (the amount, which Mineclonia
# raises in a thunderstorm) and how fast it falls (the velocity).
#
# Presentation only. The spawners arrive exactly as before, nothing sent to
# the server changes, and the rain cover map is built from map data the
# client already holds. docs/weather.md has the design and what is untested.
extends Node3D

const RainCover := preload("res://ui/rain_cover.gd")
const SHADER := preload("res://shaders/precipitation.gdshader")

# Mineclonia's own rates, as the unit of intensity: two rain spawners of 500
# a second each (900 each in a thunderstorm), and two snow spawners of 100.
# Other games' weather lands wherever its amount puts it, within the clamp.
const RAIN_REFERENCE := 1000.0
const SNOW_REFERENCE := 200.0
const MAX_INTENSITY := 2.0
const LAYER_RADII := [3.0, 6.5, 12.0, 22.0]
const SEGMENTS := 32
# Each layer reaches this far below and above the camera. Deep enough to
# look down a cliff into rain, high enough that a layer's top edge is off
# screen for any ordinary upward glance.
const BELOW := 26.0
const ABOVE := 34.0
# Seconds to ease in and out, so a storm starting or a spawner being
# replaced (Mineclonia swaps them when a storm turns to thunder) never pops.
const EASE_SECONDS := 2.5

var client: Object
var cover: RefCounted
var _spawners := {}          # server id -> {kind, rate, speed}
var _mesh: MeshInstance3D
var _material: ShaderMaterial
var _rain := 0.0
var _snow := 0.0
var _rain_speed := 17.0
var _snow_speed := 2.2
var _wind := Vector2.ZERO


func _ready() -> void:
	cover = RainCover.new(client)
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_mesh = MeshInstance3D.new()
	_mesh.mesh = build_mesh()
	_mesh.material_override = _material
	# Weather casts no shadow and should not feed global illumination; a
	# screen of rain lighting the ground would be a bright sheet round the
	# player.
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# It moves with the camera, so it is always in view; a box that big
	# keeps culling from ever second guessing that.
	_mesh.custom_aabb = AABB(Vector3(-64, -64, -64), Vector3(128, 128, 128))
	_mesh.visible = false
	add_child(_mesh)
	_publish_globals()


func _exit_tree() -> void:
	RenderingServer.global_shader_parameter_set("goanna_rain", 0.0)
	RenderingServer.global_shader_parameter_set("goanna_rain_cover_area", Vector4.ZERO)


# The nested cylinders, one surface, one draw. Vertex colour red carries the
# layer index as a fraction of the last, which the shader rounds back.
static func build_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()
	# Outermost first: blending is back to front within the one draw, and the
	# camera is at the centre, so the index order is the depth order.
	for li in range(LAYER_RADII.size() - 1, -1, -1):
		var r: float = LAYER_RADII[li]
		var tag := Color(float(li) / float(LAYER_RADII.size() - 1), 0.0, 0.0, 1.0)
		var base := verts.size()
		for s in SEGMENTS + 1:
			var a := TAU * float(s) / float(SEGMENTS)
			var x := cos(a) * r
			var z := sin(a) * r
			verts.append(Vector3(x, -BELOW, z))
			verts.append(Vector3(x, ABOVE, z))
			colours.append(tag)
			colours.append(tag)
		for s in SEGMENTS:
			var i := base + s * 2
			indices.append_array([i, i + 1, i + 2, i + 1, i + 3, i + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# The spawner as particles.gd received it. Its texture has already said it is
# weather; this reads which kind, how much and how fast.
func add_spawner(id: int, ev: Dictionary, tex_name: String) -> void:
	_spawners[id] = describe(ev, tex_name)


func remove_spawner(id: int) -> void:
	_spawners.erase(id)


func has_spawner(id: int) -> bool:
	return _spawners.has(id)


func clear() -> void:
	_spawners.clear()


# kind, rate (spawned a second) and fall speed, from a spawner definition.
# Luanti's amount is a rate for an endless spawner and a total over `time`
# for a timed one.
static func describe(ev: Dictionary, tex_name: String) -> Dictionary:
	var amount := float(ev.get("amount", 0))
	var time := float(ev.get("time", 0.0))
	var rate := amount / time if time > 0.0 else amount
	var vmin: Vector3 = ev.get("vel_min", Vector3.ZERO)
	var vmax: Vector3 = ev.get("vel_max", Vector3.ZERO)
	var fall := absf((vmin.y + vmax.y) * 0.5)
	var snow := tex_name.contains("snow")
	return {"kind": "snow" if snow else "rain", "rate": rate,
		"speed": clampf(fall, 0.8, 5.0) if snow else clampf(fall, 6.0, 30.0)}


# Target intensity of each kind, 0 to MAX_INTENSITY, and its speed.
func targets() -> Dictionary:
	var rate := {"rain": 0.0, "snow": 0.0}
	var speed := {"rain": 0.0, "snow": 0.0}
	for s in _spawners.values():
		rate[s["kind"]] += float(s["rate"])
		speed[s["kind"]] += float(s["speed"]) * float(s["rate"])
	var out := {}
	for kind in ["rain", "snow"]:
		var ref := RAIN_REFERENCE if kind == "rain" else SNOW_REFERENCE
		var r: float = rate[kind]
		# A spawner that is running at all is weather worth seeing, however
		# small its amount, so the floor is well above zero.
		out[kind] = clampf(r / ref, 0.3, MAX_INTENSITY) if r > 0.0 else 0.0
		out[kind + "_speed"] = float(speed[kind]) / r if r > 0.0 else 0.0
	return out


func _process(delta: float) -> void:
	var t := targets()
	var k := clampf(delta / EASE_SECONDS, 0.0, 1.0)
	_rain = move_toward(_rain, float(t["rain"]), k * MAX_INTENSITY)
	_snow = move_toward(_snow, float(t["snow"]), k * MAX_INTENSITY)
	if float(t["rain_speed"]) > 0.0:
		_rain_speed = float(t["rain_speed"])
	if float(t["snow_speed"]) > 0.0:
		_snow_speed = float(t["snow_speed"])
	var active := _rain > 0.001 or _snow > 0.001
	_mesh.visible = active
	var m := get_tree().get_first_node_in_group("goanna_main")
	var eye := Vector3.ZERO
	if m != null and m.get("cam") != null:
		eye = (m.cam as Node3D).global_position
	if active:
		_mesh.global_position = eye
		_update_wind(m, delta)
		# The map is needed only while something is falling; in fair
		# weather this whole node costs a dictionary walk a frame.
		if cover.step(eye, delta):
			RenderingServer.global_shader_parameter_set("goanna_rain_cover", cover.texture)
		_material.set_shader_parameter("rain_amount", _rain)
		_material.set_shader_parameter("snow_amount", _snow)
		_material.set_shader_parameter("rain_speed", _rain_speed)
		_material.set_shader_parameter("snow_speed", _snow_speed)
		_material.set_shader_parameter("wind", _wind)
	elif cover.ready:
		cover.clear()
	_publish_globals()


# There is no wind in the protocol either. main.gd drives the grass from the
# cloud drift and the storm (grass_wind, a direction scaled 0.25 to 1); the
# rain leans with the same air. On a main.gd without it, the same rule is
# worked out here from the clouds.
func _update_wind(m: Node, delta: float) -> void:
	var w := Vector2.ZERO
	if m != null:
		var gw = m.get("grass_wind")
		if gw is Vector2:
			w = gw
		elif m.get("cloud_speed") is Vector2:
			var cs: Vector2 = m.cloud_speed
			var storm := float(m.get("storm_cover")) if m.get("storm_cover") != null else 0.0
			var dir := -cs.normalized() if cs.length_squared() > 0.01 else Vector2.RIGHT
			w = dir * clampf(0.25 + cs.length() * 0.05 + storm * 0.65, 0.25, 1.0)
	# Strength 1 is a gale; call it 7 nodes a second, which leans heavy rain
	# about 20 degrees and blows snow well off the vertical.
	_wind = _wind.lerp(w * 7.0, 1.0 - exp(-delta / 2.0))


func _publish_globals() -> void:
	RenderingServer.global_shader_parameter_set("goanna_rain", _rain)
	RenderingServer.global_shader_parameter_set("goanna_rain_cover_area",
			cover.area if cover != null else Vector4.ZERO)
