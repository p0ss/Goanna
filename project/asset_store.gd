# SPDX-License-Identifier: MIT
# Versioned, independently installed Goanna asset bundles.
extends RefCounted
class_name GoannaAssetStore

const SCHEMA := "org.goanna.asset-bundle/v1"
const CATALOGUE_SCHEMA := "org.goanna.asset-catalogue/v1"

static func parse_catalogue(text: String) -> Dictionary:
	var value = JSON.parse_string(text)
	if value is not Dictionary or value.get("schema", "") != CATALOGUE_SCHEMA \
			or not value.get("bundles", []) is Array:
		return {}
	for bundle in value.bundles:
		if bundle is not Dictionary or str(bundle.get("id", "")) == "" \
				or str(bundle.get("version", "")) == "" \
				or str(bundle.get("sha256", "")).length() != 64:
			return {}
	return value

static func root() -> String:
	var override := OS.get_environment("GOANNA_ASSET_ROOT")
	return override if override != "" else ProjectSettings.globalize_path("user://content/goanna-assets")

static func _directories(path: String) -> PackedStringArray:
	var result := PackedStringArray()
	var directory := DirAccess.open(path)
	if directory == null:
		return result
	directory.list_dir_begin()
	var name := directory.get_next()
	while name != "":
		if directory.current_is_dir() and not name.begins_with("."):
			result.append(name)
		name = directory.get_next()
	directory.list_dir_end()
	result.sort()
	return result

static func _manifest(path: String) -> Dictionary:
	var value = JSON.parse_string(FileAccess.get_file_as_string(path))
	if value is not Dictionary or value.get("schema", "") != SCHEMA:
		return {}
	if str(value.get("id", "")) == "" or str(value.get("version", "")) == "":
		return {}
	if not value.get("games", []) is Array:
		return {}
	return value

static func _version_key(version: String) -> Array:
	var result := []
	for part in version.split("+")[0].split("."):
		result.append(int(part) if part.is_valid_int() else 0)
	return result

static func _newer(a: String, b: String) -> bool:
	var ak := _version_key(a)
	var bk := _version_key(b)
	for i in maxi(ak.size(), bk.size()):
		var av: int = ak[i] if i < ak.size() else 0
		var bv: int = bk[i] if i < bk.size() else 0
		if av != bv:
			return av > bv
	return a > b

# One newest immutable version per bundle ID. Different IDs are composed, so
# terrain, billboard and creature tranches can update independently.
static func installed_for_game(game: String, store_root := "") -> Array:
	var base: String = store_root if store_root != "" else root()
	var result := []
	for bundle_id in _directories(base):
		if bundle_id == "profiles":
			continue
		var best := {}
		var best_path := ""
		for version in _directories(base.path_join(bundle_id)):
			var candidate := base.path_join(bundle_id).path_join(version)
			var manifest := _manifest(candidate.path_join("manifest.json"))
			if manifest.is_empty() or not game in manifest.get("games", []):
				continue
			if best.is_empty() or _newer(str(manifest.version), str(best.version)):
				best = manifest
				best_path = candidate
		if not best.is_empty() and DirAccess.dir_exists_absolute(best_path.path_join("textures")):
			best["path"] = best_path
			result.append(best)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.id) < str(b.id))
	return result

static func profile_texture_path(game: String, store_root := "") -> String:
	var base: String = store_root if store_root != "" else root()
	var path := base.path_join("profiles").path_join(game).path_join("textures")
	return path if DirAccess.dir_exists_absolute(path) else ""

static func _copy_file(source: String, destination: String) -> bool:
	var input := FileAccess.open(source, FileAccess.READ)
	var output := FileAccess.open(destination, FileAccess.WRITE)
	if input == null or output == null:
		return false
	output.store_buffer(input.get_buffer(input.get_length()))
	return true

static func install_archive(archive_path: String, expected_sha256: String,
		store_root := "") -> String:
	if expected_sha256.length() != 64 \
			or FileAccess.get_sha256(archive_path).to_lower() != expected_sha256.to_lower():
		return "Asset download failed its archive integrity check."
	var zip := ZIPReader.new()
	if zip.open(archive_path) != OK:
		return "The asset bundle is not a readable ZIP archive."
	var base: String = store_root if store_root != "" else root()
	var staging := base.path_join(".bundle-%d-%d" % [OS.get_process_id(),
		int(Time.get_unix_time_from_system())])
	DirAccess.make_dir_recursive_absolute(staging)
	var error := _install_staged(zip, staging, base)
	# Every path out of _install_staged but a successful activation leaves
	# the unpacked copy behind: a refused bundle, and an installed version
	# delivered again, which install_bootstrap does on every launch of a
	# packaged client. Each left a hidden .bundle-* copy of the core bundle in
	# the store, and nothing ever removed them.
	if DirAccess.dir_exists_absolute(staging):
		_remove_tree(staging)
	return error

static func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.include_hidden = true
	for name in directory.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	for name in directory.get_directories():
		_remove_tree(path.path_join(name))
	DirAccess.remove_absolute(path)

static func _install_staged(zip: ZIPReader, staging: String, base: String) -> String:
	for entry in zip.get_files():
		var clean := entry.replace("\\", "/").simplify_path()
		if clean == "." or clean.begins_with("../") or clean.begins_with("/") \
				or clean != entry:
			zip.close()
			return "The asset bundle contains an unsafe path."
		var destination := staging.path_join(clean)
		if entry.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(destination)
			continue
		DirAccess.make_dir_recursive_absolute(destination.get_base_dir())
		var output := FileAccess.open(destination, FileAccess.WRITE)
		if output == null:
			zip.close()
			return "Could not stage the asset bundle."
		output.store_buffer(zip.read_file(entry))
	zip.close()
	var manifest := _manifest(staging.path_join("manifest.json"))
	if manifest.is_empty() or not manifest.get("files", []) is Array:
		return "The asset bundle manifest is invalid."
	var normals := {}
	var materials := {}
	for row in manifest.files:
		if row is not Dictionary:
			return "The asset bundle file ledger is invalid."
		var relative := str(row.get("path", ""))
		var path := staging.path_join(relative)
		if relative == "" or not FileAccess.file_exists(path) \
				or FileAccess.get_size(path) != int(row.get("bytes", -1)) \
				or FileAccess.get_sha256(path).to_lower() != str(row.get("sha256", "")).to_lower():
			return "Asset payload failed verification: %s." % relative
		if relative.begins_with("textures/") and relative.ends_with("_n.png"):
			normals[relative.trim_suffix("_n.png")] = true
		elif relative.begins_with("textures/") and relative.ends_with("_s.png"):
			materials[relative.trim_suffix("_s.png")] = true
	# Sorted, because a Dictionary's keys come out in insertion order and the
	# two lists are filled from the ledger's own order. A stem that is a
	# prefix of another stem lands in a different place in each: the ledger
	# sorts mcl_bamboo_bamboo_n.png before mcl_bamboo_bamboo_plank_n.png, and
	# mcl_bamboo_bamboo_s.png after mcl_bamboo_bamboo_plank_s.png, since the
	# suffix letter is what breaks the tie. Comparing the arrays as they came
	# rejected a bundle whose pairs are all present.
	var normal_stems := normals.keys()
	var material_stems := materials.keys()
	normal_stems.sort()
	material_stems.sort()
	if normals.is_empty() or normal_stems != material_stems \
			or normals.size() != int(manifest.get("texture_pairs", -1)):
		return "The asset bundle has incomplete normal/material pairs."
	var destination := base.path_join(str(manifest.id)).path_join(str(manifest.version))
	if DirAccess.dir_exists_absolute(destination):
		return ""
	DirAccess.make_dir_recursive_absolute(destination.get_base_dir())
	if DirAccess.rename_absolute(staging, destination) != OK:
		return "Could not activate the verified asset bundle."
	return rebuild_profiles_for_manifest(manifest, base)

static func rebuild_profiles_for_manifest(manifest: Dictionary, store_root := "") -> String:
	for game in manifest.get("games", []):
		var error := rebuild_profile(str(game), store_root)
		if error != "":
			return error
	return ""

# Rebuild a derived profile. Installed immutable bundles remain untouched.
# Bundle IDs sort deterministically; duplicate filenames are rejected because
# silently choosing one package's material would make updates order-dependent.
static func rebuild_profile(game: String, store_root := "") -> String:
	var base: String = store_root if store_root != "" else root()
	var bundles := installed_for_game(game, base)
	if bundles.is_empty():
		return "No installed asset bundle supports %s." % game
	var profile := base.path_join("profiles").path_join(game)
	var staging := base.path_join("profiles").path_join(".%s-%d" % [game, OS.get_process_id()])
	var textures := staging.path_join("textures")
	DirAccess.make_dir_recursive_absolute(textures)
	var owners := {}
	for manifest in bundles:
		var source := str(manifest.path).path_join("textures")
		var directory := DirAccess.open(source)
		if directory == null:
			return "Installed bundle %s has no texture directory." % manifest.id
		for filename in directory.get_files():
			if not filename.ends_with(".png"):
				continue
			if owners.has(filename):
				return "Asset collision: %s is supplied by %s and %s." % [filename, owners[filename], manifest.id]
			owners[filename] = manifest.id
			if not _copy_file(source.path_join(filename), textures.path_join(filename)):
				return "Could not compose %s." % filename
	var profile_manifest := {"schema": "org.goanna.asset-profile/v1", "game": game,
		"bundles": bundles.map(func(row: Dictionary): return {"id": row.id, "version": row.version}),
		"textures": owners.size()}
	var output := FileAccess.open(staging.path_join("manifest.json"), FileAccess.WRITE)
	if output == null:
		return "Could not write the asset profile manifest."
	output.store_string(JSON.stringify(profile_manifest, "  ") + "\n")
	if DirAccess.dir_exists_absolute(profile):
		var old := profile + ".old-%d" % int(Time.get_unix_time_from_system())
		if DirAccess.rename_absolute(profile, old) != OK:
			return "Could not replace the old asset profile."
	if DirAccess.rename_absolute(staging, profile) != OK:
		return "Could not activate the composed asset profile."
	return ""
