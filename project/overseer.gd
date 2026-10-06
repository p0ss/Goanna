# SPDX-License-Identifier: LGPL-2.1-or-later
# A server-authorised cutaway in an isolated World3D. The ordinary terrain,
# far field, particles, entities and lighting cannot enter this world.
extends CanvasLayer

const UNAVAILABLE := Color(0.12, 0.13, 0.14)
# Caps pass through the world's exposure and colour grade. Use a lighter
# material so unavailable cells remain distinct from unexplored black.
const UNAVAILABLE_MATERIAL := Color(0.42, 0.44, 0.46)
var memory_material: ShaderMaterial
var depth_material: StandardMaterial3D

var main: Node
var client: Node
var active := false
var channel := ""
var ignored_channel := ""
var session_ready := false
var claim: Dictionary = {}
var level := 0
var centre := Vector2.ZERO
var extent := 24.0
var sequence := 0
var revision := -1
var requested: Dictionary = {}
var snapshot: Dictionary = {}
var tools: Array = []
var tool := "inspect"
var first_corner: Variant = null
var last_corner: Variant = null
var pending: Dictionary = {}
var cursor: Dictionary = {}
var ui: RefCounted
var plans_poll := 0.0
var touch_start := Vector2.ZERO
var touch_dragged := false
var touch_active := false
var touch_index := -1
var saved_pad_enabled := false
var saved_pad_input := false
var pad: Node
var request_id := 0
var parts: Dictionary = {}
var last_receive := 0.0
var layer_received := 0.0
var last_ping := 0.0
var last_request := 0.0
var hud_poll := 0.0
var need_view := false
var dragging := false
var body := Vector3.ZERO
var saved_capture := false
var saved_mask := 0
var saved_ui := true
var root_control: Control
var viewport: SubViewport
var camera: Camera3D
var geometry: Node3D
var overlay: Node3D
var preview: Node3D
var status: Label
var inspector: Label
var palette: OptionButton
var room_name: LineEdit
var actors: Node3D
var concealment: Node3D
var slice_environment: Environment
var slice_sun: DirectionalLight3D
var slice_moon: DirectionalLight3D
var build_material: OptionButton
var build_materials: Array = []
var material_catalog: Array = []
var facing_picker: OptionButton
var mesh_queue: Array[Vector3i] = []
var mesh_nodes: Dictionary = {}
var mesh_stamps: Dictionary = {}
var wanted_stamps: Dictionary = {}

func _ready() -> void:
	layer = 150
	set_process_input(true)

func _exit_tree() -> void:
	# Entity roots normally belong to the client. Return them before this
	# viewport is destroyed, including disconnects and scene replacement.
	if active and is_instance_valid(client):
		_close()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _send(message: Dictionary) -> void:
	message.v = 1
	client.overseer_send(JSON.stringify(message))

func tick(delta: float) -> void:
	hud_poll -= delta
	if hud_poll <= 0.0:
		hud_poll = 0.2
		var granted := ""
		for h in client.hud_state().get("elements", []):
			if h.get("name", "") == "dorfcraft:overseer":
				granted = str(h.get("text", ""))
		if granted.is_empty():
			ignored_channel = ""
			if active:
				_close()
		elif granted != channel and granted != ignored_channel:
			if active:
				_close()
			if client.overseer_channel(granted):
				channel = granted
				_open()
	if not active:
		return
	for raw in client.overseer_take():
		if str(raw).length() <= 60000:
			var message: Variant = JSON.parse_string(raw)
			if message is Dictionary:
				_receive(message)
	if not active:
		return
	_build_next_mesh()
	_sync_lighting()
	var now := _now()
	if now - last_ping > (3.0 if session_ready else 0.5):
		last_ping = now
		_send({"t": "ping" if session_ready else "ready"})
	if now - last_receive > 12.0:
		leave()
		return
	if not snapshot.is_empty() and now - layer_received > 6.0:
		_clear_layer()
		status.text = "Waiting for a fresh server observation"
	if session_ready:
		var movement := Vector2.ZERO
		if get_viewport().gui_get_focus_owner() == null or ui.map_focused():
			movement.x = float(main._key_pressed(KEY_D)) - float(main._key_pressed(KEY_A))
			movement.y = float(main._key_pressed(KEY_W)) - float(main._key_pressed(KEY_S))
		if ui.map_focused():
			for device in Input.get_connected_joypads():
				var stick := Vector2(Input.get_joy_axis(device, JOY_AXIS_LEFT_X), -Input.get_joy_axis(device, JOY_AXIS_LEFT_Y))
				if stick.length() > 0.25: movement += stick
		if movement != Vector2.ZERO:
			centre += movement * extent * delta * 0.6
			_move_camera()
			need_view = true
			if ui.map_focused():
				cursor = {"x": roundi(centre.x), "y": level, "z": roundi(centre.y)}
				show_cursor()
		plans_poll -= delta
		if ui.family == "Plans" and plans_poll <= 0.0:
			plans_poll = 2.0
			_send({"t": "plans"})
		if need_view and now - last_request > 0.2:
			_request_view()

func _open() -> void:
	active = true
	session_ready = false
	last_receive = _now()
	last_ping = 0.0
	saved_capture = main.pointer_captured()
	saved_mask = main.cam.cull_mask
	main.cam.cull_mask = 0
	main.set_pointer_captured(false)
	main.dig_down = false
	main.place_down = false
	main.place_pressed = false
	pad = main.get("gamepad")
	if is_instance_valid(pad):
		saved_pad_enabled = pad.enabled
		saved_pad_input = pad.is_processing_input()
		pad.set_enabled(false)
		pad.set_process_input(false)
	if main.ui != null:
		saved_ui = main.ui.visible
		main.ui.visible = false
	root_control = Control.new()
	root_control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root_control)
	var black := ColorRect.new()
	black.color = UNAVAILABLE
	black.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_control.add_child(black)
	var container := SubViewportContainer.new()
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.stretch = true
	memory_material = ShaderMaterial.new()
	memory_material.shader = load("res://shaders/overseer_memory.gdshader")
	container.material = memory_material
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_control.add_child(container)
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	container.add_child(viewport)
	var environment := WorldEnvironment.new()
	var ordinary_environment: WorldEnvironment = main.get("env")
	slice_environment = ordinary_environment.environment.duplicate() if ordinary_environment != null else Environment.new()
	slice_environment.background_mode = Environment.BG_COLOR
	slice_environment.background_color = UNAVAILABLE_MATERIAL
	slice_environment.fog_enabled = false
	slice_environment.volumetric_fog_enabled = false
	slice_environment.glow_enabled = false
	slice_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	slice_environment.ambient_light_color = Color(0.65, 0.7, 0.8)
	slice_environment.ambient_light_energy = 0.2
	depth_material = _colour(Color(0.5, 0.6, 0.7, 0.045))
	environment.environment = slice_environment
	viewport.add_child(environment)
	slice_sun = DirectionalLight3D.new()
	slice_moon = DirectionalLight3D.new()
	viewport.add_child(slice_sun)
	viewport.add_child(slice_moon)
	slice_sun.rotation_degrees = Vector3(-65, -25, 0)
	slice_sun.light_energy = 1.0
	slice_moon.light_energy = 0.0
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.rotation_degrees = Vector3(-90, 0, 0)
	camera.near = 0.1
	camera.far = 80.0
	viewport.add_child(camera)
	camera.make_current()
	geometry = Node3D.new()
	overlay = Node3D.new()
	viewport.add_child(geometry)
	viewport.add_child(overlay)
	actors = Node3D.new()
	viewport.add_child(actors)
	concealment = Node3D.new()
	viewport.add_child(concealment)
	client.overseer_entities(actors, {})
	preview = Node3D.new()
	viewport.add_child(preview)
	tool = "inspect"
	first_corner = null
	last_corner = null
	pending = {}
	cursor = {}
	ui = preload("res://overseer_ui.gd").new()
	ui.build(self)

func _clear_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()

func _clear_layer() -> void:
	if memory_material != null:
		memory_material.set_shader_parameter("has_memory", false)
	snapshot = {}
	mesh_queue.clear()
	mesh_nodes.clear()
	mesh_stamps.clear()
	wanted_stamps.clear()
	if active and is_instance_valid(actors):
		client.overseer_entities(actors, {})
	if is_instance_valid(concealment):
		_clear_children(concealment)
	if is_instance_valid(geometry):
		_clear_children(geometry)
	if is_instance_valid(overlay):
		_clear_children(overlay)
	if is_instance_valid(preview):
		_clear_children(preview)

func _close() -> void:
	client.overseer_entities(null, {})
	active = false
	session_ready = false
	channel = ""
	client.overseer_channel("")
	parts.clear()
	_clear_layer()
	build_materials.clear()
	first_corner = null
	dragging = false
	main.cam.cull_mask = saved_mask
	if is_instance_valid(pad):
		pad.set_enabled(saved_pad_enabled)
		pad.set_process_input(saved_pad_input)
	main.set_pointer_captured(saved_capture)
	if main.ui != null:
		main.ui.visible = saved_ui
	if is_instance_valid(root_control):
		remove_child(root_control)
		root_control.queue_free()

func leave() -> void:
	if not active:
		return
	_send({"t": "leave"})
	ignored_channel = channel
	_close()

func _receive(msg: Dictionary) -> void:
	if int(msg.get("v", 0)) != 1:
		return
	var type := str(msg.get("t", ""))
	if type == "part":
		_receive_part(msg)
		return
	last_receive = _now()
	if type == "bye":
		ignored_channel = channel
		_close()
	elif type == "hello" and not session_ready:
		if not msg.get("claim") is Dictionary or not msg.get("tools") is Array:
			return
		claim = msg.claim
		if not _pos(claim.get("min")) or not _pos(claim.get("max")) or not _pos(msg.get("body"), false):
			return
		level = int(msg.y)
		body = Vector3(float(msg.body.x), float(msg.body.y), -float(msg.body.z))
		centre = Vector2(body.x, -body.z)
		tools = msg.tools
		ui.update_capabilities(msg.get("capabilities", {"tools": tools}))
		_update_materials(msg.get("materials", []))
		session_ready = true
		_move_camera()
		_request_view()
	elif type == "layer" and session_ready:
		if msg.get("palette") == null: msg.palette = []
		if msg.get("orders") == null: msg.orders = []
		if not valid_layer(msg, sequence, level, requested, claim) or int(msg.get("rev", -1)) <= revision:
			return
		_update_materials(msg.get("materials", []))
		revision = int(msg.rev)
		layer_received = _now()
		snapshot = msg
		_draw_layer()
		status.text = "Level %d | %s | Live" % [level, str(tool_definition().get("title", tool))]
		refresh_draft()
	elif type == "pong" and msg.get("capabilities") is Dictionary:
		ui.update_capabilities(msg.capabilities)
	elif type == "plans" and msg.get("plans") is Array:
		ui.update_plans(msg.plans)
	elif type == "reply":
		if str(msg.get("req", "")) != str(pending.get("req", "")) or pending.is_empty():
			return
		inspector.text = str(msg.get("reason", "Request answered"))
		var was_order: bool = pending.get("t") == "order"
		pending = {}
		if msg.get("ok", false) and was_order:
			discard_draft()
		ui.refresh()
		_send({"t": "plans"})

func _update_materials(value: Variant) -> void:
	material_catalog = value if value is Array else []
	if not pending.is_empty(): return
	var wanted: String = {"wall": "block", "floor": "block", "stairs": "stairs", "door": "door", "furniture": "furniture"}.get(tool, "")
	var available: Array = []
	for entry in material_catalog:
		if str(entry.get("kind", "block")) == wanted:
			available.append(entry)
	facing_picker.visible = tool in ["stairs", "door", "furniture"]
	build_material.visible = not wanted.is_empty()
	if available == build_materials and (wanted.is_empty() or build_material.item_count > 0):
		return
	var selected_name := ""
	if build_material.selected >= 0 and build_material.selected < build_materials.size():
		selected_name = str(build_materials[build_material.selected].name)
	if first_corner != null and not selected_name.is_empty():
		var found := false
		for entry in available:
			if str(entry.name) == selected_name: found = true
		if not found:
			available.append({"name": selected_name, "title": "Unavailable: " + selected_name, "kind": wanted, "missing": true})
	build_materials = available
	build_material.clear()
	for entry in build_materials:
		build_material.add_item(str(entry.title).split("\n")[0])
		build_material.set_item_tooltip(build_material.item_count - 1, str(entry.title))
		if str(entry.name) == selected_name:
			build_material.select(build_material.item_count - 1)
	if build_materials.is_empty() and not wanted.is_empty():
		build_material.add_item("No suitable item in stock")
		build_material.set_item_disabled(0, true)

func _receive_part(msg: Dictionary) -> void:
	var now := _now()
	for old in parts.keys():
		if now - float(parts[old].time) > 12.0:
			parts.erase(old)
	var id := int(msg.get("id", -1))
	var count := int(msg.get("n", 0))
	var index := int(msg.get("i", 0))
	var data := str(msg.get("data", ""))
	if count < 1 or count > 35 or index < 1 or index > count or data.length() > 40000:
		return
	if not parts.has(id):
		if parts.size() >= 2:
			return
		parts[id] = {"time": now, "count": count, "chunks": {}, "bytes": 0}
	var p: Dictionary = parts[id]
	if p.count != count or p.chunks.has(index):
		return
	# Luanti deliberately omits base64 padding; Godot requires it.
	if data.is_empty() or data.length() % 4 == 1:
		return
	data += "=".repeat(posmod(-data.length(), 4))
	var decoded := Marshalls.base64_to_raw(data)
	if decoded.is_empty():
		return
	p.bytes += decoded.size()
	if p.bytes > 1048576:
		parts.erase(id)
		return
	p.chunks[index] = decoded
	if p.chunks.size() == count:
		var raw := PackedByteArray()
		for i in range(1, count + 1):
			raw.append_array(p.chunks[i])
		parts.erase(id)
		var inner: Variant = JSON.parse_string(raw.get_string_from_utf8())
		if inner is Dictionary and inner.get("t", "") == "layer":
			_receive(inner)

static func _number(v: Variant, whole := true) -> bool:
	return (v is int or v is float) and is_finite(float(v)) and absf(float(v)) <= 31000.0 and (not whole or float(v) == floorf(float(v)))

static func _pos(v: Variant, whole := true) -> bool:
	return v is Dictionary and _number(v.get("x"), whole) and _number(v.get("y"), whole) and _number(v.get("z"), whole)

static func valid_layer(msg: Dictionary, seq: int, y: int, rect: Dictionary, bounds: Dictionary) -> bool:
	if int(msg.get("seq", -1)) != seq or int(msg.get("y", -32000)) != y:
		return false
	if msg.get("empty", false):
		return true
	var r: Variant = msg.get("rect")
	if not r is Dictionary or not bounds.get("min") is Dictionary or not bounds.get("max") is Dictionary:
		return false
	for key in ["x0", "x1", "z0", "z1"]:
		if not _number(r.get(key)):
			return false
	if r.x0 < rect.x0 or r.x1 > rect.x1 or r.z0 < rect.z0 or r.z1 > rect.z1:
		return false
	if r.x0 < bounds.min.x or r.x1 > bounds.max.x or r.z0 < bounds.min.z or r.z1 > bounds.max.z or y < bounds.min.y or y > bounds.max.y:
		return false
	var count := int(r.x1 - r.x0 + 1) * int(r.z1 - r.z0 + 1)
	if r.x1 < r.x0 or r.z1 < r.z0 or count > 4096:
		return false
	var entries: Variant = msg.get("palette", [])
	if not entries is Array or entries.size() > 8192:
		return false
	for field in ["cells", "floors", "dates"]:
		if not msg.get(field) is Array or msg[field].size() != count:
			return false
	for i in count:
		var c: Variant = msg.cells[i]
		var f: Variant = msg.floors[i]
		if not _number(c) or not _number(f) or c < 0 or f < 0 or c > entries.size() + 1 or f > entries.size() + 1:
			return false
		if c == 0 and f != 0:
			return false
	for entry in entries:
		if not entry is Dictionary or not entry.get("name") is String or not entry.get("texture") is String or entry.texture.length() > 4096:
			return false
	if msg.has("states") or msg.has("below"):
		if not msg.get("below") is Array or msg.below.size() < 1 or msg.below.size() > 8:
			return false
		var slices: Array = [msg] + msg.below
		for d in slices.size():
			var slice: Variant = slices[d]
			if not slice is Dictionary or not slice.get("cells") is Array or not slice.get("states") is Array:
				return false
			if slice.cells.size() != count or slice.states.size() != count:
				return false
			if slice.has("walls") and (not slice.walls is Array or slice.walls.size() != count):
				return false
			for i in count:
				if slice.has("walls"):
					var wall: Variant = slice.walls[i]
					if not _number(wall) or wall < 0 or wall == 1 or wall > entries.size() + 1:
						return false
					if wall > 0 and (d == 0 or slice.states[i] != 4 or slice.cells[i] != 0):
						return false
				var c: Variant = slice.cells[i]
				var state: Variant = slice.states[i]
				if not _number(c) or c < 0 or c > entries.size() + 1 or not _number(state) or state < 0 or state > 4:
					return false
				if (c > 0) != (state == 1 or state == 2) or (d == 0 and state == 4):
					return false
				if d > 0 and slices[d - 1].cells[i] == 0 and (c != 0 or state != 4):
					return false
		if msg.floors != msg.below[0].cells:
			return false
	return true

func _move_camera() -> void:
	centre.x = clampf(centre.x, -30960.0, 30960.0)
	centre.y = clampf(centre.y, -30960.0, 30960.0)
	camera.position = Vector3(centre.x, level + 32.0, -centre.y)
	camera.size = extent
	if memory_material != null:
		var size := get_viewport().get_visible_rect().size
		memory_material.set_shader_parameter("view_centre", centre)
		memory_material.set_shader_parameter("view_span", Vector2(extent * size.x / maxf(size.y, 1.0), extent))

func _request_view() -> void:
	sequence += 1
	revision = -1
	last_request = _now()
	need_view = false
	var size := get_viewport().get_visible_rect().size
	var half_x := mini(31, int(ceil(extent * size.x / maxf(1.0, size.y) * 0.5)) + 1)
	var half_z := mini(31, int(ceil(extent * 0.5)) + 1)
	requested = {"x0": int(floor(centre.x)) - half_x, "x1": int(floor(centre.x)) + half_x,
		"z0": int(floor(centre.y)) - half_z, "z1": int(floor(centre.y)) + half_z}
	# Clear before asking. No previous level or rectangle survives a request.
	_clear_layer()
	parts.clear()
	_send({"t": "view", "seq": sequence, "y": level, "rect": requested})
	status.text = "Level %d | Waiting for server" % level

func change_level(step: int) -> void:
	if not session_ready:
		return
	level = clampi(level + step, -30999, 30999)
	_move_camera()
	_request_view()
	refresh_draft()

func _planes(parent: Node3D, positions: Array, material: Material, width := 0.98, depth := 0.98) -> void:
	if positions.is_empty():
		return
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(width, depth)
	mesh.material = material
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	multi.instance_count = positions.size()
	for i in positions.size():
		multi.set_instance_transform(i, Transform3D(Basis.IDENTITY, positions[i]))
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multi
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)

func _colour(colour: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = colour
	if colour.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


func _sync_lighting() -> void:
	for pair in [[slice_sun, main.get("sun")], [slice_moon, main.get("moon")]]:
		if pair[1] is DirectionalLight3D:
			pair[0].rotation = pair[1].global_rotation
			pair[0].light_color = pair[1].light_color
			pair[0].light_energy = pair[1].light_energy
			pair[0].shadow_enabled = pair[1].shadow_enabled
			pair[0].directional_shadow_max_distance = camera.far
	var ordinary: WorldEnvironment = main.get("env")
	if ordinary == null or ordinary.environment == null:
		return
	var e := ordinary.environment
	# The slice shares the day's exposure and grade, but no hidden sky,
	# terrain light field or local lights. Keep a small readable night fill.
	for property in ["tonemap_mode", "tonemap_exposure", "tonemap_white",
		"adjustment_enabled", "adjustment_brightness", "adjustment_contrast",
		"adjustment_saturation", "adjustment_color_correction"]:
		slice_environment.set(property, e.get(property))
	var daylight := clampf(slice_sun.light_energy / 1.3, 0.0, 1.0)
	slice_environment.ambient_light_color = Color(0.48, 0.57, 0.72).lerp(Color(0.72, 0.77, 0.83), daylight)
	slice_environment.ambient_light_energy = clampf(e.ambient_light_energy, 0.06, 0.32)
	# Haze represents depth, with brightness following the available light.
	# It retains at least 72% of contrast even at the eight-level limit.
	var tint := Color(0.16, 0.20, 0.28).lerp(Color(0.56, 0.66, 0.78), daylight)
	tint.a = 0.045
	depth_material.albedo_color = tint

func _build_next_mesh() -> void:
	if mesh_queue.is_empty() or snapshot.is_empty():
		return
	var block: Vector3i = mesh_queue.pop_front()
	var mesh: ArrayMesh = client.overseer_mesh(snapshot, block)
	if mesh_nodes.has(block):
		var old: Node3D = mesh_nodes[block]
		geometry.remove_child(old)
		old.queue_free()
		mesh_nodes.erase(block)
	if mesh != null and mesh.get_surface_count() > 0:
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		geometry.add_child(instance)
		mesh_nodes[block] = instance
	mesh_stamps[block] = wanted_stamps.get(block, 0)

func _queue_geometry() -> void:
	var r: Dictionary = snapshot.rect
	var width := int(r.x1 - r.x0 + 1)
	var palette_stamp := hash(snapshot.palette)
	for by in range(int(floor((level - maxi(1, snapshot.get("below", []).size())) / 16.0)), int(floor(level / 16.0)) + 1):
		for bz in range(int(floor(r.z0 / 16.0)), int(floor(r.z1 / 16.0)) + 1):
			for bx in range(int(floor(r.x0 / 16.0)), int(floor(r.x1 / 16.0)) + 1):
				var block := Vector3i(bx, by, bz)
				var values: Array = [palette_stamp, level, r]
				# Neighbours affect connected nodeboxes and face culling.
				for z in range(maxi(r.z0, bz * 16 - 1), mini(r.z1, bz * 16 + 16) + 1):
					for x in range(maxi(r.x0, bx * 16 - 1), mini(r.x1, bx * 16 + 16) + 1):
						var i := (z - int(r.z0)) * width + x - int(r.x0)
						values.append(snapshot.cells[i])
						values.append(snapshot.floors[i])
						for below in snapshot.get("below", []):
							values.append(below.cells[i])
							values.append(below.get("walls", [])[i] if below.has("walls") else 0)
				var stamp := hash(values)
				wanted_stamps[block] = stamp
				if mesh_stamps.get(block, -1) != stamp and not mesh_queue.has(block):
					mesh_queue.append(block)

func _open_code(code: int) -> bool:
	return code == 1 or (code >= 2 and snapshot.palette[code - 2].get("open", false))

func _draw_concealment() -> void:
	_clear_children(concealment)
	var r: Dictionary = snapshot.rect
	var black := _colour(Color.BLACK)
	var grey := _colour(UNAVAILABLE_MATERIAL)
	var hidden: Array = []
	var missing: Array = []
	var haze: Array = []
	var depths: Array[int] = []
	var width := int(r.x1 - r.x0 + 1)
	var height := int(r.z1 - r.z0 + 1)
	var memory := Image.create(width, height, false, Image.FORMAT_R8)
	var slices: Array = [snapshot] + snapshot.get("below", [{"cells": snapshot.floors}])
	for i in snapshot.cells.size():
		var x: int = i % width
		var z: int = i / width
		var remembered := false
		var surface := -1
		for d in slices.size():
			var code := int(slices[d].cells[i])
			var states: Array = slices[d].get("states", [])
			var state := int(states[i]) if not states.is_empty() else (2 if code > 0 else 0)
			if code == 0:
				var caps: Array = missing if state == 3 else hidden
				caps.append(Vector3(r.x0 + x, level + 30.0 if d == 0 else level - d + 0.5, -(r.z0 + z)))
				break
			remembered = remembered or state == 1
			if not _open_code(code):
				surface = d
				# Openings in slabs or stairs must not show an unavailable
				# background where their unobserved support should be black.
				hidden.append(Vector3(r.x0 + x, level - d - 1.5, -(r.z0 + z)))
				break
			if d == slices.size() - 1:
				missing.append(Vector3(r.x0 + x, level - d - 0.5, -(r.z0 + z)))
		# Each intervening open level adds a physical translucent sheet.
		# Unknown bottoms stay black rather than acquiring a false fog floor.
		for d in range(1, surface):
			haze.append(Vector3(r.x0 + x, level - d + 0.499, -(r.z0 + z)))
		depths.append(surface)
		memory.set_pixel(x, z, Color.WHITE if remembered else Color.BLACK)
	_planes(concealment, hidden, black, 1.0, 1.0)
	_planes(concealment, missing, grey, 1.0, 1.0)
	# One instance per height gives transparent sorting a distinct depth.
	for d in range(1, slices.size()):
		var row: Array = []
		for p in haze:
			if is_equal_approx(p.y, level - d + 0.499): row.append(p)
		_planes(concealment, row, depth_material, 1.0, 1.0)
	# A restrained inner edge shadow is a stable depth cue directly overhead.
	# It is drawn only where two supplied surfaces establish a real drop.
	var rim := _colour(Color(0.015, 0.02, 0.03, 0.45))
	var rims: Dictionary = {}
	for i in depths.size():
		if depths[i] < 2: continue
		var x: int = i % width
		var z: int = i / width
		var depth := depths[i]
		if not rims.has(depth): rims[depth] = [[], []]
		var thickness := minf(0.18, 0.07 + depth * 0.015)
		for direction in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var xx: int = x + direction.x
			var zz: int = z + direction.y
			if xx < 0 or xx >= width or zz < 0 or zz >= height: continue
			var neighbour := depths[zz * width + xx]
			if neighbour < 0 or neighbour >= depths[i]: continue
			var p := Vector3(r.x0 + x, level + 0.49, -(r.z0 + z))
			p += Vector3(direction.x, 0, -direction.y) * (0.5 - thickness * 0.5)
			rims[depth][0 if direction.x else 1].append(p)
	for depth in rims:
		var thickness := minf(0.18, 0.07 + int(depth) * 0.015)
		_planes(concealment, rims[depth][0], rim, thickness, 1.0)
		_planes(concealment, rims[depth][1], rim, 1.0, thickness)
	memory_material.set_shader_parameter("memory_mask", ImageTexture.create_from_image(memory))
	memory_material.set_shader_parameter("rect_origin", Vector2(r.x0, r.z0))
	memory_material.set_shader_parameter("rect_size", Vector2(width, height))
	memory_material.set_shader_parameter("has_memory", true)
	# High opaque caps hide actor and nametag overhang outside supplied cells.
	var reach := extent * 4.0 + 128.0
	var left := float(r.x0) - 0.5
	var right := float(r.x1) + 0.5
	var north := -float(r.z1) - 0.5
	var south := -float(r.z0) + 0.5
	_planes(concealment, [Vector3(left - reach * 0.5, level + 30.0, (north + south) * 0.5)], grey, reach, reach * 2.0)
	_planes(concealment, [Vector3(right + reach * 0.5, level + 30.0, (north + south) * 0.5)], grey, reach, reach * 2.0)
	_planes(concealment, [Vector3((left + right) * 0.5, level + 30.0, north - reach * 0.5)], grey, right - left, reach)
	_planes(concealment, [Vector3((left + right) * 0.5, level + 30.0, south + reach * 0.5)], grey, right - left, reach)

func _draw_layer() -> void:
	_clear_children(overlay)
	if snapshot.get("empty", false):
		memory_material.set_shader_parameter("has_memory", false)
		_clear_children(geometry)
		_clear_children(concealment)
		mesh_queue.clear()
		client.overseer_entities(actors, {})
		return
	_queue_geometry()
	_draw_concealment()
	client.overseer_entities(actors, snapshot)
	var rect: Dictionary = snapshot.rect
	var marked: Dictionary = {}
	for order in snapshot.get("orders", []):
		if not order is Dictionary or not _pos(order.get("pos")):
			continue
		var p: Dictionary = order.pos
		if int(p.y) != level or p.x < rect.x0 or p.x > rect.x1 or p.z < rect.z0 or p.z > rect.z1:
			continue
		var state := str(order.get("state", "accepted"))
		if not marked.has(state):
			marked[state] = []
		marked[state].append(Vector3(p.x, level + 30.1, -p.z))
	for state in marked:
		var colour := Color(0.95, 0.7, 0.15)
		if state == "done": colour = Color(0.2, 0.75, 0.4)
		if state == "blocked": colour = Color(0.95, 0.2, 0.15)
		if state == "in_progress": colour = Color(0.2, 0.7, 1.0)
		var horizontal: Array = []
		var vertical: Array = []
		for p in marked[state]:
			horizontal.append(p + Vector3(0, 0, 0.45))
			horizontal.append(p - Vector3(0, 0, 0.45))
			vertical.append(p + Vector3(0.45, 0, 0))
			vertical.append(p - Vector3(0.45, 0, 0))
		_planes(overlay, horizontal, _colour(colour), 0.94, 0.06)
		_planes(overlay, vertical, _colour(colour), 0.06, 0.94)
	if int(floor(body.y + 0.5)) == level:
		_planes(overlay, [Vector3(body.x, level + 30.1, body.z)], _colour(Color(0.5, 0.85, 1.0)), 0.3, 0.3)

func _cell(screen: Vector2) -> Dictionary:
	var origin := camera.project_ray_origin(screen)
	return {"x": int(floor(origin.x + 0.5)), "y": level, "z": int(floor(-origin.z + 0.5))}

func select_cell(pos: Dictionary) -> void:
	if not session_ready or not _pos(pos):
		return
	if not pending.is_empty(): return
	if first_corner != null and int(first_corner.y) != level:
		inspector.text = "Return to the draft level before editing its footprint."
		return
	cursor = pos.duplicate()
	if tool == "inspect":
		inspector.text = "%s: unavailable" % str(pos)
		if snapshot.is_empty() or snapshot.get("empty", false):
			return
		var r: Dictionary = snapshot.rect
		if pos.x < r.x0 or pos.x > r.x1 or pos.z < r.z0 or pos.z > r.z1:
			return
		var i := int(pos.z - r.z0) * int(r.x1 - r.x0 + 1) + int(pos.x - r.x0)
		var c := int(snapshot.cells[i])
		var states: Array = snapshot.get("states", [])
		var state := int(states[i]) if not states.is_empty() else (2 if c > 0 else 0)
		if c == 0:
			inspector.text = "Unavailable" if state == 3 else "Unexplored"
			return
		if c == 1:
			inspector.text = "Observed air, day %s" % str(snapshot.dates[i])
			c = int(snapshot.floors[i])
			if c >= 2:
				inspector.text += "\nFloor: %s, observed day %s" % [snapshot.palette[c - 2].name, str(snapshot.palette[c - 2].get("day", "unknown"))]
		elif c >= 2:
			inspector.text = "%s, observed day %s" % [snapshot.palette[c - 2].name, str(snapshot.dates[i])]
		if state == 1:
			inspector.text += " (remembered)"
		else:
			inspector.text += " (currently visible)"
		if _open_code(int(snapshot.cells[i])):
			var below: Array = snapshot.get("below", [])
			for d in below.size():
				var lower := int(below[d].cells[i])
				if lower == 0: break
				if not _open_code(lower):
					inspector.text += "\nSurface %d level(s) below: %s" % [d + 1, snapshot.palette[lower - 2].name]
					break
		for order_entry in snapshot.get("orders", []):
			if order_entry.get("pos") == pos:
				inspector.text += "\n%s: %s %s" % [order_entry.get("kind", "Order"), order_entry.get("state", ""), order_entry.get("reason", "")]
	elif first_corner == null:
		first_corner = pos.duplicate()
		last_corner = null
		_preview_box(pos)
		inspector.text = "First corner selected. Choose the opposite corner."
		ui.refresh()
	else:
		last_corner = pos.duplicate()
		refresh_draft()
		inspector.text = "Review the footprint, then submit. Workers have not been instructed."

func tool_definition() -> Dictionary:
	for entry in tools:
		if str(entry.id) == tool: return entry
	return {}

func choose_tool(id: String) -> void:
	if not pending.is_empty(): return
	if first_corner != null and id != tool:
		inspector.text = "Submit or discard the current draft before changing tools."
		return
	for entry in tools:
		if str(entry.id) != id: continue
		if entry.get("disabled", false):
			inspector.text = str(entry.get("reason", "This action is unavailable."))
			return
		tool = id
		_update_materials(material_catalog)
		inspector.text = "Select a cell." if id == "inspect" else "Choose two corners. Selecting does not submit work."
		ui.refresh()

func can_submit() -> bool:
	if not pending.is_empty(): return true # An identical, idempotent retry.
	if first_corner == null or last_corner == null or first_corner.y != level: return false
	var definition := tool_definition()
	if definition.is_empty() or definition.get("disabled", false): return false
	if first_corner.y != last_corner.y: return false
	if definition.get("single", false) and first_corner != last_corner: return false
	var count: int = (abs(int(first_corner.x - last_corner.x)) + 1) * (abs(int(first_corner.z - last_corner.z)) + 1)
	if count * int(definition.get("height", 1)) > 512: return false
	if tool in ["wall", "floor", "stairs", "door", "furniture"]:
		if build_materials.is_empty() or build_material.selected < 0: return false
		if build_materials[build_material.selected].get("missing", false): return false
	return true

func draft_summary() -> String:
	if first_corner == null: return ""
	if last_corner == null: return "Draft | First corner: %s\nChoose the opposite corner." % str(first_corner)
	var width: int = abs(int(first_corner.x - last_corner.x)) + 1
	var depth: int = abs(int(first_corner.z - last_corner.z)) + 1
	var y := int(first_corner.y)
	var summary := "Draft | %s\n%d x %d cells | Level %d" % [str(tool_definition().get("title", tool)), width, depth, y]
	if tool == "dig": summary += " and %d\n%d cells including two-high clearance" % [y + 1, width * depth * 2]
	if tool == "floor": summary += "\nReplaces the floor on level %d" % (y - 1)
	if tool == "furniture": summary += "\nBed footprint: two cells along the facing"
	if tool == "door": summary += "\nDoor footprint: two levels"
	if tool_definition().get("single", false) and first_corner != last_corner: summary += "\nChoose the same cell for both corners."
	if y != level: summary += "\nReturn to level %d to edit or submit." % y
	if not pending.is_empty(): summary += "\nSending. Retry is safe; it does not create another order."
	return summary

func refresh_draft() -> void:
	if first_corner != null and int(first_corner.y) == level:
		_preview_box(last_corner if last_corner != null else first_corner)
	else:
		_clear_children(preview)
	if ui != null: ui.refresh()

func submit_draft() -> void:
	if not can_submit(): return
	if pending.is_empty():
		request_id += 1
		var material_name := ""
		if build_material.selected >= 0 and build_material.selected < build_materials.size(): material_name = str(build_materials[build_material.selected].name)
		pending = {"t": "order", "req": "camera:%d" % request_id, "tool": tool,
			"a": first_corner.duplicate(), "b": last_corner.duplicate(), "name": room_name.text,
			"node": material_name, "facing": facing_picker.selected}
	_send(pending.duplicate(true))
	inspector.text = "Waiting for the server to check the plan."
	ui.refresh()

func discard_draft() -> void:
	if not pending.is_empty(): return
	first_corner = null
	last_corner = null
	_clear_children(preview)
	ui.refresh()

func return_to_draft() -> void:
	if first_corner == null: return
	level = int(first_corner.y)
	centre = Vector2(first_corner.x, first_corner.z)
	_move_camera(); _request_view(); refresh_draft()

func recentre() -> void:
	centre = Vector2(body.x, -body.z)
	level = roundi(body.y)
	_move_camera(); _request_view(); refresh_draft()

func zoom(step: int) -> void:
	extent = clampf(extent * (0.85 if step > 0 else 1.0 / 0.85), 8.0, 48.0)
	_move_camera()
	need_view = true

func show_cursor() -> void:
	if cursor.is_empty(): return
	status.text = "Level %d | Cell %d, %d | Enter: select | Tab: controls" % [level, cursor.x, cursor.z]
	if first_corner != null and last_corner == null: _preview_box(cursor)
	else:
		_clear_children(preview)
		_planes(preview, [Vector3(cursor.x, level + 30.15, -cursor.z)], _colour(Color(0.8, 0.9, 1.0, 0.5)), 0.8, 0.8)

func go_back() -> void:
	if not pending.is_empty():
		inspector.text = "Submission pending. Use Leave to exit; submitted work may continue."
	elif first_corner != null: discard_draft()
	elif tool != "inspect": choose_tool("inspect")
	elif ui.family != "Select": ui.choose_family("Select")
	else: leave()

func _preview_box(pos: Dictionary) -> void:
	_clear_children(preview)
	if first_corner == null or int(first_corner.y) != level:
		return
	var left := minf(first_corner.x, pos.x) - 0.5
	var right := maxf(first_corner.x, pos.x) + 0.5
	var north := minf(first_corner.z, pos.z) - 0.5
	var south := maxf(first_corner.z, pos.z) + 0.5
	if tool == "furniture":
		var dir: Vector2 = [Vector2(0,1), Vector2(1,0), Vector2(0,-1), Vector2(-1,0)][facing_picker.selected]
		left = minf(left, first_corner.x + dir.x - 0.5)
		right = maxf(right, first_corner.x + dir.x + 0.5)
		north = minf(north, first_corner.z + dir.y - 0.5)
		south = maxf(south, first_corner.z + dir.y + 0.5)
	var material := _colour(Color(0.55, 0.7, 0.9))
	_planes(preview, [Vector3((left + right) * 0.5, level + 30.1, -north),
		Vector3((left + right) * 0.5, level + 30.1, -south)], material, right - left, 0.05)
	_planes(preview, [Vector3(left, level + 30.1, -(north + south) * 0.5),
		Vector3(right, level + 30.1, -(north + south) * 0.5)], material, 0.05, south - north)

func _input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			if touch_active or over_panel(event.position): return
			touch_active = true; touch_index = event.index
			touch_start = event.position; touch_dragged = false
		elif touch_active and event.index == touch_index:
			if not touch_dragged: select_cell(_cell(event.position))
			touch_active = false
		get_viewport().set_input_as_handled()
		return
	if event is InputEventScreenDrag and touch_active and event.index == touch_index:
		if event.position.distance_to(touch_start) > 10.0: touch_dragged = true
		if touch_dragged:
			centre += Vector2(-event.relative.x, event.relative.y) * extent / maxf(1.0, viewport.size.y)
			_move_camera(); need_view = true
		get_viewport().set_input_as_handled()
		return
	if event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_B: go_back()
		elif event.button_index == JOY_BUTTON_LEFT_SHOULDER: ui.focus_map()
		elif event.button_index == JOY_BUTTON_RIGHT_SHOULDER:
			if ui.submit.visible: ui.submit.grab_focus()
			else: ui.rail.get_child(0).grab_focus()
		elif ui.map_focused():
			if cursor.is_empty(): cursor = {"x": roundi(centre.x), "y": level, "z": roundi(centre.y)}
			cursor.y = level
			match event.button_index:
				JOY_BUTTON_A: select_cell(cursor)
				JOY_BUTTON_DPAD_LEFT: cursor.x -= 1
				JOY_BUTTON_DPAD_RIGHT: cursor.x += 1
				JOY_BUTTON_DPAD_UP: cursor.z += 1
				JOY_BUTTON_DPAD_DOWN: cursor.z -= 1
				JOY_BUTTON_X: change_level(-1)
				JOY_BUTTON_Y: change_level(1)
			show_cursor()
		else: return
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			go_back()
		elif room_name.has_focus():
			return
		elif ui.map_focused() and event.keycode in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, KEY_ENTER, KEY_KP_ENTER]:
			if cursor.is_empty(): cursor = {"x": roundi(centre.x), "y": level, "z": roundi(centre.y)}
			cursor.y = level
			if event.keycode == KEY_LEFT: cursor.x -= 1
			if event.keycode == KEY_RIGHT: cursor.x += 1
			if event.keycode == KEY_UP: cursor.z += 1
			if event.keycode == KEY_DOWN: cursor.z -= 1
			if event.keycode in [KEY_ENTER, KEY_KP_ENTER]: select_cell(cursor)
			else: show_cursor()
		elif event.keycode == KEY_PAGEUP:
			change_level(1)
		elif event.keycode == KEY_PAGEDOWN:
			change_level(-1)
		else:
			return
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		# Keep panel widgets interactive; handle world clicks everywhere else.
		var hovered := get_viewport().gui_get_hovered_control()
		if hovered != null and hovered != root_control:
			return
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			go_back()
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			dragging = event.pressed
		elif event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			ui.map_button.grab_focus()
			if not touch_active: select_cell(_cell(event.position))
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var step := 1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1
			if event.shift_pressed:
				change_level(step)
			else:
				zoom(step)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and first_corner != null and last_corner == null and not dragging:
		_preview_box(_cell(event.position))
	elif event is InputEventMouseMotion and dragging:
		centre += Vector2(-event.relative.x, event.relative.y) * extent / maxf(1.0, viewport.size.y)
		_move_camera()
		need_view = true
		get_viewport().set_input_as_handled()

func over_panel(point: Vector2) -> bool:
	for child in root_control.get_children():
		if child is PanelContainer and child.visible and child.get_global_rect().has_point(point): return true
	return false
