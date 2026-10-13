## The shader pack folder and setting (game/shader_packs.gd): which entries
## count as packs (a directory, a zip, a zip with the pack one directory
## down, and things that are not packs), unpacking a zip once and again
## when it changes, the options a pack offers, and saving the choice and
## each pack's overrides. Works in its own scratch directory under user://
## and its own config file, so it never touches the player's. Headless, no
## server or GPU:
## godot --headless --path project --script res://tests/shader_packs.gd
extends SceneTree

const ShaderPacks := preload("res://game/shader_packs.gd")

var failures := 0
var scratch := ""

func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok   ", what)
	else:
		failures += 1
		printerr("  FAIL ", what)

func _equal(a: Variant, b: Variant, what: String) -> void:
	_check(a == b, "%s (got %s, want %s)" % [what, str(a), str(b)])

func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func _zip(path: String, files: Dictionary) -> void:
	var z := ZIPPacker.new()
	z.open(path)
	for name in files:
		z.start_file(name)
		z.write_file(str(files[name]).to_utf8_buffer())
		z.close_file()
	z.close()

const SETTINGS_GLSL := """
#define SHADOWS
//#define BLOOM // Glow round bright things
#define UNUSED_FLAG
#define QUALITY 2 // [1 2 3]
#define STRENGTH 0.50 //[0.25 0.50 1.00]
#define PI 3.14159
const int shadowMapResolution = 2048; //[1024 2048]
"""

const COMPOSITE := """#version 120
#include "/lib/settings.glsl"
#ifdef SHADOWS
#endif
#if defined(BLOOM) && QUALITY > 1
#endif
void main() { gl_FragData[0] = vec4(STRENGTH); }
"""

const PROPERTIES := """
screen=QUALITY [EFFECTS] <empty>
screen.EFFECTS=BLOOM SHADOWS
"""

const LANG := """option.QUALITY=Quality
option.QUALITY.comment=How hard it tries
value.QUALITY.1=Low
screen.EFFECTS=§aEffects
option.BLOOM=Bloom
"""

func _init() -> void:
	scratch = ProjectSettings.globalize_path("user://shader-packs-test-%d" % OS.get_process_id())
	ShaderPacks._remove_tree(scratch)
	var packs := scratch.path_join("shaderpacks")
	var cache := scratch.path_join("cache")
	var cfg := scratch.path_join("goanna.cfg")
	DirAccess.make_dir_recursive_absolute(packs)

	# A directory pack, with options, screens and a language file.
	_write(packs.path_join("Alpha/shaders/lib/settings.glsl"), SETTINGS_GLSL)
	_write(packs.path_join("Alpha/shaders/composite.fsh"), COMPOSITE)
	_write(packs.path_join("Alpha/shaders/shaders.properties"), PROPERTIES)
	_write(packs.path_join("Alpha/shaders/lang/en_US.lang"), LANG)
	# A zip with shaders/ at the top, as most downloads are.
	_zip(packs.path_join("Beta.zip"), {"shaders/final.fsh": "void main() {}",
		"shaders/lib/settings.glsl": "#define FOO\n#ifdef FOO\n#endif\n"})
	# A zip holding the pack one directory down, and an entry that tries to
	# climb out of the cache.
	_zip(packs.path_join("Gamma.zip"), {"Gamma v1/shaders/final.fsh": "void main() {}",
		"Gamma v1/shaders/composite.fsh": "void main() {}",
		"Gamma v1/readme.txt": "hello",
		"Gamma v1/../../escaped.txt": "out"})
	# Things that are not packs.
	DirAccess.make_dir_recursive_absolute(packs.path_join("notes"))
	_write(packs.path_join("notes/readme.txt"), "not a pack")
	_zip(packs.path_join("textures.zip"), {"assets/stone.png": "x"})
	_write(packs.path_join("broken.zip"), "this is not a zip")
	_write(packs.path_join("pack.txt"), "nor this")
	DirAccess.make_dir_recursive_absolute(packs.path_join(".hidden/shaders"))

	print("scan")
	var found := ShaderPacks.scan(packs)
	var names: Array = []
	for p in found:
		names.append(p["name"])
	_equal(names, ["Alpha", "Beta.zip", "Gamma.zip"], "packs found, others left out")
	_equal(found[0]["kind"], "dir", "Alpha is a directory pack")
	_equal(found[1]["kind"], "zip", "Beta is a zip pack")
	_equal(ShaderPacks.zip_prefix(packs.path_join("Beta.zip")), "", "Beta's shaders/ is at the top")
	_equal(ShaderPacks.zip_prefix(packs.path_join("Gamma.zip")), "Gamma v1/", "Gamma's is one down")
	_equal(ShaderPacks.zip_prefix(packs.path_join("textures.zip")), null, "a texture zip is no pack")
	_equal(ShaderPacks.display_name("Gamma.zip"), "Gamma", "zip shown without .zip")

	print("resolve")
	var a := ShaderPacks.resolve("Alpha", packs, cache)
	_equal(a.get("path", ""), packs.path_join("Alpha"), "a directory pack is read in place")
	var g := ShaderPacks.resolve("Gamma.zip", packs, cache)
	var gpath := str(g.get("path", ""))
	_check(gpath.begins_with(cache), "a zip is unpacked into the cache")
	_equal(gpath.get_file(), "Gamma", "named after the zip, so the loader names it so")
	_check(FileAccess.file_exists(gpath.path_join("shaders/final.fsh")), "the nested pack unpacked")
	_check(FileAccess.file_exists(gpath.path_join("readme.txt")), "with its other files")
	_check(not FileAccess.file_exists(scratch.path_join("escaped.txt"))
			and not FileAccess.file_exists(cache.path_join("escaped.txt"))
			and not FileAccess.file_exists(gpath.get_base_dir().path_join("escaped.txt")),
			"an entry climbing out of the cache is not written")
	# Unpacked once: a second resolve leaves what is there alone.
	DirAccess.remove_absolute(gpath.path_join("readme.txt"))
	var g2 := ShaderPacks.resolve("Gamma.zip", packs, cache)
	_equal(g2.get("path", ""), gpath, "same place the second time")
	_check(not FileAccess.file_exists(gpath.path_join("readme.txt")), "and not unpacked again")
	# A newer zip of the same name is unpacked afresh and the old copy dropped.
	OS.delay_msec(1100)
	_zip(packs.path_join("Gamma.zip"), {"Gamma v2/shaders/final.fsh": "void main() {}"})
	var g3 := ShaderPacks.resolve("Gamma.zip", packs, cache)
	_check(str(g3.get("path", "")) != gpath, "a changed zip unpacks to a new place")
	_check(FileAccess.file_exists(str(g3.get("path", "")).path_join("shaders/final.fsh")), "with its files")
	_check(not DirAccess.dir_exists_absolute(gpath), "the stale copy is removed")
	var b := ShaderPacks.resolve("Beta.zip", packs, cache)
	_check(FileAccess.file_exists(str(b.get("path", "")).path_join("shaders/final.fsh")), "a top level zip unpacks")
	_check(ShaderPacks.resolve("textures.zip", packs, cache).has("error"), "a non-pack zip is refused")
	_check(ShaderPacks.resolve("notes", packs, cache).has("error"), "a non-pack folder is refused")
	_check(ShaderPacks.resolve("Missing", packs, cache).has("error"), "a missing pack is refused")
	_check(ShaderPacks.resolve("../Alpha", packs, cache).has("error"), "a name with a path is refused")

	print("options")
	var read := ShaderPacks.read_options(packs.path_join("Alpha"))
	var opts: Dictionary = read["options"]
	var keys := opts.keys()
	keys.sort()
	_equal(keys, ["BLOOM", "QUALITY", "SHADOWS", "STRENGTH"], "booleans tested somewhere and bracketed values")
	_equal(opts["SHADOWS"]["default"], "true", "a #define is on")
	_equal(opts["BLOOM"]["default"], "false", "a commented #define is off")
	_equal(opts["QUALITY"]["kind"], "value", "a bracketed define is a value option")
	_equal(opts["QUALITY"]["values"], ["1", "2", "3"], "with its listed values")
	_equal(opts["QUALITY"]["label"], "Quality", "named from the language file")
	_equal(opts["QUALITY"]["comment"], "How hard it tries", "and described from it")
	_equal(opts["QUALITY"]["value_labels"], {"1": "Low"}, "values named where the file names them")
	_equal(opts["STRENGTH"]["default"], "0.50", "a decimal value option")
	var layout: Array = read["layout"]
	_equal(layout, [{"option": "QUALITY"}, {"heading": "Effects", "depth": 1},
		{"option": "BLOOM"}, {"option": "SHADOWS"}],
		"laid out by the pack's screens, formatting codes dropped, unscreened options hidden")
	var beta_read := ShaderPacks.read_options(str(b["path"]))
	_equal(beta_read["layout"], [{"option": "FOO"}], "no screens: every option by name")

	print("saving")
	_equal(ShaderPacks.chosen(cfg), "", "Off before anything is chosen")
	ShaderPacks.set_chosen("Gamma.zip", cfg)
	_equal(ShaderPacks.chosen(cfg), "Gamma.zip", "the choice is saved by name")
	ShaderPacks.save_option("Alpha", "BLOOM", "true", "false", cfg)
	ShaderPacks.save_option("Alpha", "QUALITY", "3", "2", cfg)
	ShaderPacks.save_option("Alpha", "SHADOWS", "true", "true", cfg)
	_equal(ShaderPacks.saved_options("Alpha", cfg), {"BLOOM": "true", "QUALITY": "3"},
			"overrides saved per pack, defaults not kept")
	ShaderPacks.save_option("Alpha", "QUALITY", "2", "2", cfg)
	_equal(ShaderPacks.saved_options("Alpha", cfg), {"BLOOM": "true"}, "back to the default forgets it")
	_equal(ShaderPacks.saved_options("Gamma.zip", cfg), {}, "another pack's are its own")
	_equal(ShaderPacks.options_text({"QUALITY": "3", "BLOOM": "true"}), "BLOOM=true,QUALITY=3",
			"in GOANNA_SHADERPACK_OPTIONS's form")
	_equal(ShaderPacks.merge_options({"BLOOM": "true", "QUALITY": "3"}, "QUALITY=1, SHADOWS=false"),
			"BLOOM=true,QUALITY=1,SHADOWS=false", "the environment wins name by name")
	var other := ConfigFile.new()
	other.load(cfg)
	other.set_value("settings", "fov", 80.0)
	other.save(cfg)
	ShaderPacks.set_chosen("Alpha", cfg)
	var reread := ConfigFile.new()
	reread.load(cfg)
	_equal(reread.get_value("settings", "fov", 0.0), 80.0, "other settings are kept")

	print("joining")
	var saved_env := OS.get_environment("GOANNA_SHADERPACK_OPTIONS")
	var j := ShaderPacks.prepare_join(cfg, packs, cache)
	_equal(j.get("path", ""), packs.path_join("Alpha"), "a join loads the chosen pack")
	_equal(OS.get_environment("GOANNA_SHADERPACK_OPTIONS"),
			ShaderPacks.merge_options({"BLOOM": "true"}, saved_env), "with its saved options")
	ShaderPacks.set_chosen("", cfg)
	_equal(ShaderPacks.prepare_join(cfg, packs, cache), {}, "Off loads nothing")
	_equal(OS.get_environment("GOANNA_SHADERPACK_OPTIONS"), saved_env, "and puts the options back")
	ShaderPacks.set_chosen("Gone.zip", cfg)
	_check(ShaderPacks.prepare_join(cfg, packs, cache).has("error"), "a pack since removed is an error, not a crash")

	print("status")
	_equal(ShaderPacks.summary({"missing_features": ["SSBO"]}, {}),
			"Not loaded: it needs Iris features Goanna does not have (SSBO).", "missing features")
	_equal(ShaderPacks.summary({"load_error": "no programs (*.fsh) in x\n", "passes": []}, {}),
			"Not loaded: no programs (*.fsh) in x", "a load error")
	_equal(ShaderPacks.summary({"gpu_ready": true, "passes": [{"compiled": true}, {"compiled": false}]},
			{"terrain": {"translated": true}, "water": {"translated": true}, "shadow": {"translated": true}}),
			"Loaded: 1 of 2 screen passes compiled; its own terrain and water shading; its shadow map.",
			"what compiled")
	ShaderPacks.save_status("Alpha", "Loaded: x.", cfg)
	_equal(ShaderPacks.last_status(cfg)["text"], "Loaded: x.", "the note is saved")

	print("scripts")
	# The settings row and the two screens that build it, compiled.
	for path in ["res://ui/shader_pack_row.gd", "res://ui/game_ui.gd", "res://menu/menu.gd", "res://game/main.gd"]:
		var script: Script = load(path)
		_check(script != null and script.can_instantiate(), "%s compiles" % path)

	# The row itself builds: a picker that starts with Off, the folder's path
	# as text that cannot be edited, and a button to open it. It reads the
	# player's own settings and folder but writes nothing until used.
	var row := VBoxContainer.new()
	get_root().add_child(row)
	load("res://ui/shader_pack_row.gd").build(row, "description")
	var pickers := row.find_children("*", "OptionButton", true, false)
	_check(pickers.size() == 1 and (pickers[0] as OptionButton).get_item_text(0) == "Off",
			"the row offers Off first")
	var paths := row.find_children("*", "LineEdit", true, false)
	_check(paths.size() == 1 and not (paths[0] as LineEdit).editable
			and (paths[0] as LineEdit).text == ShaderPacks.folder(), "the folder is shown, read only")
	row.queue_free()

	ShaderPacks._remove_tree(scratch)
	if failures > 0:
		printerr("shader packs: FAIL (%d)" % failures)
		quit(1)
	else:
		print("shader packs: PASS")
		quit()
