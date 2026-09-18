# SPDX-License-Identifier: LGPL-2.1-or-later
# GPU fixture: --path project --script res://tests/lava_material.gd
# GOANNA_LAVA_TEXTURE optionally supplies an external tile/vertical strip.
extends SceneTree

var materials: Array[ShaderMaterial] = []
var world: Node3D
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok:
		push_error(message)
		failures += 1

func tile(rocky: bool) -> ImageTexture:
	# Deliberately different coverage, but the same asymmetric islands. This
	# makes movement and accidental glow on cold rock visible in the captures.
	var img := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	for y in 128:
		for x in 128:
			var p := Vector2(x, y) / 128.0
			var f := sin(p.x * TAU + 0.65 * sin(p.y * TAU)) * cos(p.y * TAU)
			var hot := smoothstep(-0.08, 0.17, f) if rocky else 0.7 + 0.3 * f
			var cold := Color(0.095, 0.085, 0.08)
			if OS.get_environment("GOANNA_LAVA_RED_TEST") == "1":
				cold = Color(1.0, 0.035, 0.0)
			var melt := Color(1.0, 0.29 + 0.4 * hot, 0.015)
			img.set_pixel(x, y, cold.lerp(melt, hot))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func quad(points: Array[Vector3], _uvs: Array[Vector2], material: Material, coverage: float = 1.0) -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var normal := (points[2] - points[0]).cross(points[1] - points[0]).normalized()
	var nx := maxi(1, ceili(points[0].distance_to(points[1]) * 8.0))
	var ny := maxi(1, ceili(points[0].distance_to(points[3]) * 8.0))
	for y in ny:
		for x in nx:
			for corner in [Vector2(0,0),Vector2(1,0),Vector2(1,1),Vector2(0,0),Vector2(1,1),Vector2(0,1)]:
				var u: float = (x + corner.x) / nx
				var v: float = (y + corner.y) / ny
				var p := points[0].lerp(points[1], u).lerp(points[3].lerp(points[2], u), v)
				surface.set_normal(normal)
				surface.set_color(Color(1,1,1,coverage))
				# A continuous downhill field for this test channel, shared at all edges.
				surface.set_uv(Vector2(0.0, 0.35))
				surface.add_vertex(p)
	var mesh := MeshInstance3D.new()
	mesh.mesh = surface.commit()
	mesh.material_override = material
	world.add_child(mesh)

func run() -> void:
	root.size = Vector2i(1200, 800)
	world = Node3D.new()
	root.add_child(world)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(12, 12, 16)
	camera.fov = 35.0
	camera.look_at(Vector3(0, 0.5, 0))
	camera.current = true
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.018, 0.023, 0.032)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.52, 0.7)
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.4
	camera.environment = env
	var sun := DirectionalLight3D.new()
	world.add_child(sun)
	sun.rotation_degrees = Vector3(-55, -25, 0)
	sun.light_energy = 0.7
	var textures: Array[Texture2D] = [tile(true), tile(false)]
	var path := OS.get_environment("GOANNA_LAVA_TEXTURE")
	if path.is_empty():
		path = ProjectSettings.globalize_path("res://../luanti/games/devtest/mods/basenodes/textures/default_lava.png")
	var authored := Image.load_from_file(path)
	check(authored != null, "Authored lava texture loads")
	if authored:
		authored = authored.get_region(Rect2i(0, 0, authored.get_width(), mini(authored.get_width(), authored.get_height())))
		authored.generate_mipmaps()
		textures.append(ImageTexture.create_from_image(authored))
	var rock := StandardMaterial3D.new()
	rock.albedo_color = Color(0.12, 0.14, 0.17)
	rock.roughness = 0.95
	for lane in textures.size():
		var material := ShaderMaterial.new()
		material.shader = load("res://shaders/lava.gdshader")
		material.set_shader_parameter("albedo_tex", textures[lane])
		material.set_shader_parameter("preview_time", 0.0)
		material.set_shader_parameter("surface_geometry", true)
		materials.append(material)
		var x := (lane - 1) * 4.0
		# A source pool, slope, vertical fall and receiving pool. Each top
		# segment is its own quad, like separate Luanti liquid nodes.
		var levels := [Vector2(-5, 2.0), Vector2(-3, 2.0), Vector2(-1, 1.6),
			Vector2(0, 1.1), Vector2(0, 0.1), Vector2(4, 0.1)]
		for j in levels.size() - 1:
			var a: Vector2 = levels[j]
			var b: Vector2 = levels[j + 1]
			var va := a.x if j != 3 else 0.0
			var vb := b.x if j != 3 else 1.0
			quad([Vector3(x-1.4,a.y,a.x), Vector3(x+1.4,a.y,a.x),
				Vector3(x+1.4,b.y,b.x), Vector3(x-1.4,b.y,b.x)],
				[Vector2(0,va),Vector2(2.8,va),Vector2(2.8,vb),Vector2(0,vb)], material)
			for side in [-1, 1]:
				var block := MeshInstance3D.new()
				var box := BoxMesh.new()
				box.size = Vector3(0.25, 0.35, maxf(0.2, b.x-a.x))
				block.mesh = box
				block.material_override = rock
				block.position = Vector3(x+side*1.6, (a.y+b.y)*0.5-0.15, (a.x+b.x)*0.5)
				world.add_child(block)
	var out := OS.get_environment("GOANNA_LAVA_TEST_OUT")
	if out.is_empty():
		out = "/tmp/goanna-lava-review"
	DirAccess.make_dir_recursive_absolute(out)
	var shots: Array[Image] = []
	var playback := OS.get_environment("GOANNA_LAVA_PLAYBACK") == "1"
	for time in [0.0, 3.0]:
		for material in materials:
			material.set_shader_parameter("preview_time", -1.0 if playback else time)
		if playback and time > 0.0:
			await create_timer(time).timeout
		for frame in 20:
			await process_frame
		await RenderingServer.frame_post_draw
		var shot := root.get_texture().get_image()
		shot.save_png(out.path_join("lava-%d.png" % int(time)))
		shots.append(shot)
	var changed := 0
	var hot_pixels := 0
	for y in shots[0].get_height():
		for x in shots[0].get_width():
			var a := shots[0].get_pixel(x,y)
			var b := shots[1].get_pixel(x,y)
			if absf(a.r-b.r) + absf(a.g-b.g) > 0.1:
				changed += 1
			if a.r > 0.6 and a.r > a.b * 2.0:
				hot_pixels += 1
	check(changed > 10000, "Lava must visibly transport the selected texture")
	check(hot_pixels > 10000, "Molten channels must render with the lava shader")
	print("Lava material: %d failures; %d moving pixels, %d molten pixels" % [failures, changed, hot_pixels])
	quit(1 if failures else 0)
