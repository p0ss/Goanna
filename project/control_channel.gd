# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# A loopback command channel, so a running client can be driven and
# questioned without relaunching it. Off unless GOANNA_CONTROL is set, and
# bound to 127.0.0.1 so nothing off this machine can reach it.
#
# Why it exists. Every question asked of the client used to cost a process
# launch: set one of the hundred odd GOANNA_* variables, connect, wait a
# fixed number of seconds, save a PNG, quit. That makes each experiment slow
# and it makes the timing a guess, which is how a photograph of the sky gets
# reported as a render with the feature switched off. tools/shotcheck.py
# opens with four mistakes of exactly that shape. Here the client stays up,
# the waits are on conditions rather than on the clock, and the answer comes
# back as data instead of a picture to squint at.
#
# What it may and may not do. Everything that changes the world goes to the
# server as an ordinary chat command, the same text a vanilla client sends,
# and needs the same privileges. Nothing here reaches past the protocol or
# asks for anything a vanilla client cannot ask for. What it changes locally
# is the view: the camera, the time of day override, and the lighting and
# material settings the settings panel already exposes, all of it applied
# through game_ui so there is one code path rather than two.
#
# The trap it introduces, and the answer to it. Tuning a value in a live
# process and reporting it as working is not the same as the committed code
# doing it, and CLAUDE.md forbids the second claim on the strength of the
# first. So the value of every setting is recorded before the first command
# lands, "deviations" reports what has moved since, and every shot reply and
# sidecar carries that list. A reading is only a result once it has been
# reproduced from a clean launch with nothing deviating.
extends Node

const DEFAULT_PORT := 30800
# Refuse a line longer than this rather than growing a buffer forever on a
# client that never sends a newline.
const MAX_LINE := 1 << 20

# One line each, returned by "help" and doubling as the reference for what
# this channel can do.
const COMMANDS := {
	"help": "list these commands",
	"ping": "liveness, and how long the client has been up",
	"status": "session state, camera pose, block and entity counts",
	"tp": "x,y,z: server side teleport, then wait for blocks to arrive",
	"pose": "x,y,z / pitch / yaw / fly: place the camera, no server move",
	"look": "x,y,z: aim the camera at a point",
	"fly": "on: fly camera (true) or walk with collision (false)",
	"time": "tod 0..1 (below 0 clears), server true also runs /time",
	"weather": "kind clear|rain|snow|thunder, fake true for a local spawner",
	"spawn": "name, x,y,z, count: /spawnentity through the server",
	"give": "item, count: /giveme through the server",
	"chat": "text: send a chat line, returns what the server said back",
	"set": "key, value: any settings panel key, applied live",
	"get": "key: one setting's current value",
	"settings": "every setting, its value and its value at startup",
	"deviations": "settings moved since startup, the cold verify list",
	"shot": "path: settle, capture a PNG, write a JSON sidecar beside it",
	"wait": "settle / frames / ms / expr: wait on a condition, not a clock",
	"reload_shader": "path: recompile a .gdshader from disk in place",
	"call": "method, args: any GoannaClient method",
	"eval": "expr: a GDScript expression evaluated against main",
	"quit": "disconnect and close the client",
}

var main: Node						# the goanna_main node, set before add_child

var _srv := TCPServer.new()
var _conns: Array = []				# [{peer, buf}]
var _queue: Array = []				# [{conn, id, cmd, args}]
var _busy := false
var _baseline := {}					# settings key -> value before the first command
var _tod := -1.0					# our own copy: the client does not read it back
var _reloaded := []					# shaders hot loaded since launch, a deviation
var _port := 0

func _ready() -> void:
	var spec := OS.get_environment("GOANNA_CONTROL")
	_port = int(spec) if spec.is_valid_int() and int(spec) > 1 else DEFAULT_PORT
	var err := _srv.listen(_port, "127.0.0.1")
	if err != OK:
		push_error("control: cannot listen on 127.0.0.1:%d (error %d)" % [_port, err])
		set_process(false)
		return
	print("control: listening on 127.0.0.1:%d" % _port)

func _exit_tree() -> void:
	_srv.stop()

# Accept, read and dispatch. One command runs at a time: several of them wait
# on frames, and two overlapping camera moves would each photograph the
# other's pose.
func _process(_delta: float) -> void:
	while _srv.is_connection_available():
		var peer := _srv.take_connection()
		peer.set_no_delay(true)
		_conns.append({"peer": peer, "buf": ""})
	for c in _conns.duplicate():
		var peer: StreamPeerTCP = c["peer"]
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_conns.erase(c)
			continue
		var avail := peer.get_available_bytes()
		if avail > 0:
			var got: Array = peer.get_data(avail)
			if int(got[0]) == OK:
				c["buf"] = String(c["buf"]) + (got[1] as PackedByteArray).get_string_from_utf8()
		var buf: String = c["buf"]
		var cut := buf.find("\n")
		while cut >= 0:
			_accept(c, buf.substr(0, cut).strip_edges())
			buf = buf.substr(cut + 1)
			cut = buf.find("\n")
		if buf.length() > MAX_LINE:
			_send(c, {"ok": false, "error": "line too long"})
			buf = ""
		c["buf"] = buf
	if not _busy and not _queue.is_empty():
		_busy = true
		_run(_queue.pop_front())

# A request is one JSON object per line: {"id": 1, "cmd": "tp", "args": {...}}.
# A line that does not start with a brace is read as the shorthand
# `cmd key=value key=value`, so the channel is usable from nc while debugging.
func _accept(conn: Dictionary, line: String) -> void:
	if line == "":
		return
	var req: Dictionary = {}
	if line.begins_with("{"):
		var parsed = JSON.parse_string(line)
		if not (parsed is Dictionary):
			_send(conn, {"ok": false, "error": "not a JSON object"})
			return
		req = parsed
	else:
		req = _shorthand(line)
	var cmd := String(req.get("cmd", ""))
	if cmd == "":
		_send(conn, {"ok": false, "error": "no cmd"})
		return
	var args = req.get("args", {})
	_queue.append({"conn": conn, "id": req.get("id", null), "cmd": cmd,
		"args": args if args is Dictionary else {}})

func _shorthand(line: String) -> Dictionary:
	var parts := line.split(" ", false)
	var args := {}
	for i in range(1, parts.size()):
		var kv: String = parts[i]
		var eq := kv.find("=")
		if eq < 0:
			continue
		var key := kv.substr(0, eq)
		var raw := kv.substr(eq + 1)
		var val = JSON.parse_string(raw)
		args[key] = raw if val == null else val
	return {"cmd": parts[0], "args": args}

func _run(req: Dictionary) -> void:
	var result = await _dispatch(String(req["cmd"]), req["args"])
	var msg := {"id": req["id"]}
	if result is Dictionary and (result as Dictionary).has("__error"):
		msg["ok"] = false
		msg["error"] = result["__error"]
	else:
		msg["ok"] = true
		msg["result"] = _plain(result)
	_send(req["conn"], msg)
	_busy = false

func _send(conn: Dictionary, msg: Dictionary) -> void:
	var peer: StreamPeerTCP = conn["peer"]
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data((JSON.stringify(msg) + "\n").to_utf8_buffer())

static func _err(what: String) -> Dictionary:
	return {"__error": what}

func _client() -> Node:
	return main.client

# --- commands ----------------------------------------------------------------

func _dispatch(cmd: String, a: Dictionary) -> Variant:
	if main == null or not is_instance_valid(main):
		return _err("no main node")
	_ensure_baseline()
	match cmd:
		"help":
			return {"commands": COMMANDS, "port": _port}
		"ping":
			return {"pong": true, "uptime": main.t}
		"status":
			var st: Dictionary = _client().status()
			st["camera"] = main.cam.position
			st["pitch"] = main.pitch
			st["yaw"] = main.yaw
			st["fly"] = main.fly_mode
			st["server_position"] = _client().server_player_position()
			st["entities"] = _client().entity_count()
			st["time_of_day"] = _client().sky_state().get("time_of_day", -1.0)
			st["time_of_day_override"] = _tod
			st["precipitation"] = _precipitation()
			return st
		"tp":
			var want = _vec3(a)
			if want == null:
				return _err("tp wants x, y, z (or pos: [x, y, z])")
			if not await main.teleport_to(want):
				return _err("teleport did not take, still at %s; the account may lack the teleport priv" % _client().server_player_position())
			return {"position": main.cam.position,
				"server_position": _client().server_player_position(),
				"blocks_meshed": _client().status().get("blocks_meshed", 0)}
		"pose":
			# Fly mode by default: walking physics runs every frame from the
			# server's idea of where the player is, so a camera placed under
			# it is dragged back before the next capture.
			var p = _vec3(a)
			if p != null:
				main.cam.position = p
			if a.has("pitch"):
				main.pitch = float(a["pitch"])
			if a.has("yaw"):
				main.yaw = float(a["yaw"])
			main.fly_mode = bool(a.get("fly", true))
			main.cam.rotation_degrees = Vector3(main.pitch, main.yaw, 0)
			_client().set_player_pose(main.cam.position, main.pitch, main.yaw)
			return _pose()
		"look":
			var target = _vec3(a)
			if target == null:
				return _err("look wants x, y, z")
			if main.cam.position.distance_to(target) < 0.001:
				return _err("cannot look at the camera's own position")
			main.fly_mode = true
			main.cam.look_at(target, Vector3.UP)
			main.pitch = main.cam.rotation_degrees.x
			main.yaw = main.cam.rotation_degrees.y
			_client().set_player_pose(main.cam.position, main.pitch, main.yaw)
			return _pose()
		"fly":
			main.fly_mode = bool(a.get("on", true))
			return _pose()
		"time":
			if a.has("tod"):
				_tod = float(a["tod"])
				_client().set_time_of_day_override(_tod)
				# The override moves this client's clock only. Moving the
				# world's needs the settime priv and changes it for everyone
				# on the server, so it is opt in.
				if bool(a.get("server", false)) and _tod >= 0.0:
					_client().send_chat("/time %d" % int(round(fposmod(_tod, 1.0) * 24000.0)))
			return {"time_of_day": _client().sky_state().get("time_of_day", -1.0),
				"override": _tod}
		"weather":
			var kind := String(a.get("kind", "clear"))
			if bool(a.get("fake", false)):
				var pn := _particles()
				if pn == null:
					return _err("no particle node")
				if kind == "clear":
					pn.clear_test_spawner()
				else:
					pn.inject_test_spawner(kind)
				return {"fake": true, "kind": kind, "precipitation": _precipitation()}
			# Luanti has no weather in the protocol: a game that rains does it
			# with particle spawners, and the command that starts them is the
			# game's own. Mineclonia spells it /weather; elsewhere use chat.
			_client().send_chat("/weather " + kind)
			return await _after_chat("/weather " + kind, a)
		"spawn":
			var name := String(a.get("name", ""))
			if name == "":
				return _err("spawn wants a name, for example mobs_mc:sheep")
			var at = _vec3(a)
			var sent := []
			for i in maxi(1, int(a.get("count", 1))):
				var text := "/spawnentity " + name
				if at != null:
					# Godot space in, Luanti space out, as teleport does.
					text += " %.1f,%.1f,%.1f" % [at.x, at.y, -at.z]
				_client().send_chat(text)
				sent.append(text)
			return await _after_chat(", ".join(sent), a)
		"give":
			var item := String(a.get("item", ""))
			if item == "":
				return _err("give wants an item, for example mcl_torches:torch")
			var text := "/giveme %s %d" % [item, maxi(1, int(a.get("count", 1)))]
			_client().send_chat(text)
			return await _after_chat(text, a)
		"chat":
			var text := String(a.get("text", ""))
			if text == "":
				return _err("chat wants text")
			_client().send_chat(text)
			return await _after_chat(text, a)
		"set":
			return _set_setting(a)
		"get":
			var key := String(a.get("key", ""))
			if main.ui == null:
				return _err("no UI, settings are applied through it")
			if key == "":
				return _err("get wants a key")
			return {"key": key, "value": main.ui._setting_value(key, 0.0),
				"startup": _baseline.get(key)}
		"settings":
			return _all_settings()
		"deviations":
			return _deviations()
		"shot":
			return await _shot(a)
		"wait":
			return await _wait(a)
		"reload_shader":
			return _reload_shader(String(a.get("path", "")))
		"call":
			var method := String(a.get("method", ""))
			if not _client().has_method(method):
				return _err("GoannaClient has no method '%s'" % method)
			var raw = a.get("args", [])
			return {"result": _client().callv(method, _coerce(raw if raw is Array else [raw]))}
		"eval":
			return _eval(String(a.get("expr", "")))
		"run":
			return await _run_snippet(String(a.get("src", "")))
		"quit":
			_client().disconnect_from_server()
			_quit_soon()
			return {"quitting": true}
	return _err("unknown command '%s'; try help" % cmd)

func _pose() -> Dictionary:
	return {"position": main.cam.position, "pitch": main.pitch, "yaw": main.yaw,
		"fly": main.fly_mode}

# Chat is the only channel a server answers a command on, so a command verb
# that did not report the answer would hide "you don't have permission" and
# read as success. game_ui keeps the last lines with the time they arrived;
# read them there rather than draining take_chat, which would steal them
# from the HUD.
func _after_chat(sent: String, a: Dictionary) -> Dictionary:
	var out := {"sent": sent}
	if main.ui == null:
		return out
	var t0: float = main.ui.t
	var settle := float(a.get("reply_ms", 400.0))
	var until := Time.get_ticks_msec() + int(settle)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
	var said := []
	for line in main.ui.chat_lines:
		if float(line.get("time", 0.0)) > t0:
			said.append(String(line.get("text", "")))
	out["server_said"] = said
	# A server refusing a command answers in chat and nowhere else, so without
	# this a caller has to read English to find out whether anything happened.
	for line in said:
		if line.contains("Invalid command") or line.contains("t have permission") \
				or line.contains("Insufficient privileges"):
			out["refused"] = true
			break
	return out

func _set_setting(a: Dictionary) -> Variant:
	var key := String(a.get("key", ""))
	if key == "":
		return _err("set wants key and value")
	if main.ui == null:
		return _err("no UI, settings are applied through it")
	if not a.has("value"):
		return _err("set wants a value")
	var known := key.begins_with("mat_")
	for entry in main.ui.SETTINGS:
		if String(entry[1]) == key:
			known = true
			break
	if not known:
		return _err("unknown setting '%s'; the settings command lists them" % key)
	var value := float(a["value"])
	main.ui._apply_setting(key, value)
	return {"key": key, "value": main.ui._setting_value(key, value),
		"startup": _baseline.get(key)}

func _all_settings() -> Dictionary:
	var out := {}
	if main.ui == null:
		return out
	for entry in main.ui.SETTINGS:
		var key: String = entry[1]
		if String(entry[2]) == "path":
			continue
		out[key] = {"tab": entry[0], "label": entry[3],
			"value": main.ui._setting_value(key, 0.0), "startup": _baseline.get(key)}
	return out

# The value of everything before the first command landed. Taken lazily, so
# it is the state a launch produces rather than the state _ready leaves
# halfway through it.
func _ensure_baseline() -> void:
	if not _baseline.is_empty() or main.ui == null:
		return
	for entry in main.ui.SETTINGS:
		var key: String = entry[1]
		if String(entry[2]) == "path":
			continue
		_baseline[key] = main.ui._setting_value(key, 0.0)

func _deviations() -> Dictionary:
	var out := {}
	if _tod >= 0.0:
		out["time_of_day_override"] = [-1.0, _tod]
	# A hot loaded shader is the sharpest form of the trap: the frame came
	# from code on disk, which is not necessarily code that is committed.
	if not _reloaded.is_empty():
		out["shaders_reloaded"] = _reloaded.duplicate()
	if main.ui == null:
		return out
	for key in _baseline:
		var now: float = main.ui._setting_value(key, 0.0)
		if absf(now - float(_baseline[key])) > 0.0001:
			out[key] = [_baseline[key], now]
	return out

# Capture, with the two things a capture has to carry to be evidence: proof
# the world had arrived, and the list of settings that were not the ones the
# committed code produces.
func _shot(a: Dictionary) -> Variant:
	var path := String(a.get("path", ""))
	if path == "":
		return _err("shot wants a path")
	if DisplayServer.get_name() == "headless":
		return _err("headless has no viewport texture to save; run with a display")
	if bool(a.get("settle", true)):
		await main.wait_for_streaming()
	var ui_was := true
	if main.ui != null and bool(a.get("hide_ui", true)):
		ui_was = main.ui.visible
		main.ui.visible = false
	for i in maxi(0, int(a.get("warm", 8))):
		_client().poll_blocks(64)
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	if main.ui != null:
		main.ui.visible = ui_was
	if err != OK:
		return _err("could not write %s (error %d)" % [path, err])
	var meta := {"path": path, "size": [img.get_width(), img.get_height()],
		"camera": main.cam.position, "pitch": main.pitch, "yaw": main.yaw,
		"time_of_day": _client().sky_state().get("time_of_day", -1.0),
		"blocks_meshed": _client().status().get("blocks_meshed", 0),
		"deviations": _deviations()}
	var f := FileAccess.open(path.get_basename() + ".json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_plain(meta), "  "))
		f.close()
	return meta

# Waiting on a condition rather than on a frame count or a clock. At several
# hundred frames a second a frame count elapses long before the server has
# sent anything, which is the mistake this whole channel exists to stop.
func _wait(a: Dictionary) -> Variant:
	var t0 := Time.get_ticks_msec()
	if bool(a.get("settle", false)):
		await main.wait_for_streaming()
		return {"waited_ms": Time.get_ticks_msec() - t0,
			"blocks_meshed": _client().status().get("blocks_meshed", 0)}
	if a.has("frames"):
		for i in maxi(0, int(a["frames"])):
			await get_tree().process_frame
		return {"waited_ms": Time.get_ticks_msec() - t0}
	if a.has("ms"):
		var until := t0 + maxi(0, int(a["ms"]))
		while Time.get_ticks_msec() < until:
			await get_tree().process_frame
		return {"waited_ms": Time.get_ticks_msec() - t0}
	if a.has("expr"):
		var ex := Expression.new()
		if ex.parse(String(a["expr"])) != OK:
			return _err("cannot parse: " + ex.get_error_text())
		var timeout := t0 + int(a.get("timeout_ms", 30000))
		while Time.get_ticks_msec() < timeout:
			var v = ex.execute([], main)
			if ex.has_execute_failed():
				return _err("expression failed: " + ex.get_error_text())
			if v:
				return {"waited_ms": Time.get_ticks_msec() - t0, "value": v}
			await get_tree().process_frame
		return _err("timed out after %dms waiting for %s" % [Time.get_ticks_msec() - t0, a["expr"]])
	return _err("wait wants settle, frames, ms or expr")

# Shaders are loaded from res:// at run time, so the running client can take
# an edited one without a relaunch. Assigning code to the cached resource
# updates every material already using it. An include has no resource of its
# own, so editing one reloads every shader already loaded.
func _reload_shader(path: String) -> Variant:
	if path == "":
		return _err("reload_shader wants a res:// path")
	if not FileAccess.file_exists(path):
		return _err("no such file: " + path)
	var targets: Array = []
	if path.ends_with(".gdshaderinc"):
		var d := DirAccess.open(path.get_base_dir())
		if d == null:
			return _err("cannot read " + path.get_base_dir())
		for name in d.get_files():
			var p: String = path.get_base_dir().path_join(name)
			if name.ends_with(".gdshader") and ResourceLoader.has_cached(p):
				targets.append(p)
	else:
		targets.append(path)
	var done := []
	for p in targets:
		var sh = load(p)
		if sh is Shader:
			sh.code = FileAccess.get_file_as_string(p)
			done.append(p)
			if not _reloaded.has(p):
				_reloaded.append(p)
	return {"reloaded": done}

func _eval(src: String) -> Variant:
	if src == "":
		return _err("eval wants an expression")
	var ex := Expression.new()
	if ex.parse(src) != OK:
		return _err("cannot parse (run takes snippets, eval only expressions): " + ex.get_error_text())
	# Evaluated against main, so client, cam, ui and the light_* values are
	# all in scope by their own names.
	var v = ex.execute([], main)
	if ex.has_execute_failed():
		return _err("failed: " + ex.get_error_text())
	return {"value": v}

# Expression handles one expression and no statements, so a snippet with a
# loop, a variable or a wait in it needs compiling. The snippet body becomes
# the body of run(), with main, client, cam and ui already in scope, and it
# may await: a search that has to poll frames is the usual reason to be here.
func _run_snippet(src: String) -> Variant:
	if src == "":
		return _err("run wants src, a GDScript snippet ending in a return")
	var body := ""
	for line in src.split("\n"):
		body += "\t" + line + "\n"
	var sc := GDScript.new()
	sc.source_code = "extends RefCounted\nfunc run(main, client, cam, ui):\n" + body
	if sc.reload() != OK:
		return _err("that snippet did not compile; the parse error is in the client log")
	var v = await sc.new().run(main, main.client, main.cam, main.ui)
	return {"value": v}


func _quit_soon() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit()

func _particles() -> Node:
	return get_tree().get_first_node_in_group("goanna_particles")

func _precipitation() -> float:
	var pn := _particles()
	return pn.precipitation() if pn != null else 0.0

# --- conversions -------------------------------------------------------------

static func _vec3(a: Dictionary) -> Variant:
	if a.get("pos") is Array and (a["pos"] as Array).size() == 3:
		var p: Array = a["pos"]
		return Vector3(float(p[0]), float(p[1]), float(p[2]))
	if a.has("x") and a.has("y") and a.has("z"):
		return Vector3(float(a["x"]), float(a["y"]), float(a["z"]))
	return null

# JSON has no vector, so an argument of three numbers becomes one. Every
# client method that takes a position takes it as the first argument, and
# none takes a three element array, so this cannot be ambiguous.
static func _coerce(args: Array) -> Array:
	var out := []
	for v in args:
		if v is Array and (v as Array).size() == 3 and (v[0] is float or v[0] is int):
			out.append(Vector3(float(v[0]), float(v[1]), float(v[2])))
		else:
			out.append(v)
	return out

static func _plain(v: Variant) -> Variant:
	if v is Dictionary:
		var out := {}
		for k in v:
			out[str(k)] = _plain(v[k])
		return out
	if v is PackedByteArray:
		return {"bytes": (v as PackedByteArray).size()}
	if v is Array or v is PackedStringArray or v is PackedInt32Array \
			or v is PackedFloat32Array or v is PackedVector3Array:
		var out := []
		for e in v:
			out.append(_plain(e))
		return out
	if v is Vector3 or v is Vector3i:
		return [v.x, v.y, v.z]
	if v is Vector2 or v is Vector2i:
		return [v.x, v.y]
	if v is Color:
		return [v.r, v.g, v.b, v.a]
	if v is Object:
		return str(v)
	return v
