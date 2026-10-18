#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Check camera alignment, capture rejection and isolated pack preparation."""

import json
import copy
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import goanna_render as render
from goanna_render_minecraft import (camera, validate_clock_state, validate_frame_state,
                                    validate_stage_state, validate_shader_state)
from minecraft.profile import fingerprint, prepare, unpack
from minecraft.build_bridge import mirrored_sky_marker, neutral_node_colours, liquid_tile_tints
from minecraft.light_metrics import validate_reference


class ComparisonTests(unittest.TestCase):
    def test_failed_shader_chains_are_not_accepted_as_active(self):
        chain = {'gpu_ready': True, 'passes': [{'compiled': True, 'error': ''}]}
        validate_shader_state({'chain': chain})
        validate_shader_state({'gbuffers': {'terrain': {'translated': True}}})
        for reports in ({}, {'chain': dict(chain, gpu_ready=False)},
                        {'chain': dict(chain, dead=True)},
                        {'chain': dict(chain, passes=[{'compiled': False}])}):
            with self.subTest(reports=reports), self.assertRaises(render.RenderError):
                validate_shader_state(reports)

    def test_liquid_patch_retains_existing_colormap_rules(self):
        other = b'color_rgb: None,\n'
        liquid = b'fn generate_liquid_feature() { color_rgb: None, }'
        corrected = liquid_tile_tints(other + liquid)
        self.assertTrue(corrected.startswith(other))
        self.assertIn(b'utils::get_colormap(&s2c::media::LuantiTexture::from_luanti_safe(name))', corrected)
        with self.assertRaises(ValueError):
            liquid_tile_tints(other)

    def test_reused_reference_must_match_the_inputs(self):
        original = {'bridge_sha256': 'bridge', 'fixture_commands': ['stage'],
                    'installation': {'minecraft': '26.2'},
                    'client_mods': {'iris.jar': 'renderer', 'goanna-comparison.jar': 'probe'},
                    'job': {'poses': [{'name': 'calibration', 'pos': [1, 2, 3]}]},
                    'packs': {'shader': {'sha256_tree': 'shader'}, 'resource': None}}
        validate_reference(original, copy.deepcopy(original))
        metadata_only = copy.deepcopy(original)
        metadata_only['client_mods']['goanna-comparison.jar'] = 'new-probe'
        validate_reference(original, metadata_only)
        for key, value in [('bridge_sha256', 'other'), ('fixture_commands', ['other']),
                           ('client_mods', {'iris.jar': 'other'}),
                           ('job', {'poses': [{'name': 'calibration', 'pos': [4, 5, 6]}]})]:
            changed = copy.deepcopy(original)
            changed[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_reference(original, changed)
        for section, key, value in [('job', 'time_ticks', 18000),
                                    ('job', 'shader_options', {'SOFT_SHADOWS': False}),
                                    ('packs', 'shader', {'sha256_tree': 'other'}),
                                    ('packs', 'resource', {'sha256_tree': 'other'}),
                                    ('installation', 'minecraft', '1.21.8')]:
            changed = copy.deepcopy(original)
            changed[section][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_reference(original, changed)

    def test_missing_calibration_landmarks_are_rejected(self):
        validate_stage_state({'red': 'red_concrete', 'gold': 'gold_block'})
        validate_stage_state({'red': 'minecraft:red_concrete', 'gold': 'minecraft:gold_block'})
        for nodes in ({}, {'red': 'ignore', 'gold': 'gold_block'},
                      {'red': 'red_concrete', 'gold': 'air'}):
            with self.subTest(nodes=nodes), self.assertRaises(render.RenderError):
                validate_stage_state(nodes)

    def test_capture_clocks_use_the_same_phase(self):
        for ticks, tod in [(0, 0.25), (6000, 0.5), (12000, 0.75), (18000, 0)]:
            validate_clock_state('minecraft', {'world_time': ticks}, ticks)
            validate_clock_state('goanna', {'sky': {'time_of_day': tod}}, ticks)
        with self.assertRaises(render.RenderError):
            validate_clock_state('minecraft', {'world_time': 6040}, 6000)
        with self.assertRaises(render.RenderError):
            validate_clock_state('goanna', {'sky': {'time_of_day': 0.502}}, 6000)
        with self.assertRaises(render.RenderError):
            validate_clock_state('goanna', {}, 6000)

    def test_sky_marker_identifies_the_mirrored_bridge(self):
        definition = (b'name: String::from("bridgetest:glowing_air"),\n'
                      b'            groups: vec![(String::from(""), 1)],')
        corrected = mirrored_sky_marker(definition)
        self.assertIn(b'String::from("goanna_sky_mirror_x")', corrected)
        with self.assertRaises(ValueError):
            mirrored_sky_marker(b'other node')

    def test_neutral_node_colour_preserves_explicit_tints(self):
        definition = (b'red: 100,\n    green: 70,\n    blue: 85,\n'
                      b'post_effect_color: SColor::new(100, 70, 85, 20),\n'
                      b'color_rgb: Some((80, 160, 40)),\n')
        corrected = neutral_node_colours(definition * 3)
        self.assertEqual(corrected.count(b'red: 255,'), 3)
        self.assertEqual(corrected.count(b'green: 255,'), 3)
        self.assertEqual(corrected.count(b'blue: 255,'), 3)
        self.assertEqual(corrected.count(b'SColor::new(100, 70, 85, 20)'), 3)
        self.assertEqual(corrected.count(b'color_rgb: Some((80, 160, 40))'), 3)
        with self.assertRaises(ValueError):
            neutral_node_colours(definition)

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

    def test_profile_rejects_missing_block_semantics(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            out = root / 'capture'
            out.mkdir()
            with self.assertRaisesRegex(ValueError, 'block textures are missing'):
                prepare(root, out, {})

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
            self.assertIn('block-stone.png,block/stone.png',
                          Path(env['GOANNA_TEXTURE_MAP']).read_text())
            self.assertEqual(record['texture_map']['entries'], 1)
            clean = root / 'clean'
            clean.mkdir()
            env, record = prepare(root, clean, {})
            self.assertEqual(env['GOANNA_SHADERPACK'], '')
            self.assertEqual(env['GOANNA_SHADERPACK_OPTIONS'], '')
            self.assertEqual(env['GOANNA_PACK'], '')
            self.assertIn('block-stone.png,block/stone.png',
                          Path(env['GOANNA_TEXTURE_MAP']).read_text())
            self.assertEqual(record['texture_map']['entries'], 1)
            self.assertIn('enableShaders=false', (root / 'client/config/iris.properties').read_text())
            self.assertIn('resourcePacks:[]', (root / 'client/options.txt').read_text())


if __name__ == '__main__':
    unittest.main()
