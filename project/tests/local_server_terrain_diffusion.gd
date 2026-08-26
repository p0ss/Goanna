# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Headless check for the downloaded Terrain Diffusion world setup. It deliberately
# does not launch Luanti or touch a user's worlds.
extends SceneTree

const LocalServer := preload("res://local_server.gd")
var failures := 0


func _initialize() -> void:
	var base := OS.get_temp_dir().path_join("goanna-tdl-launch-%d" % OS.get_process_id())
	var world := base.path_join("worlds").path_join("test")
	DirAccess.make_dir_recursive_absolute(world.path_join("terrain_diffusion"))
	var manifest := FileAccess.open(world.path_join("terrain_diffusion/manifest.json"), FileAccess.WRITE)
	manifest.store_string("{}")
	manifest = null
	var meta := FileAccess.open(world.path_join("map_meta.txt"), FileAccess.WRITE)
	meta.store_string("seed = 123\nmg_name = v7\n[end_of_params]\n")
	meta = null

	var server := LocalServer.new()
	_assert(LocalServer.terrain_diffusion_ready(base, "test"), "prepared world was not detected")
	_assert(server._prepare_terrain_diffusion_meta(world) == "", "map metadata preparation failed")
	_assert(server._install_terrain_diffusion(world) == "", "runtime deployment failed")
	_assert(server._install_server_mod(world) == "", "Goanna server mod deployment failed")
	var prepared := FileAccess.get_file_as_string(world.path_join("map_meta.txt"))
	_assert(prepared.contains("seed = 123"), "world seed was discarded")
	_assert(prepared.contains("mg_name = singlenode"), "singlenode was not selected")
	_assert(prepared.contains("mcl_singlenode_mapgen = false"), "Mineclonia mapgen was not disabled")
	for filename in LocalServer.TERRAIN_DIFFUSION_FILES:
		_assert(FileAccess.file_exists(world.path_join("worldmods/terrain_diffusion").path_join(filename)),
			"runtime file was not deployed: " + filename)
	for filename in LocalServer.GOANNA_SERVER_MOD_FILES:
		_assert(FileAccess.file_exists(world.path_join("worldmods/goanna_server_mod").path_join(filename)),
			"Goanna server mod file was not deployed: " + filename)
	var default_world := base.path_join("worlds").path_join("default_test")
	DirAccess.make_dir_recursive_absolute(default_world)
	var cached_bake := base.path_join("content").path_join(LocalServer.DEFAULT_TERRAIN_ID)
	DirAccess.make_dir_recursive_absolute(cached_bake.path_join("tiles"))
	var cached_manifest := FileAccess.open(cached_bake.path_join("manifest.json"), FileAccess.WRITE)
	cached_manifest.store_string("{\"format\":4}")
	cached_manifest = null
	for ti in range(LocalServer.DEFAULT_TERRAIN_I0,
			LocalServer.DEFAULT_TERRAIN_I0 + LocalServer.DEFAULT_TERRAIN_TILES):
		for tj in range(LocalServer.DEFAULT_TERRAIN_J0,
				LocalServer.DEFAULT_TERRAIN_J0 + LocalServer.DEFAULT_TERRAIN_TILES):
			var tile := FileAccess.open(cached_bake.path_join("tiles/t_%d_%d.bin" % [ti, tj]),
					FileAccess.WRITE)
			tile.store_8(0)
			tile = null
	_assert(LocalServer.default_terrain_dir_valid(cached_bake), "downloaded bake was not recognised")
	_assert(server._install_default_terrain(default_world, cached_bake) == "", "default bake deployment failed")
	_assert(server._initialise_terrain_diffusion_world(default_world, "default_test") == "",
		"default world metadata initialisation failed")
	_assert(FileAccess.file_exists(default_world.path_join("terrain_diffusion/manifest.json")),
		"default manifest was not deployed")
	_assert(FileAccess.file_exists(default_world.path_join("terrain_diffusion/tiles/t_84_80.bin")),
		"default tile was not deployed")
	_assert(FileAccess.get_file_as_string(default_world.path_join("map_meta.txt"))
		.contains("mg_name = singlenode"), "default world was not set to singlenode")
	_assert(server._write_world_options(default_world, {"gameid": "devtest", "world": "default_test",
		"creative": true, "damage": false, "announce": true, "mods": ["test_mod"]}) == "",
		"structured world options could not be written")
	var world_settings := FileAccess.get_file_as_string(default_world.path_join("world.mt"))
	_assert(world_settings.contains("gameid = devtest"), "selected game was not persisted")
	_assert(world_settings.contains("creative_mode = true"), "creative mode was not persisted")
	_assert(world_settings.contains("enable_damage = false"), "damage setting was not persisted")
	_assert(world_settings.contains("load_mod_test_mod = true"), "enabled mod was not persisted")
	_assert(LocalServer.world_options(base, "default_test").get("terrain_diffusion", false),
		"structured world reader lost the terrain generator")
	_assert(LocalServer.delete_world_recoverably(base, "default_test") == "",
		"recoverable world deletion failed")
	_assert(not DirAccess.dir_exists_absolute(default_world),
		"deleted world remained in the active world list")
	_assert(DirAccess.dir_exists_absolute(base.path_join("worlds/.goanna-trash")),
		"deleted world was not retained for recovery")
	var populated := base.path_join("worlds/populated")
	DirAccess.make_dir_recursive_absolute(populated)
	var old_map := FileAccess.open(populated.path_join("map.sqlite"), FileAccess.WRITE)
	old_map.store_string("existing map")
	old_map = null
	_assert(LocalServer.world_has_generated_map(base, "populated"),
		"populated-world guard did not detect an existing map database")
	if failures == 0:
		print("local server Terrain Diffusion: PASS")
		quit(0)
	else:
		quit(1)


func _assert(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("local server Terrain Diffusion: " + message)
