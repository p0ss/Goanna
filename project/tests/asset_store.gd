extends SceneTree

const AssetStore := preload("res://asset_store.gd")

func _init() -> void:
	var catalogue := AssetStore.parse_catalogue(JSON.stringify({
		"schema": AssetStore.CATALOGUE_SCHEMA,
		"bundles": [{"id": "org.goanna.test", "version": "1.0.0",
			"sha256": "0".repeat(64)}]}))
	assert(not catalogue.is_empty())
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
	assert(found.size() == 1)
	assert(AssetStore.rebuild_profile("test", root) == "")
	assert(FileAccess.file_exists(root.path_join("profiles/test/textures/stone_n.png")))
	print("asset store: PASS")
	quit()
