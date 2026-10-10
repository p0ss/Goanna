#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Run and close one isolated Mineclonia capture client.

Usage: python3 tools/test/lava-review/run_mineclonia.py <stage> <pack textures dir>

The client runs in headless gamescope through tools/goanna_headless.py, on
the GPU, taking the shared GPU lock (waiting up to GOANNA_LOCK_WAIT seconds,
default 1800), so no window reaches the desktop. The window is 1600 by 900,
the project's own size, which is what the desktop runs got. The cave server
on port 30581 is not started here; see docs/perf/lava-mineclonia-2026-09-18.
"""
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

if sys.argv[1:2] in (["-h"], ["--help"]):
    print(__doc__)
    sys.exit(0)

root = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(root / 'tools'))
import goanna_headless as headless  # noqa: E402
stage, pack = sys.argv[1:]
env = dict(GOANNA_PACK=str(Path(pack).resolve()),
           XDG_DATA_HOME='/tmp/goanna-lava-mineclonia-profile',
           XDG_CONFIG_HOME='/tmp/goanna-lava-mineclonia-config')
log = Path('/tmp/goanna-lava-mineclonia')/f'client-{stage}.log'
log.parent.mkdir(parents=True, exist_ok=True)
process = headless.Instance(headless.start_goanna(
    root, control_port=30882, port=30581, name='lava_review', width=1600, height=900,
    env=env, label=f'lava review {stage}',
    lock_wait=float(os.environ.get('GOANNA_LOCK_WAIT', 1800)),
    software=os.environ.get('GOANNA_SOFTWARE') == '1'))
try:
    for _ in range(120):
        if process.poll() is not None:
            raise RuntimeError(f'Client exited: {process.log}')
        if 'ready | TOSERVER_CLIENT_READY' in Path(process.log).read_text(errors='replace'):
            break
        time.sleep(0.5)
    else:
        raise RuntimeError(f'Client did not become ready: {process.log}')
    # Let the native near mesh and pooled lights settle before the pose.
    time.sleep(5)
    subprocess.run([sys.executable, str(root/'tools/test/lava-review/mineclonia_capture.py'),stage],check=True)
finally:
    if process.poll() is None:
        try:
            with socket.create_connection(('127.0.0.1',30882),timeout=3) as sock:
                sock.sendall(b'{"id":1,"cmd":"run","args":{"src":"main.get_tree().quit(); return true"}}\n')
            process.wait(timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            process.terminate()
            process.wait(timeout=10)
    shutil.copyfile(process.log, log)
