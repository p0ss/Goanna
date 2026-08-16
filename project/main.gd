extends Node3D

var client: GoannaClient
var cam: Camera3D
var t := 0.0
var last_print := -1.0
var placed := false
var yaw := 0.0
var pitch := 0.0
var speed := 12.0
var shots_done := false
var fly_mode := false
var walk_started := false

func _ready() -> void:
	client = GoannaClient.new()
	add_child(client)
	print(client.hello())
	print(client.luanti_version())

	cam = Camera3D.new()
	cam.fov = 70
	cam.far = 1000
	add_child(cam)
	cam.current = true

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, 35, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 250
	add_child(sun)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.36, 0.55, 0.85)
	sm.sky_horizon_color = Color(0.72, 0.80, 0.90)
	sm.ground_bottom_color = Color(0.25, 0.22, 0.20)
	sm.ground_horizon_color = Color(0.72, 0.80, 0.90)
	sky.sky_material = sm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 1.1
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	e.sdfgi_enabled = true
	e.sdfgi_cascades = 6
	e.sdfgi_min_cell_size = 0.5
	e.ssao_enabled = true
	e.ssao_intensity = 1.4
	e.ssil_enabled = true
	e.glow_enabled = true
	e.glow_intensity = 0.3
	e.fog_enabled = true
	e.fog_light_color = Color(0.72, 0.80, 0.90)
	e.fog_density = 0.0004
	e.fog_sky_affect = 0.15
	e.fog_aerial_perspective = 0.5
	env.environment = e
	add_child(env)

	var host := OS.get_environment("GOANNA_HOST")
	if host == "":
		host = "127.0.0.1"
	var port := int(OS.get_environment("GOANNA_PORT")) if OS.get_environment("GOANNA_PORT") != "" else 30000
	var pname := OS.get_environment("GOANNA_NAME")
	if pname == "":
		pname = "goanna"
	print("connecting to ", host, ":", port, " as ", pname)
	client.connect_to(host, port, pname, OS.get_environment("GOANNA_PASS"))
	if OS.get_environment("GOANNA_SHOT") == "":
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * 0.15
		pitch = clamp(pitch - event.relative.y * 0.15, -89, 89)
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED)
	if event is InputEventKey and event.pressed and event.keycode == KEY_F:
		fly_mode = not fly_mode
		print("fly mode: ", fly_mode)

func _process(delta: float) -> void:
	t += delta
	var s: Dictionary = client.status()
	if not placed and s.get("state") == "ready":
		var p: Vector3 = client.server_player_position()
		cam.position = p + Vector3(0, 1.6, 0)
		placed = true
		print("camera placed at ", cam.position)
	if placed and not fly_mode:
		var keys := {
			"up": Input.is_key_pressed(KEY_W), "down": Input.is_key_pressed(KEY_S),
			"left": Input.is_key_pressed(KEY_A), "right": Input.is_key_pressed(KEY_D),
			"jump": Input.is_key_pressed(KEY_SPACE), "sneak": Input.is_key_pressed(KEY_SHIFT),
			"aux1": Input.is_key_pressed(KEY_E),
		}
		if OS.get_environment("GOANNA_WALKTEST") != "":
			keys = _walktest_keys()
		var r: Dictionary = client.step_player(delta, keys, pitch, yaw)
		if r.has("eye_pos"):
			cam.position = r["eye_pos"]
			cam.rotation_degrees = Vector3(pitch, yaw, 0)
	elif placed:
		# fly controls
		var dir := Vector3.ZERO
		var basis := Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0))
		if Input.is_key_pressed(KEY_W): dir -= basis.z
		if Input.is_key_pressed(KEY_S): dir += basis.z
		if Input.is_key_pressed(KEY_A): dir -= basis.x
		if Input.is_key_pressed(KEY_D): dir += basis.x
		if Input.is_key_pressed(KEY_SPACE): dir += Vector3.UP
		if Input.is_key_pressed(KEY_SHIFT): dir -= Vector3.UP
		var sp := speed * (3.0 if Input.is_key_pressed(KEY_CTRL) else 1.0)
		cam.position += dir.normalized() * sp * delta if dir.length() > 0 else Vector3.ZERO
		cam.rotation_degrees = Vector3(pitch, yaw, 0)
	client.poll_blocks(24)
	if t - last_print >= 1.0:
		last_print = t
		var extra := ""
		if placed and not fly_mode:
			var r: Dictionary = client.step_player(0.0, {}, pitch, yaw)
			extra = " | player %s ground=%s speed=%s g=%s free=%s climb=%s" % [str(r.get("pos", Vector3())), str(r.get("on_ground", false)), str(r.get("speed", Vector3())), str(r.get("gravity", 0)), str(r.get("free_move", false)), str(r.get("climbing", false))]
		print("[%5.1fs] %s | %s | media %d/%d | blocks recv %d meshed %d | mats %d%s" % [
			t, s.get("state"), s.get("message"), s.get("media_received", 0), s.get("media_announced", 0),
			s.get("blocks_received", 0), s.get("blocks_meshed", 0), s.get("materials", 0), extra])
	var shot := OS.get_environment("GOANNA_SHOT")
	if shot != "" and OS.get_environment("GOANNA_TOGGLETEST") != "":
		# walking mode, standing still, looking straight ahead: pillar appears 4 nodes in front
		client.poll_blocks(64)
		for st in [4.0, 5.5, 7.0, 8.5, 10.0, 11.5, 13.0]:
			if absf(t - st) < delta * 0.6:
				await RenderingServer.frame_post_draw
				var img := get_viewport().get_texture().get_image()
				var path: String = shot.path_join("toggle_%d.png" % int(round(t)))
				img.save_png(path)
				print("saved ", path)
		if t > 14.0:
			client.disconnect_from_server()
			get_tree().quit()
		return
	if shot != "" and OS.get_environment("GOANNA_WALKTEST") != "":
		if (absf(t - 5.0) < delta * 0.6) or (absf(t - 9.5) < delta * 0.6):
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var path: String = shot.path_join("walk_%d.png" % int(round(t)))
			img.save_png(path)
			print("saved ", path)
		if t > 11.0:
			client.disconnect_from_server()
			get_tree().quit()
		return
	if shot != "" and not shots_done and t > 8.0:
		shots_done = true
		await _shots(shot)
		client.disconnect_from_server()
		get_tree().quit()
	var limit := float(OS.get_environment("GOANNA_SMOKE")) if OS.get_environment("GOANNA_SMOKE") != "" else 0.0
	if limit > 0.0 and t > limit:
		client.disconnect_from_server()
		get_tree().quit()

func _walktest_keys() -> Dictionary:
	var hold_w := t > 4.0 and t < 9.0
	return {"up": hold_w, "down": false, "left": false, "right": false,
		"jump": t > 6.0 and t < 6.3, "sneak": false, "aux1": false}

func _shots(dir: String) -> void:
	fly_mode = true
	var base := cam.position
	var views := [
		["a_spawn", base + Vector3(0, 6, 14), base + Vector3(0, 0, -20)],
		["b_high", base + Vector3(30, 40, 30), base],
		["c_low", base + Vector3(-12, 2, 8), base + Vector3(20, -2, -20)],
	]
	for v in views:
		cam.position = v[1]
		cam.look_at(v[2], Vector3.UP)
		client.set_player_pose(cam.position, 0, 0)
		for i in 40:
			client.poll_blocks(64)
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path: String = dir.path_join(v[0] + ".png")
		img.save_png(path)
		print("saved ", path)
