extends Node3D

# The material calibration ramp. No world, no server: a fixed camera and the
# world's own sky and lighting recipe, copied from lighting_chart.gd (which
# copies main.gd's), with three rows of node sized cubes through
# nodes_array.gdshader:
#
#   dielectric  a grey albedo, flat normal, smoothness stepped from 0 to 255
#               at F0 10 (LabPBR's plain dielectric)
#   metal       the same grey and the same steps, G at 255 (metal)
#   pack        real baked sets from GOANNA_BAKED_DIR, one cube each, and
#               beside each a second cube from GOANNA_VARIED_DIR when that is
#               set, so a re-packed specular map is judged next to the one it
#               replaces under the same light
#
# The point is to know what a given roughness and metalness look like in this
# renderer before deciding whether a texture is wrong. There is no screen
# space reflection and SDFGI carries no specular, so the only mirror a smooth
# surface can show is the sky radiance map that sky.gdshader feeds lighting.
# The ramp measures how much of that reaches the screen, and how a sun glint
# widens as roughness rises, which is the number "plastic" complaints about
# uniform sheen have to be judged against.
#
# Three lighting cases: noon and afternoon from lighting_chart.gd's table, and
# glint, the afternoon sun placed at the mirror direction of the camera
# about the top faces, so a smooth top face has to show the sun's disc. A
# glint at a low smoothness step is a lobe that is too wide, and no glint at
# 230 is a lobe that never formed.
#
# Printed per cube and face (top is horizontal, front vertical): mean sRGB,
# luma, the luma standard deviation across the patch (texture contrast plus
# any highlight), and the patch maximum, which is what a highlight raises.
# The rendered sky's zenith and horizon are printed too, since the metal
# top face at smoothness 255 should approach albedo times zenith radiance
# and the front face albedo times horizon. RAMP_OUT=/path.json writes all
# of it; PROBE_OUT=/dir saves one PNG per case.
#
# Knobs, the same as lighting_chart.gd: GOANNA_SUN, GOANNA_SDFGI,
# GOANNA_SSAO, GOANNA_WHITE, GOANNA_EXPOSURE, GOANNA_TONEMAP, GOANNA_MAT,
# GOANNA_TIMES="noon,glint", GOANNA_BAKED_DIR and GOANNA_VARIED_DIR.
# GOANNA_CLOSE=1 is the close up layout: the pack row alone, four cubes to
# a row, the camera near enough that a cube is about 300 pixels wide, which
# is the scale at which relief, occlusion and roughness variation can be
# seen at all. The wide layout above is for levels; this one is for
# structure, and the same GOANNA_BAKED_DIR swap compares two packs.
# GOANNA_NORMAL_GAIN is pack_normal_gain: unset, it is worked out from the
# loaded set the way GoannaTextureArray does it (ninth decile of the per
# texture tilt lifted to 55 degrees, capped at 4), so a flat pack is shown
# lifted as the client would show it; a number pins it. Only
# here: GOANNA_SUN_ANGLE, the sun's angular diameter in degrees (the real
# sun is 0.53; main.gd leaves Godot's 0, a point, which is what makes the
# smoothest steps lose the glint: the lobe is a needle that never lands).
#
# Run: PROBE_OUT=/tmp/ramp godot --path project material_ramp.tscn

const STEPS := [0, 64, 128, 192, 230, 255]

const MATERIALS := [
	["stone", "default_stone"],
	["dirt", "default_dirt"],
	["sand", "default_sand"],
	["gravel", "default_gravel"],
	["grass", "mcl_core_grass_block_top"],
	["planks", "mcl_core_planks_big_oak"],
	["leaves", "mcl_core_leaves_big_oak"],
	["snow", "default_snow"],
	["gold", "default_gold_block"],
	["steel", "default_steel_block"],
	["glass", "default_glass"],
	["ice", "default_ice"],
]

# Sun elevation as Luanti reports sun_direction.y; glint is placed explicitly
# in _apply_case.
const CASES := {
	"noon": {"sun": 0.999},
	"afternoon": {"sun": 0.40},
	"glint": {"sun": 0.40, "mirror": true},
	# Low sun from the camera's right, for parallax self shadow: joints
	# should go dark on their sunward wall and bright on the far one.
	"low": {"sun": 0.18, "azimuth": 1.0},
}

# Mineclonia's sky, the same dump lighting_chart.gd uses.
const SKY := {
	"day_sky": Color(0.4745, 0.651, 1.0), "day_horizon": Color(0.7529, 0.8471, 1.0),
}
const EXPOSURE_CORRECTION := 0.35
const SATURATION := 1.1
const BLOOM := 0.05

const SPACING := 1.6
# Nearest the camera first, gaps wide enough that a row's front faces clear
# the tops of the row before it at this pitch. At 2.6 apart and 22 degrees
# the pack row's fronts were the metal row's tops.
const ROW_Z := {"pack": 4.0, "dielectric": 0.0, "metal": -4.0}
const VARIED_DZ := -12.0

var baked_dir := ""
var varied_dir := ""
var sky_mat: ShaderMaterial
var env: Environment
var sun: DirectionalLight3D
var cam: Camera3D
var light_sun := 1.0
var light_ambient := 0.42
var cubes := {} # row -> [[label, MeshInstance3D]]
var close_up := false
var pack_tilts := [] # per loaded texture, mean of |xy|^2, the client's measure
var pack_materials := []
var results := {}
var strengths := {}


func _envf(name: String, dflt: float) -> float:
	var v := OS.get_environment(name)
	return float(v) if v != "" else dflt


func _luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func _load_image(dir: String, name: String) -> Image:
	var img := Image.new()
	if img.load(dir.path_join(name)) != OK:
		return null
	return img


func _array_from(img: Image) -> Texture2DArray:
	var copy := img.duplicate() as Image
	if copy.get_format() != Image.FORMAT_RGBA8:
		copy.convert(Image.FORMAT_RGBA8)
	copy.generate_mipmaps()
	var arr := Texture2DArray.new()
	arr.create_from_images([copy])
	return arr


func _flat_array(c: Color) -> Texture2DArray:
	var img := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return _array_from(img)


func _strengths() -> Dictionary:
	var s := {"normal": 1.0, "ao": 1.0, "roughness": 1.0, "specular": 1.0,
		"emission": 4.0, "sss": 1.0, "sky_light": 1.0, "vertex_ao": 1.0,
		"vertex_ao_light": 0.0, "sky_fill": 1.0, "debug_nodelight": 0.0}
	for pair in OS.get_environment("GOANNA_MAT").split(",", false):
		var kv := pair.split("=")
		if kv.size() == 2:
			s[kv[0].strip_edges()] = float(kv[1])
	return s


func _shader_material(alb: Texture2DArray, nrm: Texture2DArray, spc: Texture2DArray) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = load("res://shaders/nodes_array.gdshader")
	sm.set_shader_parameter("albedo_array", alb)
	sm.set_shader_parameter("has_normal", nrm != null)
	sm.set_shader_parameter("has_spec", spc != null)
	if nrm != null:
		sm.set_shader_parameter("normal_array", nrm)
	if spc != null:
		sm.set_shader_parameter("spec_array", spc)
	for k in strengths:
		sm.set_shader_parameter(k + "_strength", strengths[k])
	return sm


# One synthetic step: grey albedo, flat normal, the given _s bytes.
func _synthetic(smooth: int, metal: bool) -> ShaderMaterial:
	var alb := _flat_array(Color8(128, 128, 128, 255))
	var nrm := _flat_array(Color8(128, 128, 255, 128))
	var spc := _flat_array(Color8(smooth, 255 if metal else 10, 0, 255))
	return _shader_material(alb, nrm, spc)


func _packed(dir: String, stem: String) -> ShaderMaterial:
	var alb := _load_image(dir, stem + ".png")
	if alb == null:
		push_error("material ramp: cannot load %s in %s" % [stem, dir])
		return null
	var nrm := _load_image(dir, stem + "_n.png")
	var spc := _load_image(dir, stem + "_s.png")
	if nrm != null:
		pack_tilts.append(_tilt_var(nrm))
	var mat := _shader_material(_array_from(alb),
			_array_from(nrm) if nrm != null else null,
			_array_from(spc) if spc != null else null)
	pack_materials.append(mat)
	return mat


# src/goanna_textures.cpp's per texture relief measure: the mean squared
# tangent slope, sampled on a stride so it stays quick.
func _tilt_var(nrm: Image) -> float:
	var acc := 0.0
	var n := 0
	for y in range(0, nrm.get_height(), 4):
		for x in range(0, nrm.get_width(), 4):
			var c := nrm.get_pixel(x, y)
			var dx := c.r * 2.0 - 1.0
			var dy := c.g * 2.0 - 1.0
			acc += dx * dx + dy * dy
			n += 1
	return acc / maxf(n, 1)


# The client's pack_normal_gain, from the set as loaded.
func _pack_gain() -> float:
	var v := OS.get_environment("GOANNA_NORMAL_GAIN")
	if v != "":
		return float(v)
	if pack_tilts.size() < 8:
		return 1.0
	var t := pack_tilts.duplicate()
	t.sort()
	var p90: float = sqrt(t[int(t.size() * 0.9)])
	var target := sin(deg_to_rad(55.0))
	if p90 > 1e-4 and p90 < target:
		return minf(4.0, target / p90)
	return 1.0


# A node sized cube with the world's vertex layout, as lighting_chart.gd
# builds it: UV per face, UV2 layer 0, white vertex colour, CUSTOM0 block
# light 0, sky light 255, occlusion 255.
func _cube_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_custom_format(0, SurfaceTool.CUSTOM_RGBA8_UNORM)
	var faces := [
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
				st.set_custom(0, Color(0.0, 1.0, 1.0, 1.0))
				st.add_vertex(c[i])
	return st.commit()


func _place(mesh: Mesh, mat: Material, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	return mi


func _ready() -> void:
	baked_dir = OS.get_environment("GOANNA_BAKED_DIR")
	if baked_dir == "":
		baked_dir = ProjectSettings.globalize_path("res://../baked/pack-mineclonia-v2/textures")
	varied_dir = OS.get_environment("GOANNA_VARIED_DIR")
	light_sun = _envf("GOANNA_SUN", light_sun)
	strengths = _strengths()

	# --- environment: lighting_chart.gd's copy of main.gd's recipe ---
	env = Environment.new()
	var sky := Sky.new()
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/sky.gdshader")
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = light_ambient
	env.ambient_light_color = Color(0.72, 0.8, 0.9)
	var tm := OS.get_environment("GOANNA_TONEMAP")
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC if tm == "filmic" else (
			Environment.TONE_MAPPER_AGX if tm == "agx" else Environment.TONE_MAPPER_ACES)
	env.tonemap_white = _envf("GOANNA_WHITE", 4.0)
	env.tonemap_exposure = _envf("GOANNA_EXPOSURE", clamp(0.46 * (1.0 + EXPOSURE_CORRECTION * 0.25), 0.1, 3.0))
	env.adjustment_enabled = true
	env.adjustment_saturation = clamp(1.12 * SATURATION, 0.0, 2.0)
	env.adjustment_contrast = 1.05
	env.adjustment_brightness = 1.0
	env.sdfgi_enabled = true
	env.sdfgi_cascades = 6
	env.sdfgi_min_cell_size = 0.5
	env.sdfgi_energy = _envf("GOANNA_SDFGI", 1.4)
	env.sdfgi_read_sky_light = true
	env.ssao_enabled = true
	env.ssao_intensity = _envf("GOANNA_SSAO", 4.0)
	env.ssao_radius = 2.2
	env.ssao_power = 1.6
	env.ssao_detail = 1.0
	env.ssao_light_affect = 0.5
	env.ssil_enabled = true
	env.ssil_intensity = 1.4
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
	sun.light_angular_distance = _envf("GOANNA_SUN_ANGLE", 0.0)
	add_child(sun)

	var plain := StandardMaterial3D.new()
	plain.albedo_color = Color(0.5, 0.5, 0.5)
	plain.roughness = 1.0
	var count := maxi(STEPS.size(), MATERIALS.size())
	var width := SPACING * (count + 1)
	var cx := SPACING * (count - 1) * 0.5
	var floor_box := BoxMesh.new()
	floor_box.size = Vector3(width + 8, 0.5, 20)
	_place(floor_box, plain, Vector3(cx, -0.25, -1))

	var mesh := _cube_mesh()
	for row in ROW_Z:
		cubes[row] = []
	close_up = OS.get_environment("GOANNA_CLOSE") != ""
	if close_up:
		# Four to a row, rows stepping back and up so every top face and
		# front face is in view, the camera low and near.
		for i in MATERIALS.size():
			var label: String = MATERIALS[i][0]
			var mat := _packed(baked_dir, MATERIALS[i][1])
			if mat == null:
				continue
			var r := i / 4
			var c := i % 4
			cubes["pack"].append([label, _place(mesh, mat,
					Vector3((c - 1.5) * 1.3, 0.5 + r * 1.15, -r * 1.3))])
		cam = Camera3D.new()
		cam.fov = 40
		cam.position = Vector3(0.0, 3.4, 5.2)
		add_child(cam)
		cam.look_at(Vector3(0.0, 1.5, -0.8), Vector3.UP)
		cam.current = true
		_apply_gain()
		await _run_cases()
		return
	for i in STEPS.size():
		var s: int = STEPS[i]
		# centred under the pack row, which is the longer one
		var x := (i - (STEPS.size() - 1) * 0.5) * SPACING + cx
		cubes["dielectric"].append(["sm%d" % s, _place(mesh, _synthetic(s, false), Vector3(x, 0.5, ROW_Z["dielectric"]))])
		cubes["metal"].append(["sm%d" % s, _place(mesh, _synthetic(s, true), Vector3(x, 0.5, ROW_Z["metal"]))])
	for i in MATERIALS.size():
		var label: String = MATERIALS[i][0]
		var mat := _packed(baked_dir, MATERIALS[i][1])
		if mat == null:
			continue
		cubes["pack"].append([label, _place(mesh, mat, Vector3(i * SPACING, 0.5, ROW_Z["pack"]))])
		if varied_dir != "":
			var vmat := _packed(varied_dir, MATERIALS[i][1])
			if vmat != null:
				cubes["pack"].append([label + "+var", _place(mesh, vmat,
						Vector3(i * SPACING, 0.5, ROW_Z["pack"] + VARIED_DZ))])

	cam = Camera3D.new()
	cam.fov = 50
	cam.position = Vector3(cx, 10.0, 20.0)
	add_child(cam)
	cam.look_at(Vector3(cx, 0.5, 0.0), Vector3.UP)
	cam.current = true
	_apply_gain()
	await _run_cases()


func _apply_gain() -> void:
	var g := _pack_gain()
	print("RAMP pack_normal_gain %.2f over %d relief maps" % [g, pack_tilts.size()])
	for m in pack_materials:
		m.set_shader_parameter("pack_normal_gain", g)


func _run_cases() -> void:
	var names: Array = CASES.keys()
	if OS.get_environment("GOANNA_TIMES") != "":
		names = Array(OS.get_environment("GOANNA_TIMES").split(",", false))
	var dir := OS.get_environment("PROBE_OUT")
	for t in names:
		if not CASES.has(t):
			push_error("material ramp: unknown case %s" % t)
			continue
		results[t] = {}
		if CASES[t].get("mirror", false):
			# One render per column, the sun mirrored to that column's cube,
			# so every step is measured at the same angle. A single sun can
			# only be at the mirror direction of one cube; laid out in a row
			# the outer columns sit degrees off it, and a smooth lobe is
			# narrower than that, so the first version of this measured the
			# layout rather than the roughness.
			var columns := maxi(STEPS.size(), MATERIALS.size())
			if close_up:
				columns = cubes["pack"].size()
			for col in columns:
				var probe := Vector3.ZERO
				var picks := []
				for row in cubes:
					for entry in cubes[row]:
						var mi: MeshInstance3D = entry[1]
						var here_col := _column_of(row, mi)
						if close_up:
							here_col = cubes[row].find(entry)
						if here_col == col:
							picks.append([row, entry[0], mi])
							probe = mi.global_position
				if picks.is_empty():
					continue
				_apply_case(CASES[t], probe)
				for i in 40:
					await get_tree().process_frame
				await RenderingServer.frame_post_draw
				var img := get_viewport().get_texture().get_image()
				if dir != "" and col == columns / 2:
					img.save_png(dir.path_join("ramp_%s.png" % t))
				for pick in picks:
					_measure_cube(t, img, pick[0], pick[1], pick[2], ["top"])
			continue
		_apply_case(CASES[t], Vector3.ZERO)
		for i in 90:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		if dir != "":
			var path := dir.path_join("ramp_%s.png" % t)
			img.save_png(path)
			print("saved ", path)
		_measure(t, img)

	var out := OS.get_environment("RAMP_OUT")
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(results, "  "))
			print("wrote ", out)
	get_tree().quit()


# Which column a cube sits in: the synthetic rows are centred under the
# longer pack row, so the two grids share column numbers only by position.
func _column_of(row: String, mi: MeshInstance3D) -> int:
	if row == "pack":
		return int(round(mi.position.x / SPACING))
	var count := maxi(STEPS.size(), MATERIALS.size())
	var cx := SPACING * (count - 1) * 0.5
	return int(round((mi.position.x - cx) / SPACING + (STEPS.size() - 1) * 0.5)) \
			+ (count - STEPS.size()) / 2


# lighting_chart.gd's _apply_time, daytime only, with the glint placement.
func _apply_case(c: Dictionary, probe: Vector3) -> void:
	var elev: float = c["sun"]
	var sun_dir: Vector3
	if c.get("mirror", false):
		# The camera's view of this cube's top face, reflected about the
		# vertical: a perfect mirror there shows the sun's disc to the camera.
		var to_cam := (cam.position - (probe + Vector3(0, 0.5, 0))).normalized()
		sun_dir = Vector3(-to_cam.x, to_cam.y, -to_cam.z).normalized()
		elev = sun_dir.y
	elif c.has("azimuth"):
		var hz := sqrt(maxf(1.0 - elev * elev, 0.0))
		sun_dir = Vector3(hz * c["azimuth"], elev, hz * 0.25).normalized()
	else:
		var h := sqrt(maxf(1.0 - elev * elev, 0.0)) / 0.403
		sun_dir = Vector3(0.35 * h, elev, 0.2 * h).normalized()
	var up := Vector3.UP if absf(sun_dir.y) < 0.999 else Vector3.FORWARD
	sun.transform = Transform3D(Basis.looking_at(-sun_dir, up), Vector3.ZERO)
	var day: float = smoothstep(-0.02, 0.18, elev)
	var warm: float = 1.0 - smoothstep(0.0, 0.32, elev)
	sun.light_color = Color(1.0, 0.98, 0.94).lerp(Color(1.0, 0.62, 0.32), warm)
	sun.light_energy = lerp(0.0, light_sun, day)
	sun.shadow_opacity = 0.85
	var zenith: Color = SKY["day_sky"]
	zenith.s = maxf(zenith.s, 0.42)
	zenith.v = minf(zenith.v, 0.92)
	var hor: Color = SKY["day_horizon"]
	sky_mat.set_shader_parameter("sky_top", zenith)
	sky_mat.set_shader_parameter("sky_horizon", hor)
	sky_mat.set_shader_parameter("ground_color", hor.darkened(0.6))
	sky_mat.set_shader_parameter("radiance_ground_lift", 1.0)
	sky_mat.set_shader_parameter("radiance_desaturate", 0.25)
	sky_mat.set_shader_parameter("radiance_floor", Vector3.ZERO)
	sky_mat.set_shader_parameter("sun_dir", sun_dir)
	sky_mat.set_shader_parameter("moon_dir", -sun_dir)
	RenderingServer.global_shader_parameter_set("goanna_sun_dir", sun_dir)
	sky_mat.set_shader_parameter("sun_visible", true)
	sky_mat.set_shader_parameter("moon_visible", false)
	sky_mat.set_shader_parameter("sun_size", 0.045)
	sky_mat.set_shader_parameter("sun_tint", sun.light_color)
	sky_mat.set_shader_parameter("star_opacity", 0.0)
	sky_mat.set_shader_parameter("cloud_coverage", 0.0)
	env.ambient_light_energy = 0.42 * light_ambient
	env.background_energy_multiplier = 0.95
	var fill: Color = hor.lerp(Color(hor.v, hor.v, hor.v), 0.5) * 0.4
	RenderingServer.global_shader_parameter_set("goanna_sky_fill", Vector3(fill.r, fill.g, fill.b))


func _patch(img: Image, world: Vector3, half: int) -> Dictionary:
	var p := cam.unproject_position(world)
	return _patch_px(img, int(p.x), int(p.y), half)


func _patch_px(img: Image, px: int, py: int, half: int) -> Dictionary:
	var acc := Vector3.ZERO
	var l_acc := 0.0
	var l_acc2 := 0.0
	var l_max := 0.0
	var n := 0
	for dy in range(-half, half + 1):
		for dx in range(-half, half + 1):
			var x := px + dx
			var y := py + dy
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var c := img.get_pixel(x, y)
			acc += Vector3(c.r, c.g, c.b) * 255.0
			var l := _luma(c) * 255.0
			l_acc += l
			l_acc2 += l * l
			l_max = maxf(l_max, l)
			n += 1
	var mean := l_acc / maxf(n, 1)
	return {
		"rgb": acc / maxf(n, 1),
		"luma": mean,
		"sd": sqrt(maxf(l_acc2 / maxf(n, 1) - mean * mean, 0.0)),
		"max": l_max,
	}


func _measure(case_name: String, img: Image) -> void:
	var per: Dictionary = results[case_name]
	# The sky as rendered: straight up is off screen at this pitch, so the
	# top row of the frame stands in for the zenith, and a patch just above
	# the floor's far edge for the horizon.
	var zen := _patch_px(img, img.get_width() / 2, 4, 3)
	var hor := _patch_px(img, img.get_width() / 2, int(cam.unproject_position(Vector3(cam.position.x, 0.0, -400.0)).y) - 6, 3)
	print("RAMP %s sky top-of-frame rgb=%d,%d,%d horizon rgb=%d,%d,%d" % [case_name,
			zen["rgb"].x, zen["rgb"].y, zen["rgb"].z, hor["rgb"].x, hor["rgb"].y, hor["rgb"].z])
	per["sky"] = {"top": [zen["rgb"].x, zen["rgb"].y, zen["rgb"].z],
			"horizon": [hor["rgb"].x, hor["rgb"].y, hor["rgb"].z]}
	for row in cubes:
		for entry in cubes[row]:
			_measure_cube(case_name, img, row, entry[0], entry[1], ["top", "front"])


func _measure_cube(case_name: String, img: Image, row: String, label: String,
		mi: MeshInstance3D, faces: Array) -> void:
	var per: Dictionary = results[case_name]
	for face in faces:
		var half := (5 if face == "top" else 6) * (6 if close_up else 1)
		var r: Dictionary = _patch(img, mi.global_position
				+ (Vector3(0, 0.51, 0) if face == "top" else Vector3(0, 0, 0.51)), half)
		var rgb: Vector3 = r["rgb"]
		print("RAMP %s %s %s %s rgb=%d,%d,%d luma=%.0f sd=%.1f max=%.0f" % [
			case_name, row, label, face, rgb.x, rgb.y, rgb.z, r["luma"], r["sd"], r["max"]])
		per["%s/%s/%s" % [row, label, face]] = {
			"rgb": [rgb.x, rgb.y, rgb.z], "luma": r["luma"], "sd": r["sd"], "max": r["max"]}
