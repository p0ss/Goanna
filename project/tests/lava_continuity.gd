# SPDX-License-Identifier: LGPL-2.1-or-later
# GPU regression: splitting a raised lava surface at a mapblock boundary must
# not change its image. Also checks actual silhouette height against flat lava.
extends "res://tests/lava_material.gd"

func capture() -> Image:
	for frame in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func patch(x0: float, x1: float, z0: float, z1: float, mat: Material, coverage: float = 1.0) -> void:
	quad([Vector3(x0,0,z0),Vector3(x1,0,z0),Vector3(x1,0,z1),Vector3(x0,0,z1)],
		[Vector2.ZERO,Vector2.RIGHT,Vector2.ONE,Vector2.DOWN], mat, coverage)

func clear_meshes() -> void:
	for child in world.get_children():
		if child is MeshInstance3D:
			child.free()

func run() -> void:
	root.size = Vector2i(960,640)
	world = Node3D.new()
	root.add_child(world)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(16,1.3,5)
	camera.look_at(Vector3(16,0,0))
	camera.current = true
	camera.fov = 48.0
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 1.0
	camera.environment = env
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/lava.gdshader")
	mat.set_shader_parameter("albedo_tex",tile(true))
	mat.set_shader_parameter("surface_geometry",true)
	mat.set_shader_parameter("preview_time",2.0)
	patch(14,18,-2,2,mat)
	var reference := await capture()
	clear_meshes()
	# Four separately submitted meshes, including a split at world X=16.
	for x in [14.0,16.0]:
		for z in [-2.0,0.0]:
			patch(x,x+2,z,z+2,mat.duplicate())
	var split := await capture()
	clear_meshes()
	patch(14,18,-2,2,mat,0.0)
	var edge := await capture()
	clear_meshes()
	mat.set_shader_parameter("crust_height",0.0)
	patch(14,18,-2,2,mat)
	var flat := await capture()
	var error := 0.0
	var changed := 0
	var silhouette := 0
	var edge_error := 0.0
	for y in reference.get_height():
		for x in reference.get_width():
			var a := reference.get_pixel(x,y)
			var b := split.get_pixel(x,y)
			var c := flat.get_pixel(x,y)
			var d := edge.get_pixel(x,y)
			edge_error += absf(c.r-d.r)+absf(c.g-d.g)+absf(c.b-d.b)
			var difference := absf(a.r-b.r)+absf(a.g-b.g)+absf(a.b-b.b)
			error += difference
			if difference > 0.04:
				changed += 1
			if a.r+a.g+a.b > 0.03 and c.r+c.g+c.b < 0.001:
				silhouette += 1
	var pixels := reference.get_width()*reference.get_height()
	check(error/pixels < 0.001 and changed < pixels/1000, "Mapblock split must not create lava seams")
	check(silhouette > 100, "Crust must rise above the molten surface silhouette")
	check(edge_error/pixels < 0.001, "Zero shoreline coverage must flatten geometry and normals")
	var out := "/tmp/goanna-lava-continuity"
	DirAccess.make_dir_recursive_absolute(out)
	reference.save_png(out.path_join("continuous.png"))
	split.save_png(out.path_join("split.png"))
	flat.save_png(out.path_join("flat.png"))
	print("Lava continuity: %d failures; mean seam error %.6f, changed %d, raised silhouette %d pixels, edge error %.6f" % [failures,error/pixels,changed,silhouette,edge_error/pixels])
	quit(1 if failures else 0)
