#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Measure and photograph micro shadows and the short parallax march.

Run it only under the GPU lock, from the checkout whose build is under
test. What was run on 2026-10-05 (docs/systems/materials.md, "Micro shadows and
the short march"), per tier:

    flock /tmp/claude-1000/goanna-gpu.lock \\
        python3 run.py OUT --hold low &          # server and client, kept
    python3 run.py OUT --attach low --build --no-timing   # frames first
    python3 run.py OUT --attach low --rounds 16 --burst 600 --no-frames
    touch OUT/stop                               # stops both, frees the lock

then analyse.py OUT and sheet.py OUT/<tier>/frames DEST. Frames go first
because a run of teleports between poses lost the near mesh of one
platform map block for the rest of the session.

--hold refuses to start unless `tools/goanna-headless gpu-free` reports
free with no driver errors and nvidia-smi lists no compute user outside
the desktop's own. It starts one Luanti server on WORLD (a reflink copy of
test_world with fixture/ installed as a worldmod) and one headless client
at the tier's resolution, with a fresh profile written for the tier.

Timing: the variants of a tier are switched live and taken in rotation,
so drift lands on every variant alike. --burst N times N draws back to
back without presenting (see BURST_SRC for why); without it, SECONDS of
presented frames. Each sample's per frame GPU times are kept.

Frames: every variant at every look pose, at a low sun, with the profile
and the material strengths recorded beside each one.
"""

import argparse
import importlib.util
import json
import os
import pathlib
import re
import signal
import statistics
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parents[3]
LUANTI_HOME = pathlib.Path.home() / ".var/app/org.luanti.luanti"
WORLD = "goanna_occl_1005"
SERVER_PORT = 30917
CONTROL_PORT = 30957
GODOT = "/home/poss/Documents/Code/Godot/Godot_v4.5.1-stable_linux.x86_64"
PACK = REPO / "pbr_packs" / "mineclonia" / "textures"
ROUNDS = 6
SECONDS = 12.0
DESKTOP_GPU_USERS = ("kwin_wayland", "Xwayland", "freetube", "plasmashell", "firefox")

# The tier, its resolution, and the variants to alternate. Each variant is
# applied over the tier's own profile.
TIERS = {
    "low": {"size": (1280, 800), "variants": {
        "low_today": {"mat_parallax": 0, "mat_parallax_short": 0, "mat_micro_shadow": 0},
        "low_micro": {"mat_parallax": 0, "mat_parallax_short": 0, "mat_micro_shadow": 1},
        "low_short_micro": {"mat_parallax": 1, "mat_parallax_short": 1, "mat_micro_shadow": 1},
        "low_short": {"mat_parallax": 1, "mat_parallax_short": 1, "mat_micro_shadow": 0},
    }},
    "medium": {"size": (1920, 1080), "variants": {
        "medium_today": {"mat_parallax": 1, "mat_parallax_short": 0, "mat_micro_shadow": 0},
        "medium_micro": {"mat_parallax": 1, "mat_parallax_short": 0, "mat_micro_shadow": 1},
        "medium_short_micro": {"mat_parallax": 1, "mat_parallax_short": 1, "mat_micro_shadow": 1},
    }},
}

# Goanna's coordinates, which the benchmark plans and the control channel's
# tp, pose and look use: Luanti's with z negated (the server reported the
# player at z -424 after "tp -36 92 424"). The vista is the benchmark scene
# (docs/develop/benchmark.md); the rest are on the fixture platform, built at
# Luanti (-40, 90, 420), so Goanna z -420 to -433. "west" walls face -x,
# toward a low afternoon sun; "south" walls face Goanna +z, which that sun
# only rakes.
TIMING_POSES = {
    "vista": {"at": (-72, 54, 378), "aim": (-100, 46, 342), "tod": 0.5},
    "wall": {"at": (-34.5, 92.0, -421.0), "aim": (-32.5, 92.0, -421.0), "tod": None},
}
LOOK_POSES = {
    "cobble_west": {"at": (-35.5, 92.0, -421.0), "aim": (-32.5, 92.0, -421.0)},
    "stonebrick_west": {"at": (-35.5, 92.0, -427.0), "aim": (-32.5, 92.0, -427.0)},
    "brick_west": {"at": (-35.5, 92.0, -430.0), "aim": (-32.5, 92.0, -430.0)},
    "cobble_south": {"at": (-41.0, 92.0, -427.0), "aim": (-41.0, 92.0, -429.5)},
    "brick_south": {"at": (-38.0, 92.0, -427.0), "aim": (-38.0, 92.0, -429.5)},
    "stonebrick_south": {"at": (-34.0, 92.0, -427.0), "aim": (-34.0, 92.0, -429.5)},
    "log": {"at": (-38.5, 92.5, -422.0), "aim": (-36.0, 92.5, -422.0)},
    "zombie": {"at": (-38.0, 92.6, -427.4), "aim": (-38.0, 92.2, -425.0)},
}


def load_bench():
    spec = importlib.util.spec_from_file_location("goanna_bench", REPO / "tools" / "bench" / "goanna-bench.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def profiles():
    spec = importlib.util.spec_from_file_location("cbp", REPO / "tools" / "bench" / "check-bench-plans.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.shipped_profiles()


def gpu_is_ours():
    """Refuse, never wait: the owner's game, editor or training run wins."""
    out = subprocess.run([str(REPO / "tools" / "goanna-headless"), "gpu-free"],
                         capture_output=True, text=True)
    state = json.loads(out.stdout)
    if not state.get("free") or state.get("driver_errors"):
        sys.exit("GPU not free: %s" % json.dumps(state))
    apps = subprocess.run(["nvidia-smi", "--query-compute-apps=pid,process_name",
                           "--format=csv,noheader"], capture_output=True, text=True).stdout
    for line in apps.strip().splitlines():
        name = line.split(",", 1)[-1].strip()
        if not any(ok in name for ok in DESKTOP_GPU_USERS):
            sys.exit("another GPU user is present: %s" % line)


def descendants(pid):
    kids = []
    for proc in pathlib.Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            stat = (proc / "stat").read_text()
        except OSError:
            continue
        ppid = int(stat.rsplit(")", 1)[1].split()[1])
        if ppid == pid:
            kids.append(int(proc.name))
            kids.extend(descendants(int(proc.name)))
    return kids


def start_server(out):
    log = open(out / "server.log", "w")
    proc = subprocess.Popen(
        ["flatpak", "run", "--command=luanti", "org.luanti.luanti", "--server",
         "--worldname", WORLD, "--port", str(SERVER_PORT),
         "--config", str(LUANTI_HOME / "goanna_server.conf")],
        stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    time.sleep(15.0)    # the fixture is built a second after start
    if proc.poll() is not None:
        sys.exit("server exited: see %s" % (out / "server.log"))
    return proc


def stop_server(proc):
    # Only this server's own process tree, found from the PID started here.
    for pid in reversed([proc.pid] + descendants(proc.pid)):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        for pid in [proc.pid] + descendants(proc.pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def write_profile(root, tier, table):
    cfg = root / "godot" / "app_userdata" / "Goanna"
    cfg.mkdir(parents=True, exist_ok=True)
    lines = ["[settings]", "", 'graphics_profile="%s"' % tier, 'texture_pack="%s"' % PACK,
             "show_body=0", "asset_updates=false"]
    lines += ["%s=%s" % kv for kv in sorted(table[tier].items())]
    (cfg / "goanna.cfg").write_text("\n".join(lines) + "\n")


def start_client(out, tier, size):
    wrapper = out / "godot-dummy-audio"
    wrapper.write_text('#!/bin/sh\nexec %s --audio-driver Dummy "$@"\n' % GODOT)
    wrapper.chmod(0o755)
    xdg = out / ("xdg-" + tier)
    write_profile(xdg, tier, profiles())
    env = dict(os.environ, GODOT_BIN=str(wrapper))
    got = subprocess.run(
        [str(REPO / "tools" / "goanna-headless"), "start", "--cpu-compositor",
         "--project", str(REPO), "--control-port", str(CONTROL_PORT),
         "--server", "127.0.0.1:%d" % SERVER_PORT, "--name", "occl",
         "--size", "%dx%d" % size, "--label", "occlusion review " + tier,
         "--env", "XDG_DATA_HOME=%s" % xdg, "--env", "GOANNA_BENCH=1",
         "--env", "GOANNA_NO_HW_DEFAULTS=1"],
        capture_output=True, text=True, env=env)
    if got.returncode:
        sys.exit("client did not start:\n" + got.stdout + got.stderr)
    return re.search(r"goanna-\d+", got.stdout).group(0)


def stop_client(ident):
    subprocess.run([str(REPO / "tools" / "goanna-headless"), "stop", ident])


def apply(control, settings):
    for key, value in settings.items():
        control.send("set", {"key": key, "value": float(value)})


def record(control, settings, place, tag):
    """The profile and the material strengths as the client holds them."""
    held = {k: control.send("get", {"key": k}) for k in
            ("mat_parallax", "mat_parallax_short", "mat_micro_shadow", "mat_ao",
             "light_sdfgi", "render_ssao")}
    return {"tag": tag, "asked": settings, "held": held, "place": place}


def low_sun(control):
    """The first time after 0.70 at which the sun is below 20 degrees."""
    for tod in [0.70 + 0.01 * i for i in range(9)]:
        control.send("time", {"tod": tod})
        control.send("wait", {"frames": 5})
        dirn = control.send("run", {"src": "var d: Vector3 = -main.sun.global_transform.basis.z\n"
                                           "return [d.x, d.y, d.z]"})
        d = dirn.get("value") or dirn
        if -float(d[1]) < 0.342:
            return tod, d
    return 0.78, d


def pose(control, bench, spot):
    control.send("fly", {"on": True})
    control.send("pose", {"x": spot["at"][0], "y": spot["at"][1], "z": spot["at"][2],
                          "fly": True})
    control.send("look", {"x": spot["aim"][0], "y": spot["aim"][1], "z": spot["aim"][2]})
    bench.wait_quiet(control, 10.0, 300.0)
    time.sleep(2.0)


def gpu_times(path):
    out = []
    with open(path) as f:
        next(f)
        for line in f:
            cells = line.split(",")
            out.append(float(cells[3]))
    return out


# Draws without presenting, back to back, on the main thread. In headless
# gamescope with a CPU compositor the client presents about 33 frames a
# second whatever it draws, so the GPU idles most of each frame, stays in
# a low power state (P5, 900 to 1050 MHz, seen during the first run) and
# its timings swing between 2.8 and 10 ms from one second to the next with
# no setting changed. Drawn back to back the card stays busy and the
# timings settle. The world is frozen while this runs: no streaming, no
# animation, the same frame drawn again.
BURST_SRC = """var vp: RID = main.get_viewport().get_viewport_rid()
RenderingServer.viewport_set_measure_render_time(vp, true)
for i in 30:
	RenderingServer.force_draw(false, 0.0)
var out: Array = []
var last := Time.get_ticks_usec()
for i in %d:
	RenderingServer.force_draw(false, 0.0)
	var now := Time.get_ticks_usec()
	out.append([(now - last) / 1000.0, RenderingServer.viewport_get_measured_render_time_cpu(vp),
			RenderingServer.viewport_get_measured_render_time_gpu(vp)])
	last = now
return out"""


def burst(control, run_dir, draws):
    got = control.send("run", {"src": BURST_SRC % draws})
    rows = got.get("value") if isinstance(got, dict) else got
    run_dir.mkdir(parents=True, exist_ok=True)
    with open(run_dir / "frames.csv", "w") as f:
        f.write("t_s,frame_ms,cpu_ms,gpu_ms,dist_m,phase\n")
        t = 0.0
        for wall, cpu, gpu in rows:
            t += wall / 1000.0
            f.write("%.6f,%.4f,%.4f,%.4f,0.00,burst\n" % (t, wall, cpu, gpu))


def pct(values, q):
    s = sorted(values)
    return s[min(len(s) - 1, int(q * len(s)))]


def measure_tier(control, bench, tier, out, opt, build):
    """Timings, then frames, on a client already connected at the tier."""
    spec = TIERS[tier]
    results = {}
    # Mineclonia changes the weather by itself; a storm arrived part way
    # through the first run. A clear spell longer than any run.
    control.send("chat", {"text": "/weather clear 100000"})
    # Without fly the player drops from a tp in the air, and the server
    # streams around where it lands.
    control.send("fly", {"on": True})
    if build:
        control.send("tp", {"x": -36, "y": 92, "z": -424})
        said = control.send("chat", {"text": "/occl_check"})
        print("fixture:", said.get("server_said"), flush=True)
        control.send("chat", {"text": "/occl_zombie 2 5 0"})
    tod, sun = low_sun(control)
    names = list(spec["variants"])
    if not opt.no_timing:
        for place, spot in TIMING_POSES.items():
            if opt.places and place not in opt.places.split(","):
                continue
            control.send("time", {"tod": spot["tod"] if spot["tod"] else tod})
            control.send("tp", {"x": spot["at"][0], "y": spot["at"][1], "z": spot["at"][2]})
            # The server's answer to a tp can land after the pose below
            # and carry the camera off with the player; seen 2026-10-05.
            time.sleep(4.0)
            pose(control, bench, spot)
            time.sleep(20.0)     # shader compiles, far field
            # What was timed, before and after, so a pose that moved shows.
            (out / tier / place).mkdir(parents=True, exist_ok=True)
            control.send("shot", {"path": str(out / tier / place / "scene-before.png"), "warm": 10})
            for r in range(opt.rounds):
                order = names[r % len(names):] + names[:r % len(names)]
                for name in order:
                    apply(control, spec["variants"][name])
                    control.send("wait", {"frames": 30})
                    time.sleep(2.0)
                    run_dir = out / tier / place / ("%s-r%d" % (name, r))
                    if opt.burst:
                        burst(control, run_dir, opt.burst)
                    else:
                        control.send("bench", {"action": "start", "label": name})
                        time.sleep(opt.seconds)
                        control.send("bench", {"action": "stop", "dir": str(run_dir)})
                    g = gpu_times(run_dir / "frames.csv")
                    results.setdefault(place, {}).setdefault(name, []).append(
                        {"median": statistics.median(g), "p95": pct(g, 0.95), "frames": len(g)})
                    (run_dir / "settings.json").write_text(json.dumps(
                        record(control, spec["variants"][name], place, name), indent=2))
                    print("%s %s %s r%d: median %.3f p95 %.3f (%d frames)" % (
                        tier, place, name, r, statistics.median(g), pct(g, 0.95), len(g)),
                        flush=True)
            control.send("shot", {"path": str(out / tier / place / "scene-after.png"),
                                  "settle": False, "warm": 4})
    if not opt.no_frames:
        control.send("time", {"tod": tod})
        # One tp to the platform and then camera poses only. After a run of
        # tps between the poses, the near mesh of the platform's western
        # map block (x -48 to -33) was gone and never came back, though
        # the client still held its nodes; seen twice on 2026-10-05.
        control.send("tp", {"x": -28, "y": 95, "z": -424})
        time.sleep(8.0)
        for place, spot in LOOK_POSES.items():
            pose(control, bench, spot)
            for name, settings in spec["variants"].items():
                apply(control, settings)
                control.send("wait", {"frames": 30})
                shot = out / tier / "frames" / ("%s-%s.png" % (place, name))
                shot.parent.mkdir(parents=True, exist_ok=True)
                control.send("shot", {"path": str(shot), "warm": 20})
                shot.with_suffix(".settings.json").write_text(json.dumps(
                    dict(record(control, settings, place, name), tod=tod, sun=sun), indent=2))
        # The player, from in front, beside the zombie.
        control.send("set", {"key": "show_body", "value": 1.0})
        control.send("pose", {"x": -37.0, "y": 92.6, "z": -424.0, "yaw": 90.0, "fly": True})
        control.send("run", {"src": "main._set_camera_mode(2)\nreturn true"})
        for name, settings in spec["variants"].items():
            apply(control, settings)
            control.send("wait", {"frames": 30})
            shot = out / tier / "frames" / ("player-%s.png" % name)
            shot.parent.mkdir(parents=True, exist_ok=True)
            control.send("shot", {"path": str(shot), "warm": 20})
            shot.with_suffix(".settings.json").write_text(json.dumps(
                dict(record(control, settings, "player", name), tod=tod), indent=2))
        control.send("run", {"src": "main._set_camera_mode(0)\nreturn true"})
        control.send("set", {"key": "show_body", "value": 0.0})
    return results


def summarise(results):
    summary = {}
    for tier, places in results.items():
        for place, variants in places.items():
            for name, runs in variants.items():
                meds = [r["median"] for r in runs]
                p95s = [r["p95"] for r in runs]
                summary["%s/%s/%s" % (tier, place, name)] = {
                    "gpu_median_ms": statistics.median(meds),
                    "median_range": [min(meds), max(meds)],
                    "gpu_p95_ms": statistics.median(p95s),
                    "p95_range": [min(p95s), max(p95s)],
                    "rounds": len(runs), "frames": sum(r["frames"] for r in runs)}
    return summary


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--tiers", default="low,medium")
    ap.add_argument("--rounds", type=int, default=ROUNDS)
    ap.add_argument("--seconds", type=float, default=SECONDS)
    ap.add_argument("--no-timing", action="store_true")
    ap.add_argument("--burst", type=int, default=0,
                    help="time N back to back draws per sample instead of SECONDS of play")
    ap.add_argument("--no-frames", action="store_true")
    ap.add_argument("--places", default="", help="timing poses to run, comma separated")
    # --hold TIER starts the server and a client at that tier and keeps them
    # until OUT/stop exists, for driving by hand; --attach TIER measures on
    # a client already held that way. Run --hold under the GPU lock.
    ap.add_argument("--hold")
    ap.add_argument("--attach")
    ap.add_argument("--build", action="store_true", help="with --attach: lay the fixture")
    opt = ap.parse_args()
    out = pathlib.Path(opt.out)
    out.mkdir(parents=True, exist_ok=True)
    bench = load_bench()
    if opt.attach:
        control = bench.Control("127.0.0.1", CONTROL_PORT)
        res = {opt.attach: measure_tier(control, bench, opt.attach, out, opt, opt.build)}
        name = "summary-%s.json" % opt.attach
        (out / name).write_text(json.dumps({"runs": res, "summary": summarise(res)}, indent=2))
        print(json.dumps(summarise(res), indent=2))
        return
    gpu_is_ours()
    server = start_server(out)
    results = {}
    try:
        if opt.hold:
            ident = start_client(out, opt.hold, TIERS[opt.hold]["size"])
            try:
                bench.wait_ready(bench.Control("127.0.0.1", CONTROL_PORT))
                (out / "holding").write_text(ident + "\n")
                while not (out / "stop").exists():
                    time.sleep(1.0)
            finally:
                stop_client(ident)
            return
        built = False
        for tier in opt.tiers.split(","):
            ident = start_client(out, tier, TIERS[tier]["size"])
            try:
                control = bench.Control("127.0.0.1", CONTROL_PORT)
                bench.wait_ready(control)
                results[tier] = measure_tier(control, bench, tier, out, opt, not built)
                built = True
            finally:
                stop_client(ident)
    finally:
        stop_server(server)
    summary = summarise(results)
    (out / "summary.json").write_text(json.dumps({"runs": results, "summary": summary}, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
