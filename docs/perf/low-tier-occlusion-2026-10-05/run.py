#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Measure and photograph micro shadows and the short parallax march.

Not yet run: written on 2026-10-05 while the GPU was in the owner's use.
Run it only under the GPU lock, from the checkout
whose build is under test:

    flock /tmp/claude-1000/goanna-gpu.lock \\
        python3 docs/perf/low-tier-occlusion-2026-10-05/run.py OUT_DIR

It refuses to start unless `tools/goanna-headless gpu-free` reports free
with no driver errors and nvidia-smi lists no compute user outside the
desktop's own. It starts one Luanti server on WORLD (a reflink copy of
test_world with fixture/ installed as a worldmod), then one headless
client per tier at that tier's resolution, each with a fresh profile
written for the tier, and stops both before it exits.

Timing: the variants of a tier are switched live and taken in rotation,
ROUNDS rounds of SECONDS each, so drift lands on every variant alike. Each
sample's per frame GPU times are kept; the summary gives the median and
95th percentile of each sample and their spread across rounds.

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

# Luanti coordinates, as the benchmark plans use them. The vista is the
# benchmark scene (docs/benchmark.md); the rest are on the fixture platform
# (fixture/init.lua, ORIGIN -40, 90, 420).
TIMING_POSES = {
    "vista": {"at": (-72, 54, 378), "aim": (-100, 46, 342), "tod": 0.5},
    "wall": {"at": (-34.5, 92.0, 422.5), "aim": (-32.5, 92.0, 422.5), "tod": None},
}
LOOK_POSES = {
    "cobble_west": {"at": (-35.5, 92.0, 421.5), "aim": (-32.5, 92.0, 421.5)},
    "brick_west": {"at": (-35.5, 92.0, 430.5), "aim": (-32.5, 92.0, 430.5)},
    "stonebrick_west": {"at": (-35.5, 92.0, 427.5), "aim": (-32.5, 92.0, 427.5)},
    "cobble_south": {"at": (-40.5, 92.0, 429.5), "aim": (-40.5, 92.0, 432.5)},
    "brick_south": {"at": (-31.5, 92.0, 429.5), "aim": (-31.5, 92.0, 432.5)},
    "log": {"at": (-38.5, 92.5, 422.0), "aim": (-36.0, 92.5, 422.0)},
    "zombie": {"at": (-38.0, 92.6, 422.6), "aim": (-38.0, 92.2, 425.0)},
}


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
    time.sleep(8.0)
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
        dirn = control.send("run", {"src": "var d := -main.sun.global_transform.basis.z\n"
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


def pct(values, q):
    s = sorted(values)
    return s[min(len(s) - 1, int(q * len(s)))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--tiers", default="low,medium")
    opt = ap.parse_args()
    out = pathlib.Path(opt.out)
    out.mkdir(parents=True, exist_ok=True)
    gpu_is_ours()
    bench = load_bench()
    server = start_server(out)
    results = {}
    try:
        built = False
        for tier in opt.tiers.split(","):
            spec = TIERS[tier]
            ident = start_client(out, tier, spec["size"])
            try:
                control = bench.Control("127.0.0.1", CONTROL_PORT)
                bench.wait_ready(control)
                control.send("weather", {"kind": "clear"})
                if not built:
                    control.send("tp", {"x": -36, "y": 91, "z": 424})
                    control.send("chat", {"text": "/occl_build"})
                    control.send("chat", {"text": "/occl_zombie 2 5 0"})
                    built = True
                tod, sun = low_sun(control)
                names = list(spec["variants"])
                for place, spot in TIMING_POSES.items():
                    control.send("time", {"tod": spot["tod"] if spot["tod"] else tod})
                    control.send("tp", {"x": spot["at"][0], "y": spot["at"][1], "z": spot["at"][2]})
                    pose(control, bench, spot)
                    time.sleep(20.0)     # shader compiles, far field
                    for r in range(ROUNDS):
                        order = names[r % len(names):] + names[:r % len(names)]
                        for name in order:
                            apply(control, spec["variants"][name])
                            control.send("wait", {"frames": 30})
                            time.sleep(2.0)
                            run_dir = out / tier / place / ("%s-r%d" % (name, r))
                            control.send("bench", {"action": "start", "label": name})
                            time.sleep(SECONDS)
                            control.send("bench", {"action": "stop", "dir": str(run_dir)})
                            g = gpu_times(run_dir / "frames.csv")
                            results.setdefault(tier, {}).setdefault(place, {}).setdefault(
                                name, []).append({"median": statistics.median(g),
                                                  "p95": pct(g, 0.95), "frames": len(g)})
                            (run_dir / "settings.json").write_text(json.dumps(
                                record(control, spec["variants"][name], place, name),
                                indent=2))
                control.send("time", {"tod": tod})
                for place, spot in LOOK_POSES.items():
                    control.send("tp", {"x": spot["at"][0], "y": spot["at"][1], "z": spot["at"][2]})
                    pose(control, bench, spot)
                    for name, settings in spec["variants"].items():
                        apply(control, settings)
                        control.send("wait", {"frames": 30})
                        shot = out / tier / "frames" / ("%s-%s.png" % (place, name))
                        shot.parent.mkdir(parents=True, exist_ok=True)
                        control.send("shot", {"path": str(shot), "warm": 20})
                        shot.with_suffix(".settings.json").write_text(json.dumps(
                            dict(record(control, settings, place, name),
                                 tod=tod, sun=sun), indent=2))
                # The player, from in front, beside the zombie.
                control.send("set", {"key": "show_body", "value": 1.0})
                control.send("pose", {"x": -37.0, "y": 92.6, "z": 424.0, "yaw": 90.0, "fly": True})
                control.send("run", {"src": "main._set_camera_mode(2)\nreturn true"})
                for name, settings in spec["variants"].items():
                    apply(control, settings)
                    control.send("wait", {"frames": 30})
                    shot = out / tier / "frames" / ("player-%s.png" % name)
                    control.send("shot", {"path": str(shot), "warm": 20})
                    shot.with_suffix(".settings.json").write_text(json.dumps(
                        dict(record(control, settings, "player", name), tod=tod), indent=2))
                control.send("run", {"src": "main._set_camera_mode(0)\nreturn true"})
                control.send("set", {"key": "show_body", "value": 0.0})
            finally:
                stop_client(ident)
    finally:
        stop_server(server)
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
    (out / "summary.json").write_text(json.dumps({"runs": results, "summary": summary}, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
