#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Run a plan of graphics settings against a world and report which ones cost.

A plan names a scene (server, anchor, time of day, weather, actors, route)
and a list of variants, each a set of settings moved from the control
condition. This launches the client once or twice per variant, runs the
tests the plan asks for, and writes a report.

    tools/goanna-bench.py plans/lighting.json /tmp/bench-lighting

Four tests, in the order they are measured:

  load        from process start: time to connected, to playable, to settled,
              with the far horizon reached at each
  steady      settled, camera fixed at the anchor: the cost of drawing a
              frame with nothing arriving
  move_early  from the moment the world is playable, the route walked at
              player speed: can you set off immediately and keep a frame rate
  move_full   from settled, the route flown at rising speed until either the
              frame rate or the terrain streaming gives out

load and move_early each need their own process, because both measure a
world that has not been seen before. steady and move_full share the settled
one. Every plan runs its first variant again at the end: the difference
between those two runs is the noise floor, and it is printed above the table
so a smaller difference is not read as a result.

Needs a display (the client renders for real), a running server, and a built
project/bin. GODOT_BIN overrides the Godot binary.
"""

import argparse
import copy
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_PORT = 30800

# Settings a running client cannot take. Everything else is applied over the
# channel, which is the better way round: the world has already streamed
# identically, so the only difference between the two samples is the setting.
# project/main.gd makes the same argument for GOANNA_AB.
RELAUNCH_KEYS = {"texture_pack"}



class BenchError(RuntimeError):
    pass


# --- the control channel -----------------------------------------------------


class Control:
    """One line of JSON per request, the same shape tools/far-baseline.py and
    tools/goanna-mcp speak."""

    def __init__(self, host, port, timeout=600.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.sock = None
        self.next_id = 0

    def up(self):
        try:
            with socket.create_connection((self.host, self.port), timeout=1.0):
                return True
        except OSError:
            return False

    def open(self):
        self.close()
        self.sock = socket.create_connection((self.host, self.port), timeout=10.0)
        self.sock.settimeout(self.timeout)

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None

    def send(self, command, args=None):
        if self.sock is None:
            self.open()
        self.next_id += 1
        request = {"id": self.next_id, "cmd": command, "args": args or {}}
        self.sock.sendall((json.dumps(request) + "\n").encode())
        data = b""
        while b"\n" not in data:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise BenchError("the control channel closed during %s" % command)
            data += chunk
        reply = json.loads(data.split(b"\n", 1)[0])
        if not reply.get("ok"):
            raise BenchError("%s failed: %s" % (command, reply.get("error")))
        return reply.get("result")


# --- the client under test ---------------------------------------------------


def build_fingerprint():
    """What binary and what tree this run is measuring.

    This repository is worked on by more than one agent at a time. During
    the first sweeps another session was editing the lighting, which meant
    project/bin was rebuilt underneath a running plan and a second client
    was competing for the same GPU. Neither shows up in a frame time except
    as drift, and drift is exactly what a benchmark is supposed to be able
    to rule out. So the binary is hashed at the start of every variant, and
    a plan whose binary changes under it says so and stops rather than
    reporting the two halves as one experiment.
    """
    import hashlib
    out = {"libs": {}}
    for lib in sorted((REPO / "project" / "bin").glob("*.so")):
        h = hashlib.sha256()
        with open(lib, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        out["libs"][lib.name] = h.hexdigest()[:16]
    try:
        out["head"] = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                                     cwd=REPO, capture_output=True, text=True,
                                     timeout=20).stdout.strip()
        dirty = subprocess.run(["git", "status", "--porcelain"], cwd=REPO,
                               capture_output=True, text=True, timeout=20).stdout
        out["dirty"] = sorted(l[3:] for l in dirty.strip().split("\n") if l.strip())
    except (OSError, subprocess.SubprocessError):
        pass
    return out


def godot_binary():
    for cand in (os.environ.get("GODOT_BIN"), "godot", "godot4",
                 str(REPO.parent / "Godot_v4.5.1-stable_linux.x86_64")):
        if not cand:
            continue
        found = shutil.which(cand) or (cand if os.access(cand, os.X_OK) else None)
        if found:
            return found
    raise BenchError("no Godot binary found; set GODOT_BIN")


def write_profile(root, settings):
    """A scratch XDG_DATA_HOME holding one goanna.cfg.

    Settings have to be in place before the client starts, or a load
    measurement is of the defaults with the variant applied part way
    through. Godot puts user:// under XDG_DATA_HOME, so a fresh directory
    per run is a fresh profile: no stored settings, no terrain store, and
    nothing of the player's own touched.
    """
    cfg_dir = root / "godot" / "app_userdata" / "Goanna"
    cfg_dir.mkdir(parents=True, exist_ok=True)
    lines = ["[settings]", ""]
    for key, value in sorted(settings.items()):
        if isinstance(value, str):
            lines.append('%s="%s"' % (key, value))
        elif isinstance(value, bool):
            lines.append("%s=%s" % (key, "true" if value else "false"))
        else:
            lines.append("%s=%s" % (key, value))
    (cfg_dir / "goanna.cfg").write_text("\n".join(lines) + "\n")
    return root


class Client:
    def __init__(self, plan, port, out_dir, tag):
        self.plan = plan
        self.port = port
        self.log = out_dir / ("client-%s.log" % tag)
        self.proc = None
        self.control = Control("127.0.0.1", port)

    def start(self, settings, profile_dir):
        # The previous pass has just been terminated, and its listener can
        # outlive the process by a moment; only a channel still answering
        # after that is somebody else's client.
        for _ in range(20):
            if not self.control.up():
                break
            time.sleep(0.5)
        else:
            raise BenchError("something is already answering on port %d; stop it first"
                             % self.port)
        write_profile(profile_dir, settings)
        env = dict(os.environ)
        env.update({
            "GOANNA_CONTROL": str(self.port),
            "GOANNA_BENCH": "1",
            "GOANNA_HOST": str(self.plan.get("host", "127.0.0.1")),
            "GOANNA_PORT": str(self.plan.get("port", 30000)),
            "GOANNA_NAME": str(self.plan.get("name", "bench")),
            "GOANNA_PASS": str(self.plan.get("password", "")),
            "XDG_DATA_HOME": str(profile_dir),
        })
        for key, value in (self.plan.get("env") or {}).items():
            env[str(key)] = str(value)
        handle = open(self.log, "w")
        self.proc = subprocess.Popen(
            [godot_binary(), "--path", "project"], cwd=REPO, env=env,
            stdout=handle, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
            start_new_session=True)
        deadline = time.time() + 180.0
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise BenchError("the client exited during startup (%d); its log is %s\n%s"
                                 % (self.proc.returncode, self.log, self.tail()))
            if self.control.up():
                self.control.open()
                return
            time.sleep(0.4)
        raise BenchError("the control channel never opened; the log is %s\n%s"
                         % (self.log, self.tail()))

    def tail(self, lines=25):
        try:
            return "\n".join(self.log.read_text(errors="replace").split("\n")[-lines:])
        except OSError:
            return "(no log)"

    def stop(self):
        """Ask the client to leave before killing it.

        A plan launches one client after another under the same player name,
        and a server holds a session it was never told to end: the next pass
        is then denied with "that player is already connected" and waits out
        its whole timeout for a world it will never get. The channel's quit
        disconnects first, which is the difference between the two.
        """
        if self.proc and self.proc.poll() is None:
            try:
                self.control.send("quit")
            except (BenchError, OSError):
                pass
        self.control.close()
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait(timeout=10)
        self.proc = None


# --- the scene ---------------------------------------------------------------


# Singletons are out of reach of the channel's "eval", which is a Godot
# Expression evaluated against main and resolves a bare name as one of
# main's own properties. "run" compiles a real snippet, so this goes there.
MACHINE_SRC = ('return {"gpu": RenderingServer.get_video_adapter_name(), '
               '"cores": OS.get_processor_count(), '
               '"godot": Engine.get_version_info()["string"], '
               '"viewport": [main.get_viewport().get_visible_rect().size.x, '
               'main.get_viewport().get_visible_rect().size.y]}')


def describe_machine(control, plan):
    """What the numbers are of. Resolution above all: a frame time without
    the pixel count beside it compares nothing, and a window manager is free
    to have resized the client on the way up."""
    size = plan.get("resolution")
    if size:
        control.send("run", {"src": "DisplayServer.window_set_size(Vector2i(%d, %d))\n"
                                    "return true" % (int(size[0]), int(size[1]))})
        control.send("wait", {"frames": 10})
    got = control.send("run", {"src": MACHINE_SRC})["value"]
    vp = got.get("viewport") or [0, 0]
    if size and (int(vp[0]), int(vp[1])) != (int(size[0]), int(size[1])):
        # Wayland does not let a client size its own window, and the project
        # may be stretching to fit anyway. The measurement is still valid,
        # it is just not of the resolution asked for, so say so rather than
        # let the report quietly disagree with the plan.
        print("  note: asked for %dx%d, the viewport is %dx%d"
              % (int(size[0]), int(size[1]), int(vp[0]), int(vp[1])))
    return got


def wait_ready(control, timeout_s=240.0):
    """Connected, media in and the player placed, or a clear reason why not.

    Waiting on the expression alone turns a refusal into a timeout with
    nothing in it: the state sits at "denied" and the message that says why
    is one field away.
    """
    deadline = time.time() + timeout_s
    last = ""
    while time.time() < deadline:
        st = control.send("status")
        last = str(st.get("state", ""))
        if last == "ready":
            return st
        if last == "denied":
            why = str(st.get("message", "")) or "no reason given"
            extra = ""
            if "already connected" in why:
                extra = (". A client from an earlier run is still holding this "
                         "player name; the server frees it a little after that "
                         "client disconnects, or use a different name in the plan")
            raise BenchError("the server refused the connection: %s%s" % (why, extra))
        time.sleep(1.0)
    raise BenchError("the client never became ready; it is still %r" % last)


def anchor_position(control, plan):
    """Where the fixed camera stands and where every route begins.

    Anchored to the server reported player position by default, not to a
    coordinate typed into the plan: a fresh player name spawns somewhere of
    the server's choosing, and a hardcoded position would photograph a
    different place on a different world.
    """
    spec = plan.get("anchor") or {}
    offset = spec.get("offset", [0, 2, 0])
    if spec.get("at"):
        base = list(spec["at"])
    else:
        base = control.send("status")["server_position"]
        base = [base["x"], base["y"], base["z"]] if isinstance(base, dict) else list(base)
    return [base[0] + offset[0], base[1] + offset[1], base[2] + offset[2]]


def ground_at(control, x, z, from_y, drop=64):
    """The first solid node below from_y at this column, or None."""
    src = ('var y = %f\n'
           'while y > %f:\n'
           '\tvar nm = client.node_name_at(Vector3(%f, y, %f))\n'
           '\tif nm != "" and nm != "air" and nm != "ignore":\n'
           '\t\treturn y\n'
           '\ty -= 1.0\n'
           'return null' % (from_y, from_y - drop, x, z))
    return control.send("run", {"src": src})["value"]


def dress_scene(control, plan, anchor, build_scene=False):
    """Pin everything that would otherwise drift between runs, then add the
    load the plan asks for. Time of day and weather first: over a sixty
    second sample the sun moves, and a Mineclonia storm arriving halfway
    through changes the lamp count, the wetness and the cloud cover."""
    if plan.get("time_of_day") is not None:
        control.send("time", {"tod": float(plan["time_of_day"])})
    if plan.get("weather"):
        control.send("weather", {"kind": str(plan["weather"])})
    # Structures are a permanent change to the world, so they are placed only
    # when asked for. Run once with --build-scene to give a fresh world the
    # buildings, lamps and villagers a graphics benchmark needs, then leave it
    # off: placing the village again every run would stack villages.
    for st in (plan.get("structures") or []) if build_scene else []:
        at = st.get("at") or anchor
        control.send("tp", {"x": float(at[0]), "y": float(at[1]), "z": float(at[2])})
        said = control.send("chat", {"text": "/spawnstruct " + str(st["type"]),
                                     "reply_ms": 6000})
        print("  built %s at %s: %s" % (st["type"], at,
                                        "; ".join(said.get("server_said") or [])[:120]))

    # Spawning is slow on purpose: the channel spaces the chat lines so a
    # dozen mobs do not spend the server's eight messages per ten seconds and
    # get the next command refused with them.
    for actor in plan.get("actors") or []:
        at = actor.get("at", [0, 0, 0])
        want = int(actor.get("count", 1))
        x, z = anchor[0] + at[0], anchor[2] + at[2]
        # On the ground, not at an offset from the camera. Summoned in mid
        # air they fall, and in this world they fall far enough to die on
        # landing, so the scene ends up with fewer entities than the plan
        # asks for plus a scatter of dropped items, and a different number
        # every run.
        y = ground_at(control, x, z, anchor[1] + at[1])
        if y is None:
            print("  actors: no ground under %s at (%.0f, %.0f), skipped"
                  % (actor["name"], x, z))
            continue
        try:
            got = control.send("spawn", {
                "name": actor["name"], "count": want,
                "x": x, "y": y + 1.0, "z": z})
        except BenchError as exc:
            print("  actors: %s could not be spawned (%s)" % (actor["name"], exc))
            continue
        # A scene silently missing its actors is not the scene the plan
        # describes, and every number taken in it would be of something else.
        if got.get("refused") or got.get("spawned", 0) < want:
            said = "; ".join(got.get("server_said") or [])[:200]
            print("  actors: %s, %d of %d spawned. %s"
                  % (actor["name"], got.get("spawned", 0), want, said))
    # A moment for the server to send what it just spawned, or the count
    # reports the world as empty when it is not.
    control.send("wait", {"ms": 3000})
    st = control.send("status")
    print("  scene: %d entities, time of day %.2f, precipitation %.2f"
          % (int(st.get("entities", 0)), float(st.get("time_of_day", -1.0)),
             float(st.get("precipitation", 0.0))))


def apply_settings(control, settings):
    for key, value in sorted(settings.items()):
        if isinstance(value, str):
            continue          # only texture_pack, and that needs a relaunch
        control.send("set", {"key": key, "value": float(value)})


def scene_of(plan, variant, anchor):
    """The conditions a variant has to be measured under.

    One vista cannot test every setting, which is the mistake this exists to
    stop. Sun shafts are strongest near dawn and dusk and in rain, so at noon
    under a clear sky the setting is doing nothing by design and reads as
    free. Normal maps, occlusion and surface detail act on near surfaces, so
    a camera thirty nodes from anything cannot see them move either. Lamp
    shadows want a lit village after dark. A plan therefore names several
    scenes and each variant says which one it belongs to; the control is
    measured in every scene it is compared against.
    """
    scenes = plan.get("scenes") or {}
    name = variant.get("scene") or plan.get("default_scene") or "default"
    sc = dict(scenes.get(name) or {})
    sc["name"] = name
    sc.setdefault("at", anchor)
    sc.setdefault("aim", plan.get("aim"))
    sc.setdefault("time_of_day", plan.get("time_of_day"))
    sc.setdefault("weather", plan.get("weather"))
    return sc


def park(control, plan, scene):
    """Put the camera on this scene's pose and wait for it to be ready.

    The wait is not optional and not only for the settings that re-mesh. A
    pose change alone restarts block streaming, re-sorts the light pool and
    rebuilds LOD, and the first smoke run measured that instead of the
    setting: the control variant showed a whole second of 30ms frames with
    the GPU at 4.6ms and the renderer CPU at 4.8ms, the rest of it terrain
    work on the main thread. docs/baseline.md says the same thing in one
    line, do not compare a settled scene with one still streaming.
    """
    if isinstance(scene, list):          # a bare anchor, for the route tests
        scene = {"name": "default", "at": scene, "aim": plan.get("aim"),
                 "time_of_day": plan.get("time_of_day"),
                 "weather": plan.get("weather")}
    if scene.get("time_of_day") is not None:
        control.send("time", {"tod": float(scene["time_of_day"])})
    if scene.get("weather"):
        control.send("weather", {"kind": str(scene["weather"])})
    at = scene["at"]
    control.send("route", {"action": "stop"})
    control.send("fly", {"on": True})
    control.send("pose", {"x": at[0], "y": at[1], "z": at[2],
                          "pitch": float(scene.get("pitch", -8.0)),
                          "yaw": float(scene.get("yaw", 0.0)), "fly": True})
    # A plan that names what the camera looks at is checkable; one that names
    # a compass bearing is not. The first sweep run from this harness pointed
    # yaw 0 from the spawn and spent forty minutes measuring the inside of a
    # dark oak trunk two metres away, which no number in the report could
    # have revealed.
    aim = scene.get("aim")
    if aim:
        control.send("look", {"x": float(aim[0]), "y": float(aim[1]),
                              "z": float(aim[2])})
    wait_quiet(control, float(plan.get("settle_quiet", 30)),
               float(plan.get("settle_timeout", 600)))
    # A pad beyond the queues emptying, because a shader that has just been
    # recompiled or a mesh that has just been uploaded costs on the frames
    # after the queue that carried it is already empty.
    time.sleep(float(plan.get("settle_pad", 3.0)))
    wait_resolved(control, plan, str(scene.get("name", "scene")))


def wait_resolved(control, plan, tag="scene"):
    """Wait for the picture to stop changing, not just the work queues.

    Empty queues mean the scheduler has run out of things to do. They do not
    mean the frame has finished resolving: bounced light is still
    converging, far tiers are still being replaced by nearer ones, the
    volumetric fog and the raymarched cloud are still accumulating. A settle
    test that reads only counters calls all of that finished, and every
    sample after it is of a scene that still looks wrong.

    So: photograph the frame at intervals and watch the difference between
    consecutive pairs. It never reaches zero, because clouds drift, water
    animates and mobs walk. It does stop falling, and that plateau is the
    scene having resolved.
    """
    want = int(plan.get("resolve_samples", 24))
    gap = float(plan.get("resolve_gap_s", 4.0))
    tol = float(plan.get("resolve_tolerance", 0.15))
    floor = float(plan.get("resolve_floor", 0.25))
    shots = pathlib.Path(plan["_scratch"]) / "resolve"
    shots.mkdir(parents=True, exist_ok=True)
    seen = []
    prev = None
    for i in range(want):
        here = shots / ("%s-%d.png" % (tag, i))
        control.send("shot", {"path": str(here), "settle": False, "warm": 20})
        if prev is not None:
            seen.append(image_diff(prev, here)["mean"])
            # Resolved when the last two differences agree: the frame is
            # changing only as much as its own animation, and no longer
            # settling toward something.
            if len(seen) >= 3:
                recent = seen[-3:]
                # Plateaued, or already down in the animation noise. Without
                # the floor a scene whose residual is a drifting cloud can
                # wobble either side of the tolerance for ever.
                if (max(recent) - min(recent) <= tol * max(max(recent), 0.01)
                        or max(recent) <= floor):
                    return {"resolved": True, "samples": len(seen),
                            "series": [round(v, 3) for v in seen]}
        prev = here
        time.sleep(gap)
    print("  WARNING: %s never stopped resolving (frame differences %s). What "
          "follows was measured while the picture was still changing."
          % (tag, " ".join("%.3f" % v for v in seen)))
    return {"resolved": False, "samples": len(seen),
            "series": [round(v, 3) for v in seen]}


def wait_settled(control, quiet, timeout_s):
    """Queues empty for `quiet` seconds. Returns False rather than raising:
    a view that never settles is a result to record, not a run to abandon."""
    expr = ("bench.stamps.has(\"settled_s\")")
    try:
        control.send("wait", {"expr": expr, "timeout_ms": int(timeout_s * 1000)})
        return True
    except BenchError:
        return False


def wait_quiet(control, quiet, timeout_s, what="the world"):
    """The same wait, but for a client that has already settled once and has
    since been moved: bench's own stamp is taken only the first time."""
    deadline = time.time() + timeout_s
    since = None
    while time.time() < deadline:
        state = control.send("eval", {"expr": "bench._settle_since"})["value"]
        if state is not None and float(state) >= 0.0:
            if since is None:
                since = time.time()
            if time.time() - since >= quiet:
                return True
        else:
            since = None
        time.sleep(1.0)
    print("  WARNING: %s never went quiet for %.0fs within %.0fs. What "
          "follows was measured on a world that is still working."
          % (what, quiet, timeout_s))
    return False


# --- the tests ---------------------------------------------------------------


def record(control, out_dir, phase, seconds, label, capacity=None):
    args = {"action": "start", "phase": phase, "label": label}
    if capacity:
        args["capacity"] = capacity
    control.send("bench", args)
    time.sleep(seconds)
    out_dir.mkdir(parents=True, exist_ok=True)
    run = control.send("bench", {"action": "stop", "dir": str(out_dir)})
    warn_disturbed(run, label)
    return run


def warn_disturbed(run, label):
    """The client locks its keyboard and mouse out while a run records, so
    this should never fire. It is here because a lock that is never checked
    is a lock nobody knows is broken, and a moved camera looks exactly like
    a setting that made things slower."""
    moved = float(run.get("disturbed_m", 0.0))
    turned = float(run.get("disturbed_deg", 0.0))
    if moved > 0.05 or turned > 0.5:
        run["disturbed"] = True
        print("  WARNING: the camera moved during %s, by %.2f nodes and %.1f "
              "degrees. This run is not comparable with the others."
              % (label, moved, turned))
    return run


def test_load(client, plan, out_dir):
    """The three stamps. They are taken by the recorder itself from process
    start, so all this does is wait for the last one and read them off."""
    control = client.control
    quiet = float(plan.get("settle_quiet", 30))
    control.send("eval", {"expr": "bench.set(\"settle_quiet\", %f)" % quiet})
    wait_ready(control)
    settled = wait_settled(control, quiet, float(plan.get("settle_timeout", 600)))
    stamps = control.send("bench", {"action": "stamps"})
    stamps["settled"] = settled
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "stamps.json").write_text(json.dumps(stamps, indent=2))
    return stamps


def test_steady(client, plan, out_dir, anchor, label):
    control = client.control
    park(control, plan, anchor)
    return record(control, out_dir, "steady", float(plan.get("seconds", 60)), label)


def test_move_early(client, plan, out_dir, label):
    """Set off the moment the world is playable. The route starts from where
    the recorder stamped playable rather than from the anchor, because
    teleporting first would give the world a head start it does not get when
    a player simply walks away from spawn."""
    control = client.control
    control.send("wait", {"expr": 'bench.stamps.has("playable_s")',
                          "timeout_ms": 300000})
    route = dict(plan.get("route") or {})
    route["speed"] = float(plan.get("walk_speed", 4.317))
    control.send("bench", {"action": "start", "phase": "move_early", "label": label})
    control.send("route", route)
    time.sleep(float(plan.get("seconds", 60)))
    out_dir.mkdir(parents=True, exist_ok=True)
    result = control.send("bench", {"action": "stop", "dir": str(out_dir)})
    control.send("route", {"action": "stop"})
    return result



def test_move_full(client, plan, out_dir, anchor, label):
    """Fly the route at rising speed until it breaks. Two ways to break, and
    both are reported: the frame rate collapses, or the world stops keeping
    up and the camera flies over ground that has not arrived."""
    control = client.control
    ladder = plan.get("sweep") or [4.317, 10.0, 20.0, 40.0, 80.0]
    seconds = float(plan.get("sweep_seconds", plan.get("seconds", 60)) or 30)
    steps = []
    reference = None
    for speed in ladder:
        park(control, plan, anchor)
        route = dict(plan.get("route") or {})
        route["speed"] = float(speed)
        step_dir = out_dir / ("speed-%g" % speed)
        control.send("bench", {"action": "start", "phase": "move_full",
                               "label": "%s@%g" % (label, speed)})
        control.send("route", route)
        time.sleep(seconds)
        step_dir.mkdir(parents=True, exist_ok=True)
        result = control.send("bench", {"action": "stop", "dir": str(step_dir)})
        control.send("route", {"action": "stop"})
        stats = (result.get("phases") or {}).get("move_full") or {}
        ground = ground_fraction(step_dir / "samples.jsonl")
        stats = dict(stats)
        stats["speed"] = float(speed)
        stats["ground_fraction"] = ground
        if reference is None:
            reference = stats.get("median_ms") or 1.0
        # Held means the world kept up and the frames did not fall apart
        # relative to the slowest step, which is the same route at walking
        # pace and therefore the fair comparison.
        stats["held"] = bool(
            ground >= float(plan.get("ground_floor", 0.9))
            and (stats.get("median_ms") or 1e9) <= reference * float(
                plan.get("speed_slack", 1.5)))
        steps.append(stats)
        print("    %6.1f nodes/s: median %.2fms, ground %.0f%%, %s"
              % (speed, stats.get("median_ms", 0.0), ground * 100.0,
                 "held" if stats["held"] else "gave out"))
        if not stats["held"]:
            break
    held = [s["speed"] for s in steps if s["held"]]
    out = {"steps": steps, "top_speed": max(held) if held else 0.0}
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "sweep.json").write_text(json.dumps(out, indent=2))
    return out


def capture_median(control, out_dir, tag, count=9, gap=0.35):
    """A per pixel median over several frames, saved as one PNG.

    A single frame cannot be compared against another one here. The close
    pose stands in the village, where the waving leaf and plant shaders
    animate continuously and a hundred entities walk about, so two captures
    with nothing changed differed by mean 5.4 over 74% of the frame: a noise
    floor no setting could clear. A median across frames removes what moves
    and keeps what does not, which is exactly the split wanted.
    """
    from PIL import Image
    import numpy as np
    frames = []
    for i in range(count):
        p = out_dir / ("%s-%02d.png" % (tag, i))
        control.send("shot", {"path": str(p), "settle": False, "warm": 6})
        frames.append(np.asarray(Image.open(p).convert("RGB"), dtype=np.uint8))
        p.unlink(missing_ok=True)
        time.sleep(gap)
    med = np.median(np.stack(frames), axis=0).astype(np.uint8)
    out = out_dir / ("%s.png" % tag)
    Image.fromarray(med).save(out)
    return out


def image_diff(a_path, b_path):
    """How much two frames differ, in the terms that matter for "did this
    setting do anything": the mean absolute channel difference over the
    frame, and the share of pixels that moved at all."""
    from PIL import Image
    import numpy as np
    a = np.asarray(Image.open(a_path).convert("RGB"), dtype=np.int16)
    b = np.asarray(Image.open(b_path).convert("RGB"), dtype=np.int16)
    if a.shape != b.shape:
        raise BenchError("frames differ in size: %s against %s" % (a.shape, b.shape))
    d = np.abs(a - b)
    return {"mean": float(d.mean()), "max": int(d.max()),
            "changed_pct": float((d.max(axis=2) > 1).mean() * 100.0)}


def test_visual(control, plan, out_dir, scene, variant, base_settings):
    """Does this setting change the picture at all?

    A frame time sweep can only say a setting is not costing anything. It
    cannot tell "cheap" from "not implemented", and this project has had
    three separate lighting mechanisms that were inert while looking exactly
    like working ones. So: photograph the scene twice with nothing changed,
    then once with the setting moved, from one run at one pose. The first
    pair is the noise floor (clouds drift, water animates, mobs walk); the
    second is the effect. An effect that does not clear its own noise floor
    means the setting moved no pixels.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    # The noise pair and the signal pair must cost the same wall clock and
    # the same operations, or the scene's own drift over the longer gap is
    # counted as the setting's effect. The first version took B a second
    # and a half after A with nothing in between, and C after a full park
    # and resolve, and every control row then reported an effect it could
    # not have had: control~dusk came out at mean 2.08 with an empty set.
    n = int(plan.get("visual_frames", 9))
    park(control, plan, scene)
    a = capture_median(control, out_dir, "control-a", n)
    park(control, plan, scene)
    b = capture_median(control, out_dir, "control-b", n)
    want = dict(base_settings)
    want.update(variant.get("set") or {})
    apply_settings(control, {k: v for k, v in want.items()
                             if base_settings.get(k) != v})
    park(control, plan, scene)
    c = capture_median(control, out_dir, "variant", n)
    apply_settings(control, {k: base_settings[k]
                             for k in (variant.get("set") or {})
                             if k in base_settings})
    noise = image_diff(a, b)
    effect = image_diff(a, c)
    # Clears its own animation noise by a wide enough margin to be the
    # setting rather than the clouds.
    effect["noise"] = noise
    effect["visible"] = (effect["mean"] > max(noise["mean"] * 3.0, 0.05)
                         and effect["changed_pct"] > noise["changed_pct"] + 2.0)
    # Some settings are not supposed to move a pixel. Occlusion culling
    # decides what to skip drawing because it cannot be seen, so a visible
    # change there is a fault, not a feature, and "no visible effect" is the
    # pass rather than the finding.
    effect["expect_visible"] = bool(variant.get("expect_visible", True))
    return effect


def ground_fraction(samples_path):
    """The share of one second samples that found ground under the camera."""
    try:
        rows = [json.loads(line) for line in
                samples_path.read_text().strip().split("\n") if line.strip()]
    except (OSError, ValueError):
        return 1.0
    seen = [r for r in rows if "ground" in r]
    if not seen:
        return 1.0
    return sum(1 for r in seen if r["ground"]) / float(len(seen))


# --- one variant -------------------------------------------------------------


def run_variant(plan, variant, out_root, port, keep_profiles):
    name = variant["name"]
    settings = dict(plan.get("base") or {})
    settings.update(variant.get("set") or {})
    tests = plan.get("tests") or ["load", "steady", "move_early", "move_full"]
    out_dir = out_root / name
    out_dir.mkdir(parents=True, exist_ok=True)
    profiles = out_dir / "profile"
    result = {"name": name, "set": variant.get("set") or {}}

    # Pass A: load, then steady and the speed sweep from the settled world.
    wanted_a = [t for t in tests if t in ("load", "steady", "move_full")]
    if wanted_a:
        client = Client(plan, port, out_dir, "a")
        try:
            print("  launching for %s" % ", ".join(wanted_a))
            client.start(settings, profiles / "a")
            wait_ready(client.control)
            result["machine"] = describe_machine(client.control, plan)
            anchor = anchor_position(client.control, plan)
            result["anchor"] = anchor
            if "load" in tests:
                result["load"] = test_load(client, plan, out_dir / "load")
                st = result["load"]
                print("    connect %.1fs, playable %.1fs, settled %s"
                      % (st.get("connect_s", 0) - st.get("boot_s", 0),
                         st.get("playable_s", 0) - st.get("boot_s", 0),
                         ("%.1fs" % (st["settled_s"] - st["boot_s"]))
                         if st.get("settled_s") else "never"))
            else:
                wait_settled(client.control, float(plan.get("settle_quiet", 30)),
                             float(plan.get("settle_timeout", 600)))
            dress_scene(client.control, plan, anchor)
            if "steady" in tests:
                result["steady"] = test_steady(client, plan, out_dir / "steady",
                                               anchor, name)
                print("    steady: %s" % one_line(result["steady"], "steady"))
            if "move_full" in tests:
                result["move_full"] = test_move_full(client, plan,
                                                     out_dir / "move_full", anchor, name)
        finally:
            client.stop()

    # Pass B: a world nobody has seen, walked away from as soon as it is
    # playable. It needs its own process for the same reason load does.
    if "move_early" in tests:
        client = Client(plan, port, out_dir, "b")
        try:
            print("  launching for move_early")
            client.start(settings, profiles / "b")
            wait_ready(client.control)
            result["move_early"] = test_move_early(client, plan,
                                                   out_dir / "move_early", name)
            print("    move_early: %s" % one_line(result["move_early"], "move_early"))
        finally:
            client.stop()

    if not keep_profiles:
        shutil.rmtree(profiles, ignore_errors=True)
    (out_dir / "result.json").write_text(json.dumps(result, indent=2))
    return result


def run_live_sweep(plan, variants, out_root, port, keep_profiles, build_scene=False):
    tests = plan.get("tests") or ["steady"]
    """Every variant measured in one settled world, switched over the channel.

    This is the better measurement where the tests allow it, not merely the
    faster one. Two processes stream their blocks in a different order and
    settle to a slightly different scene, so a small difference between them
    is partly the streaming; switched live, the geometry, the block set and
    the light pool are identical and the setting is the only thing that
    moved. It is the argument project/main.gd already makes for GOANNA_AB.
    """
    base = dict(plan.get("base") or {})
    out_root.mkdir(parents=True, exist_ok=True)
    client = Client(plan, port, out_root, "live")
    results = []
    try:
        print("  launching one client for the whole sweep")
        client.start(base, out_root / "profile")
        control = client.control
        wait_ready(control)
        machine = describe_machine(control, plan)
        build = build_fingerprint()
        machine["build"] = build
        anchor = anchor_position(control, plan)
        # Go to the anchor before waiting for anything. Waiting at the spawn
        # is waiting on a place the plan does not measure, and a login point
        # is not guaranteed to settle at all: one run of this spent twenty
        # minutes there while the client took 246,000 blocks and the resident
        # count cycled between 259 and 464 every two seconds, in step with
        # the prune timer.
        control.send("tp", {"x": anchor[0], "y": anchor[1], "z": anchor[2]})
        park(control, plan, anchor)
        dress_scene(control, plan, anchor, build_scene)
        # A photograph of the scene, beside the report, every time. Not a
        # nicety: without it nothing in this pipeline ever shows the frame,
        # and a benchmark can spend an hour measuring a view of a tree trunk
        # while every number in the table looks perfectly reasonable.
        park(control, plan, anchor)
        control.send("shot", {"path": str(out_root / "scene.png"),
                              "settle": False, "warm": 40})
        print("  scene photographed to %s" % (out_root / "scene.png"))

        # A cold client has shaders left to compile, textures left to upload
        # and a far field still filling. The first variant would otherwise
        # carry all of it and every later one would look like an improvement.
        warm = float(plan.get("warmup_seconds", 60))
        if warm > 0:
            print("  warming up for %.0fs before the first variant" % warm)
            park(control, plan, anchor)
            record(control, out_root / "warmup", "steady", warm, "warmup")
        # What every unmentioned setting goes back to. Not the plan's base,
        # which is usually empty: the control condition is whatever the
        # client started with, hardware defaults included, and only the
        # client knows that. The channel records it before the first
        # command lands, which is why it is asked for here and not guessed.
        startup = {k: v["value"] for k, v in control.send("settings").items()}
        startup.update(base)
        # A long sweep is not a controlled experiment against one control run
        # at the end of it. Over fifty minutes this scene's primitive count
        # rose 8% on its own (mobs wander, far tiers and LOD regions keep
        # consolidating), and every variant measured late read a few percent
        # slower than the same settings measured early. So the control is
        # re-measured through the sweep, and each variant is compared against
        # the control either side of it rather than against one endpoint.
        every = int(plan.get("control_every", 4))
        # Grouped by scene, so the camera is not flown back and forth, and
        # with the control measured inside each group: a row is only ever
        # compared against a control taken under the same light, weather and
        # pose. Sorting is stable, so the plan's order survives inside a
        # group.
        groups = {}
        for v in variants:
            if v.get("is_control"):
                continue
            groups.setdefault(v.get("scene") or plan.get("default_scene")
                              or "default", []).append(v)
        schedule = []
        for scene_name, members in groups.items():
            def probe(tag, scene_name=scene_name):
                return {"name": "control~%s%s" % (scene_name, tag), "set": {},
                        "is_control": True, "scene": scene_name}
            schedule.append(probe(""))
            for i, v in enumerate(members):
                if every > 0 and i > 0 and i % every == 0:
                    schedule.append(probe("~at%d" % i))
                schedule.append(v)
            schedule.append(probe("~end"))
        variants = schedule
        began = time.time()
        current = dict(startup)
        for i, variant in enumerate(variants, 1):
            want = dict(startup)
            want.update(variant.get("set") or {})
            # Everything that differs, in both directions: a setting the
            # previous variant moved and this one does not mention has to go
            # back, or the sweep accumulates instead of comparing. The first
            # smoke run got this wrong and the control repeat at the end
            # silently ran without shadow lamps, reading 30% cheaper on the
            # GPU than the control it was meant to reproduce.
            changed = {k: v for k, v in want.items() if current.get(k) != v}
            print("[%d/%d] %s %s" % (i, len(variants), variant["name"],
                                     variant.get("set") or ""))
            apply_settings(control, changed)
            current = want
            now = build_fingerprint()
            if now["libs"] != build["libs"]:
                raise BenchError(
                    "project/bin changed during the plan, before %s. Something "
                    "rebuilt the extension while this was running, so the rows "
                    "already taken and the rows still to come would be of two "
                    "different clients. Stopping rather than reporting them as "
                    "one experiment." % variant["name"])
            scene = scene_of(plan, variant, anchor)
            row = {"name": variant["name"], "set": variant.get("set") or {},
                   "anchor": anchor, "machine": machine, "scene": scene["name"],
                   "is_control": bool(variant.get("is_control")),
                   "at_s": time.time() - began}
            if "visual" in tests:
                row["visual"] = test_visual(control, plan,
                                            out_root / variant["name"] / "visual",
                                            scene, variant, startup)
                v = row["visual"]
                print("    visual: mean %.3f, %.1f%% of pixels, against noise "
                      "%.3f / %.1f%% -> %s"
                      % (v["mean"], v["changed_pct"], v["noise"]["mean"],
                         v["noise"]["changed_pct"],
                         "changes the picture" if v["visible"] else "NO VISIBLE EFFECT"))
            if "steady" in tests:
                park(control, plan, scene)
                out_dir = out_root / variant["name"] / "steady"
                run = record(control, out_dir, "steady",
                             float(plan.get("seconds", 60)), variant["name"])
                print("    steady: %s" % one_line(run, "steady"))
                row["steady"] = run
            results.append(row)
    finally:
        client.stop()
    if not keep_profiles:
        shutil.rmtree(out_root / "profile", ignore_errors=True)
    return results


def one_line(run, phase):
    s = (run.get("phases") or {}).get(phase)
    if not s:
        return "no frames recorded"
    return ("median %.2fms, 1%% low %.2fms, %.0f fps, %s bound"
            % (s["median_ms"], s["low1_ms"], s["fps_mean"], s["bound"]))


# --- the report --------------------------------------------------------------


def pct(new, old):
    if not old:
        return 0.0
    return (new - old) / old * 100.0


def phase_stats(result, phase):
    if phase == "move_full":
        steps = (result.get("move_full") or {}).get("steps") or []
        return steps[0] if steps else None
    return ((result.get(phase) or {}).get("phases") or {}).get(phase)


def build_report(plan, results, repeat_name):
    """The table, plus the noise floor above it.

    The floor is the difference between the first variant and its repeat at
    the end of the plan. Nothing smaller than it is called a change, which
    is the whole reason the repeat is run: it costs one variant's time and
    it removes the need to argue about significance.
    """
    by_name = {r["name"]: r for r in results}
    base = next((r for r in results if r.get("is_control")), results[0])
    repeat = by_name.get(repeat_name)
    lines = []
    lines.append("# Benchmark report")
    lines.append("")
    lines.append("Plan: %s. Control condition: %s." % (
        plan.get("label", "(unnamed)"), base["name"]))
    m = base.get("machine") or {}
    if m:
        vp = m.get("viewport") or [0, 0]
        lines.append("")
        lines.append("Machine: %s, %s cores, Godot %s, viewport %dx%d."
                     % (m.get("gpu", "?"), m.get("cores", "?"), m.get("godot", "?"),
                        int(vp[0]), int(vp[1])))
        b = m.get("build") or {}
        if b:
            lines.append("")
            lines.append("Build: %s%s, %s." % (
                b.get("head", "?"),
                " with %d uncommitted files" % len(b.get("dirty") or [])
                if b.get("dirty") else "",
                ", ".join("%s %s" % (k, v) for k, v in
                          sorted((b.get("libs") or {}).items()))))
    lines.append("")

    # The control runs through the sweep, in the order they were taken. Each
    # variant is judged against the control either side of it, so a scene
    # that drifts under a long plan does not read as a row of small results.
    controls = [r for r in results
                if r is base or r.get("is_control")
                or r["name"].startswith(base["name"] + "~")]

    def control_ref(r, phase):
        same = [c for c in controls
                if c.get("scene", "default") == r.get("scene", "default")]
        stats = [(c.get("at_s", 0.0), phase_stats(c, phase)) for c in same]
        stats = [(t, v) for t, v in stats if v]
        if not stats:
            return None
        if len(stats) == 1 or "at_s" not in r:
            return stats[0][1]
        at = r.get("at_s", 0.0)
        before = [x for x in stats if x[0] <= at] or [stats[0]]
        after = [x for x in stats if x[0] >= at] or [stats[-1]]
        lo, hi = before[-1], after[0]
        if hi[0] <= lo[0]:
            return lo[1]
        f = (at - lo[0]) / (hi[0] - lo[0])
        return {k: lo[1][k] + (hi[1][k] - lo[1][k]) * f
                for k in ("median_ms", "low1_ms") if k in lo[1] and k in hi[1]}

    noise = {}
    if len(controls) > 2:
        # With the control measured repeatedly, the floor is the spread of
        # those runs rather than the gap between two of them.
        for phase in ("steady", "move_early"):
            vals = [phase_stats(c, phase) for c in controls]
            vals = [v for v in vals if v]
            if len(vals) < 3:
                continue
            noise[phase] = {}
            for key, label in (("median_ms", "median"), ("low1_ms", "low1")):
                xs = [v[key] for v in vals]
                mid = sorted(xs)[len(xs) // 2]
                noise[phase][label] = max(abs(pct(x, mid)) for x in xs)
        lines.append("## Noise floor")
        lines.append("")
        lines.append("`%s` was measured %d times through the plan. The spread "
                     "across those runs is what this machine and this world do "
                     "on their own, with nothing changed. A result smaller than "
                     "it is not a result. Each variant below is compared "
                     "against the control either side of it in time, not "
                     "against one endpoint."
                     % (base["name"], len(controls)))
        lines.append("")
        for phase, n in noise.items():
            lines.append("- %s: median %.1f%%, 1%% low %.1f%%"
                         % (phase, n["median"], n["low1"]))
        drift = [(c.get("at_s", 0.0), phase_stats(c, "steady")) for c in controls]
        drift = [(t, v["median_ms"]) for t, v in drift if v]
        if len(drift) > 2:
            lines.append("- drift, control median over the plan: %s"
                         % " ".join("%.2f" % v for _, v in drift))
        lines.append("")
    elif repeat:
        for phase in ("load", "steady", "move_early", "move_full"):
            a, b = phase_stats(base, phase), phase_stats(repeat, phase)
            if a and b:
                noise[phase] = {
                    "median": abs(pct(b["median_ms"], a["median_ms"])),
                    "low1": abs(pct(b["low1_ms"], a["low1_ms"])),
                }
        a, b = base.get("load"), repeat.get("load")
        if a and b and a.get("playable_s") and b.get("playable_s"):
            noise["load"] = {
                "playable": abs(pct(b["playable_s"] - b["boot_s"],
                                    a["playable_s"] - a["boot_s"])),
            }
        lines.append("## Noise floor")
        lines.append("")
        lines.append("`%s` was run again at the end of the plan. The difference "
                     "between the two runs is what this machine does on its own, "
                     "with nothing changed. A result smaller than this is not a "
                     "result." % base["name"])
        lines.append("")
        for phase, n in noise.items():
            if "median" in n:
                lines.append("- %s: median %.1f%%, 1%% low %.1f%%"
                             % (phase, n["median"], n["low1"]))
            else:
                lines.append("- %s: time to playable %.1f%%" % (phase, n["playable"]))
        lines.append("")

    if any("load" in r for r in results):
        lines.append("## Load")
        lines.append("")
        lines.append("| variant | connect | playable | settled | far reach when playable |")
        lines.append("| --- | --- | --- | --- | --- |")
        for r in results:
            st = r.get("load")
            if not st:
                continue
            boot = st.get("boot_s", 0.0)
            lines.append("| %s | %.1fs | %.1fs | %s | %d |" % (
                r["name"], st.get("connect_s", boot) - boot,
                st.get("playable_s", boot) - boot,
                ("%.1fs" % (st["settled_s"] - boot)) if st.get("settled_s") else "never",
                st.get("playable_far_reach", 0)))
        lines.append("")

    for phase in ("steady", "move_early", "move_full"):
        rows = [(r, phase_stats(r, phase)) for r in results]
        rows = [(r, s) for r, s in rows if s]
        if not rows:
            continue
        title = {"steady": "Steady state", "move_early": "Moving early",
                 "move_full": "Moving, first speed step"}[phase]
        lines.append("## %s" % title)
        lines.append("")
        lines.append("| variant | scene | median | 1% low | 0.1% low | low/med | "
                     "hitch/min | gpu | cpu | bound | fps | vs control |")
        lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | "
                     "--- | --- | --- |")
        floor = noise.get(phase, {})
        for r, s in rows:
            ref = control_ref(r, phase)
            if r in controls or ref is None:
                verdict = "control"
            else:
                dm = pct(s["median_ms"], ref["median_ms"])
                dp = pct(s["low1_ms"], ref["low1_ms"])
                under = (abs(dm) < floor.get("median", 0.0)
                         and abs(dp) < floor.get("low1", 0.0))
                verdict = ("under noise" if under
                           else "%+.0f%% med, %+.0f%% low" % (dm, dp))
            lines.append("| %s | %s | %.2f | %.2f | %.2f | %.2f | %.1f | %.2f | "
                         "%.2f | %s | %.0f | %s |"
                         % (r["name"], r.get("scene", "default"), s["median_ms"],
                            s["low1_ms"], s["low01_ms"], s["stability"],
                            s["hitches_per_min"], s["gpu_ms_median"],
                            s["cpu_ms_median"], s["bound"], s["fps_mean"], verdict))
        lines.append("")

    if any(r.get("visual") for r in results):
        bad = [r for r in results if r.get("is_control") and r.get("visual")
               and r["visual"]["visible"]]
        lines.append("## Does the setting change the picture")
        if bad:
            lines.append("")
            lines.append("**This table cannot be believed.** %s changed nothing "
                         "and still reported an effect, so the measurement is "
                         "picking up something other than the setting: the "
                         "scene had not finished resolving, or the two "
                         "captures did not cost the same wall clock."
                         % ", ".join(r["name"] for r in bad))
        lines.append("")
        lines.append("Two frames with nothing changed give the animation noise "
                     "floor (clouds drift, water moves, mobs walk). A third "
                     "with the setting moved gives the effect. All three come "
                     "from one run at one pose, so streaming is identical. A "
                     "setting whose effect does not clear its own noise is "
                     "moving no pixels, which a frame time on its own cannot "
                     "tell from a setting that is merely cheap.")
        lines.append("")
        lines.append("| variant | scene | mean diff | pixels changed | noise mean "
                     "| noise pixels | verdict |")
        lines.append("| --- | --- | --- | --- | --- | --- | --- |")
        for r in results:
            v = r.get("visual")
            if not v or r.get("is_control"):
                continue
            expect = v.get("expect_visible", True)
            if v["visible"]:
                verdict = "visible" if expect else "**changes the picture, and should not**"
            else:
                verdict = "**no visible effect**" if expect else "no change, as intended"
            lines.append("| %s | %s | %.3f | %.1f%% | %.3f | %.1f%% | %s |" % (
                r["name"], r.get("scene", "default"), v["mean"], v["changed_pct"],
                v["noise"]["mean"], v["noise"]["changed_pct"], verdict))
        lines.append("")
        dead = [r["name"] for r in results
                if r.get("visual") and not r["visual"]["visible"]
                and r["visual"].get("expect_visible", True)
                and not r.get("is_control")]
        if dead:
            lines.append("No visible effect, so worth checking the setting is "
                         "wired up at all before calling it cheap: %s."
                         % ", ".join(dead))
            lines.append("")

    if any(r.get("move_full") for r in results):
        lines.append("## Streaming ceiling")
        lines.append("")
        lines.append("The fastest the route was flown while the frames held and "
                     "the ground kept arriving under the camera.")
        lines.append("")
        lines.append("| variant | top speed | gave out at | why |")
        lines.append("| --- | --- | --- | --- |")
        for r in results:
            sweep = r.get("move_full")
            if not sweep:
                continue
            failed = [s for s in sweep["steps"] if not s["held"]]
            why = "-"
            if failed:
                f = failed[0]
                why = ("terrain, %.0f%% ground" % (f["ground_fraction"] * 100.0)
                       if f["ground_fraction"] < 0.9 else "frame time")
            lines.append("| %s | %.1f nodes/s | %s | %s |" % (
                r["name"], sweep["top_speed"],
                ("%.1f" % failed[0]["speed"]) if failed else "held throughout", why))
        lines.append("")

    lines.append("Columns are frame times in milliseconds. The 1% low is the "
                 "mean of the slowest one frame in a hundred, and 0.1% low the "
                 "slowest one in a thousand, rather than a percentile: Goanna "
                 "prunes blocks every two seconds and the spike that costs "
                 "sits right where a p99 falls, so the percentile moves with "
                 "how many spikes a sample caught and the tail mean does not. "
                 "low/med is the stability ratio, how much worse the bad "
                 "frames are than the ordinary ones. hitch/min counts frames "
                 "over twice the median and at least 8ms longer than it. gpu "
                 "and cpu are the median measured GPU time and renderer CPU "
                 "time; where neither fills the frame, the cost is on the main "
                 "thread, which is where meshing, LOD and block upload land.")
    lines.append("")
    spoiled = [r["name"] for r in results
               for phase in ("steady", "move_early")
               if (r.get(phase) or {}).get("disturbed")]
    if spoiled:
        lines.append("")
        lines.append("The camera was moved during %s. Those rows are of a "
                     "different view than the rest and cannot be compared "
                     "with them." % ", ".join(sorted(set(spoiled))))
        lines.append("")
    lines.append("scene.png beside this report is the view every steady state "
                 "row was measured from. Look at it before believing the "
                 "table.")
    lines.append("")
    lines.append("frames.csv beside each run holds every frame. Nothing above "
                 "was read off it by hand and nothing needs to be.")
    return "\n".join(lines)


# --- entry point -------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("plan", help="the plan, a JSON file")
    ap.add_argument("out", help="directory to write runs and the report into")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT,
                    help="control channel port (default %d)" % DEFAULT_PORT)
    ap.add_argument("--only", action="append", default=[],
                    help="run only this variant by name; repeatable")
    ap.add_argument("--no-repeat", action="store_true",
                    help="skip the control repeat, and with it the noise floor")
    ap.add_argument("--build-scene", action="store_true",
                    help="place the plan's structures before measuring. This "
                         "changes the world permanently, so run it once on a "
                         "fresh world and not again")
    ap.add_argument("--keep-profiles", action="store_true",
                    help="keep each run's scratch XDG_DATA_HOME")
    ap.add_argument("--live", dest="live", action="store_true", default=None,
                    help="measure every variant in one settled world, switching "
                         "settings over the channel. The default for a steady "
                         "state only plan with no relaunch setting in it")
    ap.add_argument("--no-live", dest="live", action="store_false",
                    help="give every variant its own process")
    args = ap.parse_args()

    plan = json.loads(pathlib.Path(args.plan).read_text())
    out_root = pathlib.Path(args.out)
    out_root.mkdir(parents=True, exist_ok=True)
    plan["_scratch"] = str(out_root)

    variants = plan.get("variants") or [{"name": "baseline"}]
    if args.only:
        variants = [v for v in variants if v["name"] in args.only]
        if not variants:
            raise BenchError("no variant matched %s" % args.only)
    repeat_name = None
    if not args.no_repeat and len(variants) > 1:
        repeat = copy.deepcopy(variants[0])
        repeat_name = repeat["name"] + "~repeat"
        repeat["name"] = repeat_name
        variants = variants + [repeat]

    relaunch = sorted(k for v in variants for k in (v.get("set") or {})
                      if k in RELAUNCH_KEYS)
    print("plan %s: %d variants, tests %s"
          % (plan.get("label", args.plan), len(variants),
             ", ".join(plan.get("tests") or ["load", "steady", "move_early", "move_full"])))
    if relaunch:
        print("note: %s change what the client loads at startup, so those "
              "variants are whole fresh processes" % ", ".join(relaunch))

    tests = plan.get("tests") or ["load", "steady", "move_early", "move_full"]
    live = args.live
    if live is None:
        live = not (set(tests) - {"steady", "visual"}) and not relaunch
    if live and (set(tests) - {"steady", "visual"} or relaunch):
        raise BenchError("a live sweep can only run the steady state test, and "
                         "not with %s in it: load and move_early need a world "
                         "nobody has seen, and that setting is read at startup"
                         % (", ".join(relaunch) or ", ".join(sorted(RELAUNCH_KEYS))))

    results = []
    started = time.time()
    if live:
        print("one settled world, %d variants switched live" % len(variants))
        results = run_live_sweep(plan, variants, out_root, args.port,
                                 args.keep_profiles, args.build_scene)
    else:
        for i, variant in enumerate(variants, 1):
            print("[%d/%d] %s %s" % (i, len(variants), variant["name"],
                                     variant.get("set") or ""))
            try:
                results.append(run_variant(plan, variant, out_root, args.port,
                                           args.keep_profiles))
            except BenchError as exc:
                print("  failed: %s" % exc)
                results.append({"name": variant["name"], "error": str(exc)})
        results = [r for r in results if "error" not in r] or results

    report = build_report(plan, results, repeat_name)
    (out_root / "report.md").write_text(report + "\n")
    (out_root / "results.json").write_text(json.dumps(results, indent=2))
    print()
    print(report)
    print()
    print("%d variants in %.0f minutes. Report: %s"
          % (len(results), (time.time() - started) / 60.0, out_root / "report.md"))


if __name__ == "__main__":
    try:
        main()
    except BenchError as exc:
        print("goanna-bench: %s" % exc, file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
