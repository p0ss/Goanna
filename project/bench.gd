# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# The benchmark recorder: per frame frame times, a once a second counter
# sample, the load stamps, and the scripted route that carries the camera
# through the world at a fixed speed.
#
# Why per frame. The one second GOANNA_PERF line and tools/far-baseline.py
# both read Engine.get_frames_per_second(), which is a smoothed average. A
# 1% low, a frame time distribution and a hitch count cannot be recovered
# from it. This node records every frame into arrays sized once when the run
# starts, so recording costs an index write and allocates nothing, and
# writes them out as a CSV when the run stops.
#
# Nothing here calls client.render_stats() per frame. That call walks
# retained terrain and reports its own cost as stats_ms, which is why the
# HUD samples it four times a second rather than every frame. It is sampled
# here on its own once a second clock and correlated with the frames by
# elapsed time.
#
# Driven from the control channel (project/control_channel.gd, the "bench"
# and "route" commands) and by tools/goanna-bench.py, which turns a plan of
# setting variants into runs and a report. See docs/benchmark.md.
extends Node

# Recorded against each frame so a phase can be summarised on its own. The
# order is the byte written to the CSV; do not renumber without changing
# tools/goanna-bench.py, which reads the names back.
const PHASES := ["idle", "load", "steady", "move_early", "move_full"]

# Frames to make room for. At 60fps this is well over an hour; at 600fps,
# which an empty scene on a fast card will reach, it is a little under ten
# minutes. Overridable per run because the ten minute soak in docs/baseline.md
# needs more than the default.
const DEFAULT_CAPACITY := 400000

# Settled means the scene has stopped changing, which is not the same as
# every counter reading zero.
#
# These are the queues that still produce visible change, so they have to be
# empty: while any of them has work in it, geometry is still arriving or
# being rebuilt and a sample would be of the rebuild.
const ZERO_KEYS := ["mesh_queued", "mesh_running", "mesh_ready",
	"lod_regions_dirty", "lod_chain_queue", "lod_building"]

# Queues going quiet is necessary but not sufficient. The scheduler can run
# out of work while the picture is still resolving: bounced light is still
# converging, the far tiers are still being replaced by nearer ones, the
# volumetric fog and the raymarched cloud are still accumulating. A settle
# test that only reads counters calls that finished, and the sample is then
# of a scene that still looks wrong. So the caller can also require the
# frame itself to stop changing; tools/goanna-bench.py drives that through
# repeated captures, since only it can compare two images.
#
# blocks_queued only has to hold still. At the benchmark vista it parks at
# 227 and never drains: the client is asking for blocks this server will not
# send (its max_block_send_distance caps what a request can reach), and the
# ask is repeated rather than retired. Nothing about the scene is changing,
# so requiring zero here waits for ever. tools/far-baseline.py requires zero
# for this key and would hang in the same place.
const STABLE_KEYS := ["blocks_queued"]

var main: Node						# the goanna_main node, set before add_child

# --- the per frame record ----------------------------------------------------
var recording := false
var label := ""
var phase := "idle"
var _phase_byte := 0
var _cap := 0
var _n := 0
var _t := PackedFloat64Array()		# seconds since the run started
var _frame_ms := PackedFloat32Array()
var _cpu_ms := PackedFloat32Array()	# frame setup plus viewport draw
var _gpu_ms := PackedFloat32Array()
var _dist := PackedFloat32Array()	# metres travelled along the route so far
var _phases := PackedByteArray()
var _run_start_us := 0
var _last_us := 0
var overflowed := false

# --- the once a second counter sample ----------------------------------------
var _samples: Array = []
var _sample_at := 0.0

# --- load stamps -------------------------------------------------------------
# Seconds since the engine started, which for a benchmark launch is close
# enough to process start: this node is built in main.gd's _ready.
var stamps := {}
var _settle_since := -1.0
var _stable := {}					# last value of each STABLE_KEYS counter
var settle_quiet := 30.0

# --- the scripted route ------------------------------------------------------
var route_mode := ""				# "" none, "fly" or "walk"
var route_speed := 4.317			# Luanti's walking speed, nodes a second
var route_pitch := 0.0
var route_yaw := 0.0
var route_travelled := 0.0			# monotonic, survives a loop wrap
var route_laps := 0
var _points: Array[Vector3] = []
var _legs := PackedFloat64Array()	# cumulative length at each point
var _cursor := 0.0					# metres along the path
var _loop := false
var _aim := ""						# "" aims along travel, else a fixed pair
var _aim_pitch := 0.0
var _aim_yaw := 0.0

# --- the camera a run is entitled to -----------------------------------------
# A benchmark client is an ordinary window on somebody's desktop. It can be
# clicked into, alt tabbed away from and typed at, and main.gd reads the
# keyboard every frame, so a stray W or an Escape (which toggles mouse
# capture, and with it mouse look) moves the camera in the middle of a
# sample. The run is then of a different view than the one before it and
# nothing says so.
#
# So while a run is recording the client stops reading real input, and the
# pose it was given is checked every frame anyway: locking the input out is
# the fix, and the check is what proves the lock held.
var disturbed_m := 0.0
var disturbed_deg := 0.0
var _hold := false
var _hold_pos := Vector3.ZERO
var _hold_pitch := 0.0
var _hold_yaw := 0.0

func _ready() -> void:
	# Uncapped and unsynced, for the same reason main.gd does this under
	# GOANNA_PERF: with vsync on every measurement reads as the refresh rate
	# and says nothing about headroom.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	RenderingServer.viewport_set_measure_render_time(
		get_viewport().get_viewport_rid(), true)
	stamps = {"boot_s": Time.get_ticks_msec() / 1000.0}

func _client() -> Node:
	return main.client if main != null else null

# --- per frame ---------------------------------------------------------------

func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	if recording and _n < _cap:
		# The frame period, measured between consecutive visits to this
		# function rather than taken from the delta argument, so it carries
		# everything the engine did in between.
		var frame_ms := float(now - _last_us) / 1000.0
		var vp := get_viewport().get_viewport_rid()
		_t[_n] = float(now - _run_start_us) / 1000000.0
		_frame_ms[_n] = frame_ms
		_cpu_ms[_n] = RenderingServer.get_frame_setup_time_cpu() \
			+ RenderingServer.viewport_get_measured_render_time_cpu(vp)
		_gpu_ms[_n] = RenderingServer.viewport_get_measured_render_time_gpu(vp)
		_dist[_n] = route_travelled
		_phases[_n] = _phase_byte
		_n += 1
		_check_hold()
	elif recording:
		overflowed = true
	_last_us = now
	_watch_load()
	_sample_counters()

# True while the client should ignore its keyboard and mouse. main.gd asks
# this before reading either.
func owns_input() -> bool:
	return recording or route_active()

# Remember the pose a stationary run starts from, so any later change to it
# is measurable. A route commands its own pose, so there is nothing to hold.
func _hold_pose() -> void:
	_hold = not route_active() and main != null
	if _hold:
		_hold_pos = main.cam.position
		_hold_pitch = main.pitch
		_hold_yaw = main.yaw

func _check_hold() -> void:
	if not _hold or route_active():
		return
	disturbed_m = maxf(disturbed_m, main.cam.position.distance_to(_hold_pos))
	disturbed_deg = maxf(disturbed_deg, maxf(absf(main.pitch - _hold_pitch),
		absf(main.yaw - _hold_yaw)))

# The three load stamps, taken once each. Definitions, because a benchmark
# that cannot say what it timed is not a measurement:
#
#   connect_s   the session reports "ready": connected, media in, player placed
#   playable_s  the ground under and around the player exists and the camera
#               is inside loaded map. ground_height answers only once twenty
#               of its eighty one columns have found a real surface within a
#               24 node footprint, so this is a floor you could stand and
#               walk on, not the first block to arrive
#   settled_s   every work queue has been empty for settle_quiet seconds
#
# far_reach is recorded beside each, because reaching a playable state with
# an empty horizon is not the same product as reaching it with a horizon.
func _watch_load() -> void:
	var client := _client()
	if client == null or stamps.has("settled_s"):
		return
	var now := Time.get_ticks_msec() / 1000.0
	var st: Dictionary = client.status()
	if not stamps.has("connect_s"):
		if str(st.get("state", "")) != "ready":
			return
		_stamp("connect_s", now)
		return
	if not stamps.has("playable_s"):
		var eye: Vector3 = main.cam.position
		if client.ground_height(eye) < -1.0e8:
			return
		var here := str(client.node_name_at(eye))
		if here == "" or here == "ignore":
			return
		_stamp("playable_s", now)
		return
	# Settled. Sampled on the counter clock rather than per frame, since
	# render_stats is the expensive call this file exists to keep out of the
	# frame loop; _sample_counters leaves the answer here.
	if _settle_since >= 0.0 and now - _settle_since >= settle_quiet:
		_stamp("settled_s", now - settle_quiet)

func _stamp(key: String, at: float) -> void:
	var client := _client()
	stamps[key] = at
	var st: Dictionary = client.render_stats() if client != null else {}
	stamps[key.replace("_s", "_far_reach")] = int(st.get("far_reach", 0))
	stamps[key.replace("_s", "_blocks")] = int(st.get("block_meshes", 0))
	print("bench: %s at %.2fs (far reach %d, %d block meshes)" % [
		key.replace("_s", ""), at, stamps[key.replace("_s", "_far_reach")],
		stamps[key.replace("_s", "_blocks")]])

# One render_stats sample a second, kept whole. This is the expensive call,
# so it is on its own clock and never inside the frame record above.
func _sample_counters() -> void:
	var client := _client()
	if client == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now < _sample_at:
		return
	_sample_at = now + 1.0
	var st: Dictionary = client.render_stats()
	var quiet := true
	for k in ZERO_KEYS:
		if int(st.get(k, 0)) != 0:
			quiet = false
			break
	if quiet:
		for k in STABLE_KEYS:
			var was: int = int(_stable.get(k, -1))
			var now_v := int(st.get(k, 0))
			_stable[k] = now_v
			if was != now_v:
				quiet = false
	if quiet:
		if _settle_since < 0.0:
			_settle_since = now
	else:
		_settle_since = -1.0
	if not recording:
		return
	_samples.append({
		"elapsed_s": float(Time.get_ticks_usec() - _run_start_us) / 1000000.0,
		"engine_s": now,
		"phase": phase, "settled": quiet,
		"position": [main.cam.position.x, main.cam.position.y, main.cam.position.z],
		"pitch": main.pitch, "yaw": main.yaw,
		"distance_m": route_travelled,
		# Whether there is ground under the camera at all. A speed sweep ends
		# where this stops answering: the player has outrun the terrain and is
		# flying over holes, which no frame time on its own would show.
		"ground": client.ground_height(main.cam.position) > -1.0e8,
		"render": st,
	})

# --- the run -----------------------------------------------------------------

func start(a: Dictionary) -> Dictionary:
	_cap = maxi(1000, int(a.get("capacity", DEFAULT_CAPACITY)))
	_t.resize(_cap)
	_frame_ms.resize(_cap)
	_cpu_ms.resize(_cap)
	_gpu_ms.resize(_cap)
	_dist.resize(_cap)
	_phases.resize(_cap)
	_n = 0
	_samples = []
	overflowed = false
	label = str(a.get("label", ""))
	route_travelled = 0.0
	route_laps = 0
	disturbed_m = 0.0
	disturbed_deg = 0.0
	mark({"phase": str(a.get("phase", "steady"))})
	_hold_pose()
	_run_start_us = Time.get_ticks_usec()
	_last_us = _run_start_us
	_sample_at = 0.0
	recording = true
	return {"recording": true, "capacity": _cap, "label": label, "phase": phase}

func mark(a: Dictionary) -> Dictionary:
	var want := str(a.get("phase", "steady"))
	var at := PHASES.find(want)
	if at < 0:
		return {"__error": "unknown phase '%s', want one of %s" % [want, PHASES]}
	phase = want
	_phase_byte = at
	_hold_pose()
	return {"phase": phase, "frames": _n}

func stop(a: Dictionary) -> Dictionary:
	if not recording:
		return {"__error": "no run is recording"}
	recording = false
	var out := summary({})
	var dir := str(a.get("dir", ""))
	if dir != "":
		var err := _write(dir)
		if err != "":
			return {"__error": err}
		out["dir"] = dir
	return out

# Everything the run measured, per phase, in the terms the report uses. A
# driver is free to recompute these from frames.csv; they are here so a run
# without a Python driver attached still answers the question.
func summary(_a: Dictionary) -> Dictionary:
	var out := {"label": label, "frames": _n, "overflowed": overflowed,
		"stamps": stamps, "disturbed_m": disturbed_m,
		"disturbed_deg": disturbed_deg, "phases": {}}
	for name in PHASES:
		var at := PHASES.find(name)
		var frames := PackedFloat32Array()
		var cpu := PackedFloat32Array()
		var gpu := PackedFloat32Array()
		var first := -1.0
		var last := 0.0
		var from_m := 0.0
		var to_m := 0.0
		for i in _n:
			if _phases[i] != at:
				continue
			# The first frame of a phase spans the switch into it, so its
			# period belongs partly to the phase before. Left out rather
			# than blamed on either.
			if first < 0.0:
				first = _t[i]
				from_m = _dist[i]
				continue
			frames.append(_frame_ms[i])
			cpu.append(_cpu_ms[i])
			gpu.append(_gpu_ms[i])
			last = _t[i]
			to_m = _dist[i]
		if frames.size() < 2:
			continue
		out["phases"][name] = _stats(frames, cpu, gpu, last - first, to_m - from_m)
	return out

func _stats(frames: PackedFloat32Array, cpu: PackedFloat32Array,
		gpu: PackedFloat32Array, seconds: float, metres: float) -> Dictionary:
	var sorted := frames.duplicate()
	sorted.sort()
	var median := _at(sorted, 0.5)
	# A hitch has to be both a large multiple of the run's own median and
	# long enough to see. Without the absolute floor a 400fps run counts
	# every 6ms frame as a stutter; without the ratio a 30fps run counts
	# nothing at all.
	var hitch_over := maxf(median * 2.0, median + 8.0)
	var hitches := 0
	for v in frames:
		if v > hitch_over:
			hitches += 1
	# What the frame was waiting on. A frame is called GPU or CPU bound only
	# when that stage fills most of it; otherwise the cost is somewhere on
	# the main thread that neither renderer timer covers, which is where
	# meshing, LOD and block upload land.
	var by := {"gpu": 0, "cpu-render": 0, "main-thread": 0}
	for i in frames.size():
		var f: float = maxf(frames[i], 0.001)
		if gpu[i] >= f * 0.6 and gpu[i] >= cpu[i]:
			by["gpu"] += 1
		elif cpu[i] >= f * 0.6:
			by["cpu-render"] += 1
		else:
			by["main-thread"] += 1
	var bound := "main-thread"
	for k in by:
		if by[k] > by[bound]:
			bound = k
	var cpu_sorted := cpu.duplicate()
	cpu_sorted.sort()
	var gpu_sorted := gpu.duplicate()
	gpu_sorted.sort()
	# The 1% low as the term is ordinarily meant: the mean of the slowest one
	# frame in a hundred, not the 99th percentile. On a scene with a
	# recurring spike (Goanna prunes blocks every two seconds, which costs
	# about 8ms on the frame it lands on) the percentile sits right at the
	# edge of the spike population and moves by half its value depending on
	# how many spikes a sample happened to catch. The mean of the tail does
	# not, and it is what a player feels.
	var low1 := _worst_mean(sorted, 0.01)
	return {
		"frames": frames.size(),
		"seconds": seconds,
		"fps_mean": frames.size() / maxf(seconds, 0.001),
		"median_ms": median,
		"low1_ms": low1,
		"low01_ms": _worst_mean(sorted, 0.001),
		"p99_ms": _at(sorted, 0.99),
		"p999_ms": _at(sorted, 0.999),
		"max_ms": sorted[sorted.size() - 1],
		"stability": low1 / maxf(median, 0.001),
		"hitches": hitches,
		"hitches_per_min": hitches * 60.0 / maxf(seconds, 0.001),
		"cpu_ms_median": _at(cpu_sorted, 0.5),
		"gpu_ms_median": _at(gpu_sorted, 0.5),
		"bound": bound,
		"bound_share": float(by[bound]) / maxf(float(frames.size()), 1.0),
		"distance_m": metres,
	}

# The mean of the slowest `fraction` of frames, at least one of them.
func _worst_mean(sorted: PackedFloat32Array, fraction: float) -> float:
	if sorted.is_empty():
		return 0.0
	var n := maxi(1, int(sorted.size() * fraction))
	var sum := 0.0
	for i in range(sorted.size() - n, sorted.size()):
		sum += sorted[i]
	return sum / float(n)

func _at(sorted: PackedFloat32Array, fraction: float) -> float:
	if sorted.is_empty():
		return 0.0
	var i := int(round(fraction * (sorted.size() - 1)))
	return sorted[clampi(i, 0, sorted.size() - 1)]

# frames.csv is the million cells nobody reads; samples.jsonl is the once a
# second counter record in the shape tools/far-baseline.py already writes;
# summary.json is what the report is built from.
func _write(dir: String) -> String:
	if DirAccess.make_dir_recursive_absolute(dir) != OK \
			and not DirAccess.dir_exists_absolute(dir):
		return "cannot create " + dir
	var f := FileAccess.open(dir.path_join("frames.csv"), FileAccess.WRITE)
	if f == null:
		return "cannot write frames.csv in " + dir
	f.store_line("t_s,frame_ms,cpu_ms,gpu_ms,dist_m,phase")
	var chunk := PackedStringArray()
	for i in _n:
		chunk.append("%.6f,%.4f,%.4f,%.4f,%.2f,%s" % [_t[i], _frame_ms[i],
			_cpu_ms[i], _gpu_ms[i], _dist[i], PHASES[_phases[i]]])
		if chunk.size() >= 8192:
			f.store_string("\n".join(chunk) + "\n")
			chunk.clear()
	if not chunk.is_empty():
		f.store_string("\n".join(chunk) + "\n")
	f.close()
	var s := FileAccess.open(dir.path_join("samples.jsonl"), FileAccess.WRITE)
	if s != null:
		for sample in _samples:
			s.store_line(JSON.stringify(sample))
		s.close()
	var j := FileAccess.open(dir.path_join("summary.json"), FileAccess.WRITE)
	if j != null:
		j.store_string(JSON.stringify(summary({}), "  "))
		j.close()
	return ""

# --- the route ---------------------------------------------------------------

# points are absolute world positions. speed is nodes a second: Luanti walks
# at about 4.3 and sprints at about 5.6, and the fly path takes whatever it
# is given so a streaming ceiling can be searched for.
func route_start(a: Dictionary) -> Dictionary:
	var raw: Array = a.get("points", [])
	if raw.size() < 2:
		return {"__error": "route wants at least two points"}
	_points = []
	for p in raw:
		if p is Array and p.size() >= 3:
			_points.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
		elif p is Vector3:
			_points.append(p)
		else:
			return {"__error": "a route point wants [x, y, z]"}
	if bool(a.get("relative", false)):
		var origin: Vector3 = main.cam.position
		for i in _points.size():
			_points[i] = origin + _points[i]
	_legs.resize(_points.size())
	_legs[0] = 0.0
	for i in range(1, _points.size()):
		_legs[i] = _legs[i - 1] + _points[i].distance_to(_points[i - 1])
	_loop = bool(a.get("loop", true))
	route_speed = maxf(0.01, float(a.get("speed", 4.317)))
	route_mode = str(a.get("mode", "fly"))
	if route_mode != "fly" and route_mode != "walk":
		return {"__error": "route mode wants fly or walk"}
	_aim = str(a.get("aim", ""))
	if _aim == "fixed":
		_aim_pitch = float(a.get("pitch", main.pitch))
		_aim_yaw = float(a.get("yaw", main.yaw))
	_cursor = 0.0
	route_travelled = 0.0
	route_laps = 0
	main.fly_mode = route_mode == "fly"
	_hold = false
	# Start on the path rather than wherever the camera happened to be, so
	# two runs of the same route see the same ground in the same order.
	if route_mode == "fly":
		main.cam.position = _points[0]
	return {"mode": route_mode, "speed": route_speed,
		"length_m": _legs[_legs.size() - 1], "points": _points.size(),
		"loop": _loop}

func route_stop() -> Dictionary:
	var was := route_mode
	route_mode = ""
	_hold_pose()
	return {"stopped": was, "travelled_m": route_travelled, "laps": route_laps}

func route_active() -> bool:
	return route_mode != "" and _points.size() >= 2

# Where the camera should be after delta seconds of travel. main.gd's fly
# branch assigns this in place of reading the keyboard.
func route_step(delta: float) -> Dictionary:
	var total: float = _legs[_legs.size() - 1]
	var step := route_speed * delta
	_cursor += step
	route_travelled += step
	while _cursor > total:
		if not _loop:
			_cursor = total
			route_mode = ""
			break
		_cursor -= total
		route_laps += 1
	var pos := _on_path(_cursor)
	if _aim == "fixed":
		route_pitch = _aim_pitch
		route_yaw = _aim_yaw
	else:
		# Aim a little way ahead rather than at the next point, or the view
		# snaps at every corner and the frame time record picks up the
		# resulting draw call step as if it were the setting under test.
		var ahead := _on_path(fposmod(_cursor + maxf(2.0, step * 4.0), total))
		var d := ahead - pos
		if d.length() > 0.001:
			d = d.normalized()
			route_yaw = rad_to_deg(atan2(-d.x, -d.z))
			route_pitch = rad_to_deg(asin(clampf(d.y, -1.0, 1.0)))
	return {"position": pos, "pitch": route_pitch, "yaw": route_yaw}

# Synthetic movement keys for the walking path, which goes through the real
# player physics in client.step_player rather than moving the camera.
func walk_keys() -> Dictionary:
	var total: float = _legs[_legs.size() - 1]
	var here: Vector3 = main.cam.position
	# Follow the path by aiming at a point ahead of the nearest one, and
	# hold W. Distance travelled is then whatever the physics grants, which
	# is the point of walking rather than flying.
	_cursor = _nearest(here)
	route_travelled = _cursor + route_laps * total
	var ahead := _on_path(fposmod(_cursor + 3.0, total))
	var d := ahead - here
	d.y = 0.0
	if d.length() > 0.001:
		d = d.normalized()
		main.yaw = rad_to_deg(atan2(-d.x, -d.z))
	return {"up": true, "down": false, "left": false, "right": false,
		"jump": false, "sneak": false, "aux1": false}

func _on_path(at: float) -> Vector3:
	var total: float = _legs[_legs.size() - 1]
	var want := clampf(at, 0.0, total)
	for i in range(1, _legs.size()):
		if want <= _legs[i]:
			var leg: float = _legs[i] - _legs[i - 1]
			var f: float = 0.0 if leg <= 0.0 else (want - _legs[i - 1]) / leg
			return _points[i - 1].lerp(_points[i], f)
	return _points[_points.size() - 1]

func _nearest(to: Vector3) -> float:
	var best := 0.0
	var bestd := 1.0e30
	for i in range(1, _points.size()):
		var a: Vector3 = _points[i - 1]
		var b: Vector3 = _points[i]
		var leg := a.distance_to(b)
		if leg <= 0.0:
			continue
		var f := clampf((to - a).dot(b - a) / (leg * leg), 0.0, 1.0)
		var d := to.distance_to(a.lerp(b, f))
		if d < bestd:
			bestd = d
			best = _legs[i - 1] + f * leg
	return best
