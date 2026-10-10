# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Get ready to play on a computer with no Luanti, end to end: what menu.gd's
# setup does, through the same local_server.gd calls. Find no install, copy
# the bundled Linux server into Goanna's own folder, download the starter game
# and check its hash, unpack it, then start a world the way Start Game does
# and wait for the server to listen. It downloads the real game (about 29 MB)
# and runs a real server, so it is meant for a clean container, which
# tools/test/test-fresh-install.sh provides, not a developer's machine.
extends SceneTree

const LocalServer := preload("res://local_server.gd")
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var found: Array = LocalServer.installs(true)
	print("fresh install: Luanti installs found before: %d" % found.size())
	_assert(found.is_empty(), "this computer already has Luanti, so it is not a fresh install")
	var bundle := LocalServer.bundled_server()
	print("fresh install: bundled server: %s" % bundle)
	if bundle == "":
		_fail("no bundled server was found")
		return
	var inst := LocalServer.install_bundled_server(bundle)
	if inst.has("error"):
		_fail(str(inst["error"]))
		return
	LocalServer.choose(inst)
	LocalServer.installs(true)
	var chosen := LocalServer.detect()
	_assert(str(chosen.get("kind", "")) == "goanna", "the copied server was not chosen as Goanna's own")
	var games_dir := str(chosen["data_dir"]).path_join("games")
	DirAccess.make_dir_recursive_absolute(games_dir)
	var archive := games_dir.path_join(".starter.zip.part")
	var http := HTTPRequest.new()
	http.download_file = archive
	root.add_child(http)
	var started := Time.get_ticks_msec()
	if http.request(str(LocalServer.STARTER_GAME["url"])) != OK:
		_fail("the game download did not start")
		return
	var reply: Array = await http.request_completed
	print("fresh install: game download HTTP %d in %.1f s" % [reply[1], (Time.get_ticks_msec() - started) / 1000.0])
	if reply[0] != HTTPRequest.RESULT_SUCCESS or reply[1] != 200:
		_fail("the game download failed")
		return
	var error := LocalServer.install_game_archive(archive, str(LocalServer.STARTER_GAME["sha256"]),
		games_dir, str(LocalServer.STARTER_GAME["id"]))
	DirAccess.remove_absolute(archive)
	if error != "":
		_fail(error)
		return
	LocalServer.installs(true)
	chosen = LocalServer.detect()
	_assert((chosen["games"] as Array).has(str(LocalServer.STARTER_GAME["id"])),
		"the starter game is not listed after installing it")
	var server := LocalServer.new()
	error = server.start_config({"gameid": str(LocalServer.STARTER_GAME["id"]),
		"world": "fresh_install_test", "player_name": "child", "creative": false,
		"damage": true, "port": 30731})
	if error != "":
		_fail("the server did not start: " + error)
		return
	started = Time.get_ticks_msec()
	var state := "starting"
	while state == "starting" and Time.get_ticks_msec() - started < 120000:
		await create_timer(0.5).timeout
		state = server.poll_ready()
	print("fresh install: server %s after %.1f s" % [state, (Time.get_ticks_msec() - started) / 1000.0])
	_assert(state == "ready", "the server did not become ready: " + state)
	server.stop()
	if failures == 0:
		print("fresh install: PASS")
		quit(0)
	else:
		quit(1)


func _fail(message: String) -> void:
	_assert(false, message)
	quit(1)


func _assert(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("fresh install: " + message)
