extends Node3D

var client: GoannaClient
var ui: CanvasLayer
var cam: Camera3D
var sun: DirectionalLight3D
var moon: DirectionalLight3D
var env: WorldEnvironment
var sky_mat: ShaderMaterial
var sky_tex_cache := {}
var cloud_off := Vector2.ZERO
var cloud_speed := Vector2(-2.0, 0.0)
var cloud_height := 120.0
var t := 0.0
var last_print := -1.0
var placed := false
var yaw := 0.0
var pitch := 0.0
var speed := 12.0
# Look controls, set from the settings panel (game_ui) and saved in goanna.cfg.
var mouse_sensitivity := 0.15
var invert_mouse := false
var view_bobbing := 1.0        # walk-cycle camera bob, 0 = off
var _bob_phase := 0.0
var shots_done := false
var chest_opened := false
var fly_mode := false
var walk_started := false
var dig_down := false
var place_down := false
var place_pressed := false
var wield := 0
var selection_box: MeshInstance3D
var pointed: Dictionary = {}
var test_dig := false
var test_plc_pressed := false
var mob_target_id := -1
var mob_last_pos := Vector3.ZERO
var inv_before := {}
var fall_reported := false
var underwater := false
var headlight: OmniLight3D
var test_started := 0.0

func _ready() -> void:
	add_to_group("goanna_main")  # game_ui updates look controls through this group
	var cfg := ConfigFile.new()
	if cfg.load("user://goanna.cfg") == OK:
		mouse_sensitivity = float(cfg.get_value("settings", "mouse_sensitivity", mouse_sensitivity))
		invert_mouse = bool(cfg.get_value("settings", "invert_mouse", invert_mouse))
		view_bobbing = float(cfg.get_value("settings", "view_bobbing", view_bobbing))
	client = GoannaClient.new()
	add_child(client)
	# In-game UI (HUD, chat, inventory, formspecs, pause menu): project/ui/.
	ui = preload("res://ui/game_ui.tscn").instantiate()
	ui.client = client
	add_child(ui)
	print(client.hello())
	print(client.luanti_version())

	cam = Camera3D.new()
	cam.fov = 70
	cam.far = 1000
	add_child(cam)
	cam.current = true

	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, 35, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 400
	# Bevel chamfers meet the light at grazing angles; raise the normal bias
	# and soften the blend so the shadow edge does not flicker/acne on them.
	sun.shadow_normal_bias = 2.0
	sun.shadow_bias = 0.03
	sun.shadow_blur = 1.5
	add_child(sun)
	moon = DirectionalLight3D.new()
	moon.light_energy = 0.0
	moon.light_color = Color(0.6, 0.7, 1.0)
	moon.shadow_enabled = true
	moon.directional_shadow_max_distance = 400
	moon.shadow_normal_bias = 2.0
	moon.shadow_bias = 0.03
	add_child(moon)

	env = WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ShaderMaterial.new()
	sm.shader = load("res://shaders/sky.gdshader")
	sky_mat = sm
	sky.sky_material = sm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 1.1
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	# AGX plus a soft ambient fill reads washed out; grade it back.
	e.adjustment_enabled = true
	e.adjustment_saturation = 1.22
	e.adjustment_contrast = 1.07
	e.adjustment_brightness = 1.02
	e.sdfgi_enabled = true
	e.sdfgi_cascades = 6
	e.sdfgi_min_cell_size = 0.5
	e.sdfgi_energy = 1.4
	e.ssao_enabled = true
	e.ssao_intensity = 3.0
	e.ssao_radius = 1.5
	e.ssao_power = 1.6
	e.ssao_detail = 1.0
	e.ssao_light_affect = 0.5
	e.ssil_enabled = true
	e.ssil_intensity = 1.4
	e.glow_enabled = true
	e.glow_intensity = 0.3
	e.fog_enabled = true
	e.fog_light_color = Color(0.72, 0.80, 0.90)
	e.fog_density = 0.0007
	e.fog_sky_affect = 0.15
	e.fog_aerial_perspective = 0.5
	env.environment = e
	add_child(env)
	# Subtle head-light so caves are navigable rather than pitch black. Short
	# range and low energy, so it is negligible against daylight but lets you
	# see a few nodes underground. (A proper fix would feed Luanti's baked node
	# light as an ambient floor.)
	headlight = OmniLight3D.new()
	headlight.light_energy = 0.5
	headlight.omni_range = 9.0
	headlight.light_color = Color(1.0, 0.96, 0.9)
	headlight.shadow_enabled = false
	add_child(headlight)

	var host := OS.get_environment("GOANNA_HOST")
	if host == "":
		host = "127.0.0.1"
	var port := int(OS.get_environment("GOANNA_PORT")) if OS.get_environment("GOANNA_PORT") != "" else 30000
	var pname := OS.get_environment("GOANNA_NAME")
	if pname == "":
		pname = "goanna"
	print("connecting to ", host, ":", port, " as ", pname)
	client.connect_to(host, port, pname, OS.get_environment("GOANNA_PASS"))
	if OS.get_environment("GOANNA_TOD") != "":
		client.set_time_of_day_override(float(OS.get_environment("GOANNA_TOD")))
	if OS.get_environment("GOANNA_SHOT") == "":
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

# Bob the camera along a walk cycle while moving on the ground: vertical at
# twice the stride frequency, a gentle side sway at the stride frequency,
# amplitude scaled by speed and the view_bobbing setting.
func _apply_view_bob(r: Dictionary, delta: float) -> void:
	if view_bobbing <= 0.0 or not r.get("on_ground", false):
		return
	var sp: Vector3 = r.get("speed", Vector3.ZERO)
	var hspeed := Vector2(sp.x, sp.z).length()
	if hspeed < 0.5:
		return
	_bob_phase += delta * (6.0 + hspeed)
	var amp := view_bobbing * 0.045 * clampf(hspeed / 4.0, 0.0, 1.0)
	var basis := cam.global_transform.basis
	cam.position += basis.x * (cos(_bob_phase) * amp) + Vector3.UP * (absf(sin(_bob_phase * 2.0)) * amp)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		if event.button_index == MOUSE_BUTTON_LEFT:
			dig_down = event.pressed
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			place_down = event.pressed
			if event.pressed:
				place_pressed = true
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_set_wield((wield + 7) % 8)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_wield((wield + 1) % 8)
	if event is InputEventKey and event.pressed and event.keycode >= KEY_1 and event.keycode <= KEY_8:
		_set_wield(event.keycode - KEY_1)
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * mouse_sensitivity
		var dy: float = event.relative.y * mouse_sensitivity * (1.0 if invert_mouse else -1.0)
		pitch = clamp(pitch + dy, -89, 89)
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED)
	if event is InputEventKey and event.pressed and event.keycode == KEY_F:
		fly_mode = not fly_mode
		print("fly mode: ", fly_mode)

func _process(delta: float) -> void:
	t += delta
	_apply_sky()
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
		test_dig = false
		test_plc_pressed = false
		_test_hooks(keys)
		var ui_blocks: bool = ui != null and ui.blocks_input()
		if ui_blocks:
			for k in keys:
				keys[k] = false
		var r: Dictionary = client.step_player(delta, keys, pitch, yaw)
		if r.has("eye_pos"):
			cam.position = r["eye_pos"]
			cam.rotation_degrees = Vector3(pitch, yaw, 0)
			_apply_view_bob(r, delta)
		var dig := (dig_down or test_dig) and not ui_blocks
		var plc := place_down and not ui_blocks
		var plc_pressed := (place_pressed or test_plc_pressed) and not ui_blocks
		if OS.get_environment("GOANNA_DIGTEST") != "":
			# look down at the ground in front (hand-diggable, timed) and use slot 4 (light14) to place
			pitch = -55.0
			if absf(t - 3.0) < delta * 0.6:
				_set_wield(4)
			dig = t > 4.0 and t < 4.9
			plc_pressed = absf(t - 8.5) < delta * 0.6 or absf(t - 9.5) < delta * 0.6
			plc = plc_pressed
			if OS.get_environment("GOANNA_SHOT") != "" and absf(t - 4.45) < delta * 0.6:
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(OS.get_environment("GOANNA_SHOT").path_join("dig_crack.png"))
				print("saved crack shot")
		if OS.get_environment("GOANNA_CHESTTEST") != "":
			# sweep the view until a chest is pointed, right-click it once, report
			# the formspec it opened, answer it
			pitch = -25.0
			if t > 3.0 and not chest_opened:
				yaw += 3.0
				if String(pointed.get("node_name", "")).contains("chest"):
					plc_pressed = true
					plc = true
					chest_opened = true
					print("chest test: pressing place at yaw ", yaw, " pointed ", pointed)
			# the in-game UI consumes take_shown_formspecs() and draws the form;
			# a screenshot shows the result
			if OS.get_environment("GOANNA_SHOT") != "" and absf(t - 8.0) < delta * 0.6:
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(OS.get_environment("GOANNA_SHOT").path_join("chest_form.png"))
				print("saved chest shot")
			if t > 12.0:
				client.disconnect_from_server()
				get_tree().quit()
		pointed = client.step_interact(delta, dig, plc, plc_pressed, keys["sneak"])
		place_pressed = false
		_update_selection_box()
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
	client.update_lights(cam.position, 48)
	client.update_motes(cam.position, 32)
	client.sync_entities(delta)
	_update_environment_extras()
	if t - last_print >= 1.0:
		last_print = t
		if OS.get_environment("GOANNA_DUMPSKY") != "" and int(t) == 3:
			print("SKY ", JSON.stringify(client.sky_state()))
		if OS.get_environment("GOANNA_DUMPUI") != "" and int(t) == 5:
			for dn in client.detached_inventory_names():
				var ds: Dictionary = client.inventory_state_at("detached:" + dn)
				print("detached ", dn, " lists ", (ds["lists"] as Dictionary).keys())
			if OS.get_environment("GOANNA_NODEMETA") != "":
				print("nodemeta ", client.inventory_state_at("nodemeta:" + OS.get_environment("GOANNA_NODEMETA")))
		if OS.get_environment("GOANNA_DUMPUI") != "":
			if int(t) == 2:
				client.send_chat("hello from goanna")
			for line in client.take_chat():
				print("CHAT ", line)
			if int(t) == 4:
				var hud: Dictionary = client.hud_state()
				print("HUD flags=%d hotbar=%d elems=%d" % [hud.get("flags", 0), hud.get("hotbar_itemcount", 0), (hud.get("elements", []) as Array).size()])
				for e in hud.get("elements", []):
					print("  HUD ", e.get("type"), " ", e.get("name"), " ", e.get("text"), " n=", e.get("number"))
				var inv: Dictionary = client.inventory_state()
				for k in (inv.get("lists", {}) as Dictionary).keys():
					var items: Array = inv["lists"][k]
					var names := []
					for it in items:
						if it.get("name", "") != "": names.append("%s x%d" % [it["name"], it["count"]])
					print("  INV %s (%d slots): %s" % [k, items.size(), ", ".join(names)])
				var tex := client.texture("default_dirt.png^default_grass_side.png")
				print("  TEX grass side: ", tex != null, " ", (tex.get_size() if tex else Vector2()))
				print("  HP ", client.hp(), " breath ", client.breath())
		var extra := ""
		if placed and not fly_mode:
			var r: Dictionary = client.step_player(0.0, {}, pitch, yaw)
			extra = " | player %s ground=%s | pointed %s %s dig=%s prog=%.2f crack=%d" % [str(r.get("pos", Vector3())), str(r.get("on_ground", false)), str(pointed.get("type", "?")), str(pointed.get("node_name", pointed.get("object_name", ""))), str(pointed.get("digging", false)), float(pointed.get("progress", 0.0)), int(pointed.get("crack_level", -1))]
		print("[%5.1fs] %s | %s | media %d/%d | blocks recv %d meshed %d | mats %d | lights %d%s" % [
			t, s.get("state"), s.get("message"), s.get("media_received", 0), s.get("media_announced", 0),
			s.get("blocks_received", 0), s.get("blocks_meshed", 0), s.get("materials", 0), s.get("node_lights", 0), extra])
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

# GOANNA_MANTLETEST=1: build a one-block step in front (needs give/place), walk
# into it, and report whether the player rose a block. Simpler: teleport to a
# known ledge on devtest and walk into it.
var _mantle_y0 := 0.0
var _mantle_done := false
func _mantle_test(keys: Dictionary) -> bool:
	if OS.get_environment("GOANNA_MANTLETEST") == "":
		return false
	# Build a clean one-block step in front on the flat devtest sand, then walk
	# north into it. yaw 180 faces -Z (Luanti +Z); the step is placed one node
	# ahead by pointing down at the sand and pressing place.
	yaw = 180.0
	if _mantle_y0 == 0.0:
		_mantle_y0 = -2.0
	if int(t) == 4:
		_set_wield(5)  # basenodes:dirt_with_grass in the devtest hotbar
	# aim down-forward and place one block one node ahead to make a step
	if t > 4.5 and t < 6.0:
		pitch = -55.0
		if absf(t - 5.0) < get_process_delta_time() * 0.6 or absf(t - 5.5) < get_process_delta_time() * 0.6:
			test_plc_pressed = true
	# now walk forward on the flat into the placed step
	if t >= 6.5 and t < 10.0:
		pitch = 0.0
		keys["up"] = true
		if _mantle_y0 < -1.0:
			_mantle_y0 = client.server_player_position().y
	if t > 10.5 and not _mantle_done:
		_mantle_done = true
		var dy := client.server_player_position().y - _mantle_y0
		print("mantletest: y rose %.2f nodes over the walk (mantle=%s)" % [dy, str(OS.get_environment("GOANNA_MANTLE"))])
		client.disconnect_from_server()
		get_tree().quit()
	return true

func _walktest_keys() -> Dictionary:
	# Hold W from 4 to 7s, then release. With GOANNA_WALKRELEASE=1, report how
	# far the player drifts in the 3s after release (should be ~0).
	var hold_w := t > 4.0 and t < 7.0
	if OS.get_environment("GOANNA_WALKRELEASE") != "":
		if absf(t - 7.0) < get_process_delta_time() * 0.6:
			_walk_release_pos = client.server_player_position()
		if t > 10.0 and not _walk_release_done:
			_walk_release_done = true
			var drift := (client.server_player_position() - _walk_release_pos).length()
			print("walkrelease: drifted %.2f nodes in 3s after releasing W" % drift)
			client.disconnect_from_server()
			get_tree().quit()
	return {"up": hold_w, "down": false, "left": false, "right": false,
		"jump": t > 6.0 and t < 6.3, "sneak": false, "aux1": false}

func _aim_at(target: Vector3) -> void:
	var d := (target - cam.position)
	if d.length() < 0.001:
		return
	d = d.normalized()
	yaw = rad_to_deg(atan2(-d.x, -d.z))
	pitch = rad_to_deg(asin(clamp(d.y, -1.0, 1.0)))

func _nearest_entity(sub: String) -> Dictionary:
	var best := {}
	var bestd := 1e9
	for e in client.entity_list():
		if not (String(e["name"]).contains(sub) or String(e["mesh"]).contains(sub)):
			continue
		var dd: float = (Vector3(e["position"]) - cam.position).length()
		if dd < bestd:
			bestd = dd
			best = e
	return best

func _main_list() -> Array:
	var inv: Dictionary = client.inventory_state()
	return (inv.get("lists", {}) as Dictionary).get("main", [])

# Test hooks: teleport next to a target instead of walking (walking a straight
# line into trees is what made the first mob test fail). Needs the teleport
# privilege on the test server. Godot z is mirrored relative to Luanti.
var test_teleported := 0.0
var _anim_reported := false
var _walk_release_pos := Vector3.ZERO
var _walk_release_done := false
func _teleport_near(target: Vector3) -> bool:
	if test_teleported > 0.0:
		return t - test_teleported > 2.0
	test_teleported = t
	var p := target + Vector3(1.5, 0.5, 1.5)
	client.send_chat("/teleport %.1f %.1f %.1f" % [p.x, p.y, -p.z])
	print("test: teleporting next to target at ", target)
	return false

# Development aid: GOANNA_ANIMPROBE=<substr> samples the "frame" field of the
# nearest matching entity every physics frame and reports frames advanced per
# second, so an animation-speed bug can be measured instead of eyeballed.
var _anim_samples: Array = []
func _anim_probe(delta: float) -> void:
	var sub := OS.get_environment("GOANNA_ANIMPROBE")
	if sub == "":
		return
	var e := _nearest_entity(sub)
	if not e.is_empty():
		_anim_samples.append({"t": t, "id": int(e["id"]), "frame": float(e.get("frame", 0.0)), "pos": Vector3(e["position"])})
	if t > 12.0 and not _anim_reported:
		_anim_reported = true
		# group by id, report frame span and moved distance
		var by_id := {}
		for smp in _anim_samples:
			by_id.get_or_add(smp["id"], []).append(smp)
		for id in by_id:
			var arr: Array = by_id[id]
			var fmin: float = arr[0]["frame"]
			var fmax := fmin
			var moved := 0.0
			var resets := 0
			for i in range(1, arr.size()):
				fmin = minf(fmin, arr[i]["frame"])
				fmax = maxf(fmax, arr[i]["frame"])
				moved += (arr[i]["pos"] - arr[i - 1]["pos"]).length()
				if arr[i]["frame"] < arr[i - 1]["frame"] - 0.01:
					resets += 1  # a loop wrap or a jitter reset
			var span: float = arr[-1]["t"] - arr[0]["t"]
			print("animprobe id=%d range %.1f..%.1f over %.1fs, %d frame-decreases (%.1f/s), moved %.1f nodes, %d samples" % [id, fmin, fmax, span, resets, resets / maxf(span, 0.01), moved, arr.size()])
			# raw trace at ~10 Hz so the sawtooth is visible
			var trace := ""
			var last_t := -1.0
			for smp in arr:
				if smp["t"] - last_t >= 0.1:
					last_t = smp["t"]
					trace += "%.1f " % smp["frame"]
			print("animprobe id=%d trace: %s" % [id, trace])
		client.disconnect_from_server()
		get_tree().quit()

var _click_sent := false
# GOANNA_CLICKTEST=1: exercise the real left-mouse dig path (dig_down), not the
# test_dig shortcut, to see whether a click actually starts a dig.
func _click_test() -> bool:
	if OS.get_environment("GOANNA_CLICKTEST") == "":
		return false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	pitch = -80.0
	if int(t) == 3 and not _click_sent:
		_click_sent = true
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = true
		Input.parse_input_event(ev)
		print("clicktest: injected left-down; mouse_mode=", Input.get_mouse_mode())
	if absf(t - round(t)) < get_process_delta_time() * 0.6:
		print("clicktest: t=%d mouse_mode=%d dig_down=%s ui_blocks=%s" % [int(t), Input.get_mouse_mode(), str(dig_down), str(ui != null and ui.blocks_input())])
	if t > 12.0:
		client.disconnect_from_server()
		get_tree().quit()
	return true

func _test_hooks(keys: Dictionary) -> void:
	if _click_test():
		return
	_anim_probe(get_process_delta_time())
	if _mantle_test(keys):
		return
	# GOANNA_FALLTEST=1: pillar-jump then fall; report hp drop and server damage line.
	if OS.get_environment("GOANNA_FALLTEST") != "":
		# grant fly+teleport, go up high, then drop and land
		if int(t) == 2 and test_started == 0.0:
			test_started = 1.0
			client.send_chat("/grant goanna all")
		if int(t) == 4 and test_started == 1.0:
			test_started = 2.0
			print("falltest: hp before ", client.hp())
			client.send_chat("/teleport 20 45 26")
		if t > 5.0:
			# stop holding anything; just fall under gravity
			for k in keys: keys[k] = false
		if client.hp() < 20 and not fall_reported:
			fall_reported = true
			print("falltest: hp after landing ", client.hp(), " at t ", t)
		if t > 20.0:
			print("falltest: final hp ", client.hp(), " (no damage taken)" if not fall_reported else "")
			client.disconnect_from_server()
			get_tree().quit()
		return
	# GOANNA_MOBTEST=<sub>: aim at nearest mob, walk to it, punch until it dies.
	var mob := OS.get_environment("GOANNA_MOBTEST")
	if mob != "":
		if inv_before.is_empty() and t > 2.0:
			inv_before = {"main": _main_list().duplicate(true)}
		var e := _nearest_entity(mob)
		if mob_target_id >= 0:
			# is our target still alive?
			var alive := false
			for x in client.entity_list():
				if int(x["id"]) == mob_target_id:
					alive = true
					mob_last_pos = Vector3(x["position"])
			if not alive:
				if test_started == 0.0:
					test_started = t
					print("mobtest: target ", mob_target_id, " gone at ", t, " main before ", inv_before.get("main", []).size())
				# walk onto the drop then report
				_aim_at(mob_last_pos)
				if (mob_last_pos - cam.position).length() > 1.2:
					keys["up"] = true
				if t - test_started > 5.0:
					print("mobtest: main after ", _main_list())
					client.disconnect_from_server()
					get_tree().quit()
				return
		if e.is_empty():
			return
		mob_target_id = int(e["id"])
		mob_last_pos = Vector3(e["position"])
		_aim_at(mob_last_pos + Vector3(0, 0.6, 0))
		var dist: float = (mob_last_pos - cam.position).length()
		if dist > 3.0:
			if _teleport_near(mob_last_pos):
				keys["up"] = true
		else:
			test_dig = true
		return
	# GOANNA_DIGDOWNTEST=1: aim straight down and dig the block underfoot; the
	# most reliable timed dig (always points at a solid node).
	if OS.get_environment("GOANNA_DIGDOWNTEST") != "":
		pitch = -89.0
		test_dig = t > 3.0 and t < 13.0
		if t > 14.0:
			client.disconnect_from_server()
			get_tree().quit()
		return
	# GOANNA_MINETEST=1: pitch down at the node in front, dig, report inventory delta.
	if OS.get_environment("GOANNA_MINETEST") != "":
		pitch = -75.0
		if int(t) == 2 and test_teleported == 0.0:
			test_teleported = 1.0
			# stand on a known solid spot (grass near the cow field) and dig down
			client.send_chat("/teleport 129 28 0")
		if int(t) == 3:
			_set_wield(int(OS.get_environment("GOANNA_MINE_SLOT")) if OS.get_environment("GOANNA_MINE_SLOT") != "" else 0)
		if inv_before.is_empty() and t > 2.0:
			inv_before = {"main": _main_list().duplicate(true)}
		test_dig = t > 4.0 and t < 11.0
		if t > 12.0:
			print("minetest: before ", inv_before.get("main", []))
			print("minetest: after ", _main_list())
			client.disconnect_from_server()
			get_tree().quit()
		return
	# GOANNA_USETEST=<sub>: aim at nearest match, right-click once, report formspecs + inventory delta.
	var use := OS.get_environment("GOANNA_USETEST")
	if use != "":
		var e2 := _nearest_entity(use)
		if inv_before.is_empty() and t > 2.0:
			inv_before = {"main": _main_list().duplicate(true)}
		if not e2.is_empty():
			var target: Vector3 = Vector3(e2["position"])
			_aim_at(target + Vector3(0, 0.6, 0))
			# get into reach first (vanilla hand reach is 4 nodes)
			if test_started == 0.0 and (target - cam.position).length() > 3.5:
				if _teleport_near(target):
					keys["up"] = true
			elif test_started == 0.0 and t > 3.0:
				test_started = t
				test_plc_pressed = true
				print("usetest: right-clicking ", e2["name"], " id ", e2["id"], " at ", (target - cam.position).length(), " nodes")
		for f in client.take_shown_formspecs():
			print("usetest: formspec name=", f["formname"], " context=", f["context"], " len=", String(f["formspec"]).length())
		if test_started > 0.0 and t - test_started > 3.0:
			print("usetest: main after ", _main_list())
			client.disconnect_from_server()
			get_tree().quit()
		return

func _shots(dir: String) -> void:
	fly_mode = true
	if ui:
		ui.visible = false  # keep the HUD/inventory out of rendering test shots
	var base := cam.position
	if OS.get_environment("GOANNA_AIM_ENTITY") != "":
		# GOANNA_AIM_ENTITY=n (the first n visible entities) or a name
		# substring; close and far views, two frames apart so animation shows.
		var sel := OS.get_environment("GOANNA_AIM_ENTITY")
		var picked: Array = []
		for e in client.entity_list():
			if sel.is_valid_int():
				if picked.size() < int(sel):
					picked.append(e)
			elif String(e["name"]).contains(sel) or String(e["mesh"]).contains(sel):
				picked.append(e)
		for k in picked.size():
			var e: Dictionary = picked[k]
			var target: Vector3 = e["position"]
			print("aiming at ", e)
			var views_e := [["e%d_entity" % k, target + Vector3(1.5, 1.2, 4.0), target + Vector3(0, 0.8, 0)],
				["e%d_entity_far" % k, target + Vector3(-6, 3, 8), target]]
			for v in views_e:
				cam.position = v[1]
				cam.look_at(v[2], Vector3.UP)
				pitch = cam.rotation_degrees.x
				yaw = cam.rotation_degrees.y
				for suffix in ["", "_b"]:
					for i in 30:
						client.poll_blocks(64)
						client.sync_entities(get_process_delta_time())
						await get_tree().process_frame
					await RenderingServer.frame_post_draw
					var img := get_viewport().get_texture().get_image()
					var path: String = dir.path_join(v[0] + suffix + ".png")
					img.save_png(path)
					print("saved ", path, " frame ", client.entity_list().filter(func(x): return x["id"] == e["id"]))
		return
	var views := [
		["a_spawn", base + Vector3(0, 6, 14), base + Vector3(0, 0, -20)],
		["b_high", base + Vector3(30, 40, 30), base],
		["c_low", base + Vector3(-12, 2, 8), base + Vector3(20, -2, -20)],
	]
	# GOANNA_VIEW="name:x,y,z:pitch,yaw[;name:...]" replaces the fixed views.
	# Positions are relative to the spawn eye position, or absolute with a
	# leading "@"; angles in degrees.
	var custom := OS.get_environment("GOANNA_VIEW")
	if custom != "":
		views = []
		for spec in custom.split(";", false):
			var parts := spec.split(":")
			var pos_str: String = parts[1]
			var origin := base
			if pos_str.begins_with("@"):
				pos_str = pos_str.substr(1)
				origin = Vector3.ZERO
			var p := pos_str.split(",")
			var a := parts[2].split(",")
			views.append([parts[0], origin + Vector3(float(p[0]), float(p[1]), float(p[2])),
				Vector2(float(a[0]), float(a[1]))])
	for v in views:
		cam.position = v[1]
		if v[2] is Vector2:
			pitch = v[2].x
			yaw = v[2].y
		else:
			cam.look_at(v[2], Vector3.UP)
			pitch = cam.rotation_degrees.x
			yaw = cam.rotation_degrees.y
		client.set_player_pose(cam.position, 0, 0)
		var warm: int = 150 if OS.get_environment("GOANNA_MOTES") != "" else 40
		for i in warm:
			client.poll_blocks(64)
			client.update_motes(cam.position, 32)
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path: String = dir.path_join(v[0] + ".png")
		img.save_png(path)
		print("saved ", path)


# Per-frame environment extras: the cave head-light follows the camera, and
# the fog switches to a dense underwater tint while the eye is submerged.
func _update_environment_extras() -> void:
	if headlight:
		headlight.global_position = cam.global_position
	# scroll the cloud layer by the server's cloud speed
	cloud_off += cloud_speed * get_process_delta_time() * 0.004
	sky_mat.set_shader_parameter("cloud_offset", cloud_off)
	sky_mat.set_shader_parameter("cloud_plane_h", clampf(cloud_height - cam.position.y, 10.0, 400.0))
	var under: bool = client.is_underwater(cam.position)
	if under == underwater:
		return
	underwater = under
	var e := env.environment
	if under:
		# Murky blue-green underwater fog; you can tell you are submerged and
		# the view shortens the way it should.
		e.fog_enabled = true
		e.fog_light_color = Color(0.10, 0.28, 0.34)
		e.fog_density = 0.12
		e.fog_aerial_perspective = 0.0
		e.fog_sky_affect = 1.0
		# Light shafts: sun scattering through the participating water volume.
		# Moderate anisotropy and density: pushing either too hard shows the
		# fog volume's depth slices as bands.
		e.volumetric_fog_enabled = true
		e.volumetric_fog_density = 0.09
		e.volumetric_fog_albedo = Color(0.25, 0.55, 0.62)
		e.volumetric_fog_anisotropy = 0.72
		e.volumetric_fog_length = 48.0
	else:
		# Restore the surface fog from the current sky state.
		_apply_sky()

# Map Luanti's sky/lighting state onto Godot's sun, sky and fog. Colours and the
# day/dawn/night scheme are the server's (or Luanti's defaults); the blend by
# sun elevation approximates Sky::update in the vanilla client.
func _apply_sky() -> void:
	var st: Dictionary = client.sky_state()
	if st.is_empty() or not st.has("sun_direction"):
		return
	var sun_dir: Vector3 = st["sun_direction"]
	var moon_dir: Vector3 = st["moon_direction"]
	var e := env.environment
	var sky: Dictionary = st["sky"]
	var elev: float = sun_dir.y  # 1 = overhead, <0 below horizon
	# --- sun and moon lights ---
	# At the zenith the direction is parallel to UP, so pick another up vector.
	if sun_dir.length() > 0.001:
		var up := Vector3.UP if absf(sun_dir.y) < 0.999 else Vector3.FORWARD
		sun.transform = Transform3D(Basis.looking_at(-sun_dir, up), Vector3.ZERO)
	if moon_dir.length() > 0.001:
		var up := Vector3.UP if absf(moon_dir.y) < 0.999 else Vector3.FORWARD
		moon.transform = Transform3D(Basis.looking_at(-moon_dir, up), Vector3.ZERO)
	var day: float = smoothstep(-0.02, 0.18, elev)
	var warm: float = 1.0 - smoothstep(0.0, 0.32, elev)
	sun.light_color = Color(1.0, 0.98, 0.94).lerp(Color(1.0, 0.62, 0.32), warm)
	sun.light_energy = lerp(0.0, 1.5, day)
	sun.visible = sun.light_energy > 0.01
	var moon_up: float = smoothstep(-0.02, 0.15, moon_dir.y) * (1.0 - day)
	moon.light_energy = 0.12 * moon_up
	moon.visible = moon.light_energy > 0.005
	var shadow_intensity: float = st["lighting"]["shadow_intensity"]
	# Luanti servers set 0..1; 0 means "not requested" for old games -> keep shadows but soft.
	sun.shadow_opacity = 1.0 if shadow_intensity <= 0.0 else clamp(shadow_intensity, 0.2, 1.0)
	moon.shadow_opacity = sun.shadow_opacity
	# --- sky colours: blend day / dawn / night like the vanilla sky ---
	var dawn: float = clamp(1.0 - abs(elev) / 0.22, 0.0, 1.0)
	var night: float = smoothstep(0.02, -0.25, elev)
	var day_w: float = clamp(1.0 - dawn - night, 0.0, 1.0)
	var top: Color = sky["day_sky"] * day_w + sky["dawn_sky"] * dawn + sky["night_sky"] * night
	var hor: Color = sky["day_horizon"] * day_w + sky["dawn_horizon"] * dawn + sky["night_horizon"] * night
	if str(sky["type"]) == "plain":
		top = sky["bgcolor"]; hor = sky["bgcolor"]
	sky_mat.set_shader_parameter("sky_top", top)
	sky_mat.set_shader_parameter("sky_horizon", hor)
	sky_mat.set_shader_parameter("ground_color", hor.darkened(0.6))
	sky_mat.set_shader_parameter("sun_dir", sun_dir.normalized() if sun_dir.length() > 0.001 else Vector3.UP)
	sky_mat.set_shader_parameter("moon_dir", moon_dir.normalized() if moon_dir.length() > 0.001 else Vector3.DOWN)
	sky_mat.set_shader_parameter("sun_visible", bool(st["sun"]["visible"]))
	sky_mat.set_shader_parameter("moon_visible", bool(st["moon"]["visible"]))
	sky_mat.set_shader_parameter("sun_size", 0.045 * float(st["sun"]["scale"]))
	sky_mat.set_shader_parameter("moon_size", 0.02 * float(st["moon"]["scale"]))
	sky_mat.set_shader_parameter("sun_tint", sun.light_color)
	_set_sky_disc("sun_tex", "sun_use_tex", str(st["sun"]["texture"]))
	_set_sky_disc("moon_tex", "moon_use_tex", str(st["moon"]["texture"]))
	# stars: the server gives colour, count and how much survives daylight
	var stars: Dictionary = st["stars"]
	var star_col: Color = stars["color"]
	var star_vis: float = (1.0 if bool(stars["visible"]) else 0.0) * lerp(1.0, float(stars["day_opacity"]), day)
	sky_mat.set_shader_parameter("star_opacity", star_col.a * star_vis)
	sky_mat.set_shader_parameter("star_color", star_col)
	sky_mat.set_shader_parameter("star_density", clamp(float(stars["count"]) / 3000.0, 0.05, 0.6))
	# clouds: density/colour here, scroll and height per frame
	var clouds: Dictionary = st["clouds"]
	var ccol: Color = clouds["color_bright"]
	ccol.a = clamp(0.55 + 0.45 * float(clouds["density"]), 0.0, 1.0)
	# clouds go dark at night, not glowing grey
	var cdim: float = lerp(1.0, 0.16, night)
	ccol = Color(ccol.r * cdim, ccol.g * cdim, ccol.b * cdim, ccol.a)
	sky_mat.set_shader_parameter("cloud_color", ccol)
	sky_mat.set_shader_parameter("cloud_coverage", clamp(float(clouds["density"]), 0.0, 0.95) if bool(sky.get("clouds", true)) else 0.0)
	var cs: Vector2 = clouds["speed"]
	cloud_speed = cs
	cloud_height = float(clouds["height"])
	# --- fog ---
	# While the eye is underwater, _update_environment_extras owns the fog and
	# the shaft volume; sky packets must not clobber them.
	if not underwater:
		var fog_col: Color = hor
		if str(sky["fog_tint_type"]) == "default":
			fog_col = fog_col.lerp(sky["fog_sun_tint"], 0.35 * dawn)
		var fc: Color = sky["fog_color"]
		if fc.a > 0.0:
			fog_col = fc
		e.fog_light_color = fog_col
		var fog_distance: float = sky["fog_distance"]
		if fog_distance > 0.0:
			e.fog_density = clamp(2.5 / fog_distance, 0.0006, 0.010)
		else:
			e.fog_density = 0.0007
	# --- ambient / grade from day-night ratio and server lighting ---
	var ratio: float = st["day_night_ratio"]
	e.ambient_light_energy = lerp(0.16, 0.6, ratio)
	e.background_energy_multiplier = lerp(0.25, 1.15, ratio)
	var lighting: Dictionary = st["lighting"]
	# Server saturation on top of our base grade, not instead of it.
	e.adjustment_saturation = clamp(1.12 * float(lighting["saturation"]), 0.0, 2.0)
	e.tonemap_exposure = clamp(1.0 + float(lighting["exposure_correction"]) * 0.25, 0.3, 3.0)
	e.glow_intensity = clamp(0.3 + float(lighting["bloom_intensity"]) * 2.0, 0.0, 2.0)
	# Luanti's volumetric_light_strength is god-ray strength (0..1), not fog
	# density: thin volume, scattering scaled by the strength.
	var vol: float = lighting["volumetric_light_strength"]
	if not underwater:
		e.volumetric_fog_enabled = vol > 0.0
		if vol > 0.0:
			e.volumetric_fog_density = 0.00025 + 0.0006 * vol
			e.volumetric_fog_emission_energy = 0.0
			e.volumetric_fog_anisotropy = 0.7
			e.volumetric_fog_albedo = Color(0.9, 0.93, 1.0)
			e.volumetric_fog_length = 96.0


# Sun/moon disc textures come from the server's media through the texture
# modifier DSL (e.g. Mineclonia's moon phase sheet); null until media arrives.
func _set_sky_disc(tex_param: String, flag_param: String, tex_name: String) -> void:
	if tex_name == "":
		sky_mat.set_shader_parameter(flag_param, false)
		return
	var t: Texture2D = sky_tex_cache.get(tex_name)
	if t == null:
		t = client.texture(tex_name)
		if t != null:
			sky_tex_cache[tex_name] = t
	sky_mat.set_shader_parameter(flag_param, t != null)
	if t != null:
		sky_mat.set_shader_parameter(tex_param, t)

func _set_wield(i: int) -> void:
	wield = i
	client.set_wield_index(i)

func _update_selection_box() -> void:
	if selection_box == null:
		selection_box = MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(1.01, 1.01, 1.01)
		selection_box.mesh = bm
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(0, 0, 0, 0.35)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_FRONT
		m.no_depth_test = false
		selection_box.material_override = m
		add_child(selection_box)
	if pointed.get("type", "nothing") == "node":
		selection_box.visible = true
		# node centre: Luanti node p spans p +- 0.5
		selection_box.position = pointed["node"]
	else:
		selection_box.visible = false
