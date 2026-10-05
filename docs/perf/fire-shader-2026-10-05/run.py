#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Photograph and time the flame material (docs/fire-material.md).

Adapted from docs/perf/low-tier-occlusion-2026-10-05/run.py, whose rules it
keeps. Run --hold only under the GPU lock, from the checkout whose build is
under test:

    flock /tmp/claude-1000/goanna-gpu.lock \\
        python3 run.py OUT --hold medium &        # server and client, kept
    python3 run.py OUT --attach medium --frames   # old against new
    python3 run.py OUT --attach medium --timing --rounds 12 --burst 600
    touch OUT/stop                                # stops both, frees the lock

--hold refuses to start unless `tools/goanna-headless gpu-free` reports
free with no driver errors and nvidia-smi lists no compute user outside
the desktop's own. It starts one Luanti server on WORLD (a reflink copy of
test_world with fixture/ installed as a worldmod) and one headless client
at the tier's resolution with a fresh profile written for the tier.

Old and new are one client switched live: GoannaClient.set_flame_material
rebuilds the materials and remeshes the near blocks, and the burning
entity's sprite takes the switch at its next frame. The node animation
clock is pinned for frames, which pins the game's frame and the flicker.
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
WORLD = "goanna_fire_1005"
SERVER_PORT = 30919
CONTROL_PORT = 30959
GODOT = "/home/poss/Documents/Code/Godot/Godot_v4.5.1-stable_linux.x86_64"
PACK = REPO / "pbr_packs" / "mineclonia" / "textures"
DESKTOP_GPU_USERS = ("kwin_wayland", "Xwayland", "freetube", "plasmashell", "firefox")

TIERS = {
    "low": {"size": (1280, 800)},
    "medium": {"size": (1920, 1080)},
}

# Variants: the flame material on or off, and the shimmer gate. "old" is
# the emissive cut-out drawn before 2026-10-05.
VARIANTS = {
    "old": {"flame": False, "render_fire_shimmer": 0},
    "new_flat": {"flame": True, "render_fire_shimmer": 0},
    "new": {"flame": True, "render_fire_shimmer": 1},
}
TIMED = {"low": ["old", "new_flat"], "medium": ["old", "new_flat", "new"]}

# Goanna coordinates: Luanti's with z negated. The fixture platform is at
# Luanti (-40, 90, 420); its top is y 90.5.
POSES = {
    "campfire": {"at": (-40.0, 92.4, -421.6), "aim": (-40.0, 91.3, -424.0)},
    "netherrack": {"at": (-37.0, 93.1, -421.4), "aim": (-37.0, 92.1, -424.0)},
    "soul": {"at": (-34.0, 93.1, -421.4), "aim": (-34.0, 92.1, -424.0)},
    "candle": {"at": (-31.0, 91.9, -422.6), "aim": (-31.0, 91.2, -424.0)},
    "zombie": {"at": (-28.0, 92.6, -421.2), "aim": (-28.0, 92.0, -424.0)},
    "water": {"at": (-38.0, 93.4, -423.2), "aim": (-38.0, 91.4, -429.5)},
    "glass": {"at": (-30.0, 92.8, -424.4), "aim": (-30.0, 92.2, -428.6)},
    "field": {"at": (-18.0, 93.0, -418.6), "aim": (-18.0, 92.3, -424.0)},
}
TIMING_POSE = "field"
TIMES = {"day": 0.5, "night": 0.0}


def load_bench():
    spec = importlib.util.spec_from_file_location("goanna_bench", REPO / "tools" / "goanna-bench.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def profiles():
    spec = importlib.util.spec_from_file_location("cbp", REPO / "tools" / "check-bench-plans.py")
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
    # Only this server's own process tree, found from the PID started here;
    # the flatpak PID alone leaves luanti.bin holding the port.
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


def gpu_free():
    out = subprocess.run([str(REPO / "tools" / "goanna-headless"), "gpu-free"],
                         capture_output=True, text=True)
    try:
        state = json.loads(out.stdout)
    except ValueError:
        return False
    return bool(state.get("free")) and not state.get("driver_errors")


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
         "--server", "127.0.0.1:%d" % SERVER_PORT, "--name", "fire",
         "--size", "%dx%d" % size, "--label", "fire review " + tier,
         "--env", "XDG_DATA_HOME=%s" % xdg, "--env", "GOANNA_BENCH=1",
         "--env", "GOANNA_NO_HW_DEFAULTS=1"],
        capture_output=True, text=True, env=env)
    if got.returncode:
        print("client did not start:\n" + got.stdout + got.stderr, flush=True)
        return None
    return re.search(r"goanna-\d+", got.stdout).group(0)


def stop_client(ident):
    subprocess.run([str(REPO / "tools" / "goanna-headless"), "stop", ident])


def apply(control, bench, variant):
    v = VARIANTS[variant]
    control.send("set", {"key": "render_fire_shimmer", "value": float(v["render_fire_shimmer"])})
    now = control.send("run", {"src": "return main.client.flame_material()"})
    now = now.get("value") if isinstance(now, dict) else now
    if bool(now) != v["flame"]:
        control.send("run", {"src": "main.client.set_flame_material(%s)\nreturn true"
                             % ("true" if v["flame"] else "false")})
        control.send("wait", {"frames": 10})
        bench.wait_quiet(control, 3.0, 120.0, "the remesh")


def record(control, variant, place):
    """The profile and the flame state as the client holds them."""
    held = {k: control.send("get", {"key": k}) for k in
            ("render_fire_shimmer", "light_sdfgi", "render_bloom", "mat_parallax",
             "mat_micro_shadow", "light_pool", "shadow_lamps")}
    flame = control.send("run", {"src": "return main.client.flame_material()"})
    return {"variant": variant, "asked": VARIANTS[variant], "held": held,
            "flame_material": flame, "place": place}


def pose(control, bench, spot):
    control.send("fly", {"on": True})
    control.send("pose", {"x": spot["at"][0], "y": spot["at"][1], "z": spot["at"][2],
                          "fly": True})
    control.send("look", {"x": spot["aim"][0], "y": spot["aim"][1], "z": spot["aim"][2]})
    bench.wait_quiet(control, 4.0, 120.0)
    time.sleep(1.0)


def gpu_times(path):
    out = []
    with open(path) as f:
        next(f)
        for line in f:
            out.append(float(line.split(",")[3]))
    return out


# Back to back draws without presenting (see the occlusion run.py for why).
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


def setup(control):
    control.send("chat", {"text": "/weather clear 100000"})
    control.send("fly", {"on": True})
    control.send("tp", {"x": -34, "y": 93, "z": -424})
    time.sleep(4.0)
    print("fixture:", control.send("chat", {"text": "/fire_check"}).get("server_said"), flush=True)


def frames(control, bench, tier, out, variants, places):
    # The zombie is spawned once the client is there to keep its block active.
    said = control.send("chat", {"text": "/fire_check"}).get("server_said")
    if " zombies 0" in str(said):
        control.send("chat", {"text": "/fire_zombie 12 4 0"})
        time.sleep(3.0)
    for tod_name, tod in TIMES.items():
        control.send("time", {"tod": tod})
        for place in places:
            spot = POSES[place]
            for name in variants:
                apply(control, bench, name)
                pose(control, bench, spot)
                # Pinned: the game's frame and the flicker are the same in
                # every variant of a pose.
                control.send("run", {"src": "main.client.set_node_animation_time(12.3)\nreturn true"})
                control.send("wait", {"frames": 20})
                shot = out / tier / "frames" / ("%s_%s-%s.png" % (place, tod_name, name))
                shot.parent.mkdir(parents=True, exist_ok=True)
                control.send("shot", {"path": str(shot), "warm": 20})
                shot.with_suffix(".settings.json").write_text(json.dumps(
                    dict(record(control, name, place), tod=tod), indent=2))
                print("shot", shot, flush=True)
            control.send("run", {"src": "main.client.set_node_animation_time(-1.0)\nreturn true"})


def timing(control, bench, tier, out, opt):
    results = {}
    names = TIMED[tier]
    control.send("time", {"tod": 0.0})
    spot = POSES[TIMING_POSE]
    apply(control, bench, names[0])
    pose(control, bench, spot)
    time.sleep(10.0)
    (out / tier / "timing").mkdir(parents=True, exist_ok=True)
    control.send("shot", {"path": str(out / tier / "timing" / "scene-before.png"), "warm": 10})
    for r in range(opt.rounds):
        order = names[r % len(names):] + names[:r % len(names)]
        for name in order:
            apply(control, bench, name)
            pose(control, bench, spot)
            control.send("wait", {"frames": 30})
            run_dir = out / tier / "timing" / ("%s-r%d" % (name, r))
            burst(control, run_dir, opt.burst)
            g = gpu_times(run_dir / "frames.csv")
            results.setdefault(name, []).append(
                {"median": statistics.median(g), "p95": pct(g, 0.95), "frames": len(g)})
            (run_dir / "settings.json").write_text(json.dumps(record(control, name, TIMING_POSE), indent=2))
            print("%s %s r%d: median %.3f p95 %.3f" % (tier, name, r, statistics.median(g),
                                                      pct(g, 0.95)), flush=True)
    control.send("shot", {"path": str(out / tier / "timing" / "scene-after.png"),
                          "settle": False, "warm": 4})
    summary = {}
    for name, runs in results.items():
        meds = [x["median"] for x in runs]
        p95s = [x["p95"] for x in runs]
        summary[name] = {"gpu_median_ms": statistics.median(meds), "median_range": [min(meds), max(meds)],
                         "gpu_p95_ms": statistics.median(p95s), "rounds": len(runs),
                         "frames": sum(x["frames"] for x in runs)}
    (out / ("timing-%s.json" % tier)).write_text(json.dumps({"runs": results, "summary": summary}, indent=2))
    print(json.dumps(summary, indent=2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--hold")
    ap.add_argument("--attach")
    ap.add_argument("--frames", action="store_true")
    ap.add_argument("--places", default=",".join(POSES))
    ap.add_argument("--variants", default="old,new")
    ap.add_argument("--timing", action="store_true")
    ap.add_argument("--rounds", type=int, default=12)
    ap.add_argument("--burst", type=int, default=600)
    opt = ap.parse_args()
    out = pathlib.Path(opt.out)
    out.mkdir(parents=True, exist_ok=True)
    bench = load_bench()
    if opt.attach:
        control = bench.Control("127.0.0.1", CONTROL_PORT)
        setup(control)
        if opt.frames:
            frames(control, bench, opt.attach, out, opt.variants.split(","), opt.places.split(","))
        if opt.timing:
            timing(control, bench, opt.attach, out, opt)
        return
    # The server uses no GPU and starts first. Other agents' clients come
    # and go; the client is started the moment the GPU is free, and again
    # if one arrived first (the launcher refuses then).
    server = start_server(out)
    try:
        ident = None
        for attempt in range(400):
            if (out / "stop").exists():
                return
            while not gpu_free() and not (out / "stop").exists():
                time.sleep(2.0)
            if (out / "stop").exists():
                return
            gpu_is_ours()
            ident = start_client(out, opt.hold, TIERS[opt.hold]["size"])
            if ident:
                break
            time.sleep(3.0)
        if not ident:
            sys.exit("the GPU never came free for the client")
        try:
            bench.wait_ready(bench.Control("127.0.0.1", CONTROL_PORT))
            (out / "holding").write_text(ident + "\n")
            while not (out / "stop").exists():
                time.sleep(1.0)
        finally:
            stop_client(ident)
    finally:
        stop_server(server)


if __name__ == "__main__":
    main()
