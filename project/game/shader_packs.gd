# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## The shader pack folder and the player's choice of pack: which packs are
## in user://shaderpacks, unpacking a zipped one once into a cache, the
## options a pack declares (as Iris lists them), the overrides the player
## saved for each pack, and a one line note of how the last join's pack
## went. Static only. Preloaded by game/main.gd (which loads the chosen
## pack at each join), ui/shader_pack_row.gd (the settings row both
## settings screens build) and tests/shader_packs.gd.
##
## GOANNA_SHADERPACK still wins over all of this: main.gd only asks here
## when it is unset. See docs/play/settings.md and
## docs/develop/shaderpack-testing.md.
extends RefCounted

## Where a player drops packs: a directory holding shaders/, or a zip as
## Modrinth and CurseForge hand them out.
const DIR := "user://shaderpacks"
## Where zips are unpacked, one directory per zip and modification time,
## so a zip is read once rather than at every join.
const CACHE := "user://shaderpack_cache"
const CFG := "user://goanna.cfg"
## The pack's file or directory name; empty is Off.
const KEY := "shader_pack"
## Overrides live in a section per pack, this followed by its name.
const OPTIONS_SECTION := "shaderpack_options/"
## How the last join's pack went, written by main.gd.
const STATUS_SECTION := "shaderpack_status"

# Source files the option scan reads, as Iris does: every program and
# include under shaders/.
const SOURCE_EXTENSIONS := ["glsl", "fsh", "vsh", "gsh", "csh", "tcs", "tes", "inc", "frag", "vert"]

# GOANNA_SHADERPACK_OPTIONS as the process started, before main.gd merged
# a pack's saved overrides into it, so a second join merges into what the
# player typed and not into the first join's merge.
static var _env_options_at_start = null

# --- the folder --------------------------------------------------------------

## The folder's absolute path, created if it is missing, so the settings row
## can show a path that exists and a file manager can open it.
static func folder(dir := DIR) -> String:
	var dir_abs := ProjectSettings.globalize_path(dir)
	DirAccess.make_dir_recursive_absolute(dir_abs)
	return dir_abs

## The packs in `dir`, sorted by name without regard to case: each a
## Dictionary of name (the file or directory name, which is what is saved),
## path (absolute) and kind ("dir" or "zip"). A directory counts when it
## holds shaders/ itself; a zip when shaders/ is at its top or one directory
## down. Anything else, and hidden names, are left out.
static func scan(dir := DIR) -> Array:
	var dir_abs := ProjectSettings.globalize_path(dir)
	var out: Array = []
	var d := DirAccess.open(dir_abs)
	if d == null:
		return out
	d.include_hidden = false
	for entry in d.get_directories():
		if entry.begins_with("."):
			continue
		if DirAccess.dir_exists_absolute(dir_abs.path_join(entry).path_join("shaders")):
			out.append({"name": entry, "path": dir_abs.path_join(entry), "kind": "dir"})
	for entry in d.get_files():
		if entry.begins_with(".") or entry.get_extension().to_lower() != "zip":
			continue
		var path := dir_abs.path_join(entry)
		if zip_prefix(path) != null:
			out.append({"name": entry, "path": path, "kind": "zip"})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)
	return out

## The directory inside a zip that holds shaders/: "" when shaders/ is at
## the top, "Name/" when the pack is one directory down, null when it is not
## a pack at all (or not a readable zip).
static func zip_prefix(zip_path: String) -> Variant:
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK:
		return null
	var files := zip.get_files()
	zip.close()
	var best: Variant = null
	for f in files:
		var parts := f.split("/")
		if parts.size() >= 2 and parts[0] == "shaders":
			return ""
		if parts.size() >= 3 and parts[1] == "shaders" and best == null:
			best = parts[0] + "/"
	return best

## A pack's name as shown: a zip's without the extension.
static func display_name(name: String) -> String:
	return name.get_basename() if name.get_extension().to_lower() == "zip" else name

# --- resolving a choice to a directory ------------------------------------------

## The directory Goanna's loader reads for pack `name` in `dir`: the
## directory itself, or for a zip the place it was unpacked to, unpacking
## it first when this zip at this modification time has not been. Returns
## {path} or {error}.
static func resolve(name: String, dir := DIR, cache := CACHE) -> Dictionary:
	if name == "" or name.contains("/") or name.contains("\\") or name.begins_with("."):
		return {"error": "no pack named '%s'" % name}
	var src := ProjectSettings.globalize_path(dir).path_join(name)
	if DirAccess.dir_exists_absolute(src):
		if not DirAccess.dir_exists_absolute(src.path_join("shaders")):
			return {"error": "%s has no shaders folder" % name}
		return {"path": src}
	if not FileAccess.file_exists(src):
		return {"error": "%s is no longer in the shader pack folder" % name}
	var prefix = zip_prefix(src)
	if prefix == null:
		return {"error": "%s is not a shader pack zip (no shaders folder inside)" % name}
	var key := "%s-%d" % [_safe(name), FileAccess.get_modified_time(src)]
	var cache_abs := ProjectSettings.globalize_path(cache)
	var unpacked := cache_abs.path_join(key)
	# The loader names a pack after its directory, so the zip's own name
	# without .zip is the last part of the path, not the cache key.
	var root := unpacked.path_join(_safe(display_name(name)))
	if not FileAccess.file_exists(unpacked.path_join(".complete")):
		_remove_tree(unpacked)
		var err := _unzip(src, str(prefix), root)
		if err != "":
			_remove_tree(unpacked)
			return {"error": err}
		var mark := FileAccess.open(unpacked.path_join(".complete"), FileAccess.WRITE)
		if mark != null:
			mark.store_line(name)
			mark.close()
		_drop_stale(cache_abs, name, key)
	return {"path": root}

# Earlier unpackings of the same zip (it was replaced by a newer file).
static func _drop_stale(cache_abs: String, name: String, keep: String) -> void:
	var d := DirAccess.open(cache_abs)
	if d == null:
		return
	for entry in d.get_directories():
		if entry == keep:
			continue
		var mark := cache_abs.path_join(entry).path_join(".complete")
		if FileAccess.file_exists(mark) and FileAccess.get_file_as_string(mark).strip_edges() == name:
			_remove_tree(cache_abs.path_join(entry))

static func _unzip(zip_path: String, prefix: String, dest: String) -> String:
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK:
		return "could not open %s" % zip_path.get_file()
	DirAccess.make_dir_recursive_absolute(dest)
	for f in zip.get_files():
		if not f.begins_with(prefix) or f.ends_with("/"):
			continue
		var rel := f.substr(prefix.length())
		# A zip names its own paths; never let one climb out of the cache.
		if rel == "" or rel.begins_with("/") or rel.contains("\\") or rel.contains(":") \
				or ("/" + rel + "/").contains("/../"):
			continue
		var out := dest.path_join(rel)
		DirAccess.make_dir_recursive_absolute(out.get_base_dir())
		var fa := FileAccess.open(out, FileAccess.WRITE)
		if fa == null:
			zip.close()
			return "could not write %s" % out
		fa.store_buffer(zip.read_file(f))
		fa.close()
	zip.close()
	return ""

static func _safe(name: String) -> String:
	var out := ""
	for c in name:
		out += c if (c.is_valid_identifier() or c.is_valid_int() or c in ".-+ ()") else "_"
	return out

static func _remove_tree(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true
	for sub in d.get_directories():
		_remove_tree(path.path_join(sub))
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)

# --- options -------------------------------------------------------------------

# An option line, as src/iris/iris_pack.cpp's matchDefine reads it:
# "#define NAME", "#define NAME value" or "//#define NAME", with an optional
# trailing comment where the allowed values are listed in brackets.
static var _define_re: RegEx
static var _ref_re: RegEx

static func _regexes() -> void:
	if _define_re != null:
		return
	_define_re = RegEx.create_from_string(
			"^\\s*(//\\s*)?#define\\s+([A-Za-z_]\\w*)(?:[ \\t]+([^/\\r\\n]*?))?\\s*(?://(.*))?\\r?$")
	_ref_re = RegEx.create_from_string(
			"#\\s*(?:ifdef|ifndef)\\s+([A-Za-z_]\\w*)|defined\\s*\\(?\\s*([A-Za-z_]\\w*)")

## The options of the pack whose root (the directory holding shaders/) is
## `root`, as Iris lists them: a boolean is a value-less #define (on) or a
## commented one (off) that some source tests with #ifdef, #ifndef or
## defined; a value option is a #define whose comment lists its allowed
## values in brackets. Returns {options: {NAME: {kind "bool" or "value",
## default, values, label, comment, value_labels}}, layout: [{heading,
## depth} or {option}]}. The layout follows shaders.properties' screen
## lines where the pack has them (only what they show, as in Iris), else
## every option by name.
static func read_options(root: String) -> Dictionary:
	_regexes()
	var shaders := root.path_join("shaders")
	var files: Array = []
	_source_files(shaders, files)
	files.sort()
	var found := {}
	var order: Array = []
	var referenced := {}
	for path in files:
		var text := FileAccess.get_file_as_string(path)
		if text == "":
			continue
		for m in _ref_re.search_all(text):
			var n := m.get_string(1) if m.get_string(1) != "" else m.get_string(2)
			referenced[n] = true
		if not text.contains("#define"):
			continue
		for line in text.split("\n"):
			if not line.contains("#define"):
				continue
			var m := _define_re.search(line)
			if m == null:
				continue
			var name := m.get_string(2)
			if found.has(name):
				continue
			var commented := m.get_string(1) != ""
			var value := m.get_string(3).strip_edges()
			var comment := m.get_string(4)
			if commented and value != "":
				continue
			if value == "":
				found[name] = {"kind": "bool", "default": "false" if commented else "true",
					"values": ["true", "false"]}
				order.append(name)
				continue
			var a := comment.find("[")
			var b := comment.find("]", a + 1)
			if a < 0 or b < 0:
				# A plain #define NAME value is a constant, not an option;
				# remember it was seen so a later bracketed one is not one either.
				found[name] = {"kind": "const"}
				continue
			var values: Array = []
			for v in comment.substr(a + 1, b - a - 1).split(" ", false):
				values.append(v)
			if not values.has(value):
				values.push_front(value)
			found[name] = {"kind": "value", "default": value, "values": values}
			order.append(name)
	var options := {}
	for name in order:
		var o: Dictionary = found[name]
		if o["kind"] == "bool" and not referenced.has(name):
			continue
		options[name] = o
	var lang := _read_lang(shaders)
	for name in options:
		var o: Dictionary = options[name]
		o["label"] = _plain(str(lang.get("option." + name, name)))
		o["comment"] = _plain(str(lang.get("option." + name + ".comment", "")))
		var labels := {}
		for v in o["values"]:
			var k := "value.%s.%s" % [name, v]
			if lang.has(k):
				labels[v] = _plain(str(lang[k]))
		o["value_labels"] = labels
	return {"options": options, "layout": _layout(shaders, options, lang)}

static func _source_files(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		_source_files(dir.path_join(sub), out)
	for f in d.get_files():
		if SOURCE_EXTENSIONS.has(f.get_extension().to_lower()):
			out.append(dir.path_join(f))

static func _read_lang(shaders: String) -> Dictionary:
	var out := {}
	var d := DirAccess.open(shaders.path_join("lang"))
	if d == null:
		return out
	var file := ""
	for f in d.get_files():
		if f.to_lower() == "en_us.lang":
			file = f
	if file == "":
		return out
	for line in FileAccess.get_file_as_string(shaders.path_join("lang").path_join(file)).split("\n"):
		var t := line.strip_edges()
		if t == "" or t.begins_with("#"):
			continue
		var eq := t.find("=")
		if eq > 0:
			out[t.substr(0, eq).strip_edges()] = t.substr(eq + 1).strip_edges()
	return out

# Minecraft's formatting codes (a section sign and one character) mean
# nothing here.
static func _plain(s: String) -> String:
	var out := ""
	var skip := false
	for c in s:
		if skip:
			skip = false
			continue
		if c == "§":
			skip = true
			continue
		out += c
	return out

# shaders.properties' screen lines, first of each key. Conditionals around
# them are not run: the first branch's layout is the one shown.
static func _screens(shaders: String) -> Dictionary:
	var out := {}
	var text := FileAccess.get_file_as_string(shaders.path_join("shaders.properties"))
	var pending := ""
	for raw in text.split("\n"):
		var t := raw.strip_edges()
		if pending != "":
			t = pending + " " + t
			pending = ""
		if t.ends_with("\\"):
			pending = t.substr(0, t.length() - 1)
			continue
		if not t.begins_with("screen"):
			continue
		var eq := t.find("=")
		if eq < 0:
			continue
		var key := t.substr(0, eq).strip_edges()
		if key.ends_with(".columns"):
			continue
		if key == "screen" or key.begins_with("screen."):
			if not out.has(key):
				out[key] = t.substr(eq + 1).strip_edges().split(" ", false)
	return out

static func _layout(shaders: String, options: Dictionary, lang: Dictionary) -> Array:
	var screens := _screens(shaders)
	var out: Array = []
	if not screens.has("screen"):
		var names := options.keys()
		names.sort()
		for n in names:
			out.append({"option": n})
		return out
	var shown := {}
	_walk_screen(screens, "screen", 0, options, lang, out, shown, {})
	return out

static func _walk_screen(screens: Dictionary, key: String, depth: int, options: Dictionary,
		lang: Dictionary, out: Array, shown: Dictionary, visited: Dictionary) -> void:
	if visited.has(key) or depth > 8:
		return
	visited[key] = true
	var subs: Array = []
	for token in screens[key]:
		if token.begins_with("[") and token.ends_with("]"):
			subs.append(token.substr(1, token.length() - 2))
		elif token == "*":
			var rest := options.keys()
			rest.sort()
			for n in rest:
				if not shown.has(n):
					shown[n] = true
					out.append({"option": n})
		elif options.has(token) and not shown.has(token):
			shown[token] = true
			out.append({"option": token})
	# Sub screens after the screen's own options, each under its heading.
	for sub in subs:
		var sk: String = "screen." + str(sub)
		if not screens.has(sk) or visited.has(sk):
			continue
		var at := out.size()
		out.append({"heading": _plain(str(lang.get(sk, sub.capitalize()))), "depth": depth + 1})
		_walk_screen(screens, sk, depth + 1, options, lang, out, shown, visited)
		# A heading with nothing under it (a screen of const options only).
		if out.size() == at + 1:
			out.pop_back()

# --- saved choices ----------------------------------------------------------------

static func chosen(cfg_path := CFG) -> String:
	var cfg := ConfigFile.new()
	cfg.load(cfg_path)
	return str(cfg.get_value("settings", KEY, ""))

static func set_chosen(name: String, cfg_path := CFG) -> void:
	var cfg := ConfigFile.new()
	cfg.load(cfg_path)
	cfg.set_value("settings", KEY, name)
	cfg.save(cfg_path)

## The saved overrides for pack `name`, NAME to value text.
static func saved_options(name: String, cfg_path := CFG) -> Dictionary:
	var cfg := ConfigFile.new()
	cfg.load(cfg_path)
	var out := {}
	var section := OPTIONS_SECTION + name
	if cfg.has_section(section):
		for k in cfg.get_section_keys(section):
			out[k] = str(cfg.get_value(section, k))
	return out

## Saves one override; `value` equal to the pack's default removes it, so
## only what the player moved is kept and a pack's new default is followed.
static func save_option(name: String, option: String, value: String, default: String,
		cfg_path := CFG) -> void:
	var cfg := ConfigFile.new()
	cfg.load(cfg_path)
	var section := OPTIONS_SECTION + name
	if value == default:
		if cfg.has_section_key(section, option):
			cfg.erase_section_key(section, option)
	else:
		cfg.set_value(section, option, value)
	cfg.save(cfg_path)

static func clear_options(name: String, cfg_path := CFG) -> void:
	var cfg := ConfigFile.new()
	cfg.load(cfg_path)
	if cfg.has_section(OPTIONS_SECTION + name):
		cfg.erase_section(OPTIONS_SECTION + name)
	cfg.save(cfg_path)

## Overrides in GOANNA_SHADERPACK_OPTIONS's form, NAME=value joined by
## commas, sorted so the same choice always reads the same.
static func options_text(overrides: Dictionary) -> String:
	var keys := overrides.keys()
	keys.sort()
	var parts: PackedStringArray = []
	for k in keys:
		parts.append("%s=%s" % [k, overrides[k]])
	return ",".join(parts)

## `saved` with `env` (GOANNA_SHADERPACK_OPTIONS text) over the top: a
## name set in the environment wins, as the environment wins elsewhere.
static func merge_options(saved: Dictionary, env: String) -> String:
	var merged := saved.duplicate()
	for item in env.replace(",", " ").split(" ", false):
		var eq := item.find("=")
		if eq > 0:
			merged[item.substr(0, eq)] = item.substr(eq + 1)
	return options_text(merged)

## What main.gd loads at a join when GOANNA_SHADERPACK is unset: {} for
## Off, else {name, path} or {name, error}. Sets GOANNA_SHADERPACK_OPTIONS
## to the pack's saved overrides under whatever the variable held when the
## process started, since both halves of the loader read the options from
## there (src/iris/iris_pack.h, parseOptionOverrides).
static func prepare_join(cfg_path := CFG, dir := DIR, cache := CACHE) -> Dictionary:
	var name := chosen(cfg_path)
	if _env_options_at_start == null:
		_env_options_at_start = OS.get_environment("GOANNA_SHADERPACK_OPTIONS")
	if name == "":
		OS.set_environment("GOANNA_SHADERPACK_OPTIONS", str(_env_options_at_start))
		return {}
	var r := resolve(name, dir, cache)
	r["name"] = name
	if r.has("error"):
		return r
	var text := merge_options(saved_options(name, cfg_path), str(_env_options_at_start))
	OS.set_environment("GOANNA_SHADERPACK_OPTIONS", text)
	r["options"] = text
	return r

# --- the last join's result ---------------------------------------------------------

## One line for the settings row from the loader's reports: `chain` is
## GoannaIrisEffect.report() (or {} when the pack has no chain or it was
## not made), `gbuffers` GoannaIrisGbuffers.report() (or {}).
static func summary(chain: Dictionary, gbuffers: Dictionary) -> String:
	var bits: PackedStringArray = []
	var missing: Array = chain.get("missing_features", [])
	if not missing.is_empty():
		return "Not loaded: it needs Iris features Goanna does not have (%s)." % ", ".join(missing)
	var load_error := str(chain.get("load_error", gbuffers.get("error", "")))
	if load_error != "" and chain.get("passes", []).is_empty() and not _any_surface(gbuffers):
		return "Not loaded: %s" % load_error.strip_edges().get_slice("\n", 0)
	var passes: Array = chain.get("passes", [])
	if not passes.is_empty():
		var ok := 0
		for p in passes:
			if bool(p.get("compiled", false)):
				ok += 1
		if bool(chain.get("gpu_ready", false)):
			bits.append("%d of %d screen passes compiled" % [ok, passes.size()])
		else:
			bits.append("%d screen passes, not yet compiled" % passes.size())
	var surfaces: PackedStringArray = []
	for s in ["terrain", "cutout", "water", "foliage"]:
		var e = gbuffers.get(s, {})
		if e is Dictionary and bool(e.get("translated", false)):
			surfaces.append(s)
	if not surfaces.is_empty():
		var listed := ", ".join(surfaces.slice(0, surfaces.size() - 1))
		listed = surfaces[0] if surfaces.size() == 1 else listed + " and " + surfaces[surfaces.size() - 1]
		bits.append("its own %s shading" % listed)
	var shadow = gbuffers.get("shadow", {})
	if shadow is Dictionary and bool(shadow.get("translated", false)):
		bits.append("its shadow map")
	var unknown: Array = chain.get("unknown_options", [])
	if not unknown.is_empty():
		bits.append("%d saved options it does not have" % unknown.size())
	if bits.is_empty():
		return "Loaded, but nothing in it could be used."
	return "Loaded: " + "; ".join(bits) + "."

static func _any_surface(gbuffers: Dictionary) -> bool:
	for s in ["terrain", "cutout", "water", "foliage"]:
		var e = gbuffers.get(s, {})
		if e is Dictionary and bool(e.get("translated", false)):
			return true
	return false

static func save_status(name: String, text: String, cfg_path := CFG) -> void:
	var cfg := ConfigFile.new()
	cfg.load(cfg_path)
	cfg.set_value(STATUS_SECTION, "pack", name)
	cfg.set_value(STATUS_SECTION, "text", text)
	cfg.set_value(STATUS_SECTION, "time", Time.get_datetime_string_from_system(false, true))
	cfg.save(cfg_path)

## {pack, text, time} from the last join that loaded a pack from the
## setting, or {}.
static func last_status(cfg_path := CFG) -> Dictionary:
	var cfg := ConfigFile.new()
	cfg.load(cfg_path)
	if not cfg.has_section(STATUS_SECTION):
		return {}
	return {"pack": str(cfg.get_value(STATUS_SECTION, "pack", "")),
		"text": str(cfg.get_value(STATUS_SECTION, "text", "")),
		"time": str(cfg.get_value(STATUS_SECTION, "time", ""))}
