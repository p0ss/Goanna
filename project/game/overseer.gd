# SPDX-License-Identifier: LGPL-2.1-or-later
## The overseer camera: a server-authorised cutaway in an isolated World3D,
## for DorfCraft's planning view. The ordinary terrain, far field, particles,
## entities and lighting cannot enter this world. game/main.gd makes one per
## game scene and calls tick() every frame; it stays idle until the server's
## "dorfcraft:overseer" HUD element grants a channel, then talks over it with
## GoannaClient.overseer_send and overseer_take. docs/systems/overseer.md.
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
# Noun-first selection: the cells chosen in Select, and the verbs the server
# says apply to them. The server decides what a selection is; this view only
# draws its answer and turns a chosen verb into the existing tool and draft.
var selection: Dictionary = {}
var affordance_req := ""
var nouns: Array = []
var verbs: Array = []
var verbs_answered := false
var extend_selection := false
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
# Layers the server sent for this rectangle, by level, with their meshes in
# a hidden node each. Stepping to one draws it at once while a fresh
# observation is requested; nothing here outlives the session.
const CACHED_LEVELS := 8
var layer_cache: Dictionary = {}
var level_meshes: Dictionary = {}
var meshed_level := 0
var geometry_signature: Variant = null
var concealment_signature: Variant = null
# Overlays the server sends with each layer. Room quality is tinted by
# tier, or left grey until the room is surveyed; miasma shades known cells
# by the strongest remembered scent reaching them.
const OVERLAY_LIMIT := 256
const ROOM_TIER_COLOURS := [Color(0.55, 0.6, 0.72, 0.3), Color(0.35, 0.75, 0.45, 0.3),
	Color(0.95, 0.75, 0.25, 0.32), Color(0.78, 0.45, 0.95, 0.34)]
const ROOM_UNSURVEYED := Color(0.5, 0.5, 0.5, 0.14)
const MIASMA_BANDS := [Color(0.55, 0.72, 0.18, 0.1), Color(0.55, 0.72, 0.18, 0.18),
	Color(0.5, 0.65, 0.15, 0.26), Color(0.45, 0.55, 0.1, 0.34)]
const TRAFFIC_BANDS := [Color(1.0, 0.75, 0.3, 0.14), Color(1.0, 0.6, 0.2, 0.24),
	Color(1.0, 0.45, 0.15, 0.34), Color(0.95, 0.25, 0.1, 0.44)]
const WORKER_MARK := Color(0.3, 0.9, 1.0, 0.95)
const WORKER_TRAIL := Color(0.3, 0.9, 1.0, 0.4)
const FORBIDDEN := Color(0.9, 0.15, 0.15, 0.2)
const LOCKED := Color(0.7, 0.05, 0.05, 0.9)
const STATION := Color(0.35, 0.5, 1.0, 0.8)
const STATION_RING := Color(0.35, 0.5, 1.0, 0.25)
const PROTECTED := Color(0.35, 0.5, 1.0, 0.12)
const GUARD_HATCH := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec4 ink : source_color;
uniform bool cross_hatch = false;
void fragment() {
	float stripe = 1.0 - step(0.12, abs(fract((UV.x + UV.y) * 3.0) - 0.5));
	if (cross_hatch) {
		stripe = max(stripe, 1.0 - step(0.12, abs(fract((UV.x - UV.y) * 3.0) - 0.5)));
	}
	ALBEDO = ink.rgb;
	ALPHA = ink.a * stripe;
}
"""
# Houses (DorfCraft's co-op households, `houses` in the layer): a housed
# room, zone, lock, station or order is filled with its house's field
# pattern in the house colour, faint, under the other sheets. The pattern is
# anchored to world nodes so it runs on across a room's cells, and its edges
# are smoothed by screen derivative so it stays crisp at every zoom. Ids the
# client does not know get a plain diagonal hatch. HOUSE_PATTERNS index the
# shader's `pattern`; 0 is the hatch. The ids are DorfCraft's
# `R.field_patterns` (mods/kindred/settlement/runes/symbols.lua).
const HOUSE_PATTERNS := ["", "chequy", "lozengy", "paly", "barry", "bendy", "fretty",
	"masoned", "gyronny", "diaper", "semy"]
const HOUSE_LIMIT := 64
const HOUSE_FILL := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec4 ink : source_color;
uniform int pattern = 0;
uniform float base = 0.08;
uniform float strength = 0.34;
varying vec2 world;
void vertex() {
	// Node (x, z) is drawn at (x, -z); cell edges fall on whole numbers.
	world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz * vec2(1.0, -1.0) + 0.5;
}
float aa(float v) { return max(fwidth(v), 1e-4); }
// 1 on the middle half of each period of v.
float half_period(float v) { return clamp((0.25 - abs(fract(v) - 0.5)) / aa(v) + 0.5, 0.0, 1.0); }
// 1 within w of a whole number of v.
float line(float v, float w) { return clamp((w - abs(fract(v + 0.5) - 0.5)) / aa(v) + 0.5, 0.0, 1.0); }
float either(float a, float b) { return a + b - 2.0 * a * b; }
void fragment() {
	vec2 p = world;
	float m;
	if (pattern == 1) m = either(half_period(p.x), half_period(p.y));
	else if (pattern == 2) m = either(half_period(p.x + p.y), half_period(p.x - p.y));
	else if (pattern == 3) m = half_period(p.x);
	else if (pattern == 4) m = half_period(p.y);
	else if (pattern == 5) m = half_period((p.x + p.y) * 1.5);
	else if (pattern == 6) m = max(line((p.x + p.y) * 1.5, 0.09), line((p.x - p.y) * 1.5, 0.09));
	else if (pattern == 7) {
		float row = floor(p.y * 2.0);
		m = max(line(p.y * 2.0, 0.08), line(p.x + 0.5 * mod(row, 2.0), 0.05));
	} else if (pattern == 8) {
		vec2 c = fract(p) - 0.5;
		m = mod(floor(atan(c.y, c.x) / 0.785398 + 8.0), 2.0);
	} else if (pattern == 9) {
		vec2 q = vec2(p.x + p.y, p.x - p.y) * 1.5;
		vec2 d = fract(q) - 0.5;
		m = max(max(line(q.x, 0.05), line(q.y, 0.05)),
			clamp((0.14 - length(d)) / aa(q.x) + 0.5, 0.0, 1.0));
	} else if (pattern == 10) {
		vec2 q = p * 2.0;
		float kept = 1.0 - mod(floor(q.x) + floor(q.y), 2.0);
		m = kept * clamp((0.2 - length(fract(q) - 0.5)) / aa(q.x) + 0.5, 0.0, 1.0);
	} else m = line((p.x - p.y) * 3.0, 0.1);
	ALBEDO = ink.rgb;
	ALPHA = ink.a * mix(base, strength, m);
}
"""
# Access marks: shared is a ring in the house colour; locked adds a solid
# corner, so the two read apart at a glance even in the same colour.
const ACCESS_MARK := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec4 ink : source_color;
uniform bool locked = false;
void fragment() {
	vec2 c = abs(UV - 0.5);
	float edge = max(c.x, c.y);
	float w = max(fwidth(edge), 1e-4);
	float inner = locked ? 0.34 : 0.39;
	float ring = clamp((edge - inner) / w + 0.5, 0.0, 1.0) * clamp((0.48 - edge) / w + 0.5, 0.0, 1.0);
	float mark = ring;
	vec3 colour = ink.rgb;
	if (locked) {
		float corner = UV.x + UV.y;
		float cw = max(fwidth(corner), 1e-4);
		float solid = clamp((0.8 - corner) / cw + 0.5, 0.0, 1.0);
		float rim = solid - clamp((0.7 - corner) / cw + 0.5, 0.0, 1.0);
		mark = max(ring, solid);
		colour = mix(ink.rgb, vec3(0.04), rim * 0.8);
	}
	ALBEDO = colour;
	ALPHA = ink.a * mark;
}
"""
# The ownership field: which house holds each cell, one texel a cell. The
# `owners` texture carries the house colour (spread one texel into empty
# neighbours so edges fade without darkening); `flags` carries coverage in
# red and "the owner's house" in green. Linear filtering softens the edges
# between houses over one cell, as a field and not a grid. The owner's house is paler and carries
# faint diagonal stripes, so the fortress's own share reads apart from
# its settlers' even in a close colour.
const OWNERSHIP_FIELD := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;
uniform sampler2D owners : source_color, filter_linear, repeat_disable;
uniform sampler2D flags : filter_linear, repeat_disable;
uniform vec2 origin;
uniform vec2 size = vec2(1.0);
varying vec2 world;
void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz * vec2(1.0, -1.0);
}
void fragment() {
	vec2 uv = (world - origin + vec2(0.5)) / size;
	vec2 f = texture(flags, uv).rg;
	if (f.r < 0.01) discard;
	float owner = clamp(f.g / f.r, 0.0, 1.0);
	float cover = clamp(f.r * 1.6, 0.0, 1.0);
	float v = (world.x + world.y) * 2.0;
	float stripe = clamp((0.15 - abs(fract(v) - 0.5)) / max(fwidth(v), 1e-4) + 0.5, 0.0, 1.0);
	ALBEDO = texture(owners, uv).rgb;
	ALPHA = cover * mix(0.42, 0.18 + 0.2 * stripe, owner);
}
"""
const ACCESS_UNKNOWN_HOUSE := Color(0.92, 0.92, 0.88)
const WATCH := Color(0.55, 0.65, 1.0, 0.85)
# The seasons' field (the layer's `climate` overlay), by level 1 to 15 of
# the server's bands. Heat runs from deep blue through a faint middle, where
# a fortress is comfortable, to red; wetness from parched tan through the
# same faint middle to deep blue. The middle is faint so the extremes read.
const HEAT_RAMP := [[1, Color(0.15, 0.25, 0.85, 0.5)], [6, Color(0.55, 0.8, 1.0, 0.36)],
	[8, Color(0.9, 0.92, 0.9, 0.12)], [10, Color(1.0, 0.85, 0.35, 0.32)],
	[12, Color(1.0, 0.5, 0.15, 0.42)], [15, Color(0.85, 0.1, 0.05, 0.55)]]
const WET_RAMP := [[1, Color(0.85, 0.6, 0.3, 0.5)], [4, Color(0.95, 0.85, 0.55, 0.34)],
	[7, Color(0.9, 0.92, 0.9, 0.12)], [9, Color(0.4, 0.8, 0.6, 0.3)],
	[11, Color(0.2, 0.6, 0.95, 0.4)], [15, Color(0.1, 0.2, 0.8, 0.55)]]
var shown_overlays := {"rooms": false, "miasma": false, "traffic": false, "heat": false, "wet": false, "access": false, "ownership": false}
# Officers' pages to this planner, by id, as the server last sent them.
var pages: Dictionary = {}
var overlay_sheets: Node3D
var house_shader: Shader
var access_shader: Shader
var ownership_shader: Shader

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

## Called by main.gd each frame. Watches the HUD grant, opens or closes the
## view to match it, drains the channel, and pans while the view is open.
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
		_send({"t": "ping"} if session_ready else {"t": "ready", "prefetch": true})
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
	selection = {}
	affordance_req = ""
	verbs = []
	nouns = []
	ui = preload("res://game/overseer_ui.gd").new()
	ui.build(self)

func _clear_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()

func _clear_layer() -> void:
	geometry_signature = null
	concealment_signature = null
	if memory_material != null:
		memory_material.set_shader_parameter("has_memory", false)
	snapshot = {}
	mesh_queue.clear()
	mesh_nodes = {}
	mesh_stamps = {}
	wanted_stamps.clear()
	layer_cache.clear()
	level_meshes.clear()
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
	selection = {}
	affordance_req = ""
	dragging = false
	main.cam.cull_mask = saved_mask
	if is_instance_valid(pad):
		pad.set_enabled(saved_pad_enabled)
		pad.set_process_input(saved_pad_input)
	if main.ui != null:
		main.ui.visible = saved_ui
	if is_instance_valid(root_control):
		remove_child(root_control)
		root_control.queue_free()
	# Return input to the main viewport before recapturing its pointer.
	main.set_pointer_captured(saved_capture)

## Closes the view at the player's request and ignores the same grant until
## the server issues a new one, so it does not reopen at once.
func leave() -> void:
	if not active:
		return
	_send({"t": "leave"})
	ignored_channel = channel
	_close()

# Every message is from the server (the session drops anything a player
# relayed), but it is still checked field by field: valid_layer and _pos
# refuse anything out of the claim, oversized or malformed before it is drawn.
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
		pages.clear()
		if msg.get("pages") is Array:
			for page in msg.pages.slice(0, 64): _take_page(page)
		ui.refresh_pages()
		session_ready = true
		_move_camera()
		_request_view()
	elif type == "layer" and session_ready:
		if msg.get("palette") == null: msg.palette = []
		if msg.get("orders") == null: msg.orders = []
		var y := int(msg.get("y", -32000))
		if y != level:
			# A neighbouring level sent ahead of need, for this same request.
			if valid_layer(msg, sequence, y, requested, claim):
				_remember(y, msg)
			return
		if not valid_layer(msg, sequence, level, requested, claim) or int(msg.get("rev", -1)) <= revision:
			return
		_remember(level, msg)
		_update_materials(msg.get("materials", []))
		revision = int(msg.rev)
		layer_received = _now()
		snapshot = msg
		_draw_layer()
		status.text = "Level %d | %s | Live" % [level, str(tool_definition().get("title", tool))]
		refresh_draft()
	elif type == "pong" and msg.get("capabilities") is Dictionary:
		ui.update_capabilities(msg.capabilities)
	elif type == "overview":
		ui.update_overview(msg)
	elif type == "affordances":
		_receive_affordances(msg)
	elif type == "plans" and msg.get("plans") is Array:
		ui.update_plans(msg.plans)
	elif type == "page" and session_ready and msg.get("page") is Dictionary:
		if msg.get("what") == "done": pages.erase(str(msg.page.get("id", "")))
		else: _take_page(msg.page)
		ui.refresh_pages()
		if ui.family == "Plans": _send({"t": "plans"})
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

func _take_page(page: Variant) -> void:
	if not page is Dictionary or not page.get("id") is String or pages.size() >= 64 and not pages.has(page.id):
		return
	if not page.get("level") in ["danger", "urgent", "note"]: page.level = "note"
	pages[page.id] = page

## Tells the server a page was read; the banner and count follow at once.
func mark_page_seen(id: String) -> void:
	if pages.has(id): pages[id].state = "seen"
	_send({"t": "seen", "id": "page:" + id})
	ui.refresh_pages()

func _update_materials(value: Variant) -> void:
	material_catalog = value if value is Array else []
	if not pending.is_empty(): return
	var fallback: String = {"wall": "block", "floor": "block", "stairs": "stairs", "door": "door", "furniture": "furniture"}.get(tool, "")
	var wanted: String = str(tool_definition().get("material", fallback))
	var available: Array = []
	for entry in material_catalog:
		if str(entry.get("kind", "block")) == wanted:
			available.append(entry)
	facing_picker.visible = bool(tool_definition().get("facing", tool in ["stairs", "door", "furniture"]))
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
	var matched := false
	for entry in build_materials:
		build_material.add_item(str(entry.title).split("\n")[0] + (" (unavailable)" if entry.get("missing", false) else ""))
		build_material.set_item_tooltip(build_material.item_count - 1, str(entry.title) + "\n" + str(entry.get("reason", "")) + "\n" + str(entry.get("requirements", "")))
		if str(entry.name) == selected_name:
			build_material.select(build_material.item_count - 1)
			matched = true
	if tool == "workshop" and not matched:
		build_material.select(-1)
		build_material.text = "Choose workshop type..."
	if build_materials.is_empty() and not wanted.is_empty():
		build_material.add_item("No suitable item in stock")
		build_material.set_item_disabled(0, true)

# A reply too big for one mod channel message arrives as numbered base64
# chunks. At most two reassemblies at once, 35 chunks and 1 MiB each, and a
# part set older than 12 seconds is dropped.
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
		if inner is Dictionary and inner.get("t", "") in ["hello", "layer"]:
			_receive(inner)

static func _number(v: Variant, whole := true) -> bool:
	return (v is int or v is float) and is_finite(float(v)) and absf(float(v)) <= 31000.0 and (not whole or float(v) == floorf(float(v)))

static func _pos(v: Variant, whole := true) -> bool:
	return v is Dictionary and _number(v.get("x"), whole) and _number(v.get("y"), whole) and _number(v.get("z"), whole)

## Whether a "layer" message answers the current request (seq and level),
## stays inside both the requested rectangle and the server's claim, and has
## consistent cell, floor, state and wall arrays. Static so the overseer tests
## can feed it messages with no view.
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
	# Clear before asking. Only a layer the server sent for this level and
	# rectangle survives, and only as memory until the fresh one arrives.
	var kept: Dictionary = layer_cache.get(level, {})
	if kept.is_empty() or kept.rect != requested:
		_clear_layer()
	else:
		_forget_other_rects()
		snapshot = _as_memory(kept.layer)
		layer_received = _now()
		_draw_layer()
	parts.clear()
	_send({"t": "view", "seq": sequence, "y": level, "rect": requested})
	status.text = "Level %d | %s" % [level, "Waiting for server" if snapshot.is_empty() else "Remembered, refreshing"]

func _remember(y: int, msg: Dictionary) -> void:
	_forget_other_rects()
	layer_cache[y] = {"rect": requested.duplicate(), "layer": msg}
	while layer_cache.size() > CACHED_LEVELS:
		var far := y
		for other in layer_cache:
			if absi(other - level) > absi(far - level): far = other
		layer_cache.erase(far)
		if level_meshes.has(far):
			level_meshes[far].node.queue_free()
			level_meshes.erase(far)

func _forget_other_rects() -> void:
	for y in layer_cache.keys():
		if layer_cache[y].rect != requested:
			layer_cache.erase(y)

# A cached layer shows remembered terrain only. Nothing in it is currently
# visible, so it shows no live entities until the server confirms sight.
static func _as_memory(msg: Dictionary) -> Dictionary:
	var out := msg.duplicate(true)
	for slice in [out] + out.get("below", []):
		var states: Array = slice.get("states", [])
		for i in states.size():
			if int(states[i]) == 2: states[i] = 1
	if out.get("states", []).is_empty() and out.has("cells"):
		out.states = []
		for c in out.cells: out.states.append(1 if int(c) > 0 else 0)
	return out

# Meshes are kept per level; switching level shows that level's node.
func _show_level_meshes() -> void:
	if not level_meshes.has(level):
		var node := Node3D.new()
		geometry.add_child(node)
		level_meshes[level] = {"node": node, "nodes": {}, "stamps": {}}
	for y in level_meshes:
		level_meshes[y].node.visible = y == level
	meshed_level = level
	mesh_nodes = level_meshes[level].nodes
	mesh_stamps = level_meshes[level].stamps
	mesh_queue.clear()
	wanted_stamps.clear()

func visible_meshes() -> int:
	var count := 0
	for y in level_meshes:
		if level_meshes[y].node.visible: count += level_meshes[y].node.get_child_count()
	return count

func change_level(step: int) -> void:
	if not session_ready:
		return
	level = clampi(level + step, -30999, 30999)
	# A selection belongs to its level; its verbs were answered for those cells.
	selection = {}
	affordance_req = ""
	verbs = []
	nouns = []
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
	# Several blocks a frame, within about 4 ms, at least one.
	var started := Time.get_ticks_usec()
	while not mesh_queue.is_empty() and not snapshot.is_empty() and level_meshes.has(meshed_level):
		var parent: Node3D = level_meshes[meshed_level].node
		var block: Vector3i = mesh_queue.pop_front()
		var mesh: ArrayMesh = client.overseer_mesh(snapshot, block)
		if mesh_nodes.has(block):
			var old: Node3D = mesh_nodes[block]
			parent.remove_child(old)
			old.queue_free()
			mesh_nodes.erase(block)
		if mesh != null and mesh.get_surface_count() > 0:
			var instance := MeshInstance3D.new()
			instance.mesh = mesh
			parent.add_child(instance)
			mesh_nodes[block] = instance
		mesh_stamps[block] = wanted_stamps.get(block, 0)
		if Time.get_ticks_usec() - started > 4000:
			break

func _queue_geometry() -> void:
	_show_level_meshes()
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
		geometry_signature = null
		concealment_signature = null
		memory_material.set_shader_parameter("has_memory", false)
		_show_level_meshes()
		_clear_children(level_meshes[level].node)
		level_meshes[level].nodes.clear()
		level_meshes[level].stamps.clear()
		_clear_children(concealment)
		mesh_queue.clear()
		client.overseer_entities(actors, {})
		return
	# Observation dates and actor/plan updates do not change terrain. Avoid
	# rewalking every column and reallocating its masks on each live reply.
	# Frozen exact keys prevent a hash collision or later array mutation from
	# keeping visibility masks for a different observation.
	var geometry_parts: Array = [level, snapshot.rect, snapshot.palette, snapshot.cells, snapshot.floors]
	var visibility_parts: Array = [snapshot.get("states", [])]
	for below in snapshot.get("below", []):
		geometry_parts.append(below.cells)
		geometry_parts.append(below.get("walls", []))
		visibility_parts.append(below.get("states", []))
	var next_geometry := geometry_parts
	var next_concealment := [geometry_parts, visibility_parts, extent]
	if geometry_signature != next_geometry or meshed_level != level:
		_queue_geometry()
		geometry_signature = next_geometry.duplicate(true)
	if concealment_signature != next_concealment:
		_draw_concealment()
		concealment_signature = next_concealment.duplicate(true)
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
		if state == "proposed": colour = Color(0.75, 0.45, 0.95)
		var horizontal: Array = []
		var vertical: Array = []
		for p in marked[state]:
			horizontal.append(p + Vector3(0, 0, 0.45))
			horizontal.append(p - Vector3(0, 0, 0.45))
			vertical.append(p + Vector3(0.45, 0, 0))
			vertical.append(p - Vector3(0.45, 0, 0))
		_planes(overlay, horizontal, _colour(colour), 0.94, 0.06)
		_planes(overlay, vertical, _colour(colour), 0.06, 0.94)
	_draw_player_marker()
	_draw_overlays()

func _draw_player_marker() -> void:
	if roundi(body.y) != level:
		return
	var p := Vector3(body.x, level + 30.2, body.z)
	# Dark outline and bright centre remain distinct from worker dots.
	_planes(overlay, [p], _colour(Color(0.03, 0.06, 0.09)), 0.95, 0.95)
	_planes(overlay, [p + Vector3(0, 0.01, 0)], _colour(Color.WHITE), 0.78, 0.78)
	_planes(overlay, [p + Vector3(0, 0.02, 0)], _colour(Color(0.1, 0.8, 1.0)), 0.48, 0.48)
	var caption := Label3D.new()
	caption.text = "You"
	caption.font_size = 48
	caption.outline_size = 12
	caption.pixel_size = 0.012
	caption.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	caption.no_depth_test = true
	caption.position = p + Vector3(0, 0.03, -0.8)
	overlay.add_child(caption)

func player_location_text() -> String:
	var delta := roundi(body.y) - level
	return "You: level %d%s" % [roundi(body.y), " (here)" if delta == 0 else " (%d %s)" % [absi(delta), "above" if delta > 0 else "below"]]

func toggle_overlay(kind: String) -> void:
	if not shown_overlays.has(kind):
		return
	shown_overlays[kind] = not shown_overlays[kind]
	_draw_overlays()

# Sheets sit just under the order marks, one MultiMesh per colour.
func _draw_overlays() -> void:
	if is_instance_valid(overlay_sheets):
		overlay_sheets.queue_free()
	overlay_sheets = null
	if snapshot.is_empty() or snapshot.get("empty", false) or not is_instance_valid(overlay):
		return
	overlay_sheets = Node3D.new()
	overlay.add_child(overlay_sheets)
	# Under the other sheets: a field cell is several nodes across.
	for kind in ["heat", "wet"]:
		if not shown_overlays[kind]:
			continue
		var field := climate_cells(snapshot, kind)
		var step := float(field.get("step", 4))
		var by_level: Dictionary = field.get("levels", {})
		for lv in by_level:
			var positions: Array = []
			for c in by_level[lv]:
				positions.append(Vector3(c.x, level + 30.03, -c.y))
			_planes(overlay_sheets, positions, _colour(climate_colour(kind, lv)), step, step)
	var houses := house_table(snapshot)
	# Ownership replaces the patterned fills while it is on: both say which
	# house holds a cell, and two tints of one colour would only muddy it.
	if shown_overlays.ownership:
		_draw_ownership(houses)
	# Housed plans, under every other sheet and outline.
	var fills := {} if shown_overlays.ownership else house_cells(snapshot)
	for id in fills:
		var positions: Array = []
		for c in fills[id]:
			positions.append(Vector3(c.x, level + 30.04, -c.y))
		_planes(overlay_sheets, positions, _house_material(houses[id]), 1.0, 1.0)
	var groups: Array = []
	if shown_overlays.rooms:
		var rooms := room_cells(snapshot)
		for tier in rooms:
			groups.append([ROOM_UNSURVEYED if tier < 0 else ROOM_TIER_COLOURS[tier], rooms[tier]])
	if shown_overlays.miasma:
		var miasma := miasma_cells(snapshot)
		for band in miasma:
			groups.append([MIASMA_BANDS[band], miasma[band]])
	if shown_overlays.traffic:
		var busy := traffic_cells(snapshot)
		for band in busy:
			groups.append([TRAFFIC_BANDS[band], busy[band]])
	# Designations are plans, always shown like order marks.
	var marks := zone_cells(snapshot)
	groups.append([PROTECTED, marks.area])
	groups.append([FORBIDDEN, marks.forbid])
	groups.append([STATION_RING, marks.ring])
	for group in groups:
		var positions: Array = []
		for c in group[1]:
			positions.append(Vector3(c.x, level + 30.05, -c.y))
		_planes(overlay_sheets, positions, _colour(group[0]), 1.0, 1.0)
	var guards := guard_cells(snapshot)
	for state in ["partial", "unreachable"]:
		if guards[state].is_empty(): continue
		var positions: Array = []
		for c in guards[state]:
			positions.append(Vector3(c.x, level + 30.07, -c.y))
		var material := ShaderMaterial.new()
		var shader := Shader.new()
		shader.code = GUARD_HATCH
		material.shader = shader
		material.set_shader_parameter("ink", Color(1.0, 0.2, 0.15, 0.7) if state == "unreachable" else Color(1.0, 0.65, 0.1, 0.65))
		material.set_shader_parameter("cross_hatch", state == "unreachable")
		# UV stripes stay inside each known cell, even beside unexplored ground.
		_planes(overlay_sheets, positions, material, 1.0, 1.0)
	var small: Array = [[LOCKED, marks.lock, 0.6], [STATION, marks.post, 0.7], [WATCH, marks.watch, 0.4]]
	if shown_overlays.traffic:
		var workers := worker_marks(snapshot)
		small.append([WORKER_TRAIL, workers.trail, 0.25])
		small.append([WORKER_MARK, workers.here, 0.55])
	for group in small:
		var positions: Array = []
		for c in group[1]:
			positions.append(Vector3(c.x, level + 30.08, -c.y))
		_planes(overlay_sheets, positions, _colour(group[0]), group[2], group[2])
	if shown_overlays.access:
		var access := access_marks(snapshot)
		for state in ["shared", "locked"]:
			for id in access[state]:
				var positions: Array = []
				for c in access[state][id]:
					positions.append(Vector3(c.x, level + 30.09, -c.y))
				var ink: Color = houses[id].colour if houses.has(id) else ACCESS_UNKNOWN_HOUSE
				_planes(overlay_sheets, positions, _access_material(ink, state == "locked"), 1.0, 1.0)

# One sheet over the layer's rectangle, sampling one texel a cell with
# linear filtering, so neighbouring houses blend over a cell's width.
func _draw_ownership(houses: Dictionary) -> void:
	var field := ownership_field(snapshot)
	if field.is_empty(): return
	var w: int = field.w
	var h: int = field.h
	var colours := Image.create(w, h, false, Image.FORMAT_RGB8)
	var flags := Image.create(w, h, false, Image.FORMAT_RG8)
	var owners: PackedStringArray = field.owners
	var any := false
	for i in owners.size():
		if owners[i].is_empty(): continue
		any = true
		colours.set_pixel(i % w, i / w, houses[owners[i]].colour)
		flags.set_pixel(i % w, i / w, Color(1, 1 if houses[owners[i]].owner else 0, 0))
	if not any: return
	# Spread each colour into empty neighbours: filtering then fades a
	# house's edge to clear, not through black.
	for i in owners.size():
		if not owners[i].is_empty(): continue
		var x := i % w
		var z := i / w
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = x + d.x
			var nz: int = z + d.y
			if nx >= 0 and nx < w and nz >= 0 and nz < h and not owners[nz * w + nx].is_empty():
				colours.set_pixel(x, z, houses[owners[nz * w + nx]].colour)
				break
	if ownership_shader == null:
		ownership_shader = Shader.new()
		ownership_shader.code = OWNERSHIP_FIELD
	var material := ShaderMaterial.new()
	material.shader = ownership_shader
	material.set_shader_parameter("owners", ImageTexture.create_from_image(colours))
	material.set_shader_parameter("flags", ImageTexture.create_from_image(flags))
	material.set_shader_parameter("origin", Vector2(field.x0, field.z0))
	material.set_shader_parameter("size", Vector2(w, h))
	_planes(overlay_sheets, [Vector3((field.x0 + field.x0 + w - 1) * 0.5, level + 30.035,
		-(field.z0 + field.z0 + h - 1) * 0.5)], material, w, h)

func _house_material(house: Dictionary) -> ShaderMaterial:
	if house_shader == null:
		house_shader = Shader.new()
		house_shader.code = HOUSE_FILL
	var material := ShaderMaterial.new()
	material.shader = house_shader
	material.set_shader_parameter("ink", house.colour)
	material.set_shader_parameter("pattern", house_pattern(house.pattern))
	return material

func _access_material(ink: Color, locked: bool) -> ShaderMaterial:
	if access_shader == null:
		access_shader = Shader.new()
		access_shader.code = ACCESS_MARK
	var material := ShaderMaterial.new()
	material.shader = access_shader
	material.set_shader_parameter("ink", Color(ink, 0.95))
	material.set_shader_parameter("locked", locked)
	return material

static func _known_cell(layer: Dictionary, x: int, z: int) -> bool:
	var r: Variant = layer.get("rect")
	if not r is Dictionary or not layer.get("cells") is Array:
		return false
	if x < int(r.x0) or x > int(r.x1) or z < int(r.z0) or z > int(r.z1):
		return false
	var i := (z - int(r.z0)) * (int(r.x1) - int(r.x0) + 1) + x - int(r.x0)
	return i < layer.cells.size() and int(layer.cells[i]) > 0

# Known cells by traffic band: under 1, under 4, under 16, then more.
static func traffic_cells(layer: Dictionary) -> Dictionary:
	var out := {}
	var overlays: Variant = layer.get("overlays")
	if not overlays is Dictionary or not overlays.get("traffic") is Array:
		return out
	var flat: Array = overlays.traffic
	for i in range(0, mini(flat.size() - 2, 3 * 4096), 3):
		if not (_number(flat[i]) and _number(flat[i + 1]) and _number(flat[i + 2])):
			continue
		var x := int(flat[i])
		var z := int(flat[i + 1])
		if not _known_cell(layer, x, z):
			continue
		var n := float(flat[i + 2]) / 10.0
		var band := 0 if n < 1.0 else 1 if n < 4.0 else 2 if n < 16.0 else 3
		if not out.has(band):
			out[band] = []
		out[band].append(Vector2i(x, z))
	return out

# Workers standing on this level, and their trails, on known cells.
static func worker_marks(layer: Dictionary) -> Dictionary:
	var out := {"here": [], "trail": []}
	for e in _overlay_list(layer, "workers"):
		if not e is Dictionary:
			continue
		if e.get("here", false) == true and _number(e.get("x")) and _number(e.get("z")) \
				and _known_cell(layer, int(e.x), int(e.z)):
			out.here.append(Vector2i(int(e.x), int(e.z)))
		var trail: Variant = e.get("trail")
		if trail is Array:
			for i in range(0, mini(trail.size() - 1, 64), 2):
				if _number(trail[i]) and _number(trail[i + 1]) and _known_cell(layer, int(trail[i]), int(trail[i + 1])):
					out.trail.append(Vector2i(int(trail[i]), int(trail[i + 1])))
	return out

# Forbidden areas, locked doors and militia stations with their rings,
# on known cells.
static func zone_cells(layer: Dictionary) -> Dictionary:
	var out := {"forbid": [], "area": [], "lock": [], "post": [], "ring": [], "watch": []}
	var r: Variant = layer.get("rect")
	if not r is Dictionary:
		return out
	for pair in [["zones", "forbid"], ["areas", "area"]]:
		out[pair[1]] = _rectangle_cells(layer, _overlay_list(layer, pair[0]))
	for e in _overlay_list(layer, "watch"):
		if not e is Dictionary or not (_number(e.get("x")) and _number(e.get("z"))):
			continue
		if e.get("kind") == "night":
			var ring := clampi(int(e.get("ring", 3)) if _number(e.get("ring", 3)) else 3, 1, 8)
			for dz in range(-ring, ring + 1):
				for dx in range(-ring, ring + 1):
					if maxi(absi(dx), absi(dz)) == ring and _known_cell(layer, int(e.x) + dx, int(e.z) + dz):
						out.watch.append(Vector2i(int(e.x) + dx, int(e.z) + dz))
		elif _known_cell(layer, int(e.x), int(e.z)):
			out.watch.append(Vector2i(int(e.x), int(e.z)))
	for e in _overlay_list(layer, "locks"):
		if e is Dictionary and _number(e.get("x")) and _number(e.get("z")) and _known_cell(layer, int(e.x), int(e.z)):
			out.lock.append(Vector2i(int(e.x), int(e.z)))
	for e in _overlay_list(layer, "stations"):
		if not e is Dictionary or not (_number(e.get("x")) and _number(e.get("z"))):
			continue
		var ring := clampi(int(e.get("ring", 3)) if _number(e.get("ring", 3)) else 3, 1, 8)
		if _known_cell(layer, int(e.x), int(e.z)):
			out.post.append(Vector2i(int(e.x), int(e.z)))
		for dz in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dz)) == ring and _known_cell(layer, int(e.x) + dx, int(e.z) + dz):
					out.ring.append(Vector2i(int(e.x) + dx, int(e.z) + dz))
	return out

# Guard access is server evidence, not inferred from the designation itself.
static func _guard_state(area: Dictionary) -> String:
	var state: Variant = area.get("reachability")
	return state if state is String and state in ["reachable", "partial", "unreachable", "unknown"] else "unknown"

static func _guard_rect(area: Dictionary) -> bool:
	var b: Variant = area.get("rect")
	return b is Dictionary and _number(b.get("x0")) and _number(b.get("x1")) \
		and _number(b.get("z0")) and _number(b.get("z1"))

static func guard_cells(layer: Dictionary) -> Dictionary:
	var out := {"partial": [], "unreachable": []}
	var r: Variant = layer.get("rect")
	if not r is Dictionary or not _guard_rect({"rect": r}):
		return out
	var partial: Array = []
	var unreachable: Array = []
	for area in _overlay_list(layer, "areas"):
		if not area is Dictionary: continue
		var state := _guard_state(area)
		if state == "partial": partial.append(area)
		elif state == "unreachable": unreachable.append(area)
	out.unreachable = _rectangle_cells(layer, unreachable)
	var blocked := {}
	for cell in out.unreachable: blocked[cell] = true
	for cell in _rectangle_cells(layer, partial):
		if not blocked.has(cell): out.partial.append(cell)
	return out

# Merge rectangle spans before visiting cells: overlapping designations must
# not allocate or draw the same cell hundreds of times.
static func _rectangle_cells(layer: Dictionary, entries: Array) -> Array:
	var out: Array = []
	var r: Variant = layer.get("rect")
	if not r is Dictionary or not _guard_rect({"rect": r}): return out
	var rows := {}
	for entry in entries:
		if not entry is Dictionary or not _guard_rect(entry): continue
		var b: Dictionary = entry.rect
		var left := maxi(int(b.x0), int(r.x0))
		var right := mini(int(b.x1), int(r.x1))
		if left > right: continue
		for z in range(maxi(int(b.z0), int(r.z0)), mini(int(b.z1), int(r.z1)) + 1):
			if not rows.has(z): rows[z] = []
			rows[z].append(Vector2i(left, right))
	for z in rows:
		var spans: Array = rows[z]
		spans.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x < b.x)
		var next_x := int(r.x0)
		for span in spans:
			for x in range(maxi(next_x, span.x), span.y + 1):
				if _known_cell(layer, x, z): out.append(Vector2i(x, z))
			next_x = maxi(next_x, span.y + 1)
	return out

static func _inside_rectangle(entry: Variant, pos: Dictionary) -> bool:
	if not entry is Dictionary or not _guard_rect(entry): return false
	var b: Dictionary = entry.rect
	return pos.x >= b.x0 and pos.x <= b.x1 and pos.z >= b.z0 and pos.z <= b.z1

static func guard_notes(layer: Dictionary, pos: Dictionary) -> String:
	if not _known_cell(layer, int(pos.x), int(pos.z)):
		return ""
	var notes := ""
	for area in _overlay_list(layer, "areas"):
		if not area is Dictionary or not _guard_rect(area):
			continue
		var b: Dictionary = area.rect
		if pos.x < b.x0 or pos.x > b.x1 or pos.z < b.z0 or pos.z > b.z1:
			continue
		var state := _guard_state(area)
		notes += "\nProtected area: guard access %s" % ("partially reachable" if state == "partial" else state)
		var reason: Variant = area.get("reason", "")
		if reason is String and not reason.is_empty():
			notes += " (%s)" % reason.left(160).replace("\n", " ")
	return notes

static func _overlay_list(layer: Dictionary, kind: String) -> Array:
	var overlays: Variant = layer.get("overlays")
	if not overlays is Dictionary or not overlays.get(kind) is Array:
		return []
	return overlays[kind].slice(0, OVERLAY_LIMIT)

# A house id as a string key: JSON gives numbers as floats, and a Lua table
# of ids 1 to n arrives as an array.
static func house_id(v: Variant) -> String:
	if v is String: return v.left(64)
	if _number(v): return str(int(v))
	return ""

## The layer's houses by id: {surname, head, colour, pattern, owner}. An
## older server sends none; a malformed record is skipped. `owner` (the
## fortress owner's own house, drawn as unhoused) is read if the server
## marks it.
static func house_table(layer: Dictionary) -> Dictionary:
	var out := {}
	var raw: Variant = layer.get("houses")
	var pairs: Array = []
	if raw is Dictionary:
		for k in raw: pairs.append([k, raw[k]])
	elif raw is Array:
		for i in raw.size(): pairs.append([i + 1, raw[i]])
	for pair in pairs.slice(0, HOUSE_LIMIT):
		var id := house_id(pair[0])
		var h: Variant = pair[1]
		if id.is_empty() or not h is Dictionary: continue
		var hex: Variant = h.get("colour")
		if not hex is String or hex.length() != 7 or not hex.begins_with("#") or not hex.substr(1).is_valid_hex_number():
			continue
		out[id] = {"surname": str(h.get("surname", "")).left(64).replace("\n", " "),
			"head": str(h.get("head", "")).left(64).replace("\n", " "),
			"colour": Color.html(hex), "pattern": str(h.get("pattern", "")).left(32),
			"owner": h.get("owner", false) == true}
	return out

## The shader index of a field pattern id; 0, the diagonal hatch, for any
## id this client does not know.
static func house_pattern(name: String) -> int:
	return maxi(HOUSE_PATTERNS.find(name), 0) if not name.is_empty() else 0

## "House Surname" for an entry's `house`, or "" when it has none.
static func house_name(houses: Dictionary, v: Variant) -> String:
	var id := house_id(v)
	if id.is_empty() or not houses.has(id): return ""
	var surname: String = houses[id].surname
	return "House " + surname if not surname.is_empty() else "A house"

static func _house_suffix(houses: Dictionary, entry: Variant) -> String:
	if not entry is Dictionary: return ""
	var name := house_name(houses, entry.get("house"))
	return " (%s)" % name if not name.is_empty() else ""

static func _cell_of(e: Variant) -> Variant:
	if not e is Dictionary: return null
	if _pos(e.get("pos")): return e.pos
	if _number(e.get("x")) and _number(e.get("z")): return e
	return null

## Known cells on this level of every housed room, zone, lock, station and
## order, by house id. The owner's house and unhoused entries are left out,
## so they look as they did before houses.
static func house_cells(layer: Dictionary) -> Dictionary:
	var houses := house_table(layer)
	var sets := {}
	if houses.is_empty() or not layer.get("rect") is Dictionary: return {}
	var add := func(entry: Variant, cells: Array) -> void:
		var id := house_id(entry.get("house"))
		if id.is_empty() or not houses.has(id) or houses[id].owner: return
		if not sets.has(id): sets[id] = {}
		for c in cells: sets[id][c] = true
	for kind in ["rooms", "zones"]:
		for e in _overlay_list(layer, kind):
			if e is Dictionary and e.has("house"): add.call(e, _rectangle_cells(layer, [e]))
	for kind in ["locks", "stations"]:
		for e in _overlay_list(layer, kind):
			var p: Variant = _cell_of(e)
			if p != null and e.has("house") and _known_cell(layer, int(p.x), int(p.z)):
				add.call(e, [Vector2i(int(p.x), int(p.z))])
	var orders: Variant = layer.get("orders")
	if orders is Array:
		for e in orders.slice(0, 4096):
			if not e is Dictionary or not e.has("house") or not _pos(e.get("pos")): continue
			if int(e.pos.y) == int(layer.get("y", -32000)) and _known_cell(layer, int(e.pos.x), int(e.pos.z)):
				add.call(e, [Vector2i(int(e.pos.x), int(e.pos.z))])
	var out := {}
	for id in sets: out[id] = sets[id].keys()
	return out

## Which house holds each known cell of the layer's rectangle: {x0, z0, w,
## h, owners}, owners a house id ("" for none) per cell, row by row from
## z0. An access mark on the cell wins, then the room it lies in, then a
## plan or designation (zone, lock, station, order) covering it. The owner's
## house counts here too. Empty when the layer lists no houses.
static func ownership_field(layer: Dictionary) -> Dictionary:
	var houses := house_table(layer)
	var r: Variant = layer.get("rect")
	if houses.is_empty() or not r is Dictionary or not _guard_rect({"rect": r}): return {}
	var w := int(r.x1) - int(r.x0) + 1
	var h := int(r.z1) - int(r.z0) + 1
	if w <= 0 or h <= 0 or w * h > 4096: return {}
	var owners := PackedStringArray()
	owners.resize(w * h)
	var rank := PackedInt32Array()
	rank.resize(w * h)
	var claim := func(id: String, cells: Array, level_rank: int) -> void:
		if not houses.has(id): return
		for c in cells:
			var i: int = (c.y - int(r.z0)) * w + c.x - int(r.x0)
			if rank[i] < level_rank:
				rank[i] = level_rank
				owners[i] = id
	for kind in ["zones"]:
		for e in _overlay_list(layer, kind):
			if e is Dictionary and e.has("house"): claim.call(house_id(e.house), _rectangle_cells(layer, [e]), 1)
	for kind in ["locks", "stations"]:
		for e in _overlay_list(layer, kind):
			var p: Variant = _cell_of(e)
			if p != null and e.has("house") and _known_cell(layer, int(p.x), int(p.z)):
				claim.call(house_id(e.house), [Vector2i(int(p.x), int(p.z))], 1)
	var orders: Variant = layer.get("orders")
	if orders is Array:
		for e in orders.slice(0, 4096):
			if e is Dictionary and e.has("house") and _pos(e.get("pos")) and int(e.pos.y) == int(layer.get("y", -32000)) \
					and _known_cell(layer, int(e.pos.x), int(e.pos.z)):
				claim.call(house_id(e.house), [Vector2i(int(e.pos.x), int(e.pos.z))], 1)
	for e in _overlay_list(layer, "rooms"):
		if e is Dictionary and e.has("house"): claim.call(house_id(e.house), _rectangle_cells(layer, [e]), 2)
	for e in _overlay_list(layer, "access"):
		var p: Variant = _cell_of(e)
		if p == null or not e.get("state") in ["shared", "locked"]: continue
		if p.has("y") and int(p.y) != int(layer.get("y", -32000)): continue
		if _known_cell(layer, int(p.x), int(p.z)):
			claim.call(house_id(e.get("house")), [Vector2i(int(p.x), int(p.z))], 3)
	return {"x0": int(r.x0), "z0": int(r.z0), "w": w, "h": h, "owners": owners, "rank": rank}

## Access marks on known cells of this level: {"shared": {house id: cells},
## "locked": {...}}. A mark naming no known house keys as "".
static func access_marks(layer: Dictionary) -> Dictionary:
	var out := {"shared": {}, "locked": {}}
	var houses := house_table(layer)
	for e in _overlay_list(layer, "access"):
		var p: Variant = _cell_of(e)
		if p == null or not e.get("state") in ["shared", "locked"]: continue
		if p.has("y") and int(p.y) != int(layer.get("y", -32000)): continue
		if not _known_cell(layer, int(p.x), int(p.z)): continue
		var id := house_id(e.get("house"))
		if not houses.has(id): id = ""
		var by: Dictionary = out[e.state]
		if not by.has(id): by[id] = []
		by[id].append(Vector2i(int(p.x), int(p.z)))
	return out

# Cells of each room on this level, by tier; -1 for not yet surveyed.
static func room_cells(layer: Dictionary) -> Dictionary:
	var out := {}
	var r: Variant = layer.get("rect")
	if not r is Dictionary:
		return out
	for e in _overlay_list(layer, "rooms"):
		if not e is Dictionary or not e.get("rect") is Dictionary:
			continue
		var b: Dictionary = e.rect
		if not (_number(b.get("x0")) and _number(b.get("x1")) and _number(b.get("z0")) and _number(b.get("z1"))):
			continue
		var tier := -1
		if e.get("surveyed", false) == true and _number(e.get("tier")):
			tier = clampi(int(e.tier), 0, ROOM_TIER_COLOURS.size() - 1)
		if not out.has(tier):
			out[tier] = []
		for z in range(maxi(int(b.z0), int(r.z0)), mini(int(b.z1), int(r.z1)) + 1):
			for x in range(maxi(int(b.x0), int(r.x0)), mini(int(b.x1), int(r.x1)) + 1):
				out[tier].append(Vector2i(x, z))
	return out

# Strength of the strongest source at each known cell, from 0 to 1. A
# source's scent is a sphere; this level cuts it at its own height.
static func miasma_strength(layer: Dictionary) -> PackedFloat32Array:
	var r: Variant = layer.get("rect")
	var strength := PackedFloat32Array()
	if not r is Dictionary or not layer.get("cells") is Array:
		return strength
	var width := int(r.x1) - int(r.x0) + 1
	var height := int(r.z1) - int(r.z0) + 1
	if width * height != layer.cells.size():
		return strength
	strength.resize(width * height)
	for e in _overlay_list(layer, "miasma"):
		if not e is Dictionary or not (_number(e.get("x")) and _number(e.get("y")) and _number(e.get("z"))
				and _number(e.get("scent"), false)):
			continue
		var dy := float(int(e.y) - int(layer.y))
		var reach_sq := float(e.scent) * float(e.scent) - dy * dy
		if reach_sq <= 0.0:
			continue
		var reach := sqrt(reach_sq)
		for z in range(maxi(int(floor(e.z - reach)), int(r.z0)), mini(int(ceil(e.z + reach)), int(r.z1)) + 1):
			for x in range(maxi(int(floor(e.x - reach)), int(r.x0)), mini(int(ceil(e.x + reach)), int(r.x1)) + 1):
				var d := Vector2(x - int(e.x), z - int(e.z)).length()
				if d >= reach:
					continue
				var i := (z - int(r.z0)) * width + x - int(r.x0)
				strength[i] = maxf(strength[i], 1.0 - d / reach)
	return strength

# The climate overlay's cells by level for `kind`, "heat" (the high four
# bits) or "wet" (the low four): {"step": nodes a cell, "levels": level to
# cell centres, x and z in nodes}. Unknown cells (0) are left out.
static func climate_cells(layer: Dictionary, kind: String) -> Dictionary:
	var out := {"step": 4, "levels": {}}
	var overlays: Variant = layer.get("overlays")
	if not overlays is Dictionary or not overlays.get("climate") is Dictionary:
		return out
	var c: Dictionary = overlays.climate
	if not (_number(c.get("x0")) and _number(c.get("z0")) and _number(c.get("w"), false)
			and _number(c.get("h"), false) and _number(c.get("step"), false)) or not c.get("cells") is Array:
		return out
	var w := int(c.w)
	var step := int(c.step)
	var cells: Array = c.cells
	if w <= 0 or step <= 0 or cells.size() != w * int(c.h):
		return out
	out.step = step
	var half := (step - 1) * 0.5
	for i in cells.size():
		if not _number(cells[i]):
			continue
		var byte := int(cells[i])
		var lv := byte >> 4 if kind == "heat" else byte & 15
		if byte == 0 or lv == 0:
			continue
		if not out.levels.has(lv):
			out.levels[lv] = []
		out.levels[lv].append(Vector2(int(c.x0) + (i % w) * step + half, int(c.z0) + (i / w) * step + half))
	return out

# A level's colour on the heat or wetness ramp, between the stops round it.
static func climate_colour(kind: String, lv: int) -> Color:
	var ramp: Array = HEAT_RAMP if kind == "heat" else WET_RAMP
	for i in range(1, ramp.size()):
		if lv <= int(ramp[i][0]):
			var a: Array = ramp[i - 1]
			var b: Array = ramp[i]
			return (a[1] as Color).lerp(b[1], clampf(float(lv - int(a[0])) / float(int(b[0]) - int(a[0])), 0.0, 1.0))
	return ramp[-1][1]

# The band name of a level, from the server's [first level, name] pairs.
static func climate_band(bands: Variant, lv: int) -> String:
	var name := ""
	if bands is Array:
		for b in bands:
			if b is Array and b.size() >= 2 and _number(b[0]) and lv >= int(b[0]):
				name = str(b[1])
	return name

# Known cells by miasma band, 0 (faint) to 3 (strong).
static func miasma_cells(layer: Dictionary) -> Dictionary:
	var out := {}
	var strength := miasma_strength(layer)
	if strength.is_empty():
		return out
	var r: Dictionary = layer.rect
	var width := int(r.x1) - int(r.x0) + 1
	for i in strength.size():
		if strength[i] <= 0.0 or int(layer.cells[i]) == 0:
			continue
		var band := mini(int(strength[i] * MIASMA_BANDS.size()), MIASMA_BANDS.size() - 1)
		if not out.has(band):
			out[band] = []
		out[band].append(Vector2i(int(r.x0) + i % width, int(r.z0) + i / width))
	return out

# What the overlays say about one cell, for Inspect.
static func overlay_notes(layer: Dictionary, pos: Dictionary) -> String:
	var notes := ""
	var houses := house_table(layer)
	for e in _overlay_list(layer, "rooms"):
		if not e is Dictionary or not e.get("rect") is Dictionary:
			continue
		var b: Dictionary = e.rect
		if pos.x < b.get("x0", 0) or pos.x > b.get("x1", -1) or pos.z < b.get("z0", 0) or pos.z > b.get("z1", -1):
			continue
		var name := "%s \"%s\"%s" % [str(e.get("title", "Room")), str(e.get("name", "")), _house_suffix(houses, e)]
		if e.get("surveyed", false) == true:
			notes += "\n%s: %s, %s points, as of day %s" % [name, str(e.get("tier_name", "")),
				str(e.get("points", 0)), str(e.get("day", "?"))]
			if e.get("valid", true) == false:
				notes += " (not usable: %s)" % str(e.get("why", "?"))
		else:
			notes += "\n%s: not yet surveyed" % name
	var best := 0.0
	var source: Dictionary = {}
	for e in _overlay_list(layer, "miasma"):
		if not e is Dictionary or not (_number(e.get("x")) and _number(e.get("y")) and _number(e.get("z"))
				and _number(e.get("scent"), false)) or float(e.scent) <= 0.0:
			continue
		var d := Vector3(pos.x - int(e.x), pos.y - int(e.y), pos.z - int(e.z)).length()
		var s := 1.0 - d / float(e.scent)
		if s > best:
			best = s
			source = e
	if best > 0.0:
		var what := "a %s %s" % [str(source.get("stage", "")), "gore pile" if source.get("kind") == "gore" else "carcass"]
		if source.get("kind") == "rubbish": what = "rubbish"
		elif source.get("kind") == "rotting": what = "rotting food"
		notes += "\nMiasma from %s, seen day %s" % [what, str(source.get("day", "?"))]
	var overlays: Variant = layer.get("overlays")
	if overlays is Dictionary and overlays.get("climate") is Dictionary:
		var c: Dictionary = overlays.climate
		if _number(c.get("x0")) and _number(c.get("z0")) and _number(c.get("w"), false) \
				and _number(c.get("step"), false) and int(c.step) > 0 and c.get("cells") is Array:
			var cx := floori(float(pos.x - int(c.x0)) / int(c.step))
			var cz := floori(float(pos.z - int(c.z0)) / int(c.step))
			var i := cz * int(c.w) + cx
			if cx >= 0 and cx < int(c.w) and cz >= 0 and i < c.cells.size() and _number(c.cells[i]) and int(c.cells[i]) > 0:
				var byte := int(c.cells[i])
				var heat := climate_band(c.get("t_bands"), byte >> 4)
				var wet := climate_band(c.get("m_bands"), byte & 15)
				if heat != "" and wet != "":
					notes += "\nClimate: %s, %s" % [heat, wet]
				elif heat != "" or wet != "":
					notes += "\nClimate: %s" % (heat + wet)
	if overlays is Dictionary and overlays.get("traffic") is Array:
		var flat: Array = overlays.traffic
		for i in range(0, mini(flat.size() - 2, 3 * 4096), 3):
			if _number(flat[i]) and _number(flat[i + 1]) and int(flat[i]) == int(pos.x) and int(flat[i + 1]) == int(pos.z) \
					and _number(flat[i + 2]):
				notes += "\nTraffic: %.1f" % (float(flat[i + 2]) / 10.0)
	for e in _overlay_list(layer, "workers"):
		if e is Dictionary and e.get("here", false) == true and e.get("x") == pos.x and e.get("z") == pos.z:
			notes += "\n%s: %s" % [str(e.get("name", "Worker")), str(e.get("activity", "idle"))]
	if _known_cell(layer, int(pos.x), int(pos.z)):
		for entry in _overlay_list(layer, "zones"):
			if _inside_rectangle(entry, pos):
				notes += "\nForbidden area%s: workers take no work here" % _house_suffix(houses, entry)
				break
		for entry in _overlay_list(layer, "locks"):
			if entry is Dictionary and entry.get("x") == pos.x and entry.get("z") == pos.z:
				notes += "\nLocked door" + _house_suffix(houses, entry)
				break
		for entry in _overlay_list(layer, "access"):
			var p: Variant = _cell_of(entry)
			if p == null or int(p.x) != int(pos.x) or int(p.z) != int(pos.z): continue
			if p.has("y") and int(p.y) != int(pos.get("y", p.y)): continue
			var who := house_name(houses, entry.get("house"))
			if who.is_empty(): who = "its house"
			if entry.get("state") == "locked":
				notes += "\nLocked: only %s may use it" % who
			elif entry.get("state") == "shared":
				notes += "\nShared by %s: others may use it, not dig it" % who
			break
	var field := ownership_field(layer)
	if not field.is_empty():
		var dx := int(pos.x) - int(field.x0)
		var dz := int(pos.z) - int(field.z0)
		if dx >= 0 and dx < int(field.w) and dz >= 0 and dz < int(field.h) and not field.owners[dz * field.w + dx].is_empty():
			var i: int = dz * field.w + dx
			notes += "\nHeld by %s (%s)" % [house_name(houses, field.owners[i]),
				["", "its plans", "its room", "its access mark"][field.rank[i]]]
	notes += guard_notes(layer, pos)
	for e in _overlay_list(layer, "watch"):
		if e is Dictionary and e.get("kind") == "door" and e.get("x") == pos.x and e.get("z") == pos.z:
			notes += "\nOuter door: watched by soldiers at night"
	for e in _overlay_list(layer, "stations"):
		if e is Dictionary and e.get("x") == pos.x and e.get("z") == pos.z:
			notes += "\nStation: %s%s" % ["all soldiers" if str(e.get("squad", "*")) == "*" else str(e.get("squad")), _house_suffix(houses, e)]
	return notes

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
		_select_for_verbs(pos, extend_selection)
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
				inspector.text += "\n%s%s: %s %s" % [order_entry.get("kind", "Order"), _house_suffix(house_table(snapshot), order_entry),
					order_entry.get("state", ""), order_entry.get("reason", "")]
		inspector.text += overlay_notes(snapshot, pos)
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

func _select_for_verbs(pos: Dictionary, extend: bool) -> void:
	if extend and not selection.is_empty() and int(selection.a.y) == level:
		selection.b = pos.duplicate()
	else:
		selection = {"a": pos.duplicate(), "b": pos.duplicate()}
	request_id += 1
	affordance_req = "verbs:%d" % request_id
	verbs = []
	nouns = []
	verbs_answered = false
	_send({"t": "affordances", "req": affordance_req, "a": selection.a.duplicate(), "b": selection.b.duplicate()})
	refresh_draft()

func clear_selection() -> void:
	if selection.is_empty(): return
	selection = {}
	affordance_req = ""
	verbs = []
	nouns = []
	refresh_draft()

## Only the answer to the latest selection is kept, and only well formed
## entries: a verb names a tool from the hello, or is Progress.
func _receive_affordances(msg: Dictionary) -> void:
	if affordance_req.is_empty() or str(msg.get("req", "")) != affordance_req:
		return
	verbs_answered = true
	verbs = []
	nouns = []
	if not msg.get("ok", false):
		inspector.text += "\n" + str(msg.get("reason", "The server refused this selection."))
	else:
		verbs = valid_verbs(msg.get("verbs"), tools)
		if msg.get("nouns") is Array:
			for noun in msg.nouns.slice(0, 8):
				if noun is Dictionary and noun.get("kind") is String: nouns.append(noun)
	if ui != null: ui.refresh()

static func valid_verbs(value: Variant, known_tools: Array) -> Array:
	var out: Array = []
	if not value is Array: return out
	var ids := {}
	for t in known_tools:
		if t is Dictionary: ids[str(t.get("id", ""))] = true
	for v in value.slice(0, 64):
		if not v is Dictionary or not v.get("id") is String: continue
		if v.id == "progress":
			if v.get("plans") is Array: out.append(v)
		elif v.get("tool") is String and ids.has(v.tool):
			out.append(v)
	return out

## The strip's entries: verbs in server order, with each tool group (crop,
## room type, storage type) folded into one entry that opens its first
## available member; the zone property control then picks among them.
static func strip_entries(list: Array) -> Array:
	var out: Array = []
	var groups := {}
	for i in list.size():
		var v: Dictionary = list[i]
		var group := str(v.get("group", ""))
		if group.is_empty():
			out.append({"verb": i, "label": str(v.get("label", v.id)), "disabled": v.get("disabled", false),
				"reason": str(v.get("reason", v.get("help", ""))), "icon": v.get("icon")})
			continue
		if groups.has(group):
			var entry: Dictionary = out[groups[group]]
			if entry.disabled and not v.get("disabled", false):
				entry.verb = i; entry.disabled = false; entry.reason = str(v.get("help", ""))
			continue
		groups[group] = out.size()
		out.append({"verb": i, "label": group, "disabled": v.get("disabled", false),
			"reason": str(v.get("reason", v.get("help", ""))), "icon": v.get("group_icon")})
	return out

## Turns a verb into the existing tool with the selection as its draft.
## Review and submission are unchanged; nothing is sent here.
func choose_verb(index: int) -> void:
	if index < 0 or index >= verbs.size() or not pending.is_empty() or first_corner != null: return
	var v: Dictionary = verbs[index]
	if v.get("disabled", false):
		inspector.text = str(v.get("reason", "This action is unavailable."))
		return
	if v.id == "progress":
		var ids: Array = v.get("plans", [])
		clear_selection()
		ui.selected_id = str(ids[0]) if not ids.is_empty() else ""
		ui.choose_family("Plans")
		return
	var definition: Dictionary = {}
	for t in tools:
		if str(t.id) == str(v.tool): definition = t
	if definition.is_empty(): return
	var a: Dictionary = selection.a.duplicate()
	var b: Dictionary = selection.b.duplicate()
	var family: String = ui.tool_family(definition)
	if family != "Plans" and family != ui.family: ui.choose_family(family)
	choose_tool(str(v.tool))
	if tool != str(v.tool): return
	first_corner = a
	last_corner = b
	refresh_draft()
	inspector.text = "Review the footprint, then submit. Workers have not been instructed."

## Where the strip sits: beside the selection's far corner, in screen space.
func selection_point() -> Vector2:
	if selection.is_empty() or camera == null: return Vector2.ZERO
	var x := maxf(selection.a.x, selection.b.x) + 0.5
	var z := minf(selection.a.z, selection.b.z) - 0.5
	return camera.unproject_position(Vector3(x, level + 30.1, -z))

func _draw_selection() -> void:
	if selection.is_empty() or int(selection.a.y) != level: return
	var left := minf(selection.a.x, selection.b.x) - 0.5
	var right := maxf(selection.a.x, selection.b.x) + 0.5
	var north := minf(selection.a.z, selection.b.z) - 0.5
	var south := maxf(selection.a.z, selection.b.z) + 0.5
	var material := _colour(Color(1.0, 0.85, 0.35))
	_planes(preview, [Vector3((left + right) * 0.5, level + 30.12, -north),
		Vector3((left + right) * 0.5, level + 30.12, -south)], material, right - left, 0.06)
	_planes(preview, [Vector3(left, level + 30.12, -(north + south) * 0.5),
		Vector3(right, level + 30.12, -(north + south) * 0.5)], material, 0.06, south - north)

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
		if id != "inspect": clear_selection()
		_update_materials(material_catalog)
		inspector.text = str(tool_definition().get("help", "Select a cell." if id == "inspect" else "Choose two corners. Selecting does not submit work."))
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
	if definition.has("width") and abs(int(first_corner.x - last_corner.x)) + 1 != int(definition.width): return false
	if definition.has("depth") and abs(int(first_corner.z - last_corner.z)) + 1 != int(definition.depth): return false
	if not str(definition.get("material", "")).is_empty():
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
	if tool == "workshop":
		summary += "\nRequires 3 x 3: station, barrel, chest, ledger and torch."
		if build_material.selected >= 0 and build_material.selected < build_materials.size():
			summary += "\n" + str(build_materials[build_material.selected].title)
		else:
			summary += "\nChoose a workshop type before submitting."
		summary += "\nVisit the ledger for keeper and production orders."
	if tool_definition().get("single", false) and first_corner != last_corner: summary += "\nChoose the same cell for both corners."
	if y != level: summary += "\nReturn to level %d to edit or submit." % y
	if not pending.is_empty(): summary += "\nSending. Retry is safe; it does not create another order."
	return summary

func refresh_draft() -> void:
	if first_corner != null and int(first_corner.y) == level:
		_preview_box(last_corner if last_corner != null else first_corner)
	else:
		_clear_children(preview)
		_draw_selection()
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
	elif not selection.is_empty(): clear_selection()
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
			elif ui.verb_strip.visible and ui.first_verb() != null: ui.first_verb().grab_focus()
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
			if event.keycode in [KEY_ENTER, KEY_KP_ENTER]:
				extend_selection = event.shift_pressed
				select_cell(cursor)
				extend_selection = false
			else: show_cursor()
		elif event.keycode >= KEY_1 and event.keycode <= KEY_6 and ui.verb_strip.visible:
			ui.press_verb(event.keycode - KEY_1)
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
			if not touch_active:
				extend_selection = event.shift_pressed
				select_cell(_cell(event.position))
				extend_selection = false
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
