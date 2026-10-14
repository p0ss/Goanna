#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Check camera alignment, capture rejection and isolated pack preparation."""

import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import goanna_render as render
from goanna_render_minecraft import camera, validate_frame_state
from minecraft.profile import fingerprint, prepare, unpack


class ComparisonTests(unittest.TestCase):
    def test_block_centres_and_camera_axes(self):
        # A Minecraft cube at (0, 100, 0) centres on (.5, 100.5, .5).
        # BridgeTest moves that centre to (-1, 100, 0) in Goanna.
        mc, goanna = camera({'pos': [.5, 100.5, .5], 'look_at': [.5, 100.5, 1.5]})
        self.assertEqual((goanna['x'], goanna['y'], goanna['z']), (-1, 100, 0))
        self.assertEqual((mc['yaw'], mc['pitch']), (0, 0))
        self.assertEqual((goanna['yaw'], goanna['pitch']), (0, 0))
        mc, goanna = camera({'pos': [0, 0, 0], 'look_at': [1, 1, 0]})
        self.assertAlmostEqual(mc['yaw'], -90)
        self.assertAlmostEqual(mc['pitch'], -45)
        self.assertAlmostEqual(goanna['yaw'], 90)
        self.assertAlmostEqual(goanna['pitch'], 45)

    def test_disconnected_or_empty_capture_is_rejected(self):
        for name, state in [('minecraft', {'connected': False}),
                            ('goanna', {'state': 'disconnected', 'blocks_meshed': 100}),
                            ('goanna', {'state': 'ready', 'blocks_meshed': 0})]:
            with self.subTest(name=name, state=state), self.assertRaises(render.RenderError):
                validate_frame_state(name, state)

    def test_archive_cannot_escape_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ('../escape', '/absolute', 'shaders/../../escape', 'shaders\\escape'):
                archive = root / 'unsafe.zip'
                with zipfile.ZipFile(archive, 'w') as output:
                    output.writestr(name, 'invalid')
                with self.subTest(name=name), self.assertRaises(ValueError):
                    unpack(archive, root / 'profile')
            self.assertFalse((root / 'escape').exists())

    def test_profiles_reset_without_changing_source_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            vanilla = root / 'data/bridgetest/textures/block'
            vanilla.mkdir(parents=True)
            (vanilla / 'stone.png').write_bytes(b'vanilla')
            (root / 'data/bridgetest/bridgetest_assets').mkdir()
            resource = root / 'resource'
            texture = resource / 'assets/minecraft/textures/block'
            texture.mkdir(parents=True)
            (texture / 'stone.png').write_bytes(b'override')
            (resource / 'pack.mcmeta').write_text(json.dumps({'pack': {'pack_format': 88}}))
            shader = root / 'shader/shaders'
            shader.mkdir(parents=True)
            (shader / 'final.fsh').write_text('void main() {}')
            before = fingerprint(resource)
            out = root / 'capture'
            out.mkdir()
            env, record = prepare(root, out, {'resource_pack': str(resource),
                'shader_pack': str(shader.parent), 'shader_options': {'SSAO': False}})
            self.assertEqual((vanilla / 'stone.png').read_bytes(), b'vanilla')
            self.assertEqual(fingerprint(resource), before)
            self.assertEqual((Path(env['GOANNA_PACK']) / 'block-stone.png').read_bytes(), b'override')
            self.assertEqual((Path(record['bridge_data']) / 'bridgetest/textures/block/stone.png')
                             .read_bytes(), b'override')
            self.assertEqual(env['GOANNA_SHADERPACK_OPTIONS'], 'SSAO=false')
            clean = root / 'clean'
            clean.mkdir()
            env, record = prepare(root, clean, {})
            self.assertEqual(env['GOANNA_SHADERPACK'], '')
            self.assertEqual(env['GOANNA_SHADERPACK_OPTIONS'], '')
            self.assertEqual(env['GOANNA_PACK'], '')
            self.assertIn('enableShaders=false', (root / 'client/config/iris.properties').read_text())
            self.assertIn('resourcePacks:[]', (root / 'client/options.txt').read_text())


if __name__ == '__main__':
    unittest.main()
