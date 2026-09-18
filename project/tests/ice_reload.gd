# SPDX-License-Identifier: LGPL-2.1-or-later
# Run with a graphics device: --path project --script res://tests/ice_reload.gd
# Recreate the world-owned ice renderer while retaining its cached shader.
extends SceneTree

class TestClient extends Node:
	func solid_ice() -> bool:
		return false

var failures := 0
var ice_shader: Shader
var retained_material: ShaderMaterial
var ready_probe: ColorRect

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok:
		push_error(message)
		failures += 1

func run() -> void:
	root.size = Vector2i(640, 400)
	var out := OS.get_environment("GOANNA_ICE_TEST_OUT")
	if out.is_empty():
		out = "/tmp/goanna-ice-reload"
	DirAccess.make_dir_recursive_absolute(out)
	var reference: Image
	for cycle in 3:
		var world := Node3D.new()
		root.add_child(world)
		var camera := Camera3D.new()
		world.add_child(camera)
		camera.position = Vector3(2.0, 1.5, 2.0)
		camera.look_at(Vector3.ZERO)
		camera.current = true
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.32, 0.45, 0.65)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color.WHITE
		env.ambient_light_energy = 0.8
		camera.environment = env
		var client := TestClient.new()
		world.add_child(client)
		var transmission := preload("res://ice_transmission.gd").new()
		world.add_child(transmission)
		transmission.initialise(camera, env, client)
		if not ready_probe:
			ready_probe = ColorRect.new()
			ready_probe.size = Vector2(16,16)
			var probe_shader := Shader.new()
			probe_shader.code = "shader_type canvas_item; global uniform float goanna_ice_transmission_ready; void fragment() { COLOR = vec4(vec3(goanna_ice_transmission_ready),1.0); }"
			var probe_material := ShaderMaterial.new()
			probe_material.shader = probe_shader
			ready_probe.material = probe_material
			root.add_child(ready_probe)
		# Keep the same Shader alive across unloads, as the game's resource cache does.
		if not ice_shader:
			ice_shader = load("res://shaders/ice.gdshader")
		if not retained_material:
			retained_material = ShaderMaterial.new()
			retained_material.shader = ice_shader
			var tile := Image.create(16,16,false,Image.FORMAT_RGBA8)
			tile.fill(Color(0.65,0.8,0.9))
			retained_material.set_shader_parameter("albedo_tex",ImageTexture.create_from_image(tile))
		var ice := MeshInstance3D.new()
		ice.mesh = BoxMesh.new()
		ice.material_override = retained_material
		ice.layers = 4
		world.add_child(ice)
		ice.add_to_group("goanna_ice")
		var light := DirectionalLight3D.new()
		world.add_child(light)
		light.rotation_degrees = Vector3(-55,-30,0)
		# NoiseTexture3D generation is asynchronous; wait for both actual volumes.
		var generated := [false, false]
		transmission.fracture_texture.changed.connect(func(): generated[0] = true)
		transmission.cloud_texture.changed.connect(func(): generated[1] = true)
		for attempt in 300:
			if generated[0] and generated[1]:
				break
			await create_timer(0.02).timeout
		check(generated[0], "Fracture volume generated")
		check(generated[1], "Cloud volume generated")
		for frame in 30:
			await process_frame
		await RenderingServer.frame_post_draw
		var shot := root.get_texture().get_image()
		check(shot.get_pixel(4,4).r > 0.99, "Transmission is active for the visible ice")
		shot.save_png(out.path_join("load-%d.png" % (cycle+1)))
		if cycle == 0:
			reference = shot
		else:
			var error := 0.0
			var changed := 0
			for y in shot.get_height():
				for x in shot.get_width():
					var a := shot.get_pixel(x,y)
					var b := reference.get_pixel(x,y)
					var difference := maxf(absf(a.r-b.r),maxf(absf(a.g-b.g),absf(a.b-b.b)))
					error += difference
					if difference > 0.04:
						changed += 1
			var pixels := shot.get_width()*shot.get_height()
			print("Ice load %d: mean error %.6f, changed pixels %d" % [cycle+1,error/pixels,changed])
			check(error/pixels < 0.001 and changed < pixels/1000, "Ice must stay identical on reload")
		world.free()
		for frame in 3:
			await process_frame
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().get_pixel(4,4).r < 0.01,
			"Leaving a world must disable transmission for retained shaders")
	print("Ice reload: %d failures" % failures)
	quit(1 if failures else 0)
