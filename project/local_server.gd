# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Launches a Luanti server in the background for singleplayer, and connects
# Goanna to it. Goanna is a client; "start a game" means running an ordinary
# unmodified Luanti server on localhost and joining it over the normal
# protocol, exactly as connecting to any other server. Nothing here modifies
# the server or the game.
#
# It finds the server the way a packager would: a luantiserver/minetestserver
# or luanti/minetest --server on PATH, else the org.luanti.luanti flatpak.
# GOANNA_SERVER_CMD overrides the argv prefix (space separated).
extends RefCounted
class_name GoannaLocalServer

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
const TERRAIN_DIFFUSION_FILES := [
	"init.lua", "tdl_far.lua", "tdl_palette.lua", "tdl_biomes.lua",
	"tdl_terrain.lua", "tdl_mapgen.lua", "settingtypes.txt", "mod.conf", "LICENSE",
]
const GOANNA_SERVER_MOD_FILES := ["init.lua", "mod.conf", "settingtypes.txt", "README.md"]
const DEFAULT_TERRAIN_ID := "tdl-default-1m-v1"
const DEFAULT_TERRAIN_URL := "https://github.com/p0ss/terrain-diffusion-luanti/releases/download/default-1m-v1/tdl-default-1m-v1.zip"
const DEFAULT_TERRAIN_SHA256 := "682f6e603fa26d095e1dc47f4c05195d50d8dfb0af9a6530e1e9bbfad32d4742"
const DEFAULT_TERRAIN_DOWNLOAD_BYTES := 6883437
const DEFAULT_TERRAIN_I0 := 84
const DEFAULT_TERRAIN_J0 := 80
const DEFAULT_TERRAIN_TILES := 4
# New worlds start at an inland valley rather than the release bake's
# monotonous central plateau. Coordinates are model pixels in (i, j) order.
const DEFAULT_TERRAIN_SHOWCASE_SPAWN := [44032, 41984]

# Where Luanti keeps games and worlds, and how to invoke its server.
# Returns {} if no server could be found.
static func detect() -> Dictionary:
	var home := OS.get_environment("HOME")
	var override := OS.get_environment("GOANNA_SERVER_CMD")
	if override != "":
		var parts := override.split(" ", false)
		return {"argv": parts, "data_dir": home.path_join(".minetest")}
	for cmd in ["luantiserver", "minetestserver"]:
		if _which(cmd):
			return {"argv": PackedStringArray([cmd]), "data_dir": home.path_join(".minetest")}
	for cmd in ["luanti", "minetest"]:
		if _which(cmd):
			return {"argv": PackedStringArray([cmd, "--server"]), "data_dir": home.path_join(".minetest")}
	if _which("flatpak") and _flatpak_installed("org.luanti.luanti"):
		return {"argv": PackedStringArray(["flatpak", "run", "--command=luanti", "org.luanti.luanti", "--server"]),
			"data_dir": home.path_join(".var/app/org.luanti.luanti/.minetest")}
	return {}

static func _which(cmd: String) -> bool:
	var out: Array = []
	return OS.execute("which", [cmd], out) == 0

static func _flatpak_installed(app: String) -> bool:
	var out: Array = []
	if OS.execute("flatpak", ["info", app], out) != 0:
		return false
	return true

# Games installed for this Luanti (directories under <data>/games with a
# game.conf), plus any the flatpak bundles that we can see.
static func list_games(data_dir: String) -> Array:
	var games: Array = []
	for base in [data_dir.path_join("games"),
			"/var/lib/flatpak/app/org.luanti.luanti/current/active/files/share/luanti/games"]:
		var d := DirAccess.open(base)
		if d == null:
			continue
		d.list_dir_begin()
		var name := d.get_next()
		while name != "":
			if d.current_is_dir() and not name.begins_with(".") and not games.has(name):
				if FileAccess.file_exists(base.path_join(name).path_join("game.conf")) \
						or FileAccess.file_exists(base.path_join(name).path_join("game.conf".to_lower())):
					games.append(name)
			name = d.get_next()
		d.list_dir_end()
	games.sort()
	return games

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
		"damage": true, "mods": [], "terrain_diffusion": terrain_diffusion_ready(data_dir, worldname)}
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

static func default_terrain_cache_dir() -> String:
	return ProjectSettings.globalize_path("user://content").path_join(DEFAULT_TERRAIN_ID)

static func default_terrain_dir_valid(src: String) -> bool:
	if not FileAccess.file_exists(src.path_join("manifest.json")):
		return false
	for ti in range(DEFAULT_TERRAIN_I0, DEFAULT_TERRAIN_I0 + DEFAULT_TERRAIN_TILES):
		for tj in range(DEFAULT_TERRAIN_J0, DEFAULT_TERRAIN_J0 + DEFAULT_TERRAIN_TILES):
			if not FileAccess.file_exists(src.path_join("tiles").path_join(
					"t_%d_%d.bin" % [ti, tj])):
				return false
	return true

static func default_terrain_cached() -> bool:
	return default_terrain_dir_valid(default_terrain_cache_dir())

static func _conf_value(value: Variant) -> String:
	return str(value).replace("\r", " ").replace("\n", " ").strip_edges()

# Materialise the cached 1 m-per-node template inside a new world.
func _install_default_terrain(world: String, source := "") -> String:
	var src: String = source if source != "" else default_terrain_cache_dir()
	var dst := world.path_join("terrain_diffusion")
	DirAccess.make_dir_recursive_absolute(dst.path_join("tiles"))
	if not _copy_resource_file(src.path_join("manifest.json"), dst.path_join("manifest.json")):
		return "Download the Terrain Diffusion default world before starting this world."
	# Keep the shared release cache immutable; customise only this world's copy.
	if source == "":
		var manifest_path := dst.path_join("manifest.json")
		var manifest_data = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
		if manifest_data is Dictionary:
			manifest_data["spawn_px"] = DEFAULT_TERRAIN_SHOWCASE_SPAWN.duplicate()
			var rewritten := FileAccess.open(manifest_path, FileAccess.WRITE)
			if rewritten == null:
				return "Could not write the Terrain Diffusion world manifest."
			rewritten.store_string(JSON.stringify(manifest_data, "  "))
	for ti in range(DEFAULT_TERRAIN_I0, DEFAULT_TERRAIN_I0 + DEFAULT_TERRAIN_TILES):
		for tj in range(DEFAULT_TERRAIN_J0, DEFAULT_TERRAIN_J0 + DEFAULT_TERRAIN_TILES):
			var filename := "t_%d_%d.bin" % [ti, tj]
			if not _copy_resource_file(src.path_join("tiles").path_join(filename),
					dst.path_join("tiles").path_join(filename)):
				return "The cached Terrain Diffusion default world is incomplete (%s is missing)." % filename
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

func _install_terrain_diffusion(world: String) -> String:
	var src := "res://vendor/terrain_diffusion"
	var dst := world.path_join("worldmods").path_join("terrain_diffusion")
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


func start(gameid_: String, worldname: String, player_name: String = "player",
		terrain_diffusion: bool = false) -> String:
	return start_config({"gameid": gameid_, "world": worldname, "player_name": player_name,
		"terrain_diffusion": terrain_diffusion})

func start_config(options: Dictionary) -> String:
	gameid = str(options.get("gameid", ""))
	var worldname := str(options.get("world", ""))
	var player_name := str(options.get("player_name", "player"))
	var terrain_diffusion := bool(options.get("terrain_diffusion", false))
	var env := detect()
	if env.is_empty():
		return "No Luanti server found. Install Luanti (or the org.luanti.luanti flatpak), or set GOANNA_SERVER_CMD."
	_argv = env["argv"]
	_data_dir = env["data_dir"]
	world_path = _data_dir.path_join("worlds").path_join(worldname)
	DirAccess.make_dir_recursive_absolute(world_path)
	if terrain_diffusion:
		if not terrain_diffusion_ready(_data_dir, worldname):
			if world_has_generated_map(_data_dir, worldname):
				return "Terrain Diffusion cannot be applied to the populated world '%s': its existing map would remain as a second stacked landscape. Create an empty world with a new name instead." % worldname
			var default_error := _install_default_terrain(world_path)
			if default_error != "":
				return default_error
		var initialise_error := _initialise_terrain_diffusion_world(world_path, worldname, gameid)
		if initialise_error != "":
			return initialise_error
		var prepare_error := _prepare_terrain_diffusion_meta(world_path)
		if prepare_error != "":
			return prepare_error
		var install_error := _install_terrain_diffusion(world_path)
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
		cf.store_string("goanna_far_rendering = true\n")
		cf.store_string("goanna_far_rendering_distance = %d\n" % far_distance)
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
			# The 62 km default bake is physically one climate zone and otherwise
			# opens as a monotonous biome. Stretch only the climate lookup so the
			# showcase spawn crosses forest, wetland and upland climates without
			# distorting the baked elevation or hydrology.
			cf.store_string("tdl_climate_stretch = 4\n")
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
		cf.store_string("anticheat_flags = digging,interaction\n")
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
	if world_path != "":
		OS.execute("pkill", ["-f", world_path])
	if pid > 0:
		OS.kill(pid)
		pid = -1
