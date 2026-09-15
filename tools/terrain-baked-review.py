#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Capture baked horizon loading and a fixed aerial route on the Asuna fixture."""
import argparse
import json
from pathlib import Path
import socket
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--port", type=int, default=30863)
parser.add_argument("--out", type=Path, required=True)
parser.add_argument("--seconds", type=int, default=60)
parser.add_argument("--flight", action="store_true")
args = parser.parse_args()
args.out = args.out.resolve()
args.out.mkdir(parents=True, exist_ok=True)


def call(command, **params):
    with socket.create_connection(("127.0.0.1", args.port), timeout=5) as stream:
        stream.settimeout(60)
        stream.sendall((json.dumps({"id": 1, "cmd": command, "args": params}) + "\n").encode())
        reply = json.loads(stream.makefile("r").readline())
    if not reply.get("ok"):
        raise RuntimeError(reply)
    return reply["result"]


deadline = time.monotonic() + 60
while True:
    try:
        if call("status").get("state") == "ready":
            break
    except OSError:
        pass
    if time.monotonic() > deadline:
        raise RuntimeError("review client did not become ready")
    time.sleep(0.25)

pose = dict(x=643.061096, y=530.882629, z=-31.118299, pitch=-20, yaw=310.49)
call("pose", **pose)
call("bench", action="start", label="baked-surface", phase="move_early" if args.flight else "load")
if args.flight:
    call("route", mode="fly", points=[[643, 700, -31], [2643, 850, -2031]],
         speed=80, loop=False, aim="fixed", pitch=-20, yaw=310.49)
start = time.monotonic()
try:
    with (args.out / "observations.jsonl").open("w") as file:
        for second in range(args.seconds):
            stats = call("inspect", target="render")
            row = {"t": time.monotonic() - start, "render": stats}
            file.write(json.dumps(row) + "\n")
            file.flush()
            if second % 5 == 0:
                print(json.dumps({"second": second, **{key: stats.get(key) for key in (
                    "surface_tiles", "surface_wanted", "surface_reach", "surface_uploads",
                    "surface_first_ms", "surface_overview_ms", "surface_retired", "lod_update_ms")}}),
                      flush=True)
            time.sleep(max(0, start + second + 1 - time.monotonic()))
finally:
    if args.flight:
        call("route", action="stop")
    print(json.dumps(call("bench", action="stop", dir=str(args.out / "timing"))), flush=True)
call("shot", path=str(args.out / "landscape.png"), settle=False, warm=0)
(args.out / "status.json").write_text(json.dumps(call("status"), indent=2) + "\n")
(args.out / "render.json").write_text(json.dumps(call("inspect", target="render"), indent=2) + "\n")
