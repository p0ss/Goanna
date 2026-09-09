extends SceneTree

const AssetStore := preload("res://asset_store.gd")

func _init() -> void:
	var archive := OS.get_environment("GOANNA_TEST_ASSET_BUNDLE")
	var expected := OS.get_environment("GOANNA_TEST_ASSET_SHA256")
	assert(archive != "" and expected != "")
	var root := ProjectSettings.globalize_path("user://asset-install-test-%d" % OS.get_process_id())
	assert(AssetStore.install_archive(archive, expected, root) == "")
	assert(FileAccess.file_exists(root.path_join(
		"profiles/minetest_game/textures/default_stone_n.png")))
	print("asset bundle install: PASS")
	quit()
