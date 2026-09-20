extends SceneTree

const AssetStore := preload("res://asset_store.gd")
const ARCHIVE_TEXTURES := ["textures/granite_n.png", "textures/granite_s.png"]

# A tripped assert halts the engine without ever reaching quit(), which reads
# as a hang rather than as a failure, so every check reports and exits
# non-zero instead.
func _fail(message: String) -> void:
	printerr("asset store: FAIL: ", message)
	quit(1)

func _init() -> void:
	var catalogue := AssetStore.parse_catalogue(JSON.stringify({
		"schema": AssetStore.CATALOGUE_SCHEMA,
		"bundles": [{"id": "org.goanna.test", "version": "1.0.0",
			"sha256": "0".repeat(64)}]}))
	if catalogue.is_empty():
		_fail("a well formed catalogue did not parse")
		return
	var root := ProjectSettings.globalize_path("user://asset-store-test-%d" % OS.get_process_id())
	var bundle := root.path_join("org.goanna.test").path_join("1.0.0")
	DirAccess.make_dir_recursive_absolute(bundle.path_join("textures"))
	var manifest := {"schema": AssetStore.SCHEMA, "id": "org.goanna.test", "version": "1.0.0",
		"games": ["test"], "texture_pairs": 1}
	var file := FileAccess.open(bundle.path_join("manifest.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(manifest))
	file = null
	for name in ["stone_n.png", "stone_s.png"]:
		var texture := FileAccess.open(bundle.path_join("textures").path_join(name), FileAccess.WRITE)
		texture.store_8(1)
		texture = null
	var found := AssetStore.installed_for_game("test", root)
	if found.size() != 1:
		_fail("installed_for_game found %d bundles for test, not 1" % found.size())
		return
	var error := AssetStore.rebuild_profile("test", root)
	if error != "":
		_fail(error)
		return
	if not FileAccess.file_exists(root.path_join("profiles/test/textures/stone_n.png")):
		_fail("the composed profile has no stone_n.png")
		return
	error = _hash_gate(root)
	if error != "":
		_fail(error)
		return
	print("asset store: PASS")
	quit()

# The archive hash is the only thing between a redirected, truncated or
# substituted download and unpacking it. tests/asset_store_install.gd covers
# it against a published bundle, which needs one to hand; this builds a small
# one in a scratch directory, so both answers are covered offline.
func _hash_gate(root: String) -> String:
	var archive := _build_archive(root + "-build")
	if archive == "":
		return "could not build a test archive"
	if AssetStore.install_archive(archive, "0".repeat(64), root) == "":
		return "an archive installed under a hash that is not its own"
	if DirAccess.dir_exists_absolute(root.path_join("org.goanna.test.archive")):
		return "a refused archive was unpacked anyway"
	if AssetStore.install_archive(archive, "abc123", root) == "":
		return "an archive installed under a hash of the wrong length"
	var error := AssetStore.install_archive(archive,
			FileAccess.get_sha256(archive), root)
	if error != "":
		return "the archive was refused under its own hash: %s" % error
	if not FileAccess.file_exists(root.path_join(
			"profiles/archive/textures/granite_n.png")):
		return "the installed archive composed no profile"
	return ""

# A bundle the store will accept: a manifest, a complete normal and material
# pair, and a ledger giving each payload's size and hash.
func _build_archive(build: String) -> String:
	DirAccess.make_dir_recursive_absolute(build.path_join("textures"))
	var files := []
	for relative in ARCHIVE_TEXTURES:
		var payload := ("goanna test payload for %s" % relative).to_utf8_buffer()
		var texture := FileAccess.open(build.path_join(relative), FileAccess.WRITE)
		if texture == null:
			return ""
		texture.store_buffer(payload)
		texture = null
		files.append({"path": relative, "bytes": payload.size(),
			"sha256": FileAccess.get_sha256(build.path_join(relative))})
	var manifest := {"schema": AssetStore.SCHEMA, "id": "org.goanna.test.archive",
		"version": "1.0.0", "games": ["archive"], "texture_pairs": 1, "files": files}
	var archive := build.path_join("org.goanna.test.archive-1.0.0.zip")
	var packer := ZIPPacker.new()
	if packer.open(archive) != OK:
		return ""
	packer.start_file("manifest.json")
	packer.write_file(JSON.stringify(manifest).to_utf8_buffer())
	packer.close_file()
	for relative in ARCHIVE_TEXTURES:
		packer.start_file(relative)
		packer.write_file(FileAccess.get_file_as_bytes(build.path_join(relative)))
		packer.close_file()
	packer.close()
	return archive
