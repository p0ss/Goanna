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

# Where Luanti keeps its worlds, for callers that need to inspect them.
static func data_dir_or_empty() -> String:
	var env := detect()
	return env["data_dir"] if not env.is_empty() else ""

# Start a server for `gameid` on `worldname` (created under the data dir if
# new). Picks a free-ish port and writes a log we can watch for readiness.
# Returns "" on success, or an error message.
# The server mod that relays goanna_* settings to the client, copied into the
# world as a worldmod so the grant written above reaches the client. A copy,
# not a link: the flatpak sandbox sees the world directory and not the
# checkout.
func _install_server_mod(world: String) -> void:
	var src := ProjectSettings.globalize_path("res://../goanna_server_mod")
	if not FileAccess.file_exists(src.path_join("init.lua")):
		# True of every exported build today: the mod lives beside project/
		# in the checkout and is not packed. Say so, or the grant written
		# above is silently never relayed and far rendering just does not
		# happen.
		push_warning("goanna_server_mod not found at %s; far rendering will not be granted in this world" % src)
		return
	var dst := world.path_join("worldmods").path_join("goanna_server_mod")
	DirAccess.make_dir_recursive_absolute(dst)
	for f in ["init.lua", "mod.conf"]:
		if FileAccess.file_exists(src.path_join(f)):
			DirAccess.copy_absolute(src.path_join(f), dst.path_join(f))


func start(gameid_: String, worldname: String, player_name: String = "player") -> String:
	gameid = gameid_
	var env := detect()
	if env.is_empty():
		return "No Luanti server found. Install Luanti (or the org.luanti.luanti flatpak), or set GOANNA_SERVER_CMD."
	_argv = env["argv"]
	_data_dir = env["data_dir"]
	world_path = _data_dir.path_join("worlds").path_join(worldname)
	DirAccess.make_dir_recursive_absolute(world_path)
	log_path = _data_dir.path_join("goanna_singleplayer.log")
	# a fixed local port; if it is busy the log tells us and start() is retried
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
		cf.store_string("goanna_far_pregenerate = true\n")
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
	_install_server_mod(world_path)
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
