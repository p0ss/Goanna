# SPDX-License-Identifier: LGPL-2.1-or-later
# Measure emitted brightness against actual displaced height, at two times.
extends "res://tests/lava_continuity.gd"

func run() -> void:
	root.size = Vector2i(640,640)
	world = Node3D.new()
	root.add_child(world)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(16,8,0.01)
	camera.look_at(Vector3(16,0,0))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 4.5
	camera.current = true
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_energy = 0.0
	camera.environment = env
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/lava.gdshader")
	mat.set_shader_parameter("albedo_tex",tile(true))
	mat.set_shader_parameter("surface_geometry",true)
	mat.set_shader_parameter("emission_energy",1.0)
	# Diagnostic reads the displaced positions from the production vertex
	# shader. It does not reproduce the height function or the heat mask.
	var height_shader := Shader.new()
	var source: String = mat.shader.code
	var end := source.rfind("}")
	height_shader.code = source.substr(0,end) + "\nALBEDO=vec3(0.0); EMISSION=vec3(clamp((displaced_pos.y-surface_pos.y)/crust_height,0.0,1.0));\n}"
	var first_glow: Image
	var first_height: Image
	var moving_glow := 0
	var moving_height := 0
	for t in [0.0,3.0]:
		clear_meshes()
		mat.set_shader_parameter("preview_time",t)
		# Independently submitted adjacent tiles share the world-space flow.
		for x in [14.0,16.0]:
			patch(x,x+2,-2,2,mat)
		var glow := await capture()
		clear_meshes()
		var diagnostic: ShaderMaterial = mat.duplicate()
		diagnostic.shader = height_shader
		for x in [14.0,16.0]:
			patch(x,x+2,-2,2,diagnostic)
		var height := await capture()
		var samples: Array[Vector2] = []
		# Stay inside the patch. Compare height quantiles: the overlapping
		# flow phases need not reach exactly zero or full height every frame.
		for y in range(80,560):
			for x in range(80,560):
				var h := height.get_pixel(x,y).r
				var g := glow.get_pixel(x,y)
				samples.append(Vector2(h,(g.r+g.g+g.b)/3.0))
				if first_glow:
					if absf(g.r-first_glow.get_pixel(x,y).r)>0.08:
						moving_glow += 1
					if absf(h-first_height.get_pixel(x,y).r)>0.08:
						moving_height += 1
		samples.sort_custom(func(a: Vector2,b: Vector2): return a.x < b.x)
		var count := samples.size()/5
		var raised_mean := 0.0
		var melt_mean := 0.0
		for i in count:
			melt_mean += samples[i].y/count
			raised_mean += samples[samples.size()-1-i].y/count
		check(samples[samples.size()-count].x - samples[count].x > 0.15, "Surface must have distinct high and low regions")
		check(raised_mean < melt_mean*0.25, "Raised crust must emit far less light than low melt")
		print("Time %.1f: raised brightness %.4f, low melt %.4f" % [t,raised_mean,melt_mean])
		first_glow = glow
		first_height = height
	check(moving_glow>1000 and moving_height>1000, "Both height and glow must move")
	print("Lava coupling: %d failures; moving glow %d, moving height %d" % [failures,moving_glow,moving_height])
	quit(1 if failures else 0)
