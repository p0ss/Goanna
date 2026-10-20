#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Measure paired calibration captures, without changing their images.

Requires Pillow. These fixed areas measure this stage and camera only;
animated textures, foliage, sky, water and geometry edges need separate
inspection even when their mean colour is sampled. Mean colour agreement
does not establish whole-frame parity.
"""

import argparse
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageStat


SURFACES = {
    'floor': (570, 590, 710, 690),
    'wood': (488, 326, 569, 378),
    'red': (456, 280, 473, 300),
    'blue': (806, 280, 821, 300),
    'gold': (628, 378, 650, 413),
    'wood_right': (574, 325, 578, 370),
    'glass': (722, 328, 780, 348),
    'foliage': (770, 435, 880, 485),
    'water': (430, 460, 490, 490),
    'sky': (500, 200, 700, 235),
    # The sea lantern's front face, above the gold pillar.
    'lamp': (628, 300, 652, 328),
}
# The current Goanna screen-space UV convention swaps the probe's rows.
# Pair the same buffers explicitly, rather than comparing different inputs.
INPUTS = {'albedo': (280, 290, 280, 650, 50, 30),
          'albedo_far': (175, 185, 175, 545, 50, 25),
          'vertex_colour': (920, 290, 920, 650, 50, 30),
          'light_coordinates': (280, 650, 280, 290, 50, 30),
          'sun_direction': (920, 650, 920, 290, 50, 30)}


def measure(reference, candidate):
    means = [ImageStat.Stat(im).mean for im in (reference, candidate)]
    error = ImageStat.Stat(ImageChops.difference(reference, candidate)).mean
    return {'minecraft_rgb': means[0], 'goanna_rgb': means[1],
            'minecraft_rgb_stddev': ImageStat.Stat(reference).stddev,
            'goanna_rgb_stddev': ImageStat.Stat(candidate).stddev,
            'mean_rgb_delta': [b - a for a, b in zip(*means)],
            'pixel_rgb_mae': error,
            'maximum_mean_channel_error': max(abs(b - a) for a, b in zip(*means))}


def validate_reference(candidate, reference):
    for key in ('bridge_sha256', 'fixture_commands'):
        if candidate.get(key) != reference.get(key):
            raise ValueError('reference differs in ' + key)
    if candidate['installation']['minecraft'] != reference['installation']['minecraft']:
        raise ValueError('reference uses another Minecraft version')
    mods = [{k: v for k, v in r.get('client_mods', {}).items()
             if k != 'goanna-comparison.jar'} for r in (candidate, reference)]
    if mods[0] != mods[1]:
        raise ValueError('reference uses different Minecraft render mods')
    for key, default in (('time_ticks', 6000), ('shader_options', {})):
        if candidate['job'].get(key, default) != reference['job'].get(key, default):
            raise ValueError('reference differs in ' + key)
    for kind in ('shader', 'resource'):
        a, b = candidate['packs'].get(kind), reference['packs'].get(kind)
        if (a or {}).get('sha256_tree') != (b or {}).get('sha256_tree'):
            raise ValueError('reference uses another ' + kind + ' pack')
    poses = [next(p for p in r['job']['poses'] if p['name'] == 'calibration')
             for r in (candidate, reference)]
    if poses[0] != poses[1]:
        raise ValueError('reference uses another calibration camera')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('--inputs', action='store_true', help='measure the light-inputs probe')
    parser.add_argument('--out', type=Path, help='write the complete JSON report here')
    parser.add_argument('--reference', type=Path,
                        help='reuse a matched Minecraft capture for a Goanna-only rerun')
    args = parser.parse_args()
    root = args.capture.resolve()
    result = json.loads((root / 'result.json').read_text())
    if not result['ok']:
        parser.error('the comparison capture failed')
    reference = args.reference.resolve() if args.reference else root
    reference_result = json.loads((reference / 'result.json').read_text())
    if not reference_result['ok']:
        parser.error('the reference capture failed')
    try:
        validate_reference(result, reference_result)
    except ValueError as error:
        parser.error(str(error))
    images = [Image.open(reference / 'calibration-minecraft.png').convert('RGB'),
              Image.open(root / 'calibration-goanna.png').convert('RGB')]
    pose = next(p for p in result['job']['poses'] if p['name'] == 'calibration')
    if (any(im.size != (1280, 720) for im in images) or
            pose.get('pos') != [8.5, 106, 24.5] or
            pose.get('look_at') != [8.5, 101.5, 6.5] or pose.get('fov') != 70):
        parser.error('these sample areas require the standard calibration camera at 1280x720')
    rows = {}
    if args.inputs:
        for name, (mx, my, gx, gy, width, height) in INPUTS.items():
            rows[name] = measure(images[0].crop((mx, my, mx + width, my + height)),
                                 images[1].crop((gx, gy, gx + width, gy + height)))
    else:
        for name, box in SURFACES.items():
            rows[name] = measure(*(im.crop(box) for im in images))
    report = {'capture': str(root), 'reference_capture': str(reference),
              'inputs': args.inputs, 'samples': rows,
              'time_ticks': result['job'].get('time_ticks', 6000),
              'shader_options': result['job'].get('shader_options', {}),
              'goanna': result['goanna'], 'bridge_sha256': result['bridge_sha256'],
              'scope': 'fixed calibration samples, no whole-frame parity claim'}
    if args.out:
        args.out.write_text(json.dumps(report, indent=2) + '\n')
    for name, row in rows.items():
        print('%s: Minecraft %s, Goanna %s, maximum mean channel error %.2f' %
              (name, [round(v, 2) for v in row['minecraft_rgb']],
               [round(v, 2) for v in row['goanna_rgb']],
               row['maximum_mean_channel_error']))


if __name__ == '__main__':
    main()
