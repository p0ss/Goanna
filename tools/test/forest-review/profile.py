#!/usr/bin/env python3
"""Profile a repeatable fly-and-stop route on an already running test client.

Requires GOANNA_BENCH=1. Moves the test character; does not edit world blocks.
Checks the fine scheduler's work limits from sampled counters. Frame-time
recording, including one-second renderer samples, uses the existing recorder.
"""
import argparse
import json
from pathlib import Path
import socket
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--port', type=int, default=30871)
p.add_argument('--out', type=Path, required=True)
p.add_argument('--origin', type=float, nargs=3, required=True)
p.add_argument('--side', type=float, default=256)
p.add_argument('--speed', type=float, default=20)
p.add_argument('--hold', type=float, default=60)
a = p.parse_args()
a.out = a.out.resolve()
a.out.mkdir(parents=True, exist_ok=True)


def call(cmd, **args):
    with socket.create_connection(('127.0.0.1', a.port), timeout=5) as s:
        s.settimeout(30)
        s.sendall((json.dumps(dict(id=1, cmd=cmd, args=args))+'\n').encode())
        reply = json.loads(s.makefile().readline())
    if not reply.get('ok'):
        raise RuntimeError(reply)
    return reply['result']


def observe(seconds):
    end = time.monotonic()+seconds
    with (a.out/'observations.jsonl').open('a') as f:
        while time.monotonic() < end:
            r = call('inspect', target='render')
            row = dict(time=time.time(), status=call('status'), render=r)
            f.write(json.dumps(row)+'\n')
            f.flush()
            assert r['fine_scan_entries'] <= 512, 'fine scan exceeded entry budget'
            assert r['fine_pending'] <= 16, 'fine request window exceeded'
            print({k: r[k] for k in ('fine_candidates', 'fine_scan_ms',
                'near_ready', 'lod_storage_built', 'lod_chain_queue')}, flush=True)
            time.sleep(min(5, max(0, end-time.monotonic())))


x, y, z = a.origin
d = a.side
points = [[x,y,z], [x+d,y,z], [x+d,y,z+d], [x,y,z+d], [x,y,z]]
call('pose', x=x, y=y, z=z, pitch=-20, yaw=0)
call('bench', action='start', label='lod-handoff-flight', phase='move_full')
try:
    call('route', mode='fly', points=points, speed=a.speed, loop=False,
         aim='fixed', pitch=-20, yaw=0)
    observe(4*d/a.speed+1)
    call('route', action='stop')
    call('bench', action='mark', phase='steady')
    observe(a.hold)
finally:
    call('route', action='stop')
    result = call('bench', action='stop', dir=str(a.out))
    print(json.dumps(result), flush=True)
