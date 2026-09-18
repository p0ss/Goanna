# SPDX-License-Identifier: LGPL-2.1-or-later
# Bake the supplied Material Maker colour graph; Goanna supplies live flow.
extends SceneTree

func _initialize() -> void:
	call_deferred("bake")

func bake() -> void:
	var assets := ProjectSettings.globalize_path("res://../asset_bundles")
	var source := FileAccess.get_file_as_string(assets.path_join("stylised_lava.gdshader"))
	# Retain the export's graph, palette and overlay operations. Discard its
	# per-face parallax and scrolling: the native lava shader handles those.
	var globals_start := source.find("float dot2")
	var fragment_start := source.find("void fragment()")
	var graph_start := source.find("// #output0: fbm2",fragment_start)
	var graph_end := source.find("\tvec3 albedo_tex =",graph_start)
	if globals_start<0 or fragment_start<0 or graph_start<0 or graph_end<0:
		push_error("Unrecognised stylised lava export")
		quit(1)
		return
	var shader := Shader.new()
	shader.code = "shader_type canvas_item; render_mode unshaded;\nconst float elapsed_time=0.0;\n" + source.substr(globals_start,fragment_start-globals_start) + "\nvoid fragment(){ float _seed_variation_=0.0; vec4 _controlled_variation_=vec4(0.0); vec2 uv=UV;\n" + source.substr(graph_start,graph_end-graph_start) + "\nCOLOR=vec4(o1304898319718_0_1_rgba.rgb,1.0);\n}"
	var material := ShaderMaterial.new()
	material.shader = shader
	for n in [1,4]:
		var image := Image.load_from_file(assets.path_join("stylised_lava_texture_%d.png" % n))
		material.set_shader_parameter("texture_%d" % n,ImageTexture.create_from_image(image))
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1024,1024)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var rect := ColorRect.new()
	rect.size = Vector2(1024,1024)
	rect.material = material
	viewport.add_child(rect)
	for frame in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	var result := viewport.get_texture().get_image()
	var out := ProjectSettings.globalize_path("res://../baked/stylised-lava/textures")
	DirAccess.make_dir_recursive_absolute(out)
	for name in ["default_lava.png","default_lava_source_animated.png","default_lava_flowing_animated.png"]:
		if result.save_png(out.path_join(name)) != OK:
			quit(1)
	var config := FileAccess.open(out.path_join("texture_pack.conf"),FileAccess.WRITE)
	config.store_string("name = Goanna stylised lava\ndescription = Material Maker lava artwork with Goanna continuous flow and raised crust\n")
	print("Baked stylised lava: ",out)
	quit()
