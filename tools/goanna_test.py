#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Durable shared test queue. Host-specific behaviour belongs in an adapter.

No game process starts on submit. Run serve explicitly when memory permits.
"""
import argparse
import base64
import concurrent.futures
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import secrets
import signal
import sqlite3
import subprocess
import sys
import threading
import time

MODES = ('probe', 'player', 'software', 'gpu', 'exclusive')
TERMINAL = ('passed', 'failed', 'cancelled', 'timed_out', 'interrupted')
PACKAGES = ('kindred', 'kindred_creatures', 'kindred_cultures', 'kindred_world')
MAX_PAYLOAD = 64 * 1024 * 1024


def stamp(pid):
    try:
        fields = Path('/proc/%d/stat' % pid).read_text().rsplit(')', 1)[1].split()
        return None if fields[0] in ('Z', 'X') else int(fields[19])
    except (OSError, ValueError, IndexError):
        return None


def memory_available():
    fields = dict(line.split(':', 1) for line in Path('/proc/meminfo').read_text().splitlines())
    return int(fields['MemAvailable'].split()[0]) * 1024


def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args], check=True,
                          capture_output=True).stdout


def snapshot(repo, paths):
    """Freeze files, including tracked deletions. Refuse symlinks and escapes."""
    repo = Path(repo).resolve()
    selected = set()
    for raw in paths:
        rel = PurePosixPath(raw)
        if (rel.is_absolute() or '..' in rel.parts or len(rel.parts) < 2
                or rel.parts[0] != 'mods' or rel.parts[1] not in PACKAGES):
            raise ValueError('overlay path outside the four packages: %s' % raw)
        names = git(repo, 'ls-files', '-z', '--cached', '--others',
                    '--exclude-standard', '--', str(rel)).split(b'\0')
        selected.update(os.fsdecode(n) for n in names if n)
    result, total = [], 0
    for name in sorted(selected):
        path = repo / name
        if any(p.is_symlink() for p in (path, *path.parents) if p != repo):
            raise ValueError('symlink overlay refused: %s' % name)
        if not path.resolve().is_relative_to(repo):
            raise ValueError('overlay escapes worktree: %s' % name)
        data = path.read_bytes() if path.exists() else None
        total += len(data or b'')
        if total > MAX_PAYLOAD:
            raise ValueError('overlay exceeds 64 MiB')
        result.append({'path': name, 'data': base64.b64encode(data).decode() if data is not None else None,
                       'sha256': hashlib.sha256(data).hexdigest() if data is not None else None})
    return result


def validate(payload):
    if payload.get('mode') not in MODES:
        raise ValueError('unknown execution mode')
    for key, upper in (('timeout', 600), ('queue_timeout', 86400), ('cleanup_timeout', 120)):
        value = payload.get(key, {'timeout': 300, 'queue_timeout': 3600, 'cleanup_timeout': 30}[key])
        if key == 'timeout' and payload['mode'] == 'exclusive':
            upper = 10800
        if not isinstance(value, (int, float)) or not 0 < value <= upper:
            raise ValueError('%s must be positive and at most %s' % (key, upper))
        payload[key] = value
    players = payload.get('players', 0 if payload['mode'] == 'probe' or payload['mode'] == 'exclusive' and payload.get('probe') else 1)
    if not isinstance(players, int) or not 0 <= players <= 8:
        raise ValueError('players must be 0 to 8')
    if payload['mode'] == 'probe' and players:
        raise ValueError('probe mode has no client; use a player job with a setup probe')
    if payload['mode'] != 'probe' and not players and not (payload['mode'] == 'exclusive' and payload.get('probe')):
        raise ValueError('client jobs require at least one player')
    if payload['mode'] == 'gpu' and players != 1:
        raise ValueError('the GPU pool has exactly one client')
    payload['players'] = players
    script = payload.get('script') or {}
    if not isinstance(script, dict):
        raise ValueError('client script must be a JSON object')
    if set(script) - {'steps', 'hold_seconds', 'project', 'server_settings', 'client_mode'}:
        raise ValueError('shared scripts use steps; owned render fixture jobs keep their existing runner')
    client_mode = script.get('client_mode', 'player')
    if payload['mode'] == 'exclusive' and client_mode not in ('player', 'software', 'gpu'):
        raise ValueError('private client mode must be player, software or gpu')
    resources = payload.setdefault('resources', ['state:global'])
    if not isinstance(resources, list) or not all(isinstance(x, str) and x for x in resources):
        raise ValueError('resources must be non-empty names')
    seen = set()
    total = (len(payload.get('probe', '').encode()) + len(payload.get('setup_probe', '').encode())
             + len(json.dumps(payload.get('script', {})).encode()))
    for entry in payload.get('overlay', []):
        name = entry['path']
        path = PurePosixPath(name)
        if (path.is_absolute() or '..' in path.parts or len(path.parts) < 3
                or path.parts[0] != 'mods' or path.parts[1] not in PACKAGES
                or name in seen):
            raise ValueError('invalid or duplicate overlay destination: %s' % name)
        seen.add(name)
        data = entry.get('data')
        if data is not None:
            decoded = base64.b64decode(data, validate=True)
            if hashlib.sha256(decoded).hexdigest() != entry.get('sha256'):
                raise ValueError('overlay hash mismatch: %s' % name)
            total += len(decoded)
    if total > MAX_PAYLOAD:
        raise ValueError('payload exceeds 64 MiB')
    if payload.get('hot_provider') and not payload.get('overlay'):
        raise ValueError('hot reload needs frozen overlay files')
    # Overlay execution stays exclusive until provider independence is verified.
    payload['exclusive'] = bool(payload.get('overlay') or payload['mode'] == 'exclusive'
                                or payload.get('exclusive'))
    if payload['mode'] == 'probe' and not payload.get('probe'):
        raise ValueError('probe mode needs a Lua probe')
    if payload['mode'] != 'probe' and not isinstance(payload.get('script'), dict) and not (payload['mode'] == 'exclusive' and payload.get('probe')):
        raise ValueError('client mode needs a JSON script')
    return payload


class Queue:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self.db() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY, submitted REAL NOT NULL,
                    state TEXT NOT NULL, payload TEXT NOT NULL,
                    result TEXT, owner INTEGER, owner_start INTEGER,
                    started REAL, ended REAL, cancelled INTEGER DEFAULT 0,
                    reason TEXT, attempt INTEGER DEFAULT 0);
                CREATE TABLE IF NOT EXISTS events (
                    job TEXT NOT NULL, at REAL NOT NULL,
                    state TEXT NOT NULL, detail TEXT);
            ''')

    @contextlib.contextmanager
    def db(self):
        db = sqlite3.connect(self.root / 'queue.sqlite3', timeout=30)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA journal_mode=WAL')
        try:
            with db:
                yield db
        finally:
            db.close()

    def submit(self, payload):
        payload = validate(dict(payload))
        ident = '%013d-%s' % (int(time.time() * 1000), secrets.token_hex(5))
        with self.db() as db:
            db.execute('INSERT INTO jobs(id,submitted,state,payload) VALUES(?,?,?,?)',
                       (ident, time.time(), 'queued', json.dumps(payload)))
            db.execute('INSERT INTO events VALUES(?,?,?,?)', (ident, time.time(), 'queued', None))
        return ident

    def get(self, ident):
        with self.db() as db:
            row = db.execute('SELECT * FROM jobs WHERE id=?', (ident,)).fetchone()
        if row is None:
            raise ValueError('unknown job: %s' % ident)
        result = dict(row)
        for key in ('payload', 'result'):
            result[key] = json.loads(result[key]) if result[key] else None
        return result

    def list(self):
        with self.db() as db:
            ids = [r[0] for r in db.execute('SELECT id FROM jobs ORDER BY submitted,id')]
        return [self.get(ident) for ident in ids]

    def transition(self, ident, state, result=None, reason=None):
        with self.db() as db:
            db.execute('UPDATE jobs SET state=?, result=COALESCE(?,result), reason=?, '
                       'ended=CASE WHEN ? THEN ? ELSE ended END WHERE id=?',
                       (state, json.dumps(result) if result is not None else None,
                        reason, state in TERMINAL, time.time(), ident))
            db.execute('INSERT INTO events VALUES(?,?,?,?)',
                       (ident, time.time(), state, json.dumps(result) if result is not None else reason))

    def cancel(self, ident):
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT state FROM jobs WHERE id=?', (ident,)).fetchone()
            if row is None:
                raise ValueError('unknown job: %s' % ident)
            if row['state'] in TERMINAL:
                return
            db.execute('UPDATE jobs SET cancelled=1, state=CASE WHEN state="queued" '
                       "THEN 'cancelled' ELSE state END WHERE id=?", (ident,))
            db.execute('INSERT INTO events VALUES(?,?,?,?)',
                       (ident, time.time(), 'cancel_requested', None))

    def recover(self):
        for row in self.list():
            if row['state'] not in TERMINAL + ('queued',):
                if row['owner'] is None or stamp(row['owner']) != row['owner_start'] or row['owner_start'] is None:
                    self.transition(row['id'], 'interrupted', reason='supervisor exited; cleanup required')

    def admit(self, limits, min_free=16 * 1024**3, admission=None):
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            rows = [dict(r) for r in db.execute('SELECT * FROM jobs ORDER BY submitted,id')]
            active = [json.loads(r['payload']) for r in rows if r['state'] not in TERMINAL + ('queued',)]
            for row in rows:
                if row['state'] != 'queued':
                    continue
                p = json.loads(row['payload'])
                if row['cancelled'] or time.time() > row['submitted'] + p['queue_timeout']:
                    state = 'cancelled' if row['cancelled'] else 'timed_out'
                    db.execute('UPDATE jobs SET state=?,ended=? WHERE id=?', (state, time.time(), row['id']))
                    continue
                reason = None
                previous = json.loads(row['result']) if row['result'] else {}
                if previous.get('retry_after', 0) > time.time():
                    reason = 'waiting after GPU yield'
                elif memory_available() < min_free:
                    reason = 'waiting for free memory'
                elif p['exclusive'] and active or any(a['exclusive'] for a in active):
                    reason = 'waiting for an exclusive drain'
                elif any(a['base'] != p['base'] for a in active):
                    reason = 'waiting for a base generation drain'
                elif set(p['resources']) & {x for a in active for x in a['resources']}:
                    reason = 'waiting for mutable resources'
                else:
                    mode = p['mode']
                    used = sum(max(1, a['players']) for a in active if a['mode'] == mode)
                    if used + max(1, p['players']) > limits.get(mode, 1):
                        reason = 'waiting for %s slots' % mode
                if reason is None and admission is not None:
                    reason = admission(p)
                db.execute('UPDATE jobs SET reason=? WHERE id=?', (reason, row['id']))
                if reason:
                    # An ageing exclusive job reserves the next drain.
                    if p['exclusive'] and time.time() - row['submitted'] >= 600:
                        return None
                    continue
                db.execute('UPDATE jobs SET state=?,owner=?,owner_start=?,started=?,attempt=attempt+1 '
                           'WHERE id=?', ('preparing', os.getpid(), stamp(os.getpid()), time.time(), row['id']))
                db.execute('INSERT INTO events VALUES(?,?,?,?)', (row['id'], time.time(), 'preparing', None))
                return row['id']
        return None


def load_adapter(path):
    spec = importlib.util.spec_from_file_location('shared_test_host_adapter', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Service:
    def __init__(self, queue, adapter, limits, min_free):
        self.queue, self.adapter = queue, adapter
        self.limits, self.min_free = limits, min_free
        self.stop = threading.Event()
        self.jobs = {}
        self.paused = None

    def execute(self, ident):
        row = self.queue.get(ident)
        payload = dict(row['payload'], attempt=row['attempt'])
        work = self.queue.root / 'artifacts' / ident
        work.mkdir(parents=True, exist_ok=True)
        lease, result, state = None, {}, 'failed'
        deadline = time.monotonic() + payload['timeout']

        def cancelled():
            return (self.stop.is_set() or self.queue.get(ident)['cancelled']
                    or time.monotonic() > deadline or memory_available() < 16 * 1024**3)

        try:
            lease = self.adapter.prepare(payload, work, cancelled)
            self.queue.transition(ident, 'running')
            result = self.adapter.execute(payload, lease, work, cancelled)
            state = 'queued' if result.get('retry') else ('passed' if result.get('ok') else 'failed')
        except Exception as exc:
            result = {'ok': False, 'error': str(exc)}
            if getattr(exc, 'interrupted', False):
                state = 'interrupted'
            if getattr(exc, 'pause_dispatch', False):
                self.paused = str(exc)
        finally:
            self.queue.transition(ident, 'cleaning')
            try:
                self.adapter.cleanup(payload, lease, work, payload['cleanup_timeout'])
                result['cleanup'] = 'complete'
            except Exception as exc:
                result.update(ok=False, cleanup='failed', cleanup_error=str(exc))
                state = 'interrupted'
                self.paused = 'cleanup failed: %s' % exc
            if self.queue.get(ident)['cancelled']:
                state = 'cancelled'
            elif self.stop.is_set():
                state = 'interrupted'
            elif time.monotonic() > deadline:
                state = 'timed_out'
            result.update(id=ident, lease=lease, finished=time.time(), artifacts=str(work))
            (work / ('attempt-%d.json' % row['attempt'])).write_text(json.dumps(result, indent=2))
            self.queue.transition(ident, state, result)

    def serve(self):
        with open(self.queue.root / 'supervisor.lock', 'a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError('a shared test supervisor is already running')
            self.queue.recover()
            # Recover host leases before admitting another job after a crash.
            self.adapter.recover(self.queue)
            for sig in (signal.SIGTERM, signal.SIGINT):
                signal.signal(sig, lambda *_: self.stop.set())
            with concurrent.futures.ThreadPoolExecutor(max_workers=sum(self.limits.values())) as pool:
                while not self.stop.is_set():
                    for ident, future in list(self.jobs.items()):
                        if future.done():
                            future.result()
                            del self.jobs[ident]
                    status = {'pid': os.getpid(), 'start': stamp(os.getpid()), 'updated': time.time(),
                              'limits': self.limits, 'paused': self.paused, 'active': list(self.jobs)}
                    temporary = self.queue.root / 'supervisor.tmp'
                    temporary.write_text(json.dumps(status))
                    temporary.replace(self.queue.root / 'supervisor.json')
                    ident = None if self.paused else self.queue.admit(self.limits, self.min_free, getattr(self.adapter, 'admission', None))
                    if ident:
                        self.jobs[ident] = pool.submit(self.execute, ident)
                    else:
                        self.stop.wait(0.25)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', default=os.environ.get('GOANNA_TEST_STATE', str(Path.home() / '.cache/goanna-test')))
    sub = parser.add_subparsers(dest='command', required=True)
    submit = sub.add_parser('submit')
    submit.add_argument('--repo', required=True)
    submit.add_argument('--base', default='main')
    submit.add_argument('--probe')
    submit.add_argument('--script')
    submit.add_argument('--setup-probe')
    submit.add_argument('--mode', choices=MODES, default='probe')
    submit.add_argument('--builder', default='empty')
    submit.add_argument('--param', action='append', default=[])
    submit.add_argument('--players', type=int)
    submit.add_argument('--resource', action='append')
    submit.add_argument('--overlay-from')
    submit.add_argument('--reload-provider')
    submit.add_argument('--paths', nargs='+', default=[])
    submit.add_argument('--timeout', type=float, default=300)
    submit.add_argument('--queue-timeout', type=float, default=3600)
    submit.add_argument('--detach', action='store_true')
    sub.add_parser('queue')
    cancel = sub.add_parser('cancel')
    cancel.add_argument('id')
    result = sub.add_parser('result')
    result.add_argument('id')
    serve = sub.add_parser('serve')
    serve.add_argument('--adapter', required=True)
    serve.add_argument('--min-free-gib', type=float, default=24)
    serve.add_argument('--slots', action='append', default=[])
    args = parser.parse_args(argv)
    if args.command == 'submit' and not os.environ.get('GOANNA_TEST_STATE') and '--state' not in (argv or sys.argv[1:]):
        args.state = str(Path(args.repo).resolve() / '.cache/shared-test')
    q = Queue(args.state)
    if args.command == 'submit':
        repo = Path(args.repo).resolve()
        revision = git(repo, 'rev-parse', '--verify', args.base + '^{commit}').decode().strip()
        payload = {'repo': str(repo), 'base': revision, 'mode': args.mode,
                   'builder': args.builder, 'params': dict(p.split('=', 1) for p in args.param),
                   'timeout': args.timeout, 'queue_timeout': args.queue_timeout,
                   'resources': args.resource or ['state:global']}
        if args.players is not None:
            payload['players'] = args.players
        if args.probe:
            payload['probe'] = Path(args.probe).read_text()
        if args.setup_probe:
            payload['setup_probe'] = Path(args.setup_probe).read_text()
        if args.script:
            payload['script'] = json.loads(Path(args.script).read_text())
        if args.reload_provider:
            payload['hot_provider'] = args.reload_provider
            payload['resources'].append('provider:' + args.reload_provider)
        if args.paths:
            payload['overlay'] = snapshot(args.overlay_from or repo, args.paths)
        ident = q.submit(payload)
        if args.detach:
            print(json.dumps({'id': ident, 'state': 'queued'}))
            return 0
        def interrupted(signum, frame):
            q.cancel(ident)
            raise SystemExit(128 + signum)
        for signum in (signal.SIGINT, signal.SIGTERM):
            signal.signal(signum, interrupted)
        until = time.monotonic() + args.queue_timeout + args.timeout + 120
        try:
            while q.get(ident)['state'] not in TERMINAL:
                if time.monotonic() > until:
                    q.cancel(ident)
                    raise RuntimeError('job wait deadline; cancellation requested')
                time.sleep(0.25)
        except (KeyboardInterrupt, SystemExit):
            q.cancel(ident)
            raise
        row = q.get(ident)
        print(json.dumps(row, indent=2))
        return 0 if row['state'] == 'passed' else 1
    if args.command == 'serve':
        limits = dict.fromkeys(MODES, 1)
        limits.update({k: int(v) for k, v in (x.split('=', 1) for x in args.slots)})
        if set(limits) != set(MODES) or not all(0 < v <= 8 for v in limits.values()) or limits['gpu'] != 1:
            raise ValueError('slots must be 1 to 8; GPU slots must stay at 1')
        if args.min_free_gib < 16:
            raise ValueError('free-memory reserve must be at least 16 GiB')
        Service(q, load_adapter(args.adapter), limits, args.min_free_gib * 1024**3).serve()
    elif args.command == 'cancel':
        q.cancel(args.id)
    elif args.command == 'result':
        print(json.dumps(q.get(args.id), indent=2))
    else:
        rows = []
        for row in q.list():
            p = row['payload']
            rows.append({**{k: row[k] for k in ('id', 'state', 'submitted', 'started', 'reason', 'attempt')},
                         'mode': p['mode'], 'base': p['base'], 'players': p['players'],
                         'resources': p['resources'], 'overlay_files': len(p.get('overlay', []))})
        print(json.dumps(rows, indent=2))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
