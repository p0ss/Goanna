#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Compare Minecraft and Godot mipmaps on the CPU, without starting clients."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import goanna_headless


def statistics(path):
    with Image.open(path) as source:
        image = source.convert('RGBA')
        raw = image.tobytes()
        pixels = [raw[i:i + 4] for i in range(0, len(raw), 4)]
        visible = [p for p in pixels if p[3] >= 26]
        return {
            'size': list(image.size),
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'mean_alpha': sum(p[3] for p in pixels) / len(pixels),
            'coverage_0_1': len(visible) / len(pixels),
            'coverage_0_5': sum(p[3] >= 128 for p in pixels) / len(pixels),
            'visible_mean_rgb': [sum(p[c] for p in visible) / len(visible)
                                 for c in range(3)] if visible else None,
        }


def run(command, log, env=None):
    result = subprocess.run(command, env=env, cwd=log.parent,
                            capture_output=True, text=True, timeout=90)
    log.write_text(result.stdout + result.stderr)
    if result.returncode or 'ERROR:' in result.stderr:
        raise RuntimeError('CPU probe failed; see ' + str(log))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('texture', type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--root', type=Path, default=Path('build/minecraft'))
    parser.add_argument('--godot')
    parser.add_argument('--name', help='Minecraft sprite identifier')
    parser.add_argument('--strategy', choices=('auto', 'mean', 'cutout',
                        'strict_cutout', 'dark_cutout'))
    parser.add_argument('--levels', type=int, default=4)
    args = parser.parse_args()
    texture, out = args.texture.resolve(), args.out.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error('output directory must be empty')
    with Image.open(texture) as image:
        maximum = int(math.log2(min(image.size)))
    if not 0 <= args.levels <= maximum:
        parser.error('levels must be between 0 and %d' % maximum)
    metadata_path = texture.with_suffix(texture.suffix + '.mcmeta')
    metadata = json.loads(metadata_path.read_text()) if metadata_path.exists() else {}
    options = metadata.get('texture', {})
    strategy = args.strategy or options.get('mipmap_strategy', 'auto')
    name = args.name or 'minecraft:block/' + texture.stem
    bias = float(options.get('alpha_cutoff_bias', 0))
    installation = json.loads((args.root / 'installation.json').read_text())
    if installation['minecraft'] != '26.2':
        parser.error('this probe targets the named Minecraft 26.2 API')
    out.mkdir(parents=True, exist_ok=True)
    for engine in ('minecraft', 'godot'):
        (out / engine).mkdir()
    here = Path(__file__).resolve().parent
    java = installation['java']
    run([java, '--enable-native-access=ALL-UNNAMED',
         '--sun-misc-unsafe-memory-access=allow', '-cp',
         os.pathsep.join(installation['classpath']), str(here / 'MipmapProbe.java'),
         str(texture), str(out / 'minecraft'), name, strategy, str(bias),
         str(args.levels)], out / 'minecraft.log')
    scratch = out / 'cpu-project'
    scratch.mkdir()
    (scratch / 'project.godot').write_text('config_version=5\n')
    env = dict(os.environ, XDG_CONFIG_HOME=str(scratch / 'config'),
               XDG_DATA_HOME=str(scratch / 'data'), XDG_CACHE_HOME=str(scratch / 'cache'))
    godot = args.godot or goanna_headless.find_godot()
    run([godot, '--headless', '--path', str(scratch), '--script',
         str(here / 'mipmap_probe.gd'), '--', str(texture), str(out / 'godot'),
         str(args.levels)], out / 'godot.log', env)
    report = {
        'mode': 'cpu-only', 'minecraft': installation['minecraft'],
        'minecraft_client_sha256': hashlib.sha256(
            (args.root / 'client.jar').read_bytes()).hexdigest(),
        'godot': subprocess.check_output([godot, '--version'], text=True).strip(),
        'texture': str(texture), 'sha256': hashlib.sha256(texture.read_bytes()).hexdigest(),
        'metadata': metadata, 'strategy': strategy, 'name': name,
        'alpha_cutoff_bias': bias,
        'probe_sources': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in (here / 'MipmapProbe.java', here / 'mipmap_probe.gd')},
        'note': 'Minecraft may change transparent RGB in the base image. '
                'Coverage at both thresholds is reported; shader thresholds vary. '
                'This compares generated pixels, not live atlas sampling.',
        'levels': [{engine: statistics(out / engine / ('mip-%d.png' % level))
                    for engine in ('minecraft', 'godot')}
                   for level in range(args.levels + 1)],
    }
    (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(out / 'report.json')


if __name__ == '__main__':
    main()
