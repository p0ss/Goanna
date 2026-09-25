extends SceneTree

# A real bundle, built by the real bundler, installed into a fresh store the
# way a client installs one it has downloaded.
#
# AssetStore.install_archive compared its _n and _s stem lists in arrival
# order, and threw away every archive whose stems included one that is a
# prefix of another. Mineclonia's pack has several, so a fresh profile
# fetched 95 MB and kept nothing, and no test noticed because none had ever
# installed an archive tools/pbr_bundle.py made. tests/asset_store.gd builds
# its archives by hand with ZIPPacker, which proves the store agrees with
# itself; this proves it agrees with the tool that makes what we publish.
#
# The fixture is a few 4 by 4 textures written here and packed by
#   python3 tools/pbr_bundle.py build ...
# so nothing binary is committed and the archive's layout, ledger order and
# manifest are whatever the bundler produces today. It needs python3 with
# Pillow on PATH, as the bundler does.
#
#   godot --headless --path project --script res://tests/asset_bundle_install.gd

const AssetStore := preload("res://asset_store.gd")
const AssetUpdater := preload("res://asset_updater.gd")

const GAME := "goanna_fixture"
const BUNDLE_ID := "org.goanna.test.fixture"
const VERSION := "1.0.0"
# mcl_bamboo_bamboo is a prefix of mcl_bamboo_bamboo_plank, as in the real
# pack. The ledger is sorted, so the short stem comes first among the
# normals and last among the materials. default_stone is the control.
const STEMS := ["default_stone", "mcl_bamboo_bamboo", "mcl_bamboo_bamboo_plank"]

var _scratch := ""

func _fail(message: String) -> void:
	printerr("asset bundle install: FAIL: ", message)
	quit(1)

func _init() -> void:
	_scratch = ProjectSettings.globalize_path(
			"user://asset-bundle-install-%d" % OS.get_process_id())
	var error := _run()
	# Removed either way: the pid in the name keeps runs apart, but a failed
	# run would otherwise leave a store behind in the user data directory.
	_remove(_scratch)
	if error != "":
		_fail(error)
		return
	print("asset bundle install: PASS (%d pairs, prefix stems included)" % STEMS.size())
	quit()

func _run() -> String:
	var sources := _scratch.path_join("sources")
	var store := _scratch.path_join("store")
	if DirAccess.dir_exists_absolute(store):
		return "the scratch store %s already exists; a stale run was left behind" % store
	DirAccess.make_dir_recursive_absolute(sources)
	var expected := {}
	for i in STEMS.size():
		for suffix in ["_n", "_s"]:
			var name: String = STEMS[i] + suffix + ".png"
			var path := sources.path_join(name)
			if _texture(i, suffix == "_n").save_png(path) != OK:
				return "could not write the fixture texture %s" % name
			expected[name] = FileAccess.get_sha256(path)

	var archive := _scratch.path_join("%s-%s.zip" % [BUNDLE_ID, VERSION])
	var tools := ProjectSettings.globalize_path("res://").path_join("../tools").simplify_path()
	var output := []
	var status := OS.execute("python3", [tools.path_join("pbr_bundle.py"), "build",
		"--textures", sources, "--id", BUNDLE_ID, "--version", VERSION,
		"--tranche", "terrain", "--game", GAME,
		"--source-package", "goanna/fixture", "--source-release", "1",
		"--source-sha256", "0".repeat(64), "--pipeline-version", "1",
		"--output", archive], output, true)
	if status != 0 or not FileAccess.file_exists(archive):
		return "tools/pbr_bundle.py build failed (%d): %s" % [status, "".join(output)]

	# A fresh profile: the store root the client resolves through
	# AssetStore.root(), pointed at an empty directory. install_archive is
	# then called exactly as asset_updater.gd calls it on a finished
	# download, with no root of its own.
	OS.set_environment("GOANNA_ASSET_ROOT", store)
	if AssetStore.root() != store:
		return "GOANNA_ASSET_ROOT did not move the store root"
	var digest := FileAccess.get_sha256(archive)
	var install_error := AssetStore.install_archive(archive, digest)
	if install_error != "":
		return "the bundler's own archive was refused: %s" % install_error

	var updater: Node = AssetUpdater.new()
	var seen: bool = updater._installed({"id": BUNDLE_ID, "version": VERSION})
	updater.free()
	if not seen:
		return "the updater does not see the installed bundle, so it would fetch it again"

	var textures := AssetStore.profile_texture_path(GAME)
	if textures == "":
		return "no composed profile for %s" % GAME
	if textures != store.path_join("profiles").path_join(GAME).path_join("textures"):
		return "the composed profile is at %s, not under the store" % textures
	var found := {}
	for name in DirAccess.get_files_at(textures):
		found[name] = FileAccess.get_sha256(textures.path_join(name))
	for name in expected:
		if not found.has(name):
			return "the composed textures directory has no %s" % name
		if found[name] != expected[name]:
			return "%s in the composed textures directory is not the file that was bundled" % name
	for name in found:
		if not expected.has(name):
			return "the composed textures directory has %s, which was never bundled" % name
	var profile = JSON.parse_string(FileAccess.get_file_as_string(
			textures.get_base_dir().path_join("manifest.json")))
	if profile is not Dictionary or int(profile.get("textures", -1)) != expected.size():
		return "the profile manifest does not count %d textures" % expected.size()

	# A second delivery of the same version is accepted and changes nothing.
	install_error = AssetStore.install_archive(archive, digest)
	if install_error != "":
		return "reinstalling the same archive was refused: %s" % install_error
	if DirAccess.get_files_at(textures).size() != expected.size():
		return "reinstalling the same archive changed the composed profile"
	# install_bootstrap redelivers the core bundle on every packaged launch,
	# and each delivery used to leave its unpacked copy in the store.
	var directory := DirAccess.open(store)
	directory.include_hidden = true
	for name in directory.get_directories():
		if name.begins_with(".bundle-"):
			return "the install left its staging copy %s in the store" % name

	# A refused archive must leave nothing behind either.
	var corrupt := _scratch.path_join("corrupt.zip")
	var bytes := FileAccess.get_file_as_bytes(archive)
	var file := FileAccess.open(corrupt, FileAccess.WRITE)
	file.store_buffer(bytes.slice(0, bytes.size() / 2))
	file = null
	if AssetStore.install_archive(corrupt, FileAccess.get_sha256(corrupt)) == "":
		return "half an archive was accepted"
	for name in directory.get_directories():
		if name.begins_with(".bundle-"):
			return "a refused archive left its staging copy %s in the store" % name
	return ""

# 4 by 4, with the normal's height running 0 to 255 across its alpha, as
# the bake writes it, so the bundler's height fill check passes. The colour
# differs per stem so a crossed file shows up as a hash mismatch.
func _texture(index: int, normal: bool) -> Image:
	var image := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	for y in 4:
		for x in 4:
			if normal:
				image.set_pixel(x, y, Color8(128, 128 + index, 255, x * 85))
			else:
				image.set_pixel(x, y, Color8(40 + index, 10, 0, 255))
	return image

func _remove(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.include_hidden = true
	for name in directory.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	for name in directory.get_directories():
		_remove(path.path_join(name))
	DirAccess.remove_absolute(path)
