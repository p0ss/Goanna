# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Headless checks for server discovery helpers. This does not inspect or launch
# an installed server, so its result is independent of the developer machine.
extends SceneTree

const LocalServer := preload("res://local_server.gd")
var failures := 0


func _initialize() -> void:
	var base := OS.get_temp_dir().path_join("goanna-server-discovery-%d" % OS.get_process_id())
	var games_dir := base.path_join("usr/games")
	DirAccess.make_dir_recursive_absolute(games_dir)
	var fake := games_dir.path_join("luanti")
	var executable := FileAccess.open(fake, FileAccess.WRITE)
	executable.store_string("test")
	executable = null

	_assert(LocalServer._find_executable_in_dirs("luanti", [games_dir]) == fake,
		"a Luanti executable outside PATH was not found")
	_assert(LocalServer._find_executable_in_dirs("minetest", [games_dir]) == "",
		"a missing compatibility executable was reported")

	# A game whose title differs from its directory name, like VoxeLibre in
	# mineclone2, must be listed by its id and named by its title.
	var data_dir := base.path_join("data")
	var game_dir := data_dir.path_join("games").path_join("mineclone2")
	DirAccess.make_dir_recursive_absolute(game_dir)
	var conf := FileAccess.open(game_dir.path_join("game.conf"), FileAccess.WRITE)
	conf.store_string("title = VoxeLibre\ndescription = A game\n")
	conf = null
	DirAccess.make_dir_recursive_absolute(data_dir.path_join("games").path_join("untitled"))
	var untitled := FileAccess.open(data_dir.path_join("games/untitled/game.conf"), FileAccess.WRITE)
	untitled.store_string("description = No title line\n")
	untitled = null
	_assert(LocalServer.list_games(data_dir) == ["mineclone2", "untitled"],
		"games were not listed by directory name")
	_assert(LocalServer.game_title(data_dir, "mineclone2") == "VoxeLibre",
		"the game.conf title was not read")
	_assert(LocalServer.game_title(data_dir, "untitled") == "untitled",
		"a game without a title did not fall back to its id")
	_assert(LocalServer.game_title(data_dir, "absent") == "absent",
		"a missing game did not fall back to its id")

	if failures == 0:
		print("local server discovery: PASS")
		quit(0)
	else:
		quit(1)


func _assert(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("local server discovery: " + message)
