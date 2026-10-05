#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Measure the texture resolution tier: video memory, GPU time and frames.

Run it only under the GPU lock, from the checkout whose build is under
test:

    flock /tmp/claude-1000/goanna-gpu.lock python3 run.py OUT \\
        --pack 256=PACK256 --pack 128=PACK128 --pack 512=PACK512

Each configuration is a pack and a texture_size. The setting applies when
a world's textures are loaded, so every configuration is its own client
session, joined fresh to one server kept for the whole run; sessions are
taken in rotation over --rounds, so drift lands on every configuration
alike. Every session runs the Medium profile at 1920x1080 with only
texture_size changed, so the difference is the textures' own.

In each session: the benchmark vista at noon (docs/benchmark.md), settled,
then Godot's video memory monitors, then --samples bursts of --burst draws
back to back without presenting (the occlusion review's method, see
docs/perf/low-tier-occlusion-2026-10-05/run.py, BURST_SRC); then the same
at a stone wall on the occlusion fixture's platform, close enough that the
wall fills the frame, and the monitors again. In the first round, frames
at a low sun: the stone, cobble and stone brick walls and the held zombie.

--hold and --attach are not offered: a session per configuration is the
point. The refusals of the occlusion driver apply: it starts nothing
unless `tools/goanna-headless gpu-free` reports free with no driver errors
and nvidia-smi lists no compute user outside the desktop's own.
"""

import argparse
import importlib.util
import json
import pathlib
import re
import statistics
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
SIZE = (1920, 1080)
PROFILE = "medium"


def occl():
    spec = importlib.util.spec_from_file_location(
        "occl_run", REPO / "docs" / "perf" / "low-tier-occlusion-2026-10-05" / "run.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    # Ports of this run's own, so it cannot meet a held occlusion review.
    mod.SERVER_PORT = 30918
    mod.CONTROL_PORT = 30958
    return mod


O = occl()
BENCH = O.load_bench()

# Goanna coordinates, as the occlusion driver's. The walls face -x toward a
# low afternoon sun; the stone wall is the fixture's second, at Luanti z 423
# to 425. The zombie stands in the platform's eastern map block: in the
# first run the western one's near mesh was lost after the tps, as the
# occlusion review saw, and the zombie frame showed open sky.
VISTA = {"at": (-72, 54, 378), "aim": (-100, 46, 342)}
WALL = {"at": (-34.5, 92.0, -424.0), "aim": (-32.5, 92.0, -424.0)}
LOOKS = {
    "stone_wall": {"at": (-35.5, 92.0, -424.0), "aim": (-32.5, 92.0, -424.0)},
    "cobble_wall": {"at": (-35.5, 92.0, -421.0), "aim": (-32.5, 92.0, -421.0)},
    "stonebrick_wall": {"at": (-35.5, 92.0, -427.0), "aim": (-32.5, 92.0, -427.0)},
    "zombie": {"at": (-29.0, 92.6, -427.4), "aim": (-29.0, 92.2, -425.0)},
}

MEMORY_SRC = """return [Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED),
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED),
		Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED),
		main.client.texture_size(), main.client.texture_size_applied()]"""


def write_profile(root, pack, size):
    cfg = root / "godot" / "app_userdata" / "Goanna"
    cfg.mkdir(parents=True, exist_ok=True)
    table = dict(O.profiles()[PROFILE])
    table["texture_size"] = float(size)
    lines = ["[settings]", "", 'graphics_profile="%s"' % PROFILE, 'texture_pack="%s"' % pack,
             "show_body=0", "asset_updates=false", "material_updates=false"]
    lines += ["%s=%s" % kv for kv in sorted(table.items())]
    (cfg / "goanna.cfg").write_text("\n".join(lines) + "\n")


def start_client(out, label, pack, size):
    wrapper = out / "godot-dummy-audio"
    wrapper.write_text('#!/bin/sh\nexec %s --audio-driver Dummy "$@"\n' % O.GODOT)
    wrapper.chmod(0o755)
    xdg = out / ("xdg-" + label)
    if xdg.exists():
        subprocess.run(["rm", "-rf", str(xdg)], check=True)
    write_profile(xdg, pack, size)
    env = dict(O.os.environ, GODOT_BIN=str(wrapper))
    got = subprocess.run(
        [str(REPO / "tools" / "goanna-headless"), "start", "--cpu-compositor",
         "--project", str(REPO), "--control-port", str(O.CONTROL_PORT),
         "--server", "127.0.0.1:%d" % O.SERVER_PORT, "--name", "texsize",
         "--size", "%dx%d" % SIZE, "--label", "texture size review " + label,
         "--env", "XDG_DATA_HOME=%s" % xdg, "--env", "GOANNA_BENCH=1",
         "--env", "GOANNA_NO_HW_DEFAULTS=1", "--env", "GOANNA_TEXTURE_SIZE=%d" % size],
        capture_output=True, text=True, env=env)
    (out / ("start-%s.txt" % label)).write_text(got.stdout + got.stderr)
    if got.returncode:
        sys.exit("client did not start:\n" + got.stdout + got.stderr)
    ident = re.search(r"goanna-\d+", got.stdout).group(0)
    logs = re.findall(r"(/\S+/output\.log)", got.stdout + got.stderr)
    return ident, (logs[0] if logs else None)


def memory(control):
    got = control.send("run", {"src": MEMORY_SRC})
    v = got.get("value") if isinstance(got, dict) else got
    return {"texture_mib": v[0] / 2 ** 20, "video_mib": v[1] / 2 ** 20,
            "buffer_mib": v[2] / 2 ** 20, "texture_size": v[3], "applied": v[4]}


def time_here(control, run_dir, samples, draws):
    meds = []
    for s in range(samples):
        d = run_dir / ("s%d" % s)
        O.burst(control, d, draws)
        g = O.gpu_times(d / "frames.csv")
        meds.append({"median": statistics.median(g), "p95": O.pct(g, 0.95), "frames": len(g)})
    return meds


def session(control, out, label, first_round, opt, tod_low):
    res = {}
    control.send("chat", {"text": "/weather clear 100000"})
    control.send("fly", {"on": True})
    if first_round and not opt.zombie_done:
        control.send("tp", {"x": -36, "y": 92, "z": -424})
        time.sleep(6.0)
        said = control.send("chat", {"text": "/occl_check"})
        print("fixture:", said.get("server_said"), flush=True)
        control.send("chat", {"text": "/occl_zombie 11 5 0"})
        opt.zombie_done = True
    # The vista at noon.
    control.send("time", {"tod": 0.5})
    control.send("tp", {"x": VISTA["at"][0], "y": VISTA["at"][1], "z": VISTA["at"][2]})
    time.sleep(4.0)
    O.pose(control, BENCH, VISTA)
    time.sleep(opt.settle)
    d = out / label
    d.mkdir(parents=True, exist_ok=True)
    control.send("shot", {"path": str(d / "vista.png"), "warm": 10})
    res["vista_memory"] = memory(control)
    res["vista"] = time_here(control, d / "vista", opt.samples, opt.burst)
    # The wall, close.
    control.send("time", {"tod": tod_low})
    control.send("tp", {"x": -28, "y": 95, "z": -424})
    time.sleep(8.0)
    O.pose(control, BENCH, WALL)
    time.sleep(10.0)
    control.send("shot", {"path": str(d / "wall.png"), "warm": 10})
    res["wall"] = time_here(control, d / "wall", opt.samples, opt.burst)
    res["wall_memory"] = memory(control)
    if first_round:
        for name, spot in LOOKS.items():
            O.pose(control, BENCH, spot)
            control.send("wait", {"frames": 30})
            shot = out / "frames" / ("%s-%s.png" % (name, label))
            shot.parent.mkdir(parents=True, exist_ok=True)
            control.send("shot", {"path": str(shot), "warm": 20})
        res["after_frames_memory"] = memory(control)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--pack", action="append", required=True,
                    help="LABEL=DIR[:SIZE], e.g. 256to128=/path/pack256:128")
    ap.add_argument("--rounds", type=int, default=2)
    ap.add_argument("--samples", type=int, default=4)
    ap.add_argument("--burst", type=int, default=400)
    ap.add_argument("--settle", type=float, default=30.0)
    opt = ap.parse_args()
    opt.zombie_done = False
    out = pathlib.Path(opt.out)
    out.mkdir(parents=True, exist_ok=True)
    configs = []
    for p in opt.pack:
        label, rest = p.split("=", 1)
        pack, size = rest.rsplit(":", 1)
        configs.append((label, pack, int(size)))
    O.gpu_is_ours()
    server = O.start_server(out)
    results = {}
    try:
        tod_low = 0.74
        for r in range(opt.rounds):
            order = configs[r % len(configs):] + configs[:r % len(configs)]
            for label, pack, size in order:
                ident, log = start_client(out, label, pack, size)
                try:
                    control = BENCH.Control("127.0.0.1", O.CONTROL_PORT)
                    BENCH.wait_ready(control)
                    if r == 0 and label == order[0][0]:
                        tod_low, _ = O.low_sun(control)
                    res = session(control, out, "%s-r%d" % (label, r), r == 0, opt, tod_low)
                    res["config"] = {"pack": pack, "texture_size": size, "round": r}
                    if log and pathlib.Path(log).exists():
                        res["pack_line"] = [l for l in pathlib.Path(log).read_text(
                            errors="replace").splitlines() if "Goanna texture pack" in l]
                    results.setdefault(label, []).append(res)
                    print(label, r, json.dumps({k: v for k, v in res.items()
                                                if k.endswith("memory") or k == "pack_line"}),
                          flush=True)
                    for place in ("vista", "wall"):
                        print("   %s gpu medians %s" % (place, [round(m["median"], 3) for m in res[place]]),
                              flush=True)
                finally:
                    O.stop_client(ident)
                    time.sleep(5.0)
                (out / "results.json").write_text(json.dumps(results, indent=2))
    finally:
        O.stop_server(server)
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
