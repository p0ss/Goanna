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

	if failures == 0:
		print("local server discovery: PASS")
		quit(0)
	else:
		quit(1)


func _assert(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("local server discovery: " + message)
