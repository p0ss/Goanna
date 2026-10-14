#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Measure paired calibration captures, without changing their images.

Requires Pillow. These fixed areas measure this stage and camera only;
animated textures, foliage, sky, water and geometry edges need separate
inspection. Mean colour agreement does not establish whole-frame parity.
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
}
# The current Goanna screen-space UV convention swaps the probe's rows.
# Pair the same buffers explicitly, rather than comparing different inputs.
INPUTS = {'albedo': (280, 290, 280, 650),
          'vertex_colour': (920, 290, 920, 650),
          'light_coordinates': (280, 650, 280, 290),
          'sun_direction': (920, 650, 920, 290)}


def measure(reference, candidate):
    means = [ImageStat.Stat(im).mean for im in (reference, candidate)]
    error = ImageStat.Stat(ImageChops.difference(reference, candidate)).mean
    return {'minecraft_rgb': means[0], 'goanna_rgb': means[1],
            'mean_rgb_delta': [b - a for a, b in zip(*means)],
            'pixel_rgb_mae': error,
            'maximum_mean_channel_error': max(abs(b - a) for a, b in zip(*means))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('--inputs', action='store_true', help='measure the light-inputs probe')
    parser.add_argument('--out', type=Path, help='write the complete JSON report here')
    args = parser.parse_args()
    root = args.capture.resolve()
    result = json.loads((root / 'result.json').read_text())
    if not result['ok']:
        parser.error('the comparison capture failed')
    images = [Image.open(root / ('calibration-' + renderer + '.png')).convert('RGB')
              for renderer in ('minecraft', 'goanna')]
    pose = next(p for p in result['job']['poses'] if p['name'] == 'calibration')
    if (any(im.size != (1280, 720) for im in images) or
            pose.get('pos') != [8.5, 106, 24.5] or
            pose.get('look_at') != [8.5, 101.5, 6.5] or pose.get('fov') != 70):
        parser.error('these sample areas require the standard calibration camera at 1280x720')
    rows = {}
    if args.inputs:
        for name, (mx, my, gx, gy) in INPUTS.items():
            rows[name] = measure(images[0].crop((mx, my, mx + 50, my + 30)),
                                 images[1].crop((gx, gy, gx + 50, gy + 30)))
    else:
        for name, box in SURFACES.items():
            rows[name] = measure(*(im.crop(box) for im in images))
    report = {'capture': str(root), 'inputs': args.inputs, 'samples': rows,
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
