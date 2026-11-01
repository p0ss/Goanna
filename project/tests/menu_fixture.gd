# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## Not a test: a made up Luanti data folder for the menu tests and captures
## (tests/menu_layout.gd, tests/menu_screens_render.gd), so they need no
## Luanti install and never show the player's own worlds. Three games (one a
## modpack on Mineclonia), two mods, a texture pack, three worlds played at
## known times, a remembered last world and a saved public server list.
## GOANNA_SERVER_CMD points at /bin/true: nothing here starts a server.
extends RefCounted

const DIR := "user://menu_fixture"

static func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

# Sets a file's modification time, which is what Last played reads.
static func _touch(path: String, when: String) -> void:
	OS.execute("touch", PackedStringArray(["-d", when, path]))

## Builds the folder and points the menu at it. Returns its absolute path.
static func build(last_world := "Barrelreach") -> String:
	var root := ProjectSettings.globalize_path(DIR)
	_write(root.path_join("games/mineclonia/game.conf"), "title = Mineclonia\n")
	_write(root.path_join("games/mineclone2/game.conf"), "title = VoxeLibre\n")
	_write(root.path_join("games/minetest_game/game.conf"), "title = Minetest Game\n")
	_write(root.path_join("mods/kindred_holdfast/modpack.conf"), "name = kindred_holdfast\n")
	for member in ["kindred", "kindred_creatures", "kindred_cultures", "kindred_world"]:
		_write(root.path_join("mods/kindred_holdfast/%s/mod.conf" % member), "name = %s\n" % member)
	_write(root.path_join("mods/doors_plus/mod.conf"), "name = doors_plus\n")
	_write(root.path_join("mods/signs_lib/mod.conf"), "name = signs_lib\n")
	DirAccess.make_dir_recursive_absolute(root.path_join("textures/Craft_and_Ruin"))
	var worlds := {
		"Barrelreach": ["mineclonia", "load_mod_kindred = true\nload_mod_kindred_creatures = true\nload_mod_kindred_cultures = true\nload_mod_kindred_world = true\n", "2 hours ago"],
		"Seaside test": ["mineclone2", "creative_mode = true\nenable_damage = false\nload_mod_doors_plus = true\n", "3 days ago"],
		"Old valley": ["minetest_game", "", "2026-09-20 18:00"],
	}
	for name in worlds:
		var w: Array = worlds[name]
		var mt := root.path_join("worlds/%s/world.mt" % name)
		_write(mt, "gameid = %s\nbackend = sqlite3\n%s" % [w[0], w[1]])
		_touch(mt, str(w[2]))
	var cfg := ConfigFile.new()
	cfg.load("user://goanna.cfg")
	if last_world != "":
		cfg.set_value("local", "world", last_world)
		cfg.set_value("local", "game", "mineclonia|kindred_holdfast")
	elif cfg.has_section_key("local", "world"):
		cfg.erase_section_key("local", "world")
	cfg.set_value("player", "name", "possum")
	cfg.set_value("server", "host", "192.168.1.20")
	cfg.set_value("server", "port", "30000")
	cfg.set_value("server", "recent", [
		{"address": "192.168.1.20", "port": 30000, "name": ""},
		{"address": "play.example.org", "port": 30001, "name": "Example survival"}])
	cfg.save("user://goanna.cfg")
	var servers := []
	for i in 24:
		servers.append({"address": "server%d.example.org" % i, "port": 30000 + (i % 3),
			"name": ["Northern Isles", "Creative Plots", "Skyblock Classic", "Village Life",
				"Red Rock Survival", "Builders' Guild"][i % 6] + (" %d" % (i / 6 + 1) if i >= 6 else ""),
			"gameid": ["mineclonia", "minetest_game", "mineclone2", "nodecore"][i % 4],
			"clients": (i * 7) % 23, "clients_max": 32, "ping": 0.02 + 0.011 * i,
			"description": "A made up server for the menu captures."})
	_write(root.path_join("serverlist.json"), JSON.stringify({"list": servers}))
	OS.set_environment("GOANNA_SERVER_CMD", "/bin/true")
	OS.set_environment("GOANNA_SERVER_DATA_DIR", root)
	OS.set_environment("GOANNA_SERVER_LIST_FILE", root.path_join("serverlist.json"))
	OS.set_environment("GOANNA_MENU", "1")
	OS.set_environment("GOANNA_NO_SHOWCASE", "1")
	return root
