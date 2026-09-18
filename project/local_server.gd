# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Launches a Luanti server in the background for singleplayer, and connects
# Goanna to it. Goanna is a client; "start a game" means running an ordinary
# unmodified Luanti server on localhost and joining it over the normal
# protocol, exactly as connecting to any other server. Nothing here modifies
# the server or the game.
#
# Which Luanti it runs is decided under "finding Luanti" below: every install
# the machine seems to have, by Luanti's own path rules, with the player's
# choice remembered. GOANNA_SERVER_CMD overrides the argv prefix (space
# separated).
extends RefCounted
class_name GoannaLocalServer

const AssetStore := preload("res://asset_store.gd")

var pid := -1
var port := 0
var gameid := "" # the game start() was asked for, for per game client defaults
var log_path := ""
var world_path := ""
var _argv: PackedStringArray
var _data_dir := ""
# Mapblocks (16 nodes each) the local server will send. Luanti's own default is
# 12; the client still has to ask for it through its own view range setting,
# and asking for more than this gets nothing.
var send_distance := 32
# How far the local server grants far rendering, in nodes (docs/far-rendering.md).
var far_distance := 1024
# Named one by one because an exported build cannot list a res:// directory.
# A runtime file missing from this list is not deployed and the mod fails to
# load on the register_mapgen_script call for it, so add new ones here.
const TERRAIN_DIFFUSION_FILES := [
	"init.lua", "tdl_far.lua", "tdl_palette.lua", "tdl_biomes.lua",
	"tdl_terrain.lua", "tdl_decorate.lua", "tdl_forest.lua", "tdl_column.lua", "tdl_mapgen.lua",
	"settingtypes.txt", "mod.conf", "LICENSE",
]
const GOANNA_SERVER_MOD_FILES := ["init.lua", "surface.lua", "fine.lua", "surface_material.lua", "damage.lua", "mod.conf", "settingtypes.txt", "README.md"]
const PBR_GAME_DIRS := {
	"minetest": "minetest_game",
	"minetest_game": "minetest_game",
	"mineclonia": "mineclonia",
}
# The worlds the player can choose between, and where to fetch each. These
# used to be one world in seven constants; they are data now because there is
# more than one. Each entry carries its own tile window and spawn, because a
# world is only the tiles it actually ships.
const TERRAIN_CATALOGUE := "res://terrain_worlds.json"
const TERRAIN_CATALOGUE_SCHEMA := "org.goanna.terrain-catalogue/v1"
static var _terrain_cache: Dictionary = {}

static func terrain_catalogue() -> Dictionary:
	if not _terrain_cache.is_empty():
		return _terrain_cache
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(TERRAIN_CATALOGUE))
	if parsed is not Dictionary or str(parsed.get("schema", "")) != TERRAIN_CATALOGUE_SCHEMA:
		push_warning("Terrain world catalogue is missing or not %s." % TERRAIN_CATALOGUE_SCHEMA)
		return {}
	_terrain_cache = parsed
	return _terrain_cache

# Every world, in catalogue order, for the world-creation list.
static func terrain_worlds() -> Array:
	var catalogue := terrain_catalogue()
	return catalogue.get("worlds", []) if not catalogue.is_empty() else []

static func default_terrain_id() -> String:
	var catalogue := terrain_catalogue()
	return str(catalogue.get("default", "")) if not catalogue.is_empty() else ""

# One world by id. Returns {} for an id the catalogue does not list, which is
# how an old goanna.cfg naming a retired world is handled.
static func terrain_world(id: String) -> Dictionary:
	for world in terrain_worlds():
		if world is Dictionary and str(world.get("id", "")) == id:
			return world
	return {}

# --- finding Luanti ----------------------------------------------------------
#
# Start Game needs a Luanti server and Goanna has none of its own, so it has to
# find the one the player already has. No platform keeps a register of that.
# So this looks where each kind of packaging puts Luanti, then applies Luanti's
# own path rules to whatever it finds: porting.cpp (initializePaths,
# setSystemPaths) for the share and user directories, and content/subgames.cpp
# (getAvailableGamePaths) for where games are looked for. Every install found
# is kept, not only the first, because a machine can have more than one and
# only the player knows which one their worlds are in. The menu lists them and
# remembers the choice in goanna.cfg.
#
# The old lookup found a server and then looked for games only in
# ~/.minetest/games, so on Debian and Ubuntu (and Pop!_OS, which uses Ubuntu's
# archive) it found /usr/games/minetest and reported no games at all: Ubuntu
# 24.04's minetest-data puts devtest and Minetest Game in
# /usr/share/games/minetest/games.
#
# Where each kind lives, as checked against the packages themselves:
#   Debian, Ubuntu    /usr/games/minetest, share /usr/share/games/minetest
#   other Linux       /usr/bin/luanti, share /usr/share/luanti
#   Flatpak           ~/.local/share/flatpak (user) or /var/lib/flatpak
#                     (system). Its launcher sets the user path to
#                     ~/.var/app/<id>/.minetest.
#   Snap              /snap/bin/<name>, data ~/snap/<name>/current/.minetest
#   AppImage          anywhere, data ~/.minetest
#   Windows zip       anywhere. A RUN_IN_PLACE build, so its data is the
#                     unpacked folder itself.
#   Windows .exe      unpacks itself to %LOCALAPPDATA%\luanti\<version> and
#                     keeps its data in %APPDATA%\Minetest
#   macOS             Luanti.app, data ~/Library/Application Support/minetest
# GOANNA_SERVER_CMD still overrides all of it (the server argv, space
# separated, with GOANNA_SERVER_DATA_DIR for its data directory).

const CFG_PATH := "user://goanna.cfg"
const FLATPAK_IDS := ["org.luanti.luanti", "net.minetest.Minetest"]
const FLATHUB_REPO := "https://dl.flathub.org/repo/flathub.flatpakrepo"
const DOWNLOAD_PAGE := "https://www.luanti.org/downloads/"
# Where Goanna unpacks a Luanti it installed itself.
const OWN_LUANTI_DIR := "user://luanti"
# The official Windows build that Install Luanti fetches. Pinned, with the
# sha256 GitHub publishes for the asset, rather than "latest", because what is
# downloaded is then run. 5.17.0 is the release Goanna's client core is built
# from.
const LUANTI_WINDOWS := {
	"version": "5.17.0",
	"url": "https://github.com/luanti-org/luanti/releases/download/5.17.0/luanti-5.17.0-win64.zip",
	"sha256": "3ce20c77f5c206a988d7a6b883439e2759e3cf67428c9dbcf99ecd2936da631c",
	"bytes": 17539019,
}
const _EXECUTABLE_NAMES := ["luantiserver", "minetestserver", "luanti", "minetest"]

static var _installs: Array = []
static var _scanned := false
static var _chosen: Dictionary = {}

# The install Start Game uses: GOANNA_SERVER_CMD if set, else the one the
# player chose, else the first found that has a game, else the first found.
# {} when there is none. The keys:
#   kind         package, portable, appimage, snap, flatpak, goanna or custom
#   key          what goanna.cfg remembers it by
#   product      Luanti or Minetest, from the program's own name
#   version      when the install says, else ""
#   location     the program, or the flatpak's deployed files
#   argv         the server command, before the per world arguments
#   client_argv  Luanti's own client, to install games with; may be empty
#   data_dir     Luanti's user path: worlds, mods, texture packs, games
#   share_dir    Luanti's share path, when it can be seen from outside
#   game_dirs    where games are looked for, in Luanti's order
#   games        the game directories found there
static func detect() -> Dictionary:
	var custom := _custom_install()
	if not custom.is_empty():
		_chosen = custom
		return custom
	_chosen = preferred(installs(), saved_choice())
	return _chosen

static func preferred(all: Array, wanted: String) -> Dictionary:
	var saved := _find_key(all, wanted) if wanted != "" else {}
	if not saved.is_empty():
		return saved
	for inst in all:
		if not (inst["games"] as Array).is_empty():
			return inst
	return all[0] if not all.is_empty() else {}

# Every install found, most preferred first. Scanned once per run, because the
# menu asks often; pass rescan after the player installs or moves one.
static func installs(rescan := false) -> Array:
	if _scanned and not rescan:
		return _installs
	var ctx := _context()
	_installs = scan_installs(ctx)
	# One the player located by hand, somewhere the scan does not look. It is
	# built again from its path every time, so one that has since been deleted
	# drops out instead of being offered.
	var wanted := saved_choice()
	if wanted.begins_with("exe:") and _find_key(_installs, wanted).is_empty() \
			and FileAccess.file_exists(wanted.substr(4)):
		_add_install(_installs, _install_from_executable(wanted.substr(4), ctx))
	_scanned = true
	return _installs

static func saved_choice() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return ""
	return str(cfg.get_value("luanti", "install", ""))

# Remember `inst` as the one to use. Kept in the scan's list even when the scan
# would not have found it, so the menu can show it.
static func choose(inst: Dictionary) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value("luanti", "install", str(inst.get("key", "")))
	cfg.save(CFG_PATH)
	if _find_key(_installs, str(inst.get("key", ""))).is_empty():
		_installs.append(inst)
	_chosen = inst

# What the player pointed at with Locate: a Luanti program, an AppImage, a
# macOS .app, or a folder holding one (the Windows zip's folder, its bin/, a
# source checkout). {} when there is no Luanti there. Only programs named like
# Luanti's are accepted, because whatever is accepted gets run.
static func install_at(path: String, ctx: Dictionary = {}) -> Dictionary:
	if ctx.is_empty():
		ctx = _context()
	var windows := str(ctx["platform"]) == "Windows"
	path = path.simplify_path()
	if FileAccess.file_exists(path):
		var lower := path.get_file().to_lower()
		var stem := lower.trim_suffix(".exe") if windows else lower
		if lower.ends_with(".appimage") or _EXECUTABLE_NAMES.has(stem):
			return _install_from_executable(path, ctx)
		return {}
	if not DirAccess.dir_exists_absolute(path):
		return {}
	# The client first, so Open Luanti is available for what is chosen here.
	for name in ["luanti", "minetest", "luantiserver", "minetestserver"]:
		for dir in [path.path_join("bin"), path, path.path_join("Contents/MacOS")]:
			var exe := _executable_in(dir, name, windows)
			if exe != "":
				return _install_from_executable(exe, ctx)
	return {}

# Where the scan looks on this machine, for the menu to show when it finds
# nothing: the list a player needs to see to know why.
static func search_places() -> PackedStringArray:
	var ctx := _context()
	var lines: PackedStringArray = []
	lines.append("Programs named %s in: %s" % [", ".join(_EXECUTABLE_NAMES),
		", ".join(PackedStringArray(_search_dirs(ctx)))])
	for base in ctx["flatpak_bases"]:
		lines.append("Flatpak (%s): %s" % [str(base[0]), str(base[1])])
	if str(ctx["flatpak_command"]) == "" and str(ctx["platform"]) == "Linux":
		lines.append("(no flatpak command found, so Flatpak installs cannot be run)")
	if not (ctx["app_dirs"] as Array).is_empty():
		lines.append("AppImages and apps in: " + ", ".join(PackedStringArray(ctx["app_dirs"])))
	lines.append("Folders named luanti* or minetest* in: "
		+ ", ".join(PackedStringArray(ctx["folder_bases"])))
	return lines

# The machine as the scan sees it. Everything platform specific is decided
# here, so scan_installs can be run against a made up machine in a test.
static func _context() -> Dictionary:
	var platform := OS.get_name()
	if platform != "Windows" and platform != "macOS":
		platform = "Linux" # the BSDs follow the same rules in porting.cpp
	var windows := platform == "Windows"
	var home := OS.get_environment("USERPROFILE" if windows else "HOME")
	var env := {}
	for key in ["PATH", "LUANTI_USER_PATH", "MINETEST_USER_PATH", "LUANTI_GAME_PATH",
			"MINETEST_GAME_PATH", "MINETEST_SUBGAME_PATH", "APPDATA", "LOCALAPPDATA",
			"ProgramFiles", "ProgramFiles(x86)", "ProgramData", "SystemDrive",
			"XDG_DATA_HOME", "FLATPAK_USER_DIR", "FLATPAK_SYSTEM_DIR"]:
		env[key] = OS.get_environment(key)
	var own_dir := ProjectSettings.globalize_path(OWN_LUANTI_DIR)
	# Desktop, Downloads and Documents are where an unpacked zip or a
	# downloaded AppImage usually sits. The system reports them, which follows
	# a folder moved into OneDrive on Windows.
	var places: Array = []
	for which in [OS.SYSTEM_DIR_DESKTOP, OS.SYSTEM_DIR_DOWNLOADS, OS.SYSTEM_DIR_DOCUMENTS]:
		var place := OS.get_system_dir(which)
		if place != "":
			_append_unique(places, place)
	var ctx := {"platform": platform, "home": home, "env": env, "own_dir": own_dir,
		"system_dirs": [], "flatpak_bases": [], "flatpak_command": "",
		"app_dirs": [], "folder_bases": []}
	if windows:
		var local := str(env["LOCALAPPDATA"])
		var bases: Array = places.duplicate()
		for base in [home, home.path_join("Games"), local, local.path_join("Programs"),
				str(env["ProgramFiles"]), str(env["ProgramFiles(x86)"]),
				str(env["SystemDrive"]) + "/Games", home.path_join("scoop/apps"),
				str(env["ProgramData"]).path_join("chocolatey/lib"),
				local.path_join("Microsoft/WinGet/Packages"), own_dir]:
			# An unset variable leaves a relative or root relative path.
			if base.is_absolute_path() and not base.begins_with("/"):
				_append_unique(bases, base)
		ctx["folder_bases"] = bases
	elif platform == "macOS":
		ctx["system_dirs"] = ["/opt/homebrew/bin", "/usr/local/bin"]
		ctx["app_dirs"] = ["/Applications", home.path_join("Applications")]
		ctx["folder_bases"] = [home, own_dir]
	else:
		# A desktop session need not give the programs it starts the PATH an
		# interactive shell has (COSMIC did not), and Debian puts games in
		# /usr/games on purpose, so PATH alone is never enough.
		ctx["system_dirs"] = ["/usr/games", "/usr/local/games", "/usr/bin", "/usr/local/bin",
			"/snap/bin", "/var/lib/snapd/snap/bin", home.path_join(".local/bin"),
			home.path_join(".nix-profile/bin"), "/run/current-system/sw/bin",
			"/home/linuxbrew/.linuxbrew/bin"]
		var data_home := str(env["XDG_DATA_HOME"])
		if data_home == "":
			data_home = home.path_join(".local/share")
		var user_base := str(env["FLATPAK_USER_DIR"])
		var system_base := str(env["FLATPAK_SYSTEM_DIR"])
		ctx["flatpak_bases"] = [
			["user", user_base if user_base != "" else data_home.path_join("flatpak")],
			["system", system_base if system_base != "" else "/var/lib/flatpak"]]
		ctx["flatpak_command"] = _executable_on(["flatpak"], _path_dirs(env, false)
			+ ["/usr/bin", "/usr/local/bin"], false)
		var apps: Array = [home.path_join("Applications"), home.path_join(".local/bin"),
			home.path_join("bin"), "/opt"]
		for place in places:
			_append_unique(apps, place)
		ctx["app_dirs"] = apps
		var bases: Array = [home, home.path_join("Games"), "/opt", own_dir]
		for place in places:
			_append_unique(bases, place)
		ctx["folder_bases"] = bases
	return ctx

static func scan_installs(ctx: Dictionary) -> Array:
	var found: Array = []
	var windows := str(ctx["platform"]) == "Windows"
	# Server only programs first: they need nothing from the desktop, and the
	# client of the same install is merged into the same entry by _add_install.
	for name in _EXECUTABLE_NAMES:
		for dir in _search_dirs(ctx):
			var exe := _executable_in(str(dir), name, windows)
			if exe != "":
				_add_install(found, _install_from_executable(exe, ctx))
	for inst in _flatpak_installs(ctx):
		_add_install(found, inst)
	for dir in ctx["app_dirs"]:
		var d := DirAccess.open(str(dir))
		if d == null:
			continue
		for name in d.get_files():
			var lower := name.to_lower()
			if lower.ends_with(".appimage") and (lower.contains("luanti") or lower.contains("minetest")):
				_add_install(found, _install_from_executable(str(dir).path_join(name), ctx))
		for name in d.get_directories():
			var lower := name.to_lower()
			if lower.ends_with(".app") and (lower.contains("luanti") or lower.contains("minetest")):
				_add_install(found, install_at(str(dir).path_join(name), ctx))
	# Unpacked builds: the Windows zip wherever it was extracted, the Windows
	# .exe's own unpack directory, Scoop, Chocolatey and winget, a source
	# checkout, and what Goanna installed itself. Only folders named luanti* or
	# minetest* are opened, and at most two levels below them, so this is a
	# handful of directory listings however full the disk is.
	for base in ctx["folder_bases"]:
		for folder in _subdirs(str(base)):
			var lower := str(folder).get_file().to_lower()
			if not (lower.begins_with("luanti") or lower.begins_with("minetest")):
				continue
			var roots: Array = [folder]
			roots.append_array(_subdirs(str(folder)))
			roots.append_array(_subdirs(str(folder).path_join("tools")))
			for root in roots:
				for name in _EXECUTABLE_NAMES:
					var exe := _executable_in(str(root).path_join("bin"), name, windows)
					if exe != "":
						_add_install(found, _install_from_executable(exe, ctx))
	return found

# A program found on disk, turned into an install by Luanti's own rules.
static func _install_from_executable(path: String, ctx: Dictionary) -> Dictionary:
	var home := str(ctx["home"])
	# A Snap's command is a link to /usr/bin/snap, so it is recognised by
	# where it is before any link is followed.
	var link_dir := path.get_base_dir()
	if link_dir == "/snap/bin" or link_dir == "/var/lib/snapd/snap/bin":
		var snap := path.get_file()
		var snap_root := "/snap".path_join(snap).path_join("current")
		var snap_share := _first_with_builtin([snap_root.path_join("usr/share/luanti"),
			snap_root.path_join("usr/share/minetest"), snap_root.path_join("share/luanti"),
			snap_root.path_join("share/minetest")])
		return _make_install("snap", "exe:" + path, _product(snap), _version_in(snap_root),
			path, PackedStringArray([path, "--server"]), PackedStringArray([path]),
			home.path_join("snap").path_join(snap).path_join("current/.minetest"), snap_share, [])
	# Luanti finds its share directory from where its binary really is
	# (/proc/self/exe), so links are followed first.
	var exe := _resolve_link(path)
	var lower := exe.get_file().to_lower()
	var appimage := lower.ends_with(".appimage")
	var name := lower.trim_suffix(".exe")
	var server_only := not appimage and name.ends_with("server")
	var root := exe.get_base_dir().get_base_dir()
	var kind := "package"
	var share := ""
	var data := ""
	if appimage:
		# Its share directory is inside the image, invisible until it runs.
		kind = "appimage"
		data = _default_user_dir(ctx)
	elif _run_in_place(root):
		# RUN_IN_PLACE, as the Windows zip and most source builds are: share and
		# user are both the folder above bin/, and LUANTI_USER_PATH is ignored.
		kind = "portable"
		share = root
		data = root
	else:
		# setSystemPaths: the compiled in share directory, then
		# bin/../share/<project>, then bin/.. . Distributions compile in one
		# of the first ones, so they are found without knowing it. Resources
		# is a macOS bundle's.
		share = _first_with_builtin([root.path_join("share/luanti"),
			root.path_join("share/minetest"), root.path_join("share/games/luanti"),
			root.path_join("share/games/minetest"), root.path_join("Resources"), root])
		data = _default_user_dir(ctx)
	var own_dir := str(ctx["own_dir"])
	if own_dir != "" and exe.begins_with(own_dir):
		kind = "goanna"
	var argv := PackedStringArray([exe]) if server_only else PackedStringArray([exe, "--server"])
	var client := PackedStringArray() if server_only else PackedStringArray([exe])
	return _make_install(kind, "exe:" + exe, _product(name), _version_in(exe), exe, argv,
		client, data, share, _env_game_dirs(ctx) if kind != "portable" else [])

static func _flatpak_installs(ctx: Dictionary) -> Array:
	var found: Array = []
	var flatpak := str(ctx["flatpak_command"])
	if flatpak == "":
		return found # installed or not, it cannot be run
	var home := str(ctx["home"])
	for id in FLATPAK_IDS:
		for base in ctx["flatpak_bases"]:
			var scope := str(base[0])
			var location := str(base[1]).path_join("app").path_join(id).path_join("current/active")
			if not DirAccess.dir_exists_absolute(location.path_join("files")):
				continue
			var run := PackedStringArray([flatpak, "run", "--" + scope])
			var argv := run.duplicate()
			# Through the app's own launcher, which is what sets its user path.
			argv.append_array(["--command=" + ("luanti" if id == "org.luanti.luanti" else "minetest"),
				id, "--server"])
			var client := run.duplicate()
			client.append(id)
			var share := _first_with_builtin([location.path_join("files/share/luanti"),
				location.path_join("files/share/minetest")])
			# The host's LUANTI_GAME_PATH names host paths the sandbox cannot
			# see, so only the app's own two directories count.
			found.append(_make_install("flatpak", "flatpak:%s:%s" % [id, scope],
				_product(id), _metainfo_version(location, id), location, argv, client,
				home.path_join(".var/app").path_join(id).path_join(".minetest"), share, []))
	return found

static func _make_install(kind: String, key: String, product: String, version: String,
		location: String, argv: PackedStringArray, client_argv: PackedStringArray,
		data_dir: String, share_dir: String, extra_game_dirs: Array) -> Dictionary:
	var game_dirs: Array = []
	if share_dir != "":
		game_dirs.append(share_dir.path_join("games"))
	_append_unique(game_dirs, data_dir.path_join("games"))
	for dir in extra_game_dirs:
		_append_unique(game_dirs, str(dir))
	return {"kind": kind, "key": key, "product": product, "version": version,
		"location": location, "argv": argv, "client_argv": client_argv,
		"data_dir": data_dir, "share_dir": share_dir, "game_dirs": game_dirs,
		"games": _games_in(game_dirs)}

# The same install reached twice, as the server and the client of one package
# or through two links, is one entry: the first one found, which is the server
# only program when there is one, lending it the client's command.
static func _add_install(found: Array, inst: Dictionary) -> void:
	if inst.is_empty():
		return
	for existing in found:
		if _same_install(existing, inst):
			if (existing["client_argv"] as PackedStringArray).is_empty():
				existing["client_argv"] = inst["client_argv"]
			return
	found.append(inst)

static func _same_install(a: Dictionary, b: Dictionary) -> bool:
	if str(a["data_dir"]) != str(b["data_dir"]):
		return false
	if str(a["share_dir"]) != "" or str(b["share_dir"]) != "":
		return str(a["share_dir"]) == str(b["share_dir"])
	return str(a["location"]) == str(b["location"])

static func _custom_install() -> Dictionary:
	var override := OS.get_environment("GOANNA_SERVER_CMD")
	if override == "":
		return {}
	var ctx := _context()
	var data := OS.get_environment("GOANNA_SERVER_DATA_DIR")
	if data == "":
		data = _default_user_dir(ctx)
	return _make_install("custom", "cmd:" + override, "Luanti", "", override,
		override.split(" ", false), PackedStringArray(), data, "", _env_game_dirs(ctx))

static func _find_key(list: Array, key: String) -> Dictionary:
	for inst in list:
		if str(inst["key"]) == key:
			return inst
	return {}

# Luanti's user path when nothing puts it beside the program.
static func _default_user_dir(ctx: Dictionary) -> String:
	var env: Dictionary = ctx["env"]
	for variable in ["LUANTI_USER_PATH", "MINETEST_USER_PATH"]:
		if str(env.get(variable, "")) != "":
			return str(env[variable])
	match str(ctx["platform"]):
		"Windows":
			return str(env.get("APPDATA", "")).path_join("Minetest")
		"macOS":
			return str(ctx["home"]).path_join("Library/Application Support/minetest")
	return str(ctx["home"]).path_join(".minetest")

# getSubgamePathEnv: the first of these that is set, as a path list.
static func _env_game_dirs(ctx: Dictionary) -> Array:
	var env: Dictionary = ctx["env"]
	for variable in ["LUANTI_GAME_PATH", "MINETEST_GAME_PATH", "MINETEST_SUBGAME_PATH"]:
		var value := str(env.get(variable, ""))
		if value != "":
			return Array(value.split(";" if str(ctx["platform"]) == "Windows" else ":", false))
	return []

static func _search_dirs(ctx: Dictionary) -> Array:
	var dirs := _path_dirs(ctx["env"], str(ctx["platform"]) == "Windows")
	for dir in ctx["system_dirs"]:
		_append_unique(dirs, str(dir))
	return dirs

static func _path_dirs(env: Dictionary, windows: bool) -> Array:
	var dirs: Array = []
	for dir in str(env.get("PATH", "")).split(";" if windows else ":", false):
		_append_unique(dirs, dir)
	return dirs

static func _executable_on(names: Array, dirs: Array, windows: bool) -> String:
	for dir in dirs:
		for name in names:
			var exe := _executable_in(str(dir), str(name), windows)
			if exe != "":
				return exe
	return ""

static func _executable_in(dir: String, name: String, windows: bool) -> String:
	if dir == "":
		return ""
	var candidate := dir.path_join(name + (".exe" if windows else ""))
	return candidate if FileAccess.file_exists(candidate) else ""

# A RUN_IN_PLACE build installs these two placeholders beside bin/, and no
# other build does (Luanti's CMakeLists.txt, install() under RUN_IN_PLACE).
static func _run_in_place(root: String) -> bool:
	return DirAccess.dir_exists_absolute(root.path_join("builtin")) and (
		FileAccess.file_exists(root.path_join("mods/mods_here.txt"))
		or FileAccess.file_exists(root.path_join("textures/texture_packs_here.txt")))

# Luanti recognises its share directory by its builtin/ subdirectory.
static func _first_with_builtin(candidates: Array) -> String:
	for dir in candidates:
		if DirAccess.dir_exists_absolute(str(dir).path_join("builtin")):
			return str(dir).simplify_path()
	return ""

static func _resolve_link(path: String) -> String:
	for i in 8:
		var d := DirAccess.open(path.get_base_dir())
		if d == null or not d.is_link(path.get_file()):
			return path
		var target := d.read_link(path.get_file())
		if not target.is_absolute_path():
			target = path.get_base_dir().path_join(target)
		path = target.simplify_path()
	return path

static func _subdirs(path: String) -> Array:
	var d := DirAccess.open(path)
	if d == null:
		return []
	var result: Array = []
	for name in d.get_directories():
		result.append(path.path_join(name))
	return result

static func _product(name: String) -> String:
	return "Minetest" if name.to_lower().contains("minetest") else "Luanti"

# A version written into the path, as the Windows zip, the Windows .exe's
# unpack directory and AppImages have. A distribution package has none.
static func _version_in(path: String) -> String:
	var pattern := RegEx.new()
	pattern.compile("(?:^|[-_/\\\\])(\\d+\\.\\d+\\.\\d+)(?=$|[-_/\\\\.])")
	var found := pattern.search(path)
	return found.get_string(1) if found != null else ""

static func _metainfo_version(location: String, id: String) -> String:
	for name in [id + ".metainfo.xml", id + ".appdata.xml"]:
		var path := location.path_join("files/share/metainfo").path_join(name)
		if not FileAccess.file_exists(path):
			continue
		var pattern := RegEx.new()
		pattern.compile("<release[^>]*version=\"([^\"]+)\"")
		var found := pattern.search(FileAccess.get_file_as_string(path))
		if found != null:
			return found.get_string(1)
	return ""

static func _append_unique(list: Array, value: String) -> void:
	if value != "" and not list.has(value):
		list.append(value)

# Game directories under `game_dirs`, in Luanti's order: an id found twice is
# the first one, as getAvailableGamePaths has it, and ids compare after
# normalizeGameId, which drops a trailing _game. Listed by directory name,
# which is what the server is told and what PBR_GAME_DIRS keys on.
static func _games_in(game_dirs: Array) -> Array:
	var games: Array = []
	var seen := {}
	for base in game_dirs:
		var d := DirAccess.open(str(base))
		if d == null:
			continue
		for name in d.get_directories():
			if not FileAccess.file_exists(str(base).path_join(name).path_join("game.conf")):
				continue
			var id := name.trim_suffix("_game") if name != "_game" else name
			if seen.has(id):
				continue
			seen[id] = true
			games.append(name)
	games.sort()
	return games

# Where games are looked for, for the helpers below that are handed only a
# data directory: the chosen install's list when it is that install's,
# otherwise the first scanned install with that data directory, otherwise the
# data directory's own games/.
static func _game_dirs(data_dir: String) -> Array:
	if not _chosen.is_empty() and str(_chosen["data_dir"]) == data_dir:
		return _chosen["game_dirs"]
	var inst := {}
	for candidate in _installs:
		if str(candidate["data_dir"]) == data_dir:
			inst = candidate
			break
	return inst["game_dirs"] if not inst.is_empty() else [data_dir.path_join("games")]

static func _game_dir(data_dir: String, gameid: String) -> String:
	for base in _game_dirs(data_dir):
		var dir := str(base).path_join(gameid)
		if FileAccess.file_exists(dir.path_join("game.conf")):
			return dir
	return ""

# Games installed for this Luanti, in its share directory, its user path and
# LUANTI_GAME_PATH.
static func list_games(data_dir: String) -> Array:
	return _games_in(_game_dirs(data_dir))

# The name a game calls itself, from the `title` line of its game.conf, or
# the directory name when there is none. The two differ more often than you
# would think: VoxeLibre still lives in a directory called mineclone2 so that
# old worlds keep loading, and a player who installed "VoxeLibre" from
# ContentDB will not recognise it under that name.
static func game_title(data_dir: String, gameid: String) -> String:
	var dir := _game_dir(data_dir, gameid)
	if dir == "":
		return gameid
	for line in FileAccess.get_file_as_string(dir.path_join("game.conf")).split("\n"):
		if line.get_slice("=", 0).strip_edges() == "title":
			var title := line.get_slice("=", 1).strip_edges()
			if title != "":
				return title
	return gameid

# How Install Luanti would install the Flathub build here, or {} when this
# machine has no flatpak command. Into the system installation when Flathub is
# already configured there, so the runtime is shared with the player's other
# apps and any password prompt is the one a software centre would show;
# otherwise into the user's own installation, which needs no password but
# downloads its own copy of the runtime.
static func flatpak_install_plan() -> Dictionary:
	var flatpak := str(_context()["flatpak_command"])
	if flatpak == "":
		return {}
	var system := false
	var out: Array = []
	if OS.execute(flatpak, ["remotes", "--system", "--columns=name"], out) == 0 and not out.is_empty():
		for line in str(out[0]).split("\n"):
			if line.strip_edges() == "flathub":
				system = true
	var steps: Array = []
	if system:
		steps.append([flatpak, "install", "--system", "-y", "flathub", FLATPAK_IDS[0]])
	else:
		steps.append([flatpak, "remote-add", "--user", "--if-not-exists", "flathub", FLATHUB_REPO])
		steps.append([flatpak, "install", "--user", "-y", "flathub", FLATPAK_IDS[0]])
	return {"scope": "system" if system else "user", "steps": steps}

static func flatpak_available() -> bool:
	return str(_context()["flatpak_command"]) != ""

# Runs `steps` one after another without blocking the menu, their output going
# to `log_path`. The exit status is written to `status_path` once they finish,
# through a rename so that it is never read half written. Returns the pid.
static func run_steps_in_background(steps: Array, log_path: String, status_path: String) -> int:
	var commands: PackedStringArray = []
	for step in steps:
		var words: PackedStringArray = []
		for word in step:
			words.append(_shell_quote(str(word)))
		commands.append(" ".join(words))
	var script := "(%s) > %s 2>&1; echo $? > %s && mv %s %s" % [" && ".join(commands),
		_shell_quote(log_path), _shell_quote(status_path + ".part"),
		_shell_quote(status_path + ".part"), _shell_quote(status_path)]
	return OS.create_process("/bin/sh", ["-c", script])

static func _shell_quote(word: String) -> String:
	return "'" + word.replace("'", "'\\''") + "'"

# Unpacks the official Windows build, already downloaded to `archive_path`,
# into `parent`. Checked against `expected_sha256` first, because it is going
# to be run. An earlier install of the same version is kept rather than
# replaced, since a portable build's worlds are inside it. Returns "" or an
# error for the player.
static func install_portable_archive(archive_path: String, expected_sha256: String,
		parent: String) -> String:
	if expected_sha256.length() != 64 \
			or FileAccess.get_sha256(archive_path).to_lower() != expected_sha256.to_lower():
		return "The Luanti download failed its integrity check and was discarded."
	var zip := ZIPReader.new()
	if zip.open(archive_path) != OK:
		return "The Luanti download is not a readable ZIP archive."
	DirAccess.make_dir_recursive_absolute(parent)
	var staging := parent.path_join(".unpack-%d" % OS.get_process_id())
	_remove_tree(staging)
	var top := ""
	for entry in zip.get_files():
		var clean := entry.replace("\\", "/").simplify_path()
		var first := clean.get_slice("/", 0)
		if clean == "." or clean.begins_with("../") or clean.begins_with("/") \
				or clean.contains(":") or (top != "" and first != top):
			zip.close()
			_remove_tree(staging)
			return "The Luanti download is not laid out as expected, so it was not unpacked."
		top = first
		var destination := staging.path_join(clean)
		if entry.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(destination)
			continue
		DirAccess.make_dir_recursive_absolute(destination.get_base_dir())
		var output := FileAccess.open(destination, FileAccess.WRITE)
		if output == null:
			zip.close()
			_remove_tree(staging)
			return "Could not write %s." % destination
		output.store_buffer(zip.read_file(entry))
	zip.close()
	if top == "" or not FileAccess.file_exists(staging.path_join(top).path_join("bin/luanti.exe")):
		_remove_tree(staging)
		return "The Luanti download has no bin/luanti.exe."
	var destination := parent.path_join(top)
	if not DirAccess.dir_exists_absolute(destination) \
			and DirAccess.rename_absolute(staging.path_join(top), destination) != OK:
		_remove_tree(staging)
		return "Could not move Luanti into %s." % destination
	_remove_tree(staging)
	return ""

# Mods and texture packs the detected Luanti already has. Goanna does not
# install content, it borrows whatever that install carries, so these are for
# showing the player what Start Game can offer and nothing else.
static func list_mods(data_dir: String) -> Array:
	return _list_dirs([data_dir.path_join("mods")], ["mod.conf", "init.lua", "modpack.conf"])

static func list_texture_packs(data_dir: String) -> Array:
	return _list_dirs([data_dir.path_join("textures")], [])

# Subdirectories of `bases` that carry at least one of `markers`, or any
# subdirectory when `markers` is empty. Sorted, de-duplicated across bases.
static func _list_dirs(bases: Array, markers: Array) -> Array:
	var found: Array = []
	for base in bases:
		var d := DirAccess.open(base)
		if d == null:
			continue
		d.list_dir_begin()
		var name := d.get_next()
		while name != "":
			if d.current_is_dir() and not name.begins_with(".") and not found.has(name):
				if markers.is_empty():
					found.append(name)
				else:
					for m in markers:
						if FileAccess.file_exists(base.path_join(name).path_join(m)):
							found.append(name)
							break
			name = d.get_next()
		d.list_dir_end()
	found.sort()
	return found

# Existing worlds and the game each was made with.
static func list_worlds(data_dir: String) -> Array:
	var worlds: Array = []
	var d := DirAccess.open(data_dir.path_join("worlds"))
	if d == null:
		return worlds
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var wm := data_dir.path_join("worlds").path_join(name).path_join("world.mt")
		if d.current_is_dir() and FileAccess.file_exists(wm):
			var gid := ""
			var cf := ConfigFile.new()
			var f := FileAccess.open(wm, FileAccess.READ)
			if f:
				while not f.eof_reached():
					var line := f.get_line().strip_edges()
					if line.begins_with("gameid"):
						gid = line.get_slice("=", 1).strip_edges()
			worlds.append({"name": name, "gameid": gid})
		name = d.get_next()
	d.list_dir_end()
	worlds.sort_custom(func(a, b): return a["name"] < b["name"])
	return worlds

# The game a world was created with, or "" if it is new/unknown. A world
# remembers its game, and loading it under another one makes every stored
# node unknown, so the caller must respect this.
static func world_gameid(data_dir: String, worldname: String) -> String:
	var wm := data_dir.path_join("worlds").path_join(worldname).path_join("world.mt")
	var f := FileAccess.open(wm, FileAccess.READ)
	if f == null:
		return ""
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("gameid"):
			return line.get_slice("=", 1).strip_edges()
	return ""

static func world_options(data_dir: String, worldname: String) -> Dictionary:
	var result := {"gameid": world_gameid(data_dir, worldname), "creative": false,
		"damage": true, "mods": [], "pbr_materials": true,
		"terrain_diffusion": terrain_diffusion_ready(data_dir, worldname)}
	var path := data_dir.path_join("worlds").path_join(worldname).path_join("world.mt")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return result
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		var key := line.get_slice("=", 0).strip_edges()
		var value := line.get_slice("=", 1).strip_edges()
		if key == "creative_mode":
			result["creative"] = value == "true"
		elif key == "enable_damage":
			result["damage"] = value != "false"
		elif key == "load_mod_goanna_pbr":
			result["pbr_materials"] = value != "false"
		elif key.begins_with("load_mod_") and value != "false":
			(result["mods"] as Array).append(key.trim_prefix("load_mod_"))
	return result

static func delete_world_recoverably(data_dir: String, worldname: String) -> String:
	var source := data_dir.path_join("worlds").path_join(worldname)
	if not DirAccess.dir_exists_absolute(source):
		return "World not found: %s" % worldname
	var trash := data_dir.path_join("worlds").path_join(".goanna-trash")
	DirAccess.make_dir_recursive_absolute(trash)
	var stamp := int(Time.get_unix_time_from_system())
	var target := trash.path_join("%s-%d" % [worldname, stamp])
	var err := DirAccess.rename_absolute(source, target)
	return "" if err == OK else "Could not move the world to %s." % target

# Where Luanti keeps its worlds, for callers that need to inspect them.
static func data_dir_or_empty() -> String:
	var env := detect()
	return env["data_dir"] if not env.is_empty() else ""

static func bundled_pbr_texture_path(game: String) -> String:
	# An installed profile decides on its own, without consulting
	# PBR_GAME_DIRS. That map names only the packs carried in this
	# repository, and a game can have bundles without being in it: art whose
	# licence is clear for part of a game is still worth shipping for that
	# part, and a node with no companion map simply keeps the server's own
	# texture. Partial coverage is an answer, not a failure.
	var installed := AssetStore.profile_texture_path(game)
	if installed != "":
		return installed
	if not PBR_GAME_DIRS.has(game):
		return ""
	# Transitional development fallback. Release archives no longer contain
	# pbr_packs; installed versioned bundles are the production path.
	var legacy := ProjectSettings.globalize_path("res://../pbr_packs").path_join(
		str(PBR_GAME_DIRS[game])).path_join("textures")
	return legacy if DirAccess.dir_exists_absolute(legacy) else ""

# Whether this game has any PBR art at all, from either source. Used to decide
# if the material worldmod is worth loading.
static func pbr_art_available(game: String) -> bool:
	return bundled_pbr_texture_path(game) != ""

# A Terrain Diffusion world carries its own generated tile cache. The default
# bake is downloaded once into a shared content cache, then copied into each
# world so existing worlds never depend on a network request or mutable asset.
static func terrain_diffusion_ready(data_dir: String, worldname: String) -> bool:
	return FileAccess.file_exists(data_dir.path_join("worlds").path_join(worldname)
		.path_join("terrain_diffusion").path_join("manifest.json"))

static func world_has_generated_map(data_dir: String, worldname: String) -> bool:
	var world := data_dir.path_join("worlds").path_join(worldname)
	for backend in ["map.sqlite", "map.db", "map.lmdb"]:
		if FileAccess.file_exists(world.path_join(backend)):
			return true
	return DirAccess.dir_exists_absolute(world.path_join("map"))

static func _copy_resource_file(src: String, dst: String) -> bool:
	var input := FileAccess.open(src, FileAccess.READ)
	if input == null:
		return false
	var output := FileAccess.open(dst, FileAccess.WRITE)
	if output == null:
		return false
	output.store_buffer(input.get_buffer(input.get_length()))
	return true

static func _copy_resource_tree(src: String, dst: String) -> bool:
	var source := DirAccess.open(src)
	if source == null:
		return false
	DirAccess.make_dir_recursive_absolute(dst)
	source.list_dir_begin()
	var name := source.get_next()
	while name != "":
		if not name.begins_with("."):
			var from := src.path_join(name)
			var to := dst.path_join(name)
			if source.current_is_dir():
				if not _copy_resource_tree(from, to):
					source.list_dir_end()
					return false
			elif not _copy_resource_file(from, to):
				source.list_dir_end()
				return false
		name = source.get_next()
	source.list_dir_end()
	return true

# Each world caches under its own id, so choosing a second one does not
# discard the first and worlds already created keep the cache they were built
# from.
static func terrain_cache_dir(id: String) -> String:
	return ProjectSettings.globalize_path("user://content").path_join(id)

# Complete means every tile the world's own manifest window names, not a fixed
# 16x16: a five tile world is whole with twenty five files.
static func terrain_dir_valid(src: String, world: Dictionary) -> bool:
	if world.is_empty() or not FileAccess.file_exists(src.path_join("manifest.json")):
		return false
	var i0 := int(world.get("tile_i0", 0))
	var j0 := int(world.get("tile_j0", 0))
	var n := int(world.get("tiles", 0))
	if n <= 0:
		return false
	for ti in range(i0, i0 + n):
		for tj in range(j0, j0 + n):
			if not FileAccess.file_exists(src.path_join("tiles").path_join(
					"t_%d_%d.bin" % [ti, tj])):
				return false
	return true

static func terrain_cached(id: String) -> bool:
	var world := terrain_world(id)
	return terrain_dir_valid(terrain_cache_dir(id), world)

static func _conf_value(value: Variant) -> String:
	return str(value).replace("\r", " ").replace("\n", " ").strip_edges()

# Materialise one cached 1 m-per-node world inside a new Luanti world.
func _install_terrain_world(world_dir: String, id: String, source := "") -> String:
	var world := terrain_world(id)
	if world.is_empty():
		return "Unknown terrain world '%s'." % id
	var src: String = source if source != "" else terrain_cache_dir(id)
	var dst := world_dir.path_join("terrain_diffusion")
	DirAccess.make_dir_recursive_absolute(dst.path_join("tiles"))
	if not _copy_resource_file(src.path_join("manifest.json"), dst.path_join("manifest.json")):
		return "Download the %s world before starting this world." % str(world.get("label", id))
	# Keep the shared release cache immutable; customise only this world's copy.
	if source == "":
		var manifest_path := dst.path_join("manifest.json")
		var manifest_data = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
		if manifest_data is Dictionary:
			manifest_data["spawn_px"] = Array(world.get("spawn_px", [])).duplicate()
			var rewritten := FileAccess.open(manifest_path, FileAccess.WRITE)
			if rewritten == null:
				return "Could not write the Terrain Diffusion world manifest."
			rewritten.store_string(JSON.stringify(manifest_data, "  "))
	var i0 := int(world.get("tile_i0", 0))
	var j0 := int(world.get("tile_j0", 0))
	var n := int(world.get("tiles", 0))
	for ti in range(i0, i0 + n):
		for tj in range(j0, j0 + n):
			var filename := "t_%d_%d.bin" % [ti, tj]
			if not _copy_resource_file(src.path_join("tiles").path_join(filename),
					dst.path_join("tiles").path_join(filename)):
				return "The cached %s world is incomplete (%s is missing)." % [
						str(world.get("label", id)), filename]
	return ""

func _initialise_terrain_diffusion_world(world: String, worldname: String,
		world_gameid: String = "mineclonia") -> String:
	var world_mt := world.path_join("world.mt")
	if not FileAccess.file_exists(world_mt):
		var wf := FileAccess.open(world_mt, FileAccess.WRITE)
		if wf == null:
			return "Could not initialise %s." % world_mt
		wf.store_string("gameid = %s\nworld_name = %s\nbackend = sqlite3\n" % [world_gameid, worldname])
		wf.store_string("player_backend = sqlite3\nauth_backend = sqlite3\nmod_storage_backend = sqlite3\n")
		wf.store_string("creative_mode = false\nenable_damage = true\nserver_announce = false\n")
	var map_meta := world.path_join("map_meta.txt")
	if not FileAccess.file_exists(map_meta):
		var mf := FileAccess.open(map_meta, FileAccess.WRITE)
		if mf == null:
			return "Could not initialise %s." % map_meta
		mf.store_string("seed = 1234\nchunksize = 5\nwater_level = 1\n")
		mf.store_string("mg_flags = caves, nodungeons, light, decorations, biomes, ores\n")
		mf.store_string("mg_name = singlenode\nmcl_singlenode_mapgen = false\n[end_of_params]\n")
	return ""

func _write_world_options(world: String, options: Dictionary) -> String:
	var path := world.path_join("world.mt")
	var values := {
		"gameid": str(options.get("gameid", "")),
		"world_name": str(options.get("world", "")),
		"creative_mode": "true" if bool(options.get("creative", false)) else "false",
		"enable_damage": "true" if bool(options.get("damage", true)) else "false",
		"server_announce": "true" if bool(options.get("announce", false)) else "false",
	}
	var mods: Array = options.get("mods", [])
	for mod in mods:
		values["load_mod_" + str(mod)] = "true"
	values["load_mod_goanna_pbr"] = "true" if bool(options.get("pbr_materials", true)) \
		and pbr_art_available(str(options.get("gameid", ""))) else "false"
	var kept: PackedStringArray = []
	if FileAccess.file_exists(path):
		for line in FileAccess.get_file_as_string(path).split("\n"):
			var key := line.get_slice("=", 0).strip_edges()
			if values.has(key) or key.begins_with("load_mod_"):
				continue
			if line != "":
				kept.append(line)
	for key in values:
		kept.append("%s = %s" % [key, values[key]])
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		return "Could not update %s." % path
	output.store_string("\n".join(kept) + "\n")
	return ""

# Where a game keeps its own Terrain Diffusion, or "" if it has none. Kythen
# ships one at `mods/terrain_diffusion`, diverged from the bundled runtime and
# carrying files the bundle has never heard of.
static func game_terrain_diffusion_path(data_dir: String, gameid: String) -> String:
	if gameid == "":
		return ""
	for base_entry in _game_dirs(data_dir):
		var base := str(base_entry)
		var mods := base.path_join(gameid).path_join("mods")
		var direct := mods.path_join("terrain_diffusion")
		if FileAccess.file_exists(direct.path_join("init.lua")):
			return direct
		# A game may carry it inside a modpack, which is one directory deeper.
		var d := DirAccess.open(mods)
		if d == null:
			continue
		d.list_dir_begin()
		var name := d.get_next()
		while name != "":
			if d.current_is_dir() and not name.begins_with("."):
				var nested := mods.path_join(name).path_join("terrain_diffusion")
				if FileAccess.file_exists(nested.path_join("init.lua")):
					d.list_dir_end()
					return nested
			name = d.get_next()
		d.list_dir_end()
	return ""

static func _remove_tree(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if not name.begins_with("."):
			var entry := path.path_join(name)
			if d.current_is_dir():
				_remove_tree(entry)
			else:
				DirAccess.remove_absolute(entry)
		name = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)

# Luanti adds game mods first and world mods second, and on a name clash the
# later one wins: "Will not load: <gamemod>, Overridden by: <worldmod>". So
# installing the bundled runtime into a game that ships its own silently
# replaced it, and Kythen's copy, which places the game's registered
# decorations, never ran. Defer to the game and take the stale copy with us,
# because a world from an earlier launch already has one sitting in worldmods.
func _install_terrain_diffusion(world: String, data_dir: String, gameid: String) -> String:
	var dst := world.path_join("worldmods").path_join("terrain_diffusion")
	var theirs := game_terrain_diffusion_path(data_dir, gameid)
	if theirs != "":
		if DirAccess.dir_exists_absolute(dst):
			_remove_tree(dst)
			print("[goanna] removed the bundled Terrain Diffusion from worldmods")
		print("[goanna] %s ships its own Terrain Diffusion at %s, using that" % [gameid, theirs])
		return ""
	var src := "res://vendor/terrain_diffusion"
	DirAccess.make_dir_recursive_absolute(dst)
	for filename in TERRAIN_DIFFUSION_FILES:
		if not _copy_resource_file(src.path_join(filename), dst.path_join(filename)):
			return "The bundled Terrain Diffusion runtime is missing %s." % filename
	return ""

# These settings must exist before mods load: singlenode keeps engine mapgen
# out, while disabling Mineclonia's own singlenode generator leaves the world
# to Terrain Diffusion. Preserve every seed and game-authored parameter.
func _prepare_terrain_diffusion_meta(world: String) -> String:
	var path := world.path_join("map_meta.txt")
	if not FileAccess.file_exists(path):
		return "Terrain Diffusion has been baked, but %s is missing. Start Mineclonia once to initialise the world, then bake it." % path
	var lines := FileAccess.get_file_as_string(path).split("\n")
	var kept: PackedStringArray = []
	for line in lines:
		if line.begins_with("mg_name =") or line.begins_with("mcl_singlenode_mapgen =") \
				or line.strip_edges() == "[end_of_params]":
			continue
		if line != "":
			kept.append(line)
	kept.append("mg_name = singlenode")
	kept.append("mcl_singlenode_mapgen = false")
	kept.append("[end_of_params]")
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		return "Could not update %s for Terrain Diffusion." % path
	output.store_string("\n".join(kept) + "\n")
	return ""

# Start a server for `gameid` on `worldname` (created under the data dir if
# new). Picks a free-ish port and writes a log we can watch for readiness.
# Returns "" on success, or an error message.
# The server mod that relays goanna_* settings to the client, copied into the
# world as a worldmod so the grant written above reaches the client. A copy,
# not a link: the flatpak sandbox sees the world directory and not the
# checkout.
func _install_server_mod(world: String) -> String:
	var src := ProjectSettings.globalize_path("res://../goanna_server_mod")
	if not FileAccess.file_exists(src.path_join("init.lua")):
		src = "res://vendor/goanna_server_mod"
	var dst := world.path_join("worldmods").path_join("goanna_server_mod")
	DirAccess.make_dir_recursive_absolute(dst)
	for filename in GOANNA_SERVER_MOD_FILES:
		if not _copy_resource_file(src.path_join(filename), dst.path_join(filename)):
			return "The bundled Goanna server mod is missing %s." % filename
	return ""

func _install_pbr_mod(world: String, game: String) -> String:
	var installed := AssetStore.profile_texture_path(game)
	if installed != "":
		var installed_dst := world.path_join("worldmods").path_join("goanna_pbr")
		if not _copy_resource_tree(installed, installed_dst.path_join("textures")):
			return "The installed PBR asset profile for %s is incomplete." % game
		var init := FileAccess.open(installed_dst.path_join("init.lua"), FileAccess.WRITE)
		var conf := FileAccess.open(installed_dst.path_join("mod.conf"), FileAccess.WRITE)
		if init == null or conf == null:
			return "Could not install the PBR material worldmod for %s." % game
		init.store_string("-- Versioned Goanna material assets; textures only.\n")
		conf.store_string("name = goanna_pbr\ntitle = Goanna PBR materials\n")
		return ""
	if not PBR_GAME_DIRS.has(game):
		return ""
	var pack_dir := str(PBR_GAME_DIRS[game])
	var src := ProjectSettings.globalize_path("res://../pbr_packs").path_join(pack_dir)
	if not DirAccess.dir_exists_absolute(src):
		return "Install a Goanna PBR asset bundle for %s before enabling materials." % game
	var dst := world.path_join("worldmods").path_join("goanna_pbr")
	if not _copy_resource_tree(src, dst):
		return "The bundled PBR material pack for %s is incomplete." % game
	return ""


func start(gameid_: String, worldname: String, player_name: String = "player",
		terrain_world_id: String = "") -> String:
	return start_config({"gameid": gameid_, "world": worldname, "player_name": player_name,
		"terrain_world": terrain_world_id})

func start_config(options: Dictionary) -> String:
	gameid = str(options.get("gameid", ""))
	var worldname := str(options.get("world", ""))
	var player_name := str(options.get("player_name", "player"))
	# Which world, not merely whether. An older goanna.cfg says only true, so
	# that still means the catalogue's default rather than an error.
	var terrain_world_id := str(options.get("terrain_world", ""))
	if terrain_world_id == "" and bool(options.get("terrain_diffusion", false)):
		terrain_world_id = default_terrain_id()
	var terrain_diffusion := terrain_world_id != ""
	var pbr_materials := bool(options.get("pbr_materials", true))
	var env := detect()
	if env.is_empty():
		return "No Luanti install found. Choose, locate or install one from Start Game, or set GOANNA_SERVER_CMD."
	_argv = env["argv"]
	_data_dir = env["data_dir"]
	world_path = _data_dir.path_join("worlds").path_join(worldname)
	DirAccess.make_dir_recursive_absolute(world_path)
	if terrain_diffusion:
		if not terrain_diffusion_ready(_data_dir, worldname):
			if world_has_generated_map(_data_dir, worldname):
				return "Terrain Diffusion cannot be applied to the populated world '%s': its existing map would remain as a second stacked landscape. Create an empty world with a new name instead." % worldname
			var install_world_error := _install_terrain_world(world_path, terrain_world_id)
			if install_world_error != "":
				return install_world_error
		var initialise_error := _initialise_terrain_diffusion_world(world_path, worldname, gameid)
		if initialise_error != "":
			return initialise_error
		var prepare_error := _prepare_terrain_diffusion_meta(world_path)
		if prepare_error != "":
			return prepare_error
		var install_error := _install_terrain_diffusion(world_path, _data_dir, gameid)
		if install_error != "":
			return install_error
	var world_options_error := _write_world_options(world_path, options)
	if world_options_error != "":
		return world_options_error
	log_path = _data_dir.path_join("goanna_singleplayer.log")
	# a fixed local port; if it is busy the log tells us and start() is retried
	port = int(options.get("port", 0))
	if port == 0:
		port = 30800 + (hash(worldname) % 150)
	# How far the server will send blocks at all. Luanti defaults
	# max_block_send_distance to 12 mapblocks, 192 nodes, and that is a hard
	# ceiling on what any client can draw however much it asks for: see
	# docs/far-rendering.md, where it is the reason distant vistas need more
	# than a bigger view range. Raised here because a local single player
	# server has one client and can afford it. Written next to the world so it
	# is visible inside the flatpak sandbox, which cannot see the host's home.
	var conf_path := _data_dir.path_join("goanna_local_server.conf")
	var cf := FileAccess.open(conf_path, FileAccess.WRITE)
	if cf:
		var hosting := bool(options.get("host", false))
		cf.store_string("bind_address = %s\n" % ("0.0.0.0" if hosting else "127.0.0.1"))
		cf.store_string("server_name = %s\n" % _conf_value(options.get("server_name", worldname)))
		cf.store_string("server_description = %s\n" % _conf_value(options.get("server_description", "")))
		cf.store_string("max_users = %d\n" % int(options.get("max_users", 8)))
		cf.store_string("server_announce = %s\n" % ("true" if bool(options.get("announce", false)) else "false"))
		var server_password := _conf_value(options.get("password", ""))
		if server_password != "":
			cf.store_string("default_password = %s\n" % server_password)
		cf.store_string("max_block_send_distance = %d\n" % send_distance)
		# The queue limits throttle how fast those blocks actually arrive; the
		# defaults are tuned for the default distance and starve a larger one.
		cf.store_string("max_simultaneous_block_sends_per_client = 16\n")
		# Three far-generation streams can touch hundreds of thousands of
		# mapblocks. The measured run generated a 471 MB world, and ten minutes
		# of retention kept a large part of that as a silent server working set.
		# One minute still
		# covers ordinary revisits without retaining the whole generated ring.
		cf.store_string("server_unload_unused_data_timeout = 60\n")
		cf.store_string("goanna_far_summary_cache_areas = 1024\n")
		cf.store_string("goanna_far_log_stats = true\n")
		# A single player world on this machine, run by a server this client
		# launched: there is no one to be unfair to, so far rendering is
		# granted here, over the goanna:v1 channel the server mod installed
		# below provides. docs/far-rendering.md, "the server decides".
		# Luanti disables mod channels by default. The grant cannot reach the
		# client unless the transport carrying it is enabled too.
		cf.store_string("enable_mod_channels = true\n")
		cf.store_string("goanna_far_rendering = true\n")
		# Shared dig damage, on for the same reason far rendering is: the
		# player launched this server, so the operator deciding whether to
		# trust a client's account of a block it is digging is the player
		# themselves, and the only other people on it are ones they invited.
		# Off remains the default for a server someone else is running, where
		# that is a real question. goanna_server_mod/damage.lua has the trade.
		cf.store_string("goanna_shared_dig_damage = true\n")
		# The player's own Far draw distance setting is the grant, floored at
		# the old conservative bound. It is their machine paying for the
		# mapgen and the drawing, so how vast the vista gets is their call;
		# a fixed 1024 here was the invisible ceiling that made the far
		# distance slider appear to do nothing past it.
		var grant := clampi(int(options.get("far_distance", far_distance)), far_distance, 8192)
		cf.store_string("goanna_far_rendering_distance = %d\n" % grant)
		# TDL can synthesise its coarse surface directly from the bake
		# without emerging mapblocks, so its horizon is nearly free: at
		# least the old 4096, and further when the player asks for further.
		if terrain_diffusion:
			cf.store_string("goanna_far_provider_distance = %d\n" % maxi(4096, grant))
		# A fresh world has no far terrain to summarise. The server generates
		# only within the range the client asks for (max_block_generate_distance
		# is capped by the client's wanted range in clientiface.cpp), so the
		# grant above puts no horizon on a world nobody has walked. The mod's
		# pregeneration is the server's own answer: it generates outward from
		# each player at its own pace, one 128 node area at a time and a slice
		# of an area per emerge call so the player's own blocks are never
		# queued behind it (docs/far-rendering.md, "Pregeneration yields to
		# the player"), and pushes each area's summary as it lands. It is the
		# operator's choice, and here the operator is the player.
		# A Terrain Diffusion provider answers unexplored columns directly from
		# baked tiles. Full-block pregeneration would duplicate that work and
		# consume the disk space this path exists to avoid.
		cf.store_string("goanna_far_pregenerate = %s\n" % ("false" if terrain_diffusion else "true"))
		if terrain_diffusion:
			# Reconstruct each native 30 m sample onto thirty 1 m nodes. Pin this
			# so a global Luanti preference cannot make the world coarser.
			cf.store_string("tdl_nodes_per_pixel = 30\n")
			# v3 is baked around a deliberate multi-biome showcase spawn, so keep
			# climate aligned with the terrain rather than stretching it.
			cf.store_string("tdl_climate_stretch = 1\n")
		# Three asynchronous area streams keep a flying local player supplied;
		# each stream queues only one 64-node slice at a time, so live terrain
		# still gets frequent opportunities between them.
		cf.store_string("goanna_far_pregenerate_concurrency = 3\n")
		# Privileges. The client's fly toggle works whether or not the server
		# allows it, exactly as the vanilla client's does, and a server that
		# does not allow it answers every flying step with "moved too fast"
		# and resets the player to the ground. On a public server that is
		# correct. On the server this player just launched for themselves it
		# means flying loads nothing, because the live blocks and the far
		# summaries both follow where the server believes the player is. So
		# new players on this server start with the single player set:
		# Luanti gives fly, fast, noclip, teleport, give and settime to no one
		# by default, not even the admin (give_to_admin follows
		# give_to_singleplayer, and those are registered false), which is why
		# name= below is not enough on its own.
		cf.store_string("default_privs = interact, shout, fly, fast, noclip, teleport, give, settime\n")
		# This is a private server launched by this client for its owner. The
		# movement validator still rejects fast flight even with fly/fast
		# privileges (the server log then repeats "moved too fast" while the
		# local camera travels kilometres away). Far requests are validated and
		# pregeneration is centred on that authoritative server position, so the
		# disagreement looks exactly like a hard streaming limit. Keep digging
		# and interaction checks, but let this single player's movement be the
		# streaming centre. A public server must make its own trust decision.
		# Flag settings inherit omitted flags from Luanti's defaults. Merely
		# leaving movement out keeps it enabled and the streaming centre behind.
		cf.store_string("anticheat_flags = digging,interaction,nomovement\n")
		# default_privs applies at first join only, so a player created in an
		# earlier world keeps what they had. Naming the player as the server's
		# admin gives them the privs priv on every world, old or new, so
		# "/grantme all" is available when that happens.
		if player_name != "":
			cf.store_string("name = %s\n" % player_name)
		# A scripted run is not a game. The harness and the agents that drive
		# this client are there to photograph the world, and a night falling
		# partway through a capture, or a mob killing the player between two
		# frames of a comparison, ruins the measurement rather than merely
		# annoying someone: two shots meant to differ by one change end up
		# differing by the hour and by whether anyone was still alive. So a
		# run nobody is watching gets a frozen clock and no damage.
		# GOANNA_LOCAL_TEST is menu.gd's own marker for exactly that, and a
		# player's own world is left as the game intends.
		#
		# time_speed 0 stops the clock where the world starts it; the client's
		# own GOANNA_TOD and the control channel's time command set which hour
		# a shot is taken at, so this only has to stop it moving. Damage off
		# is Luanti's own setting and needs nothing from the game, unlike
		# turning mob spawning off, which every game spells differently: the
		# mobs still walk about here, they just cannot hurt anyone.
		if OS.get_environment("GOANNA_LOCAL_TEST") != "":
			cf.store_string("enable_damage = false\n")
			cf.store_string("time_speed = 0\n")
		cf = null
	var server_mod_error := _install_server_mod(world_path)
	if server_mod_error != "":
		return server_mod_error
	if pbr_materials and pbr_art_available(gameid):
		var pbr_error := _install_pbr_mod(world_path, gameid)
		if pbr_error != "":
			return pbr_error
	var argv := Array(_argv)
	argv.append_array([
		"--world", world_path,
		"--gameid", gameid,
		"--port", str(port),
		"--logfile", log_path,
		"--config", conf_path,
	])
	# fresh log so readiness detection is not fooled by an old run
	var lf := FileAccess.open(log_path, FileAccess.WRITE)
	if lf:
		lf.store_string("")
		lf = null
	var exe: String = argv[0]
	var args := argv.slice(1)
	pid = OS.create_process(exe, PackedStringArray(args))
	if pid <= 0:
		return "Could not launch the server (%s)." % exe
	return ""

# Poll the log for the "listening" line. Returns "starting", "ready" or an
# error string.
func poll_ready() -> String:
	if not FileAccess.file_exists(log_path):
		return "starting"
	var text := FileAccess.get_file_as_string(log_path)
	if text.find("listening on") >= 0 or text.find("Server for gameid") >= 0:
		return "ready"
	if text.find("already in use") >= 0:
		return "Port %d is already in use." % port
	if text.findn("error") >= 0 and text.findn("ERROR[Main]") >= 0:
		# surface the first hard error line
		for line in text.split("\n"):
			if line.find("ERROR[Main]") >= 0:
				return line.strip_edges()
	return "starting"

func stop() -> void:
	# The pid is the flatpak/launcher wrapper; the actual server runs in a
	# sandbox under a different pid, so killing by the unique world path is
	# what reliably stops it (and works for a native server too).
	# Windows has no pkill and no wrapper: the pid is the server itself.
	if world_path != "" and OS.get_name() != "Windows":
		OS.execute("pkill", ["-f", world_path])
	if pid > 0:
		OS.kill(pid)
		pid = -1
