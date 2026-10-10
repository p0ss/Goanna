# SPDX-License-Identifier: LGPL-2.1-or-later
# Offline portal review and rendering checks. Run through goanna-headless.
extends Node3D

var camera: Camera3D
var nether: ShaderMaterial
var end: ShaderMaterial
var failures := 0
var solids: Array[Vector3i] = []
var nether_sheets: Array[MeshInstance3D] = []
var out := OS.get_environment("GOANNA_PORTAL_OUT")

func check(ok: bool, message: String) -> void:
	if not ok:
		push_error(message)
		failures += 1

func box(at: Vector3, size: Vector3, colour: Color) -> void:
	var mesh := MeshInstance3D.new()
	var shape := BoxMesh.new()
	shape.size = size
	mesh.mesh = shape
	mesh.position = at
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.roughness = 0.88
	mesh.material_override = mat
	add_child(mesh)

func sheet(origin: Vector3, u: Vector3, v: Vector3, material: Material) -> MeshInstance3D:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for uv in [Vector2(0, 0), Vector2(0, 1), Vector2(1, 1),
			Vector2(0, 0), Vector2(1, 1), Vector2(1, 0)]:
		surface.set_normal(u.cross(v).normalized())
		surface.set_uv(uv)
		var centre := Vector3i((origin + (u + v) * 0.5).round())
		var edges := 0
		var directions := [Vector3i(u), Vector3i(-u), Vector3i(v), Vector3i(-v)]
		for edge in 4:
			if centre + directions[edge] in solids:
				edges |= 1 << edge
		surface.set_uv2(Vector2(edges, 0))
		surface.add_vertex(origin + u * uv.x + v * uv.y)
	var mesh := MeshInstance3D.new()
	mesh.mesh = surface.commit()
	mesh.material_override = material
	add_child(mesh)
	return mesh

func material(path: String, colour: Color) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(path)
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(colour)
	mat.set_shader_parameter("albedo_tex", ImageTexture.create_from_image(img))
	mat.set_shader_parameter("preview_time", 0.0)
	return mat

func capture(name_: String) -> Image:
	for frame in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(out.path_join(name_ + ".png"))
	return img

func difference(a: Image, b: Image) -> int:
	var count := 0
	for y in a.get_height():
		for x in a.get_width():
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if absf(ca.r-cb.r) + absf(ca.g-cb.g) + absf(ca.b-cb.b) > 0.08:
				count += 1
	return count

func centre_colour(img: Image) -> Color:
	var total := Color(0, 0, 0, 0)
	for y in range(300, 500):
		for x in range(540, 740):
			total += img.get_pixel(x, y)
	return total / 40000.0

func check_absorption(dry: Image, wet: Image, label: String) -> void:
	var before := centre_colour(dry)
	var after := centre_colour(wet)
	var red_keep := after.r / maxf(before.r, 0.001)
	var blue_keep := after.b / maxf(before.b, 0.001)
	print("%s underwater red/blue transmission: %.3f / %.3f" % [label, red_keep, blue_keep])
	check(red_keep < 0.6 and red_keep < blue_keep * 0.75,
		label + " absorbs red more strongly than blue under water")

func transmitted_green(panel: Image, hidden: Image) -> float:
	var total := 0.0
	for y in range(300, 500):
		for x in range(540, 740):
			total += panel.get_pixel(x, y).srgb_to_linear().g
			total -= hidden.get_pixel(x, y).srgb_to_linear().g
	return total

func coverage(alpha: float) -> void:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.33, 0.025, 0.65, alpha))
	nether.set_shader_parameter("albedo_tex", ImageTexture.create_from_image(img))

func _ready() -> void:
	if out.is_empty():
		out = "/tmp/goanna-portal-review"
	DirAccess.make_dir_recursive_absolute(out)
	get_window().size = Vector2i(1280, 800)
	camera = Camera3D.new()
	add_child(camera)
	camera.current = true
	camera.position = Vector3(8, 7.5, 13)
	camera.look_at(Vector3(-0.8, 1.6, 0))
	camera.fov = 45
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.014, 0.019, 0.035)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.7, 0.9)
	env.ambient_light_energy = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.45
	camera.environment = env
	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.rotation_degrees = Vector3(-50, -25, 0)
	sun.light_energy = 1.0
	box(Vector3(0, -0.7, 0), Vector3(18, 0.4, 12), Color(0.12, 0.14, 0.18))
	# Coloured columns behind the Nether membrane expose its distortion.
	for i in 11:
		box(Vector3(-5.5 + i * 0.5, 2, -1.5), Vector3(0.18, 5, 0.2),
			Color(0.22, 0.38 + 0.04 * (i % 3), 0.50))
	for x in range(-5, 0):
		for y in range(0, 6):
			if x in [-5, -1] or y in [0, 5]:
				box(Vector3(x, y, 0), Vector3.ONE, Color(0.075, 0.035, 0.115))
				solids.append(Vector3i(x, y, 0))
	nether = material("res://shaders/portal_nether.gdshader", Color(0.33, 0.025, 0.65, 0.7))
	# Separate node quads, as in the live mesh. No per-tile border is wanted.
	for x in range(-4, -1):
		for y in range(1, 5):
			nether_sheets.append(sheet(Vector3(x-0.5, y-0.5, 0.1), Vector3.RIGHT, Vector3.UP, nether))
	for x in range(0, 5):
		for z in range(-2, 3):
			if x in [0, 4] or z in [-2, 2]:
				box(Vector3(x, 0, z), Vector3.ONE, Color(0.13, 0.30, 0.26))
	end = material("res://shaders/portal_end.gdshader", Color(0.01, 0.03, 0.04, 1))
	for x in range(1, 4):
		for z in range(-1, 2):
			sheet(Vector3(x-0.5, 0.25, z+0.5), Vector3.RIGHT, Vector3.FORWARD, end)
	# Same full-cube encoding and half-node origin as the live lamp grid.
	var slices: Array[Image] = []
	for z in 16:
		var img := Image.create(16, 16, false, Image.FORMAT_RF)
		img.fill(Color(0, 0, 0))
		for cell in solids:
			if cell.z + 8 == z:
				img.set_pixel(cell.x + 8, cell.y + 8, Color(-1, 0, 0))
		slices.append(img)
	var grid := ImageTexture3D.new()
	grid.create(Image.FORMAT_RF, 16, 16, 16, false, slices)
	RenderingServer.global_shader_parameter_set("goanna_lamp_occlusion_grid", grid)
	RenderingServer.global_shader_parameter_set("goanna_lamp_occlusion_box", Vector4(-8.5, -8.5, -8.5, 16))
	var first := await capture("portals")
	nether.set_shader_parameter("preview_time", 3.0)
	end.set_shader_parameter("preview_time", 3.0)
	var later := await capture("portals-time")
	check(difference(first, later) > 1000, "Portal animation changes the rendered image")
	camera.position = Vector3(3, 3.3, 4.8)
	camera.look_at(Vector3(2, 0.25, 0))
	var deep := await capture("end-depth")
	end.set_shader_parameter("parallax_depth", 0.0)
	var flat := await capture("end-flat")
	check(difference(deep, flat) > 2000, "End star layers respond to ray depth")
	end.set_shader_parameter("parallax_depth", 2.8)
	camera.position.x += 1.2
	camera.look_at(Vector3(2, 0.25, 0))
	await capture("end-moved")
	camera.position = Vector3(-3, 2.5, 6)
	camera.look_at(Vector3(-3, 2.5, 0))
	await capture("nether-front")
	# A foreground bar must occlude the membrane, not enter its refraction.
	box(Vector3(-3.7, 2.5, 1.5), Vector3(0.24, 3, 0.24), Color(0.8, 0.12, 0.035))
	var with_grid := await capture("nether-foreground")
	RenderingServer.global_shader_parameter_set("goanna_lamp_occlusion_box", Vector4.ZERO)
	var without_grid := await capture("nether-no-grid")
	check(difference(with_grid, without_grid) < 20, "Baked frame contacts keep the rim without the lamp grid")
	nether.set_shader_parameter("preview_time", 0.0)
	var start := await capture("nether-clock-start")
	nether.set_shader_parameter("preview_time", 60.0)
	var wrap := await capture("nether-clock-wrap")
	check(difference(start, wrap) < 20, "The animation clock wraps without a visible jump")
	# These checks isolate the material from bloom and ordinary scene fog.
	env.glow_enabled = false
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var panel := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.6, 2.0)
	panel.mesh = quad
	panel.position = Vector3(-2.6, 2.5, -0.4)
	var glass := StandardMaterial3D.new()
	glass.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.albedo_color = Color(0.1, 1.0, 0.15, 0.65)
	glass.render_priority = -1
	panel.material_override = glass
	add_child(panel)
	var transmitted := await capture("nether-transparent-behind")
	panel.hide()
	var no_panel := await capture("nether-no-transparent-behind")
	check(difference(transmitted, no_panel) > 1000,
		"Transparent objects behind the Nether membrane remain visible")
	coverage(0.0)
	var clear := await capture("nether-zero-alpha")
	for mesh in nether_sheets:
		mesh.hide()
	var absent := await capture("nether-absent")
	check(difference(clear, absent) < 20, "Zero source alpha leaves no membrane or glow")
	for mesh in nether_sheets:
		mesh.show()
	coverage(1.0)
	var opaque := await capture("nether-opaque")
	panel.show()
	var opaque_panel := await capture("nether-opaque-panel")
	check(difference(opaque, opaque_panel) < 20, "Opaque source alpha hides objects behind the membrane")
	RenderingServer.global_shader_parameter_set("goanna_water_absorption", Vector3(0.45, 0.11, 0.05))
	RenderingServer.global_shader_parameter_set("goanna_water_surface", Vector4(100, 0, 0, 0))
	RenderingServer.global_shader_parameter_set("goanna_eye_underwater", 1.0)
	var wet_nether := await capture("nether-underwater-opaque")
	check_absorption(opaque_panel, wet_nether, "Nether")
	coverage(0.7)
	var wet_panel := await capture("nether-underwater")
	panel.hide()
	var wet_no_panel := await capture("nether-underwater-no-panel")
	check(difference(wet_panel, wet_no_panel) > 1000,
		"Transparent objects behind the Nether membrane remain visible under water")
	# Only the portal responds to the water globals in this isolated scene.
	# Its own radiance cancels in each difference; the transmitted panel's
	# contribution must stay unchanged instead of being absorbed again.
	var dry_transmission := transmitted_green(transmitted, no_panel)
	var wet_transmission := transmitted_green(wet_panel, wet_no_panel)
	check(dry_transmission > 1.0 and absf(wet_transmission / dry_transmission - 1.0) < 0.1,
		"Nether does not apply absorption a second time to its background")
	# Look straight down so the centre sample contains only the End sheet.
	camera.position = Vector3(2, 5, 0)
	camera.look_at(Vector3(2, 0.25, 0), Vector3.FORWARD)
	var wet_end := await capture("end-underwater")
	RenderingServer.global_shader_parameter_set("goanna_eye_underwater", 0.0)
	var dry_end := await capture("end-dry")
	check_absorption(dry_end, wet_end, "End")
	print("Portal study: %d failures; captures in %s" % [failures, out])
	get_tree().quit(1 if failures else 0)
