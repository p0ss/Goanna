#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Run and close one isolated Mineclonia capture client."""
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

root = Path(__file__).resolve().parents[2]
stage, pack = sys.argv[1:]
env = os.environ.copy()
env.update(GOANNA_HOST='127.0.0.1', GOANNA_PORT='30581', GOANNA_NAME='lava_review',
           GOANNA_CONTROL='30882', GOANNA_PACK=str(Path(pack).resolve()),
           XDG_DATA_HOME='/tmp/goanna-lava-mineclonia-profile',
           XDG_CONFIG_HOME='/tmp/goanna-lava-mineclonia-config')
log = Path('/tmp/goanna-lava-mineclonia')/f'client-{stage}.log'
with log.open('w') as output:
    process = subprocess.Popen([str(root.parent/'Godot_v4.5.1-stable_linux.x86_64'),
                                '--path', str(root/'project')], env=env, stdout=output, stderr=output)
    try:
        for _ in range(120):
            if process.poll() is not None:
                raise RuntimeError(f'Client exited: {log}')
            if 'ready | TOSERVER_CLIENT_READY' in log.read_text():
                break
            time.sleep(0.5)
        else:
            raise RuntimeError(f'Client did not become ready: {log}')
        # Let the native near mesh and pooled lights settle before the pose.
        time.sleep(5)
        subprocess.run([sys.executable, str(root/'tools/lava-review/mineclonia_capture.py'),stage],check=True)
    finally:
        if process.poll() is None:
            try:
                with socket.create_connection(('127.0.0.1',30882),timeout=3) as sock:
                    sock.sendall(b'{"id":1,"cmd":"run","args":{"src":"main.get_tree().quit(); return true"}}\n')
                process.wait(timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                process.terminate()
                process.wait(timeout=10)
