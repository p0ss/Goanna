extends SceneTree

const AssetStore := preload("res://asset_store.gd")

# A tripped assert halts the engine without ever reaching quit(), so every
# failure of this check used to hang until the caller's timeout killed it,
# which reads the same as a crash. Report the reason and exit non-zero.
func _fail(message: String) -> void:
	printerr("asset bundle install: FAIL: ", message)
	quit(1)

func _init() -> void:
	var archive := OS.get_environment("GOANNA_TEST_ASSET_BUNDLE")
	var expected := OS.get_environment("GOANNA_TEST_ASSET_SHA256")
	if archive == "" or expected == "":
		_fail("set GOANNA_TEST_ASSET_BUNDLE to a bundle and "
				+ "GOANNA_TEST_ASSET_SHA256 to its archive hash")
		return
	var root := ProjectSettings.globalize_path(
			"user://asset-install-test-%d" % OS.get_process_id())
	var error := AssetStore.install_archive(archive, expected, root)
	if error != "":
		_fail(error)
		return
	if not FileAccess.file_exists(root.path_join(
			"profiles/minetest_game/textures/default_stone_n.png")):
		_fail("the composed profile has no default_stone_n.png")
		return
	print("asset bundle install: PASS")
	quit()
