#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Record near/far handoffs on the disposable terrain flight fixture."""
import argparse
import json
from pathlib import Path
import socket
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--port", type=int, default=30863)
parser.add_argument("--out", type=Path, required=True)
args = parser.parse_args()
args.out = args.out.resolve()
args.out.mkdir(parents=True, exist_ok=True)


def call(command, **params):
    with socket.create_connection(("127.0.0.1", args.port), timeout=10) as stream:
        stream.settimeout(60)
        stream.sendall((json.dumps({"id": 1, "cmd": command, "args": params}) + "\n").encode())
        reply = json.loads(stream.makefile("r").readline())
    if not reply.get("ok"):
        raise RuntimeError(reply)
    return reply["result"]


call("pose", x=-4000, y=572, z=-4000, pitch=-35, yaw=180)
time.sleep(3)
call("bench", action="start", label="terrain-descent", phase="move_early")
recording = True
try:
    for name, points in [
        ("descent", [[-4000, 572, -4000], [-4000, 465, -4000]]),
        ("ascent", [[-4000, 465, -4000], [-4000, 572, -4000]]),
    ]:
        call("route", mode="fly", points=points, speed=8, loop=False,
             aim="fixed", pitch=-35, yaw=180)
        for second in range(15):
            time.sleep(1)
            row = {"leg": name, "second": second, "status": call("status"),
                   "render": call("inspect", target="render")}
            with (args.out / "observations.jsonl").open("a") as file:
                file.write(json.dumps(row) + "\n")
        call("route", action="stop")
        # Stop the timing recorder before PNG encoding, which stalls a frame.
        print(json.dumps(call("bench", action="stop", dir=str(args.out / name))), flush=True)
        recording = False
        call("shot", path=str(args.out / (name + ".png")), settle=False, warm=0)
        if name == "descent":
            time.sleep(10)
            call("shot", path=str(args.out / "low-held.png"), settle=False, warm=0)
            call("bench", action="start", label="terrain-ascent", phase="move_early")
            recording = True
finally:
    try:
        call("route", action="stop")
    finally:
        if recording:
            call("bench", action="stop", dir=str(args.out / "interrupted"))
