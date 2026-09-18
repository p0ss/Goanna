# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Headless checks for finding Luanti. Every machine here is made up, a tree of
# empty files laid out the way each kind of packaging lays Luanti out, and the
# scan is handed a context describing it, so the result does not depend on
# what the developer machine has installed. Nothing is launched.
extends SceneTree

const LocalServer := preload("res://local_server.gd")
var failures := 0
var base := ""


func _initialize() -> void:
	base = OS.get_temp_dir().path_join("goanna-server-discovery-%d" % OS.get_process_id())
	_linux()
	_windows()
	_located()
	_portable_archive()
	_titles()
	LocalServer._remove_tree(base)
	if failures == 0:
		print("local server discovery: PASS")
		quit(0)
	else:
		quit(1)


func _linux() -> void:
	var root := base.path_join("linux")
	var home := root.path_join("home/p")
	# Debian and Ubuntu: the programs in /usr/games and the games they bundle
	# under /usr/share/games/minetest, nowhere near ~/.minetest. This is the
	# layout the old lookup missed.
	_file(root.path_join("usr/games/minetest"))
	_file(root.path_join("usr/games/minetestserver"))
	var share := root.path_join("usr/share/games/minetest")
	_dir(share.path_join("builtin"))
	_game(share.path_join("games/minetest"), "Minetest Game")
	_game(share.path_join("games/devtest"), "Development Test")
	_game(home.path_join(".minetest/games/mineclone2"), "VoxeLibre")
	# Luanti reads minetest_game as the id minetest, which the share
	# directory already has, and the share directory is searched first.
	_game(home.path_join(".minetest/games/minetest_game"), "Minetest Game")
	# A system Flatpak, and the flatpak command needed to run it.
	_file(root.path_join("usr/bin/flatpak"))
	var active := root.path_join("var/lib/flatpak/app/org.luanti.luanti/current/active")
	_dir(active.path_join("files/share/luanti/builtin"))
	_file(active.path_join("files/share/metainfo/org.luanti.luanti.metainfo.xml"),
		"<releases>\n  <release date=\"2026-08-20\" version=\"5.17.0\"/>\n</releases>\n")
	_game(home.path_join(".var/app/org.luanti.luanti/.minetest/games/mineclonia"), "Mineclonia")
	# An AppImage in ~/Applications, and a RUN_IN_PLACE source checkout.
	_file(home.path_join("Applications/Luanti-5.16.1-x86_64.AppImage"))
	var checkout := home.path_join("luanti")
	_file(checkout.path_join("bin/luanti"))
	_dir(checkout.path_join("builtin"))
	_file(checkout.path_join("mods/mods_here.txt"))
	_game(checkout.path_join("games/devtest"), "Development Test")

	var ctx := {"platform": "Linux", "home": home,
		"env": {"PATH": root.path_join("usr/games")}, "own_dir": root.path_join("goanna"),
		"system_dirs": [root.path_join("usr/bin")],
		"flatpak_bases": [["user", home.path_join(".local/share/flatpak")],
			["system", root.path_join("var/lib/flatpak")]],
		"flatpak_command": root.path_join("usr/bin/flatpak"),
		"app_dirs": [home.path_join("Applications")], "folder_bases": [home]}
	var found := LocalServer.scan_installs(ctx)
	_assert(found.size() == 4, "expected 4 Linux installs, found %d" % found.size())
	if found.size() != 4:
		return

	var debian: Dictionary = found[0]
	_assert(debian["kind"] == "package", "the Debian package was not first")
	_assert(debian["argv"] == PackedStringArray([root.path_join("usr/games/minetestserver")]),
		"the server only program was not used for the server")
	_assert(debian["client_argv"] == PackedStringArray([root.path_join("usr/games/minetest")]),
		"the client of the same package was not merged in")
	_assert(debian["share_dir"] == share, "the Debian share directory was not found")
	_assert(debian["data_dir"] == home.path_join(".minetest"), "the Debian user path is wrong")
	_assert(debian["games"] == ["devtest", "mineclone2", "minetest"],
		"the Debian games were %s" % str(debian["games"]))
	_assert(debian["product"] == "Minetest", "the Debian program was not named Minetest")

	var flatpak: Dictionary = found[1]
	_assert(flatpak["kind"] == "flatpak" and flatpak["key"] == "flatpak:org.luanti.luanti:system",
		"the system Flatpak was not found")
	_assert(flatpak["argv"] == PackedStringArray([root.path_join("usr/bin/flatpak"), "run",
		"--system", "--command=luanti", "org.luanti.luanti", "--server"]),
		"the Flatpak server command is wrong: %s" % str(flatpak["argv"]))
	_assert(flatpak["version"] == "5.17.0", "the Flatpak version was not read")
	_assert(flatpak["games"] == ["mineclonia"], "the Flatpak games were %s" % str(flatpak["games"]))

	var appimage: Dictionary = found[2]
	_assert(appimage["kind"] == "appimage" and appimage["version"] == "5.16.1",
		"the AppImage was not found with its version")
	_assert(appimage["data_dir"] == home.path_join(".minetest"), "the AppImage user path is wrong")

	var source: Dictionary = found[3]
	_assert(source["kind"] == "portable" and source["data_dir"] == checkout,
		"a RUN_IN_PLACE checkout did not keep its data in place")
	_assert(source["games"] == ["devtest"], "the checkout's games were %s" % str(source["games"]))

	# Preference: the player's choice, else the first with a game.
	_assert(LocalServer.preferred(found, "")["key"] == debian["key"],
		"the first install with games was not preferred")
	_assert(LocalServer.preferred(found, flatpak["key"])["key"] == flatpak["key"],
		"the player's choice was not honoured")
	_assert(LocalServer.preferred(found, "exe:/gone")["key"] == debian["key"],
		"a choice that no longer exists was not ignored")
	var empty := debian.duplicate()
	empty["key"] = "exe:/empty"
	empty["games"] = []
	_assert(LocalServer.preferred([empty, flatpak], "")["key"] == flatpak["key"],
		"an install with no games was preferred over one with games")
	_assert(LocalServer.preferred([], "").is_empty(), "no installs did not give {}")

	# Nothing on PATH and no flatpak command: the Flatpak cannot be run, so
	# it is not offered.
	ctx["env"] = {"PATH": ""}
	ctx["flatpak_command"] = ""
	for inst in LocalServer.scan_installs(ctx):
		_assert(inst["kind"] != "flatpak", "a Flatpak was offered with no flatpak command")


func _windows() -> void:
	var root := base.path_join("windows")
	var user := root.path_join("Users/p")
	var roaming := user.path_join("AppData/Roaming")
	var local := user.path_join("AppData/Local")
	var own := root.path_join("goanna/luanti")
	# The zip unpacked into a folder of its own name, as Explorer's "Extract
	# All" does, so the build is one level further down.
	var zip := user.path_join("Downloads/luanti-5.16.1-win64/luanti-5.16.1-win64")
	_portable(zip)
	_game(zip.path_join("games/mineclonia"), "Mineclonia")
	# The self extracting .exe: RUN_IN_PLACE off, data in %APPDATA%\Minetest.
	var sfx := local.path_join("luanti/5.17.0")
	_file(sfx.path_join("bin/luanti.exe"))
	_dir(sfx.path_join("builtin"))
	_game(roaming.path_join("Minetest/games/minetest_game"), "Minetest Game")
	# What Install Luanti unpacks.
	_portable(own.path_join("luanti-5.16.1-win64"))

	var ctx := {"platform": "Windows", "home": user,
		"env": {"PATH": "", "APPDATA": roaming, "LOCALAPPDATA": local}, "own_dir": own,
		"system_dirs": [], "flatpak_bases": [], "flatpak_command": "", "app_dirs": [],
		"folder_bases": [user.path_join("Downloads"), local, own]}
	var found := LocalServer.scan_installs(ctx)
	_assert(found.size() == 3, "expected 3 Windows installs, found %d" % found.size())
	if found.size() != 3:
		return
	var portable: Dictionary = found[0]
	_assert(portable["kind"] == "portable" and portable["data_dir"] == zip,
		"the Windows zip did not keep its data in place")
	_assert(portable["version"] == "5.16.1", "the zip's version was not read from its folder")
	_assert(portable["argv"] == PackedStringArray([zip.path_join("bin/luanti.exe"), "--server"]),
		"the zip's server command is wrong")
	_assert(portable["games"] == ["mineclonia"], "the zip's games were %s" % str(portable["games"]))
	var unpacked: Dictionary = found[1]
	_assert(unpacked["kind"] == "package" and unpacked["data_dir"] == roaming.path_join("Minetest"),
		"the .exe's unpack directory did not use %APPDATA%\\Minetest")
	_assert(unpacked["version"] == "5.17.0" and unpacked["games"] == ["minetest_game"],
		"the .exe's version or games are wrong")
	_assert(found[2]["kind"] == "goanna", "Goanna's own install was not recognised")

	# Locate: the folder, its bin/, and the program itself are all the zip;
	# a program with another name is refused, because it would be run.
	for picked in [zip, zip.path_join("bin"), zip.path_join("bin/luanti.exe")]:
		_assert(LocalServer.install_at(picked, ctx).get("data_dir", "") == zip,
			"locating %s did not find the zip" % picked)
	_file(user.path_join("Downloads/setup.exe"))
	_assert(LocalServer.install_at(user.path_join("Downloads/setup.exe"), ctx).is_empty(),
		"a program not named like Luanti was accepted")
	_assert(LocalServer.install_at(user.path_join("Downloads"), ctx).is_empty(),
		"a folder with no Luanti in it was accepted")


func _located() -> void:
	# A Linux AppImage the scan does not look for, located by hand.
	var home := base.path_join("located/home")
	var appimage := home.path_join("Somewhere/luanti-5.16.1.AppImage")
	_file(appimage)
	var ctx := {"platform": "Linux", "home": home, "env": {}, "own_dir": "",
		"system_dirs": [], "flatpak_bases": [], "flatpak_command": "", "app_dirs": [],
		"folder_bases": []}
	var inst := LocalServer.install_at(appimage, ctx)
	_assert(inst.get("kind", "") == "appimage", "a located AppImage was not accepted")
	_assert(inst.get("argv", PackedStringArray()) == PackedStringArray([appimage, "--server"]),
		"a located AppImage's server command is wrong")


func _portable_archive() -> void:
	var dir := base.path_join("archive")
	DirAccess.make_dir_recursive_absolute(dir)
	var good := dir.path_join("good.zip")
	_zip(good, ["luanti-9.9.9-win64/bin/luanti.exe", "luanti-9.9.9-win64/builtin/init.lua",
		"luanti-9.9.9-win64/mods/mods_here.txt"])
	var own := dir.path_join("own")
	_assert(LocalServer.install_portable_archive(good, "0".repeat(64), own) != "",
		"an archive with the wrong hash was unpacked")
	_assert(not DirAccess.dir_exists_absolute(own.path_join("luanti-9.9.9-win64")),
		"an archive with the wrong hash left files behind")
	var sha := FileAccess.get_sha256(good)
	_assert(LocalServer.install_portable_archive(good, sha, own) == "",
		"a good archive was refused")
	_assert(FileAccess.file_exists(own.path_join("luanti-9.9.9-win64/bin/luanti.exe")),
		"a good archive was not unpacked")
	_assert(LocalServer.install_portable_archive(good, sha, own) == "",
		"installing the same version twice failed")
	for bad in [["../escape/bin/luanti.exe"], ["a/bin/luanti.exe", "b/builtin/init.lua"],
			["luanti-9.9.9-win64/builtin/init.lua"]]:
		var path := dir.path_join("bad.zip")
		_zip(path, bad)
		_assert(LocalServer.install_portable_archive(path, FileAccess.get_sha256(path),
			dir.path_join("bad")) != "", "a malformed archive was accepted: %s" % str(bad))


func _titles() -> void:
	# With no install scanned, a data directory's own games/ is searched.
	var data_dir := base.path_join("data")
	_game(data_dir.path_join("games/mineclone2"), "VoxeLibre")
	_file(data_dir.path_join("games/untitled/game.conf"), "description = No title line\n")
	_assert(LocalServer.list_games(data_dir) == ["mineclone2", "untitled"],
		"games were not listed by directory name")
	_assert(LocalServer.game_title(data_dir, "mineclone2") == "VoxeLibre",
		"the game.conf title was not read")
	_assert(LocalServer.game_title(data_dir, "untitled") == "untitled",
		"a game without a title did not fall back to its id")
	_assert(LocalServer.game_title(data_dir, "absent") == "absent",
		"a missing game did not fall back to its id")


func _portable(root: String) -> void:
	_file(root.path_join("bin/luanti.exe"))
	_dir(root.path_join("builtin"))
	_file(root.path_join("mods/mods_here.txt"))


func _game(dir: String, title: String) -> void:
	_file(dir.path_join("game.conf"), "title = %s\n" % title)


func _dir(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path)


func _file(path: String, text := "") -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)


func _zip(path: String, entries: Array) -> void:
	var packer := ZIPPacker.new()
	packer.open(path)
	for entry in entries:
		packer.start_file(str(entry))
		packer.write_file("x".to_utf8_buffer())
		packer.close_file()
	packer.close()


func _assert(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("local server discovery: " + message)
