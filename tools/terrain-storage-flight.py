#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Record a storage revisit on the disposable tdl_showcase flight fixture.

Run once, restart the client with the same profile, then run again. The tool
moves the preview camera; it does not clear caches or change world blocks.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import socket
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--port", type=int, default=30863)
parser.add_argument("--out", type=Path, required=True)
parser.add_argument("--probe", type=Path)
args = parser.parse_args()
args.out = args.out.resolve()
args.out.mkdir(parents=True, exist_ok=True)


def call(command, **params):
    with socket.create_connection(("127.0.0.1", args.port), timeout=10) as stream:
        stream.settimeout(180)
        stream.sendall((json.dumps({"id": 1, "cmd": command, "args": params}) + "\n").encode())
        reply = json.loads(stream.makefile("r").readline())
    if not reply.get("ok"):
        raise RuntimeError(reply)
    return reply["result"]


def observe(phase, elapsed):
    status = call("status")
    render = call("inspect", target="render")
    row = {"phase": phase, "elapsed": elapsed, "status": status, "render": render}
    if args.probe:
        for _ in range(10):
            try:
                server = json.loads(args.probe.read_text())
                break
            except ValueError:
                time.sleep(0.02)
        else:
            raise RuntimeError("Cannot read server position probe")
        p = server["position"]
        row["server_error"] = math.dist(status["camera"], [p["x"], p["y"], -p["z"]])
        if row["server_error"] > 128 or time.time() - args.probe.stat().st_mtime > 5:
            raise RuntimeError("Server did not follow the camera")
    with (args.out / "observations.jsonl").open("a") as file:
        file.write(json.dumps(row) + "\n")
    print(phase, elapsed, {k: render.get(k) for k in (
        "lod_storage_hits", "lod_storage_misses", "lod_storage_pending",
        "lod_summary_cache_hits", "lod_summary_cache_writes", "lod_storage_errors")}, flush=True)


call("time", tod=0.5, server=True)
call("chat", text="/weather clear 86400")
call("pose", x=-4000, y=572, z=-4000, pitch=-18, yaw=0)
time.sleep(10)
binary = Path(__file__).resolve().parent.parent / "project/bin/libgoanna.linux.template_debug.x86_64.so"
(args.out / "metadata.json").write_text(json.dumps({
    "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "start": call("status"), "render": call("inspect", target="render"),
    "note": "Storage validation; no claim of settled or matched baseline terrain."
}, indent=2) + "\n")
call("bench", action="start", label="terrain-storage-revisit", phase="move_early")
try:
    points = [[-4000, 572, -4000], [-4000, 654, -5000], [-4000, 693, -5500]]
    for phase, route, yaw in [("outbound", points, 0), ("return", list(reversed(points)), 180)]:
        call("route", mode="fly", points=route, speed=40, loop=False,
             aim="fixed", pitch=-18, yaw=yaw)
        begin = time.monotonic()
        for elapsed in range(0, 41, 10):
            time.sleep(max(0, elapsed - (time.monotonic() - begin)))
            observe(phase, elapsed)
        call("route", action="stop")
    call("bench", action="mark", phase="steady")
    for elapsed in range(10, 31, 10):
        time.sleep(10)
        observe("hold", elapsed)
finally:
    call("route", action="stop")
    print(json.dumps(call("bench", action="stop", dir=str(args.out))), flush=True)

# PNG encoding is a main-thread diagnostic cost, not a flight hitch.
call("shot", path=str(args.out / "held.png"), settle=False, warm=0)
