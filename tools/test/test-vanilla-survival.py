#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Check vanilla creative/survival configuration without starting a client."""
import json
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import goanna_render as render
import goanna_render_vanilla as vanilla


class StopBeforeStart(Exception):
    pass


class SurvivalTest(unittest.TestCase):
    def server(self, directory, **kwargs):
        return vanilla.ReferenceServer('mineclonia', None, (0, 0, 0), '', directory,
                                       poses=[], tod=.5, **kwargs)

    def test_default_preserves_exact_configuration(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'server.conf'
            original = '# retained\ncreative_mode = true\nother = retained\n'
            path.write_text(original)
            stamp = path.stat().st_mtime_ns
            with mock.patch.object(render.Server, 'write_conf', return_value=path):
                server = self.server(Path(temporary))
                self.assertEqual(server.write_conf(), path)
            self.assertTrue(server.creative)
            self.assertEqual(path.read_text(), original)
            self.assertEqual(path.stat().st_mtime_ns, stamp)

    def test_survival_changes_only_the_validated_setting(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'server.conf'
            path.write_text('# retained\ncreative_mode = true\nother = retained\n')
            with mock.patch.object(render.Server, 'write_conf', return_value=path):
                server = self.server(Path(temporary), creative=False)
                server.write_conf()
            self.assertFalse(server.creative)
            self.assertEqual(path.read_text(), '# retained\ncreative_mode = false\nother = retained\n')

    def test_missing_duplicate_and_malformed_settings_reject(self):
        for text in ('other = retained\n', 'creative_mode = true\ncreative_mode = false\n',
                     'creative_mode = maybe\n'):
            with self.subTest(text=text), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / 'server.conf'
                path.write_text(text)
                with mock.patch.object(render.Server, 'write_conf', return_value=path):
                    with self.assertRaises(render.RenderError):
                        self.server(Path(temporary), creative=False).write_conf()
                self.assertEqual(path.read_text(), text)

    def test_mode_requires_boolean(self):
        with self.assertRaises(render.RenderError):
            self.server(Path('/tmp'), creative='false')

    def test_cli_default_and_survival_forward_before_start(self):
        for flags, expected in (([], True), (['--survival'], False)):
            with self.subTest(flags=flags), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                job = root / 'job.json'
                job.write_text(json.dumps({'out': str(root / 'frames'), 'frame': 'world',
                                           'poses': [{'name': 'one', 'pos': [0, 2, 0]}]}))
                with mock.patch.object(render.gh, 'acquire_gpu_lock', return_value=(None, False)), \
                     mock.patch.object(render, 'foreign_gpu_users', return_value=[]), \
                     mock.patch.object(vanilla, 'ReferenceServer', side_effect=StopBeforeStart) as factory:
                    with self.assertRaises(StopBeforeStart):
                        vanilla.command([str(job), '--world-from', 'not-started'] + flags)
                self.assertIs(factory.call_args.kwargs['creative'], expected)


class CaptureAckTest(unittest.TestCase):
    def test_matching_completed_capture(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            image = root / 'image.png'
            image.write_bytes(b'completed image')
            ack = root / 'ack.json'
            ack.write_text(json.dumps({'sha256': hashlib.sha256(image.read_bytes()).hexdigest(),
                                       'world_visible': True}))
            vanilla.wait_capture_ack(ack, image, 1)

    def test_wrong_image_unverified_and_malformed_reject(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            image = root / 'image.png'
            image.write_bytes(b'image')
            ack = root / 'ack.json'
            for value in ('{}', '[]', 'invalid', json.dumps({'sha256': 'wrong', 'world_visible': True})):
                ack.write_text(value)
                with self.assertRaises(render.RenderError):
                    vanilla.wait_capture_ack(ack, image, 1)

    def test_missing_ack_times_out(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            image = root / 'image.png'
            image.write_bytes(b'image')
            with mock.patch.object(vanilla.time, 'monotonic', side_effect=[0, 2]):
                with self.assertRaises(render.RenderError):
                    vanilla.wait_capture_ack(root / 'absent.json', image, 1)


if __name__ == '__main__':
    unittest.main()
