# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Borrow a server lease for structured player tests and rendered checks.

A borrowed client never creates, mutates settings on, or stops its server.
Rendered checks enter through goanna-render shared, retaining the GPU lock.
"""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time

import goanna_headless as gh
from goanna_render import foreign_gpu_users


def endpoint():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def query(port, command, args, token=None, timeout=5):
    request = {'id': 1, 'cmd': command, 'args': args}
    if token:
        request['token'] = token
    with socket.create_connection(('127.0.0.1', port), timeout=timeout) as peer:
        peer.sendall((json.dumps(request) + '\n').encode())
        data = b''
        while b'\n' not in data:
            chunk = peer.recv(65536)
            if not chunk:
                raise RuntimeError('client closed its control channel')
            data += chunk
            if len(data) > 16 * 1024**2:
                raise RuntimeError('oversized client reply')
    reply = json.loads(data.split(b'\n', 1)[0], strict=False)
    if not reply.get('ok'):
        raise RuntimeError(reply.get('error', 'client command failed'))
    return reply.get('result')


def assertion(result, spec):
    value = result
    for part in spec.get('path', '').split('.'):
        if part:
            value = value[int(part)] if isinstance(value, list) else value[part]
    if 'equals' in spec and value != spec['equals']:
        raise AssertionError('%s: expected %r, got %r' % (spec.get('path'), spec['equals'], value))
    if 'contains' in spec and spec['contains'] not in value:
        raise AssertionError('%s does not contain %r' % (value, spec['contains']))
    return True


def stop_record(path, job_id):
    record = json.loads(Path(path).read_text())
    if record.get('instance'):
        try:
            current = gh.load(record['instance'])
        except gh.LaunchError:
            return
        if (current.get('meta') or {}).get('shared_test') == job_id:
            gh.stop(record['instance'])
    elif record.get('pid') and gh.proc_start(record['pid']) == record.get('start'):
        for signum in (signal.SIGTERM, signal.SIGKILL):
            if gh.proc_start(record['pid']) != record.get('start'):
                break
            try:
                os.kill(record['pid'], signum)
            except ProcessLookupError:
                break
            deadline = time.monotonic() + 3
            while gh.proc_start(record['pid']) == record.get('start') and time.monotonic() < deadline:
                time.sleep(0.1)


class GPUYield(RuntimeError):
    pass


class BorrowedClient:
    def __init__(self, lease, index, mode, work, script):
        self.lease, self.index, self.mode = lease, index, mode
        self.work = work / ('client-%d-attempt-%d' % (index, script.get('_attempt', 1)))
        self.work.mkdir(parents=True, exist_ok=True)
        self.project = gh.resolve_project(script.get('project') or Path(__file__).resolve().parents[1])
        self.control_port, self.player_port = endpoint(), endpoint()
        while self.player_port == self.control_port:
            self.player_port = endpoint()
        self.token = os.urandom(24).hex()
        self.proc, self.rec, self.log = None, None, None
        self.env = {'GOANNA_CONTROL': str(self.control_port),
                    'GOANNA_PLAYER_AGENT': str(self.player_port),
                    'GOANNA_HOST': lease['host'], 'GOANNA_PORT': str(lease['port']),
                    'GOANNA_NAME': lease['players'][index], 'GOANNA_PASS': '',
                    'GOANNA_NO_POINTER_CAPTURE': '1',
                    'GOANNA_PBR_SET': '1', 'GOANNA_NO_PBR': '1',
                    'XDG_DATA_HOME': str(self.work / 'xdg')}

    def start(self, cancelled):
        if self.mode == 'player':
            godot = gh.find_godot(self.project)
            env = {k: v for k, v in os.environ.items() if k not in ('DISPLAY', 'WAYLAND_DISPLAY')}
            env.update(self.env)
            self.log = open(self.work / 'output.log', 'ab')
            self.proc = subprocess.Popen([godot, '--headless', '--audio-driver', 'Dummy',
                                          '--path', str(self.project), '--max-fps', '30'],
                                         env=env, stdout=self.log, stderr=subprocess.STDOUT,
                                         stdin=subprocess.DEVNULL, start_new_session=True)
            (self.work / 'process.json').write_text(json.dumps(
                {'pid': self.proc.pid, 'start': gh.proc_start(self.proc.pid)}))
        else:
            self.rec = gh.start_goanna(self.project, control_port=self.control_port,
                                       host=self.lease['host'], port=self.lease['port'],
                                       name=self.lease['players'][self.index],
                                       width=640, height=360, software=self.mode == 'software',
                                       env=self.env, label='shared test ' + self.lease['id'],
                                       ready_timeout=60, meta={'shared_test': self.lease['id']})
            (self.work / 'process.json').write_text(json.dumps({'instance': self.rec['id']}))
        while not cancelled():
            if self.proc and self.proc.poll() is not None:
                raise RuntimeError('headless client exited; see %s' % self.work)
            try:
                status = query(self.control_port, 'status', {})
                if status.get('state') == 'denied':
                    raise RuntimeError('server denied client: %s' % status)
                if status.get('state') == 'ready':
                    self.token = (self.work / 'xdg/godot/app_userdata/Goanna' /
                                  ('player_agent_%d.token' % self.player_port)).read_text().strip()
                    query(self.player_port, 'hello', {}, self.token)
                    def inspect_expression(expression):
                        value = query(self.control_port, 'run', {'src': 'return ' + expression})
                        return value.get('value') if isinstance(value, dict) else value
                    adapter = inspect_expression('RenderingServer.get_video_adapter_name()')
                    status['test_versions'] = {
                        'godot': inspect_expression('Engine.get_version_info().string'),
                        'adapter': adapter, 'mode': self.mode,
                        'log': str(self.work / 'output.log') if self.proc else self.rec.get('client_log')}
                    cpu = any(x in str(adapter).lower() for x in ('llvmpipe', 'lavapipe', 'software'))
                    if self.mode == 'software' and not cpu:
                        raise RuntimeError('software mode did not select a CPU adapter: %s' % adapter)
                    if self.mode == 'gpu' and (cpu or not adapter):
                        raise RuntimeError('GPU mode did not select a hardware adapter: %s' % adapter)
                    return status
            except (OSError, json.JSONDecodeError):
                pass
            time.sleep(0.1)
        raise RuntimeError('client readiness cancelled or timed out')

    def stop(self):
        if self.rec:
            gh.stop(self.rec['id'])
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        if self.log:
            self.log.close()


def run(payload, lease, work, cancelled, render_entry=False):
    if payload['mode'] in ('gpu', 'software') and not render_entry:
        # Rendered checks have a single entry point, including CPU shots.
        request = work / 'render-request.json'
        request.write_text(json.dumps({'payload': payload, 'lease': lease}))
        result_path = work / 'render-result.json'
        log = open(work / 'render-worker.log', 'ab')
        proc = subprocess.Popen([sys.executable, str(Path(__file__).with_name('goanna-render')),
                                 'shared', str(request), str(result_path)],
                                stdout=log, stderr=subprocess.STDOUT)
        try:
            while proc.poll() is None:
                if cancelled():
                    proc.terminate()
                    try:
                        proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                    raise RuntimeError('render worker cancelled')
                time.sleep(0.1)
            if proc.returncode or not result_path.exists():
                raise RuntimeError('render worker failed; see %s' % (work / 'render-worker.log'))
            return json.loads(result_path.read_text())
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
            log.close()
    clients, results = [], []
    payload['script']['_attempt'] = payload.get('attempt', 1)

    def checkpoint():
        if cancelled():
            raise RuntimeError('client job cancelled or timed out')
        if payload['mode'] == 'gpu':
            own = {os.getpid(), *gh.descendants(os.getpid())}
            for client in clients:
                if client.rec:
                    for key in ('supervisor_pid', 'gamescope_pid', 'child_pid'):
                        if client.rec.get(key):
                            own.add(client.rec[key])
            busy = foreign_gpu_users(own)
            if busy:
                raise GPUYield('; '.join(busy))

    try:
        for index in range(payload['players']):
            client = BorrowedClient(lease, index, payload['mode'], work, payload['script'])
            clients.append(client)
            status = client.start(cancelled)
            results.append({'kind': 'ready', 'client': index, 'result': status})
        if payload.get('barrier'):
            barrier = payload['barrier']
            token = barrier['id']
            if not token.isalnum():
                raise ValueError('invalid barrier ID')
            folder = work.parent / '_barriers' / token
            folder.mkdir(parents=True, exist_ok=True)
            (folder / (lease['id'] + '.ready')).write_text(str(time.time()))
            while len(list(folder.glob('*.ready'))) < barrier['count']:
                if cancelled():
                    raise RuntimeError('client readiness barrier timed out')
                time.sleep(0.1)
        hold = min(120, max(0, float(payload['script'].get('hold_seconds', 0))))
        until = time.monotonic() + hold
        while time.monotonic() < until:
            checkpoint()
            for client in clients:
                query(client.player_port, 'observe', {}, client.token)
            time.sleep(0.2)
        for step in payload['script'].get('steps', []):
            checkpoint()
            client = clients[step.get('client', 0)]
            command, args = step['cmd'], dict(step.get('args') or {})
            channel = step.get('channel', 'player')
            if channel not in ('player', 'control'):
                raise ValueError('unknown client channel')
            if command == 'shot':
                if not render_entry:
                    raise ValueError('dummy renderer cannot take screenshots')
                destination = work / ('frame-%02d-%03d.png' % (payload.get('attempt', 1), len(results)))
                args = {'path': str(destination)}
            if channel == 'control':
                if command == 'wait' and set(args) - {'settle', 'frames', 'ms'}:
                    raise ValueError('shared waits accept settle, frames or ms only')
                # Shared jobs cannot send server-global chat commands or
                # arbitrary code. Fixture changes belong in a bounded probe.
                if command not in ('status', 'inspect', 'pose', 'look', 'wait', 'shot', 'ui_tree',
                                   'ui_click', 'ui_type', 'ui_scroll', 'key', 'label'):
                    raise ValueError('control command is not shared-safe: %s' % command)
                result = query(client.control_port, command, args, timeout=10)
            else:
                if command not in ('hello', 'observe', 'wait', 'action_status'):
                    if 'based_on' not in args:
                        observation = query(client.player_port, 'observe', {}, client.token)
                        args['based_on'] = observation['sequence']
                result = query(client.player_port, command, args, client.token, timeout=35)
            if result and isinstance(result, dict) and result.get('status') == 'accepted':
                action_id = result.get('id')
                if action_id is not None:
                    waited = query(client.player_port, 'wait', {'action': action_id}, client.token, timeout=35)
                    result = waited.get('action', waited)
            if (isinstance(result, dict) and result.get('status') in ('refused', 'stale', 'interrupted')
                    and not step.get('expect')):
                raise AssertionError('player action did not complete: %s' % result)
            for expected in step.get('expect', []):
                assertion(result, expected)
            results.append({'kind': 'step', 'command': command, 'client': step.get('client', 0),
                            'result': result})
        return {'ok': True, 'steps': results, 'generation': lease['generation']}
    finally:
        for client in reversed(clients):
            client.stop()


def render_command(argv):
    """goanna-render shared REQUEST RESULT: one borrowed scene, no server ownership."""
    if len(argv) != 2:
        raise ValueError('shared expects request and result paths')
    request_path, result_path = map(Path, argv)
    request = json.loads(request_path.read_text())
    payload, lease = request['payload'], request['lease']
    if payload['mode'] not in ('gpu', 'software'):
        raise ValueError('shared render entry expects GPU or software mode')
    stopped = False

    def cancel(*_):
        nonlocal stopped
        stopped = True

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, cancel)
    deadline = time.monotonic() + payload['timeout']
    try:
        result = run(payload, lease, request_path.parent,
                     lambda: stopped or time.monotonic() > deadline, render_entry=True)
    except GPUYield as exc:
        result = {'ok': False, 'retry': True, 'retry_after': time.time() + 60,
                  'reason': 'yielded GPU: ' + str(exc)}
    result_path.write_text(json.dumps(result))
    return 0
