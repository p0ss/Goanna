#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Capture ice geometry/material diagnostics on an isolated Mineclonia server."""
import argparse
import json
import socket
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("stage", help="Label such as before or after")
parser.add_argument("--port", type=int, default=30862)
parser.add_argument("--output", type=Path, default=Path("build/ice-review"))
parser.add_argument("--create-fixture", action="store_true",
                    help="Build the test pool in the disposable world")
args = parser.parse_args()

def call(command, **params):
    with socket.create_connection(("127.0.0.1", args.port), timeout=10) as sock:
        sock.settimeout(180)
        sock.sendall((json.dumps({"id": 1, "cmd": command, "args": params}) + "\n").encode())
        result = json.loads(sock.makefile("r").readline())
    if not result.get("ok"):
        raise RuntimeError(result)
    return result["result"]

def run(source):
    result = call("run", src=source)
    if result.get("value") is None:
        raise RuntimeError("Client snippet failed; inspect the client log")
    return result

out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
stage = args.stage
if args.create_fixture:
    reply = call("chat", text="/ice_review")
    if reply.get("refused"):
        raise RuntimeError(reply)
    print(reply, flush=True)
call("time", tod=0.5, server=True)
call("set", key="far_distance", value=128)
views={'above':(9,85,12,-23,48),'side':(5,79.1,8,0,65),'below':(-3,76.5,8,23,0),'edge':(5,80.2,8,-8,65),'top-close':(-1,81.5,8,-65,65),'relief-close':(-1,81.5,4,-2,45)}
for name,(x,y,z,pitch,yaw) in views.items():
 run('Engine.time_scale=1.0; main.set_process(true); return true')
 call('pose',x=x,y=y,z=z,pitch=pitch,yaw=yaw)
 time.sleep(8)
 call('wait',settle=True)
 run('main.set_process(false); Engine.time_scale=0.0; return true')
 call('wait',frames=48)
 r=call('shot',path=str(out/f'{name}-{stage}.png'),settle=False,warm=0)
 r['stats']=call('inspect',target='render')
 r['ice']=call('get',key='solid_ice')
 (out/f'{name}-{stage}.json').write_text(json.dumps(r,indent=2))
 print(name,stage,flush=True)
