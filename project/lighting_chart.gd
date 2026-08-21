extends Node3D

# The material chart, docs/pbr-plan.md step 1: the lighting and material
# instrument. No world, no server, a fixed camera and fixed lights. One row
# per material class, one column per lighting condition, each cell a node
# sized cube wearing a baked LabPBR set through the shader the world uses
# (nodes_array.gdshader, with the vertex layout of docs/mesh-attributes.md),
# and the number each cell rendered at printed beside what it should have
# been. A change to the shader or the environment shows up here as a number
# before anyone looks at a screenshot.
#
# Columns, per time of day:
#   open   a cube in the open, sky light 255, occlusion 255
#   bay    the same cube under a roof with a wall behind, real occluding
#          geometry, which is the "roofed bay" docs/pbr-plan.md step 3 wants
#          dark without the headlight. Its sky light byte is 0.7, not 1.0:
#          Luanti's spread light under a roof a few nodes in is two or three
#          levels below full sun, and that is what the fill would see there
#   dark   the open cubes again, in a second capture at the same place with
#          sky light 0 in CUSTOM0: what the shader does with Luanti's own
#          "no sky here" on its own, with nothing else moved
# Times of day are the four cases step 3 is judged on: noon, afternoon, dawn
# (low warm sun) and night (moon), each driven through the same blend of
# Mineclonia's sky values that main.gd's _apply_sky does, copied not re
# derived, so a value tuned here transfers.
#
# What is printed, per cell and per face (front is vertical, top is
# horizontal): mean sRGB, luma, how much of the patch clips (any channel at
# 250 or more), the standard deviation of luma across the patch against the
# albedo texture's own (does snow keep its texture), and the albedo mean so
# the ratio rendered over albedo can be read. Then per condition the luma
# gap between the two closest classes, which is whether materials are told
# apart (the smallest colour distance between any two classes on the front
# face, since gold and steel at the same luma are not confused), and the
# fraction of the frame below the horizon that clips, which
# is the "clipping outside the sky" figure. CHART_OUT=/path.json writes all
# of it; PROBE_OUT=/dir saves one PNG per capture. tools/chart_summary.py
# reduces the JSON to the step 3 pass or fail lines.
#
# Knobs, the same names as main.gd where main.gd has them: GOANNA_SUN,
# GOANNA_AMBIENT, GOANNA_SDFGI, GOANNA_SSAO, GOANNA_WHITE, GOANNA_EXPOSURE,
# GOANNA_MAT="channel=value,..." for the shader strengths. Only here:
# GOANNA_SDFGI_ON, GOANNA_SSAO_ON, GOANNA_SSIL_ON, GOANNA_SKY_CONTRIB,
# GOANNA_SDFGI_SKY, GOANNA_SSAO_LIGHT_AFFECT, GOANNA_SSIL, GOANNA_HEADLIGHT
# (adds main.gd's head light at the camera), GOANNA_TIMES="noon,dawn" to
# run fewer columns, GOANNA_BAKED_DIR for the LabPBR set, and the sky
# radiance controls in shaders/sky.gdshader: GOANNA_RAD_GROUND,
# GOANNA_RAD_DESAT, GOANNA_RAD_FLOOR (a scale on the night floor), and
# GOANNA_SKY_FILL, the strength of the sky fill the node shaders add from
# the sky light channel (nodes_array_common.gdshaderinc); the colour is the
# horizon's, desaturated, weighted by day, as main.gd sets it.
#
# What this chart settled, 2026-08-21, Godot 4.5.1, RTX 3090, Vulkan
# Forward+ (tools/chart_summary.py prints the pass or fail lines): the old
# recipe scored 7 of 15, with tops at 1.87 times albedo, snow flat white,
# walls at 0.28 of the top and night pitch black. Sun 1.0, ACES white 4.0
# and exposure 0.5 fix the tops and the clipping; the sky radiance controls
# fix the night and the blue bay; and walls turned out to be a limit of the
# GI rather than of the exposure, SDFGI giving a vertical face about 0.27
# of a horizontal face's ambient at every energy tried, so the node shaders
# now add a sky fill from Luanti's sky light channel, 0.4 of the horizon
# colour by day. 14 of 15 with that; the fifteenth is snow keeping only 0.4
# of its texture contrast at noon, which is the ACES shoulder at the snow's
# brightness, and filmic did not mend it without flattening everything else.
#
# What the first version of this chart found, on Godot 4.5.1, RTX 3090,
# Vulkan Forward+, with two cases (a stone cube in sun, a dirt wall in a
# bay), kept because main.gd's comments cite it: with SDFGI on,
# ambient_light_energy, ambient_light_color and sky contribution are all
# inert for covered geometry (SDFGI replaces environment ambient outright);
# the levers that reach a shadowed surface are sdfgi_energy, SSIL (which
# was subtracting light from the bay, 57,47,43 with it on against 81,66,59
# off) and sdfgi_read_sky_light (off, the bay fell to 14,5,0). SSAO barely
# touched the bay and cost the sun cube two counts.
#
# Run: godot --path project lighting_chart.tscn

const MATERIALS := [
	# label, baked stem. Twelve classes, the ones step 2's table names.
	["stone", "default_stone"],
	["dirt", "default_dirt"],
	["sand", "default_sand"],
	["gravel", "default_gravel"],
	["snow", "default_snow"],
	["wood", "default_wood"],
	["leaves", "default_leaves"],
	["ice", "default_ice"],
	["gold", "default_gold_block"],
	["steel", "default_steel_block"],
	["wool", "wool_white"],
	["glowstone", "mcl_nether_glowstone"],
]

# Sun elevation per time of day (sun_direction.y as Luanti reports it), and
# the moon's. Noon is Mineclonia at time 0.5 as dumped from a live server
# (sun_direction 0.038, 0.999, 0). Night puts the moon where the sun was.
const TIMES := {
	"noon": {"sun": 0.999, "moon": -0.999},
	"afternoon": {"sun": 0.40, "moon": -0.40},
	"dawn": {"sun": 0.08, "moon": -0.08},
	"night": {"sun": -0.40, "moon": 0.80},
}

# Mineclonia's sky, from GOANNA_DUMPSKY against a live server, 2026-08-21.
const SKY := {
	"day_sky": Color(0.4745, 0.651, 1.0), "day_horizon": Color(0.7529, 0.8471, 1.0),
	"dawn_sky": Color(0.4745, 0.651, 1.0), "dawn_horizon": Color(0.7529, 0.8471, 1.0),
	"night_sky": Color(0.0, 0.0, 0.0), "night_horizon": Color(0.2902, 0.4039, 0.5647),
	"fog_sun_tint": Color(1.0, 0.3725, 0.2),
}
# Mineclonia's lighting block, same dump.
const EXPOSURE_CORRECTION := 0.35
const SATURATION := 1.1
const BLOOM := 0.05

const SPACING := 1.6
const ROW_Z := {"open": 0.0, "bay": -5.0}
# The frame above this row is sky; clipping is counted below it.
const HORIZON_ROW := 300

var baked_dir := ""
var sky_mat: ShaderMaterial
var env: Environment
var sun: DirectionalLight3D
var moon: DirectionalLight3D
var cam: Camera3D
var headlight: OmniLight3D
# main.gd's recipe as settled here on 2026-08-21; GOANNA_* overrides each.
var light_sun := 1.0
var light_ambient := 0.42
var rad_ground := 1.0
var rad_desat := 0.25
var rad_floor := 3.5
var sky_fill := 0.4
var cubes := {} # row -> [MeshInstance3D]
var open_mesh: ArrayMesh
var bay_mesh: ArrayMesh
var dark_mesh: ArrayMesh
var albedo_stats := {} # label -> {mean, sd}
var results := {}


func _envf(name: String, dflt: float) -> float:
	var v := OS.get_environment(name)
	return float(v) if v != "" else dflt


func _load_image(name: String) -> Image:
	var img := Image.new()
	var err := img.load(baked_dir.path_join(name))
	if err != OK:
		push_error("lighting chart: cannot load %s (%d)" % [name, err])
		return null
	return img


func _array(img: Image, srgb: bool) -> Texture2DArray:
	if img == null:
		return null
	var copy := img.duplicate() as Image
	if copy.get_format() != Image.FORMAT_RGBA8:
		copy.convert(Image.FORMAT_RGBA8)
	copy.generate_mipmaps()
	var arr := Texture2DArray.new()
	arr.create_from_images([copy])
	return arr


func _luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


# Per material: one material, shared by its three cubes. The strengths are
# GoannaClient's defaults, overridable with GOANNA_MAT exactly as main.gd
# does, so the chart and the world can be driven by the same string.
func _material(stem: String, label: String) -> ShaderMaterial:
	var alb := _load_image(stem + ".png")
	var nrm := _load_image(stem + "_n.png")
	var spc := _load_image(stem + "_s.png")
	if alb != null:
		var acc := 0.0
		var acc2 := 0.0
		var n := 0
		for y in alb.get_height():
			for x in alb.get_width():
				var l := _luma(alb.get_pixel(x, y)) * 255.0
				acc += l
				acc2 += l * l
				n += 1
		var mean := acc / maxf(n, 1)
		albedo_stats[label] = {"mean": mean, "sd": sqrt(maxf(acc2 / maxf(n, 1) - mean * mean, 0.0))}
	var sm := ShaderMaterial.new()
	sm.shader = load("res://shaders/nodes_array.gdshader")
	sm.set_shader_parameter("albedo_array", _array(alb, true))
	sm.set_shader_parameter("has_normal", nrm != null)
	sm.set_shader_parameter("has_spec", spc != null)
	if nrm != null:
		sm.set_shader_parameter("normal_array", _array(nrm, false))
	if spc != null:
		sm.set_shader_parameter("spec_array", _array(spc, false))
	var strengths := {"normal": 1.0, "ao": 1.0, "roughness": 1.0, "specular": 1.0,
		"emission": 4.0, "sss": 1.0, "sky_light": 1.0, "vertex_ao": 1.0,
		"vertex_ao_light": 0.0, "sky_fill": 1.0, "debug_nodelight": 0.0}
	for pair in OS.get_environment("GOANNA_MAT").split(",", false):
		var kv := pair.split("=")
		if kv.size() == 2:
			strengths[kv[0].strip_edges()] = float(kv[1])
	for k in strengths:
		sm.set_shader_parameter(k + "_strength", strengths[k])
	return sm


# A node sized cube with the world's vertex layout: UV per face, UV2 (layer 0,
# block id 0), a white tint in the vertex colour, and CUSTOM0 as four bytes: block light,
# sky light, occlusion, spare. Clockwise front faces.
func _cube_mesh(custom: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_custom_format(0, SurfaceTool.CUSTOM_RGBA8_UNORM)
	var faces := [
		# normal, four corners clockwise seen from outside, uv per corner
		[Vector3.UP, [Vector3(-0.5, 0.5, -0.5), Vector3(0.5, 0.5, -0.5), Vector3(0.5, 0.5, 0.5), Vector3(-0.5, 0.5, 0.5)]],
		[Vector3.DOWN, [Vector3(-0.5, -0.5, 0.5), Vector3(0.5, -0.5, 0.5), Vector3(0.5, -0.5, -0.5), Vector3(-0.5, -0.5, -0.5)]],
		[Vector3.RIGHT, [Vector3(0.5, 0.5, 0.5), Vector3(0.5, 0.5, -0.5), Vector3(0.5, -0.5, -0.5), Vector3(0.5, -0.5, 0.5)]],
		[Vector3.LEFT, [Vector3(-0.5, 0.5, -0.5), Vector3(-0.5, 0.5, 0.5), Vector3(-0.5, -0.5, 0.5), Vector3(-0.5, -0.5, -0.5)]],
		[Vector3.BACK, [Vector3(-0.5, 0.5, 0.5), Vector3(0.5, 0.5, 0.5), Vector3(0.5, -0.5, 0.5), Vector3(-0.5, -0.5, 0.5)]],
		[Vector3.FORWARD, [Vector3(0.5, 0.5, -0.5), Vector3(-0.5, 0.5, -0.5), Vector3(-0.5, -0.5, -0.5), Vector3(0.5, -0.5, -0.5)]],
	]
	var uvs := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	for f in faces:
		var nrm: Vector3 = f[0]
		var c: Array = f[1]
		for tri in [[0, 1, 2], [0, 2, 3]]:
			for i in tri:
				st.set_normal(nrm)
				st.set_uv(uvs[i])
				st.set_uv2(Vector2(0, 0))
				st.set_color(Color.WHITE)
				st.set_custom(0, custom)
				st.add_vertex(c[i])
	return st.commit()


func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	return mi


func _ready() -> void:
	baked_dir = OS.get_environment("GOANNA_BAKED_DIR")
	if baked_dir == "":
		baked_dir = ProjectSettings.globalize_path("res://../baked/pack-mineclonia-v2/textures")
	light_sun = _envf("GOANNA_SUN", light_sun)
	light_ambient = _envf("GOANNA_AMBIENT", light_ambient)
	rad_ground = _envf("GOANNA_RAD_GROUND", rad_ground)
	rad_desat = _envf("GOANNA_RAD_DESAT", rad_desat)
	rad_floor = _envf("GOANNA_RAD_FLOOR", rad_floor)
	sky_fill = _envf("GOANNA_SKY_FILL", sky_fill)

	# --- environment: main.gd's own recipe, copied ---
	env = Environment.new()
	var sky := Sky.new()
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/sky.gdshader")
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = _envf("GOANNA_SKY_CONTRIB", 1.0)
	env.ambient_light_energy = light_ambient
	env.ambient_light_color = Color(0.72, 0.8, 0.9)
	# GOANNA_TONEMAP=filmic|aces|agx, to judge the shoulder on snow.
	var tm := OS.get_environment("GOANNA_TONEMAP")
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC if tm == "filmic" else (
			Environment.TONE_MAPPER_AGX if tm == "agx" else Environment.TONE_MAPPER_ACES)
	env.tonemap_white = _envf("GOANNA_WHITE", 4.0)
	env.tonemap_exposure = _envf("GOANNA_EXPOSURE", clamp(0.46 * (1.0 + EXPOSURE_CORRECTION * 0.25), 0.1, 3.0))
	env.adjustment_enabled = true
	env.adjustment_saturation = clamp(1.12 * SATURATION, 0.0, 2.0)
	env.adjustment_contrast = 1.05
	env.adjustment_brightness = 1.0
	env.sdfgi_enabled = _envf("GOANNA_SDFGI_ON", 1.0) > 0.5
	env.sdfgi_cascades = 6
	env.sdfgi_min_cell_size = 0.5
	env.sdfgi_energy = _envf("GOANNA_SDFGI", 1.4)
	env.sdfgi_read_sky_light = _envf("GOANNA_SDFGI_SKY", 1.0) > 0.5
	env.ssao_enabled = _envf("GOANNA_SSAO_ON", 1.0) > 0.5
	env.ssao_intensity = _envf("GOANNA_SSAO", 4.0)
	env.ssao_radius = 2.2
	env.ssao_power = 1.6
	env.ssao_detail = 1.0
	env.ssao_light_affect = _envf("GOANNA_SSAO_LIGHT_AFFECT", 0.5)
	env.ssil_enabled = _envf("GOANNA_SSIL_ON", 1.0) > 0.5
	env.ssil_intensity = _envf("GOANNA_SSIL", 1.4)
	env.glow_enabled = true
	env.glow_intensity = clamp(0.3 + BLOOM * 2.0, 0.0, 2.0)
	env.fog_enabled = false
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 60
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.6
	sun.shadow_blur = 1.0
	sun.directional_shadow_blend_splits = true
	add_child(sun)
	moon = DirectionalLight3D.new()
	moon.light_color = Color(0.6, 0.7, 1.0)
	moon.shadow_enabled = true
	moon.directional_shadow_max_distance = 60
	moon.shadow_bias = 0.04
	moon.shadow_normal_bias = 1.6
	add_child(moon)

	# grey, undecorated structural geometry: a floor, and the bay's roof and
	# back wall
	var plain := StandardMaterial3D.new()
	plain.albedo_color = Color(0.5, 0.5, 0.5)
	plain.roughness = 1.0
	var width := SPACING * (MATERIALS.size() + 1)
	var cx := SPACING * (MATERIALS.size() - 1) * 0.5
	_box(Vector3(width + 8, 0.5, 20), Vector3(cx, -0.25, -1), plain)
	# bay: roof 2 above the cubes, wall behind, side walls at both ends, open
	# toward the camera
	_box(Vector3(width, 0.5, 4), Vector3(cx, 2.25, ROW_Z["bay"] - 0.5), plain)
	_box(Vector3(width, 2.5, 0.5), Vector3(cx, 1.25, ROW_Z["bay"] - 2.25), plain)
	_box(Vector3(0.5, 2.5, 4), Vector3(cx - width * 0.5, 1.25, ROW_Z["bay"] - 0.5), plain)
	_box(Vector3(0.5, 2.5, 4), Vector3(cx + width * 0.5, 1.25, ROW_Z["bay"] - 0.5), plain)

	open_mesh = _cube_mesh(Color(0.0, 1.0, 1.0, 1.0)) # block 0, sky 255, ao 255
	bay_mesh = _cube_mesh(Color(0.0, 0.7, 1.0, 1.0)) # under a roof, see above
	dark_mesh = _cube_mesh(Color(0.0, 0.0, 1.0, 1.0)) # sky light 0
	for row in ROW_Z:
		cubes[row] = []
	for i in MATERIALS.size():
		var label: String = MATERIALS[i][0]
		var mat := _material(MATERIALS[i][1], label)
		for row in ROW_Z:
			var mi := MeshInstance3D.new()
			mi.mesh = bay_mesh if row == "bay" else open_mesh
			mi.material_override = mat
			mi.position = Vector3(i * SPACING, 0.5, ROW_Z[row])
			add_child(mi)
			cubes[row].append(mi)

	cam = Camera3D.new()
	cam.fov = 50
	cam.position = Vector3(cx, 7.0, 16.0)
	add_child(cam)
	cam.look_at(Vector3(cx, 0.5, -2.0), Vector3.UP)
	cam.current = true

	if _envf("GOANNA_HEADLIGHT", 0.0) > 0.5:
		headlight = OmniLight3D.new()
		headlight.light_energy = 0.5
		headlight.omni_range = 9.0
		headlight.light_color = Color(1.0, 0.96, 0.9)
		headlight.shadow_enabled = false
		headlight.position = cam.position
		add_child(headlight)

	var times: Array = TIMES.keys()
	if OS.get_environment("GOANNA_TIMES") != "":
		times = Array(OS.get_environment("GOANNA_TIMES").split(",", false))
	for t in times:
		if not TIMES.has(t):
			push_error("lighting chart: unknown time %s" % t)
			continue
		_apply_time(TIMES[t]["sun"], TIMES[t]["moon"])
		results[t] = {}
		for pass_name in ["lit", "dark"]:
			for mi in cubes["open"]:
				mi.mesh = dark_mesh if pass_name == "dark" else open_mesh
			# SDFGI needs real time to converge after a lighting change.
			for i in (90 if pass_name == "lit" else 20):
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var dir := OS.get_environment("PROBE_OUT")
			if dir != "":
				var path := dir.path_join("chart_%s_%s.png" % [t, pass_name])
				img.save_png(path)
				print("saved ", path)
			if pass_name == "lit":
				_measure(t, img, ["open", "bay"], "")
				_frame_clip(t, img)
			else:
				_measure(t, img, ["open"], "dark")
		for mi in cubes["open"]:
			mi.mesh = open_mesh

	var out := OS.get_environment("CHART_OUT")
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(results, "  "))
			print("wrote ", out)
	get_tree().quit()


# main.gd's _apply_sky, for one elevation, against Mineclonia's sky values.
func _apply_time(elev: float, moon_elev: float) -> void:
	# Same azimuth as the old chart (0.35, 0.2 in x and z), the elevation
	# set by the time of day.
	var h := sqrt(maxf(1.0 - elev * elev, 0.0)) / 0.403
	var sun_dir := Vector3(0.35 * h, elev, 0.2 * h).normalized()
	var moon_dir := Vector3(-sun_dir.x, moon_elev, -sun_dir.z).normalized()
	var up := Vector3.UP if absf(sun_dir.y) < 0.999 else Vector3.FORWARD
	sun.transform = Transform3D(Basis.looking_at(-sun_dir, up), Vector3.ZERO)
	up = Vector3.UP if absf(moon_dir.y) < 0.999 else Vector3.FORWARD
	moon.transform = Transform3D(Basis.looking_at(-moon_dir, up), Vector3.ZERO)
	var day: float = smoothstep(-0.02, 0.18, elev)
	var warm: float = 1.0 - smoothstep(0.0, 0.32, elev)
	sun.light_color = Color(1.0, 0.98, 0.94).lerp(Color(1.0, 0.62, 0.32), warm)
	sun.light_energy = lerp(0.0, light_sun, day)
	sun.visible = sun.light_energy > 0.01
	var moon_up: float = smoothstep(-0.02, 0.15, moon_dir.y) * (1.0 - day)
	moon.light_energy = _envf("GOANNA_MOON", 0.25) * moon_up
	moon.visible = moon.light_energy > 0.005
	sun.shadow_opacity = 0.85 # Mineclonia sends 0.33, clamped to the floor
	moon.shadow_opacity = sun.shadow_opacity
	var dawn: float = clamp(1.0 - abs(elev) / 0.22, 0.0, 1.0)
	var night: float = smoothstep(0.02, -0.25, elev)
	var day_w: float = clamp(1.0 - dawn - night, 0.0, 1.0)
	var top: Color = SKY["day_sky"] * day_w + SKY["dawn_sky"] * dawn + SKY["night_sky"] * night
	var hor: Color = SKY["day_horizon"] * day_w + SKY["dawn_horizon"] * dawn + SKY["night_horizon"] * night
	var zenith := top
	zenith.s = maxf(zenith.s, 0.42)
	zenith.v = minf(zenith.v, 0.92)
	sky_mat.set_shader_parameter("sky_top", zenith)
	sky_mat.set_shader_parameter("sky_horizon", hor)
	sky_mat.set_shader_parameter("ground_color", hor.darkened(0.6))
	# Lighting only, see sky.gdshader. The night floor is the night horizon
	# colour, scaled, weighted by how much night it is.
	sky_mat.set_shader_parameter("radiance_ground_lift", rad_ground)
	sky_mat.set_shader_parameter("radiance_desaturate", rad_desat)
	var floor_col: Color = SKY["night_horizon"] * (rad_floor * night)
	sky_mat.set_shader_parameter("radiance_floor", Vector3(floor_col.r, floor_col.g, floor_col.b))
	sky_mat.set_shader_parameter("sun_dir", sun_dir)
	sky_mat.set_shader_parameter("moon_dir", moon_dir)
	sky_mat.set_shader_parameter("sun_visible", true)
	sky_mat.set_shader_parameter("moon_visible", true)
	sky_mat.set_shader_parameter("sun_size", 0.045)
	sky_mat.set_shader_parameter("moon_size", 0.02 * 3.75)
	sky_mat.set_shader_parameter("sun_tint", sun.light_color)
	sky_mat.set_shader_parameter("star_opacity", 0.41 * lerp(1.0, 0.0, day))
	sky_mat.set_shader_parameter("cloud_coverage", 0.0)
	# Luanti's day_night_ratio is 1 by day and about 0.2 by night; main.gd
	# reads it off the server, here it follows the sun.
	var ratio: float = lerp(0.2, 1.0, day)
	env.ambient_light_energy = lerp(0.14, 0.42, ratio) * light_ambient
	env.background_energy_multiplier = lerp(0.25, 0.95, ratio)
	# The sky fill the node shaders add: the horizon colour pulled toward
	# grey, by day only. The global is colour times strength.
	# By day the horizon colour pulled half way to grey; by night the night
	# horizon at night_fill of the strength, which is what the vanilla
	# client's dim blue night is. GOANNA_NIGHT_FILL sets the night share.
	var night_fill := _envf("GOANNA_NIGHT_FILL", 1.6)
	var fill: Color = hor.lerp(Color(hor.v, hor.v, hor.v), 0.5) * (sky_fill * day) \
			+ SKY["night_horizon"] * (sky_fill * night_fill * night)
	RenderingServer.global_shader_parameter_set("goanna_sky_fill", Vector3(fill.r, fill.g, fill.b))


func _patch(img: Image, world: Vector3, half: int) -> Dictionary:
	var p := cam.unproject_position(world)
	var acc := Vector3.ZERO
	var l_acc := 0.0
	var l_acc2 := 0.0
	var clip := 0
	var n := 0
	for dy in range(-half, half + 1):
		for dx in range(-half, half + 1):
			var x := int(p.x) + dx
			var y := int(p.y) + dy
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var c := img.get_pixel(x, y)
			acc += Vector3(c.r, c.g, c.b) * 255.0
			var l := _luma(c) * 255.0
			l_acc += l
			l_acc2 += l * l
			if c.r >= 0.98 or c.g >= 0.98 or c.b >= 0.98:
				clip += 1
			n += 1
	var mean := l_acc / maxf(n, 1)
	return {
		"rgb": acc / maxf(n, 1),
		"luma": mean,
		"sd": sqrt(maxf(l_acc2 / maxf(n, 1) - mean * mean, 0.0)),
		"clip": float(clip) / maxf(n, 1),
	}


# How much of the frame below the horizon clips: the step 3 figure that
# wants to stay in single figures, measured over everything that is not sky.
func _frame_clip(time: String, img: Image) -> void:
	var clip := 0
	var n := 0
	for y in range(HORIZON_ROW, img.get_height()):
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.r >= 0.98 or c.g >= 0.98 or c.b >= 0.98:
				clip += 1
			n += 1
	var frac := float(clip) / maxf(n, 1)
	print("CHART %s frame clipping below horizon: %.1f%%" % [time, frac * 100.0])
	results[time]["frame_clip"] = frac


func _measure(time: String, img: Image, rows: Array, rename: String) -> void:
	var per_time: Dictionary = results[time]
	for geometry_row in rows:
		var row: String = rename if rename != "" else geometry_row
		var lumas := []
		for i in MATERIALS.size():
			var label: String = MATERIALS[i][0]
			var mi: MeshInstance3D = cubes[geometry_row][i]
			var faces := {
				"front": _patch(img, mi.global_position + Vector3(0, 0, 0.51), 6),
				"top": _patch(img, mi.global_position + Vector3(0, 0.51, 0), 5),
			}
			var alb: Dictionary = albedo_stats.get(label, {"mean": 0.0, "sd": 0.0})
			for face in faces:
				var r: Dictionary = faces[face]
				var rgb: Vector3 = r["rgb"]
				print("CHART %s %s %s %s rgb=%d,%d,%d luma=%.0f clip=%.2f sd=%.1f/%.1f albedo=%.0f ratio=%.2f" % [
					time, row, label, face, rgb.x, rgb.y, rgb.z, r["luma"], r["clip"],
					r["sd"], alb["sd"], alb["mean"], r["luma"] / maxf(alb["mean"], 1.0)])
				per_time["%s/%s/%s" % [row, label, face]] = {
					"rgb": [rgb.x, rgb.y, rgb.z], "luma": r["luma"], "clip": r["clip"],
					"sd": r["sd"], "albedo_sd": alb["sd"], "albedo_mean": alb["mean"]}
			lumas.append([faces["front"]["rgb"], label])
		# Are the classes told apart: the smallest colour distance between
		# any two, on the vertical face, where albedo differences are least
		# helped by the sun.
		var gap := 1e9
		var pair := ""
		for a in lumas.size():
			for b in range(a + 1, lumas.size()):
				var g: float = (lumas[a][0] as Vector3).distance_to(lumas[b][0])
				if g < gap:
					gap = g
					pair = "%s/%s" % [lumas[a][1], lumas[b][1]]
		print("CHART %s %s separability: closest front colour distance %.1f (%s)" % [time, row, gap, pair])
		per_time["%s/separability" % row] = {"gap": gap, "pair": pair}
