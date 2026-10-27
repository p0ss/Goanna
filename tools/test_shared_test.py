#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Queue admission, cancellation, snapshot and recovery tests. No game runs."""
import base64
import concurrent.futures
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import goanna_test as shared


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.queue = shared.Queue(Path(self.temp.name) / 'queue')
        self.limits = dict.fromkeys(shared.MODES, 2)
        self.limits['gpu'] = 1
        self.memory = patch.object(shared, 'memory_available', return_value=64 * 1024**3)
        self.memory.start()
        self.addCleanup(self.memory.stop)

    def job(self, **overrides):
        p = dict(mode='probe', probe='job.done()', base='a', resources=['a'])
        p.update(overrides)
        return self.queue.submit(p)

    def admit(self):
        return self.queue.admit(self.limits)

    def test_independent_jobs_overlap_but_conflicts_wait(self):
        first, conflict, independent = self.job(), self.job(), self.job(resources=['b'])
        self.assertEqual(self.admit(), first)
        self.assertEqual(self.admit(), independent)
        self.assertIsNone(self.admit())
        self.queue.transition(first, 'passed')
        self.assertEqual(self.admit(), conflict)

    def test_concurrent_admission_cannot_oversubscribe(self):
        self.limits['probe'] = 1
        for i in range(8):
            self.job(resources=[str(i)])
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            admitted = list(pool.map(lambda _: self.admit(), range(8)))
        self.assertEqual(sum(x is not None for x in admitted), 1)

    def test_base_change_drains(self):
        a, b = self.job(), self.job(base='b', resources=['b'])
        self.assertEqual(self.admit(), a)
        self.assertIsNone(self.admit())
        self.queue.transition(a, 'passed')
        self.assertEqual(self.admit(), b)

    def test_overlay_is_exclusive(self):
        data = b'local x = 1'
        overlay = [{'path': 'mods/kindred_creatures/providers/a.lua',
                    'data': base64.b64encode(data).decode(),
                    'sha256': hashlib.sha256(data).hexdigest()}]
        a, b = self.job(), self.job(resources=['b'], overlay=overlay)
        self.assertEqual(self.admit(), a)
        self.assertIsNone(self.admit())
        self.queue.transition(a, 'passed')
        self.assertEqual(self.admit(), b)
        self.assertTrue(self.queue.get(b)['payload']['exclusive'])

    def test_gpu_limit_and_multi_player_accounting(self):
        a = self.job(mode='gpu', script={}, resources=['a'])
        self.job(mode='gpu', script={}, resources=['b'])
        self.assertEqual(self.admit(), a)
        self.assertIsNone(self.admit())
        self.job(mode='player', script={}, players=3, resources=['c'])
        self.assertIsNone(self.admit())

    def test_cancelled_and_expired_jobs_never_run(self):
        a, b = self.job(), self.job()
        self.queue.cancel(a)
        with self.queue.db() as db:
            db.execute('UPDATE jobs SET submitted=0 WHERE id=?', (b,))
        self.assertIsNone(self.admit())
        self.assertEqual(self.queue.get(a)['state'], 'cancelled')
        self.assertEqual(self.queue.get(b)['state'], 'timed_out')

    def test_memory_gate_preserves_queue(self):
        a = self.job()
        with patch.object(shared, 'memory_available', return_value=1):
            self.assertIsNone(self.admit())
        self.assertEqual(self.queue.get(a)['state'], 'queued')
        self.assertEqual(self.admit(), a)

    def test_recovery_survives_reopening(self):
        a = self.job()
        self.admit()
        with self.queue.db() as db:
            db.execute('UPDATE jobs SET owner_start=-1 WHERE id=?', (a,))
        reopened = shared.Queue(self.queue.root)
        reopened.recover()
        self.assertEqual(reopened.get(a)['state'], 'interrupted')

    def test_owned_render_schema_is_not_silently_accepted_as_an_empty_test(self):
        with self.assertRaisesRegex(ValueError, 'owned render fixture'):
            self.job(mode='gpu', script={'poses': [{'name': 'front'}]})

    def test_payload_rejects_escape_hash_and_duplicate(self):
        for overlay in (
            [{'path': '../x', 'data': None}],
            [{'path': 'mods/kindred/x.lua', 'data': 'eA==', 'sha256': 'wrong'}],
            [{'path': 'mods/kindred/x.lua', 'data': None}] * 2,
        ):
            with self.assertRaises(ValueError):
                self.job(overlay=overlay)

    def test_snapshots_freeze_untracked_and_deleted_files(self):
        repo = Path(self.temp.name) / 'repo'
        repo.mkdir()
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        folder = repo / 'mods/kindred'
        folder.mkdir(parents=True)
        old = folder / 'old.lua'
        old.write_text('old')
        subprocess.run(['git', '-C', str(repo), 'add', 'mods/kindred/old.lua'], check=True)
        old.unlink()
        new = folder / 'new.lua'
        new.write_text('first')
        frozen = shared.snapshot(repo, ['mods/kindred'])
        new.write_text('second')
        self.assertEqual(base64.b64decode(frozen[0]['data']), b'first')
        self.assertIsNone(frozen[1]['data'])
        new.unlink()
        new.symlink_to('/etc/passwd')
        with self.assertRaises(ValueError):
            shared.snapshot(repo, ['mods/kindred'])

    def test_cleanup_failure_pauses_dispatch(self):
        class Adapter:
            def prepare(self, *args):
                return {'generation': 'test'}
            def execute(self, *args):
                return {'ok': True}
            def cleanup(self, *args):
                raise RuntimeError('leftover state')
        ident = self.job()
        self.admit()
        service = shared.Service(self.queue, Adapter(), self.limits, 0)
        service.execute(ident)
        self.assertEqual(self.queue.get(ident)['state'], 'interrupted')
        self.assertIn('cleanup failed', service.paused)


class ClientTests(unittest.TestCase):
    def setUp(self):
        import goanna_test_client
        self.client = goanna_test_client
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.lease = {'id': 'test-job', 'generation': 'generation', 'players': ['one', 'two']}

    def fake_client(self):
        from unittest.mock import MagicMock
        fake = MagicMock()
        fake.control_port = 12345
        fake.player_port = 12346
        fake.token = 'test-token'
        fake.start.return_value = {'state': 'ready'}
        return fake

    def test_actions_use_observation_sequence_and_clients_stop(self):
        fake = self.fake_client()
        replies = [{'sequence': 42}, {'status': 'completed'}]
        payload = {'mode': 'player', 'players': 1,
                   'script': {'steps': [{'cmd': 'move', 'args': {'duration_ms': 10}}]}}
        with patch.object(self.client, 'BorrowedClient', return_value=fake), \
                patch.object(self.client, 'query', side_effect=replies) as query:
            result = self.client.run(payload, self.lease, self.work, lambda: False)
        self.assertTrue(result['ok'])
        self.assertEqual(query.call_args_list[1].args[2]['based_on'], 42)
        fake.stop.assert_called_once()

    def test_refused_action_is_a_failure_and_cleans_all_players(self):
        fake = self.fake_client()
        payload = {'mode': 'player', 'players': 2, 'script': {'steps': [{'cmd': 'dig'}]}}
        with patch.object(self.client, 'BorrowedClient', return_value=fake), \
                patch.object(self.client, 'query', side_effect=[{'sequence': 1}, {'status': 'refused'}]):
            with self.assertRaises(AssertionError):
                self.client.run(payload, self.lease, self.work, lambda: False)
        self.assertEqual(fake.stop.call_count, 2)

    def test_shared_control_refuses_world_mutation(self):
        fake = self.fake_client()
        payload = {'mode': 'player', 'players': 1, 'script': {'steps': [
            {'channel': 'control', 'cmd': 'chat', 'args': {'text': '/time 0'}}]}}
        with patch.object(self.client, 'BorrowedClient', return_value=fake), \
                patch.object(self.client, 'query') as query:
            with self.assertRaises(ValueError):
                self.client.run(payload, self.lease, self.work, lambda: False)
        query.assert_not_called()
        fake.stop.assert_called_once()

    def test_dummy_renderer_cannot_claim_a_screenshot(self):
        fake = self.fake_client()
        payload = {'mode': 'player', 'players': 1, 'script': {'steps': [
            {'channel': 'control', 'cmd': 'shot'}]}}
        with patch.object(self.client, 'BorrowedClient', return_value=fake):
            with self.assertRaises(ValueError):
                self.client.run(payload, self.lease, self.work, lambda: False)
        fake.stop.assert_called_once()

    def test_lost_host_stops_render_subprocess_even_when_checkpoint_raises(self):
        from unittest.mock import MagicMock
        proc = MagicMock()
        proc.poll.return_value = None
        payload = {'mode': 'software', 'players': 1, 'timeout': 10, 'script': {}}
        def lost_host():
            raise RuntimeError('host generation lost')
        with patch.object(self.client.subprocess, 'Popen', return_value=proc):
            with self.assertRaisesRegex(RuntimeError, 'host generation lost'):
                self.client.run(payload, self.lease, self.work, lost_host)
        proc.terminate.assert_called_once()
        proc.wait.assert_called_once()

    def test_crash_recovery_does_not_signal_reused_pid(self):
        path = self.work / 'process.json'
        import json
        path.write_text(json.dumps({'pid': 123, 'start': 1}))
        with patch.object(self.client.gh, 'proc_start', return_value=2), \
                patch.object(self.client.os, 'kill') as kill:
            self.client.stop_record(path, 'test-job')
        kill.assert_not_called()


if __name__ == '__main__':
    unittest.main()
