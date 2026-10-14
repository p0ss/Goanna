#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Build a pinned BridgeTest in the ignored comparison installation."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

BRIDGE_REV = '093807327ea75fbaff91ee3f5dc56c83dbe2efdd'
DATA_REV = '46b78398b6f351958e02fbd266424f0ee0ab138b'
TOOLCHAIN = 'nightly-2026-10-14'


def checkout(url, revision, destination):
    if not destination.exists():
        subprocess.run(['git', 'clone', '--no-checkout', url, str(destination)], check=True)
        subprocess.run(['git', '-C', str(destination), 'checkout', '--detach', revision],
                       check=True)
    actual = subprocess.check_output(['git', '-C', str(destination), 'rev-parse', 'HEAD'],
                                     text=True).strip()
    if actual != revision:
        raise ValueError('Unexpected checkout revision: ' + str(destination))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('build/minecraft'))
    parser.add_argument('--cargo', default='cargo')
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    root = args.root.resolve()
    sources = root / 'sources'
    sources.mkdir(parents=True, exist_ok=True)
    bridge, data = sources / 'bridgetest', sources / 'minecraft-data'
    checkout('https://github.com/l-koehler/bridgetest.git', BRIDGE_REV, bridge)
    checkout('https://github.com/PrismarineJS/minecraft-data.git', DATA_REV, data)
    # minecraft-data-rs 0.8.1 uses the old item name. The bridge otherwise
    # panics on joining, before it can send definitions. Keep the correction
    # in our build copy and record it, rather than changing the owner's clone.
    mapping = bridge / 'extra_data/item_texture_map.json'
    original = subprocess.check_output(['git', '-C', str(bridge), 'show',
                                        'HEAD:extra_data/item_texture_map.json'])
    entries = json.loads(original)
    entries['minecraft:scute'] = entries['minecraft:turtle_scute']
    overlay = (json.dumps(entries, indent=2) + '\n').encode()
    if mapping.read_bytes() not in (original, overlay):
        raise ValueError('Unexpected local edits in the bridge texture map')
    mapping.write_bytes(overlay)
    rules = bridge / 'src/s2c/defs.rs'
    original_rules = subprocess.check_output(['git', '-C', str(bridge), 'show',
                                              'HEAD:src/s2c/defs.rs'])
    old = b'privileges: vec![String::from("interact"), String::from("shout")],'
    new = (b'privileges: if std::env::var("GOANNA_COMPARISON_CAMERA").ok().as_deref() == Some("1") '
           b'{ vec![String::from("interact"), String::from("shout"), String::from("fly"), String::from("noclip")] } '
           b'else { vec![String::from("interact"), String::from("shout")] },')
    if original_rules.count(old) != 1:
        raise ValueError('BridgeTest privilege definition changed')
    comparison_rules = original_rules.replace(old, new)
    if rules.read_bytes() not in (original_rules, comparison_rules):
        raise ValueError('Unexpected edits in the bridge rule definitions')
    rules.write_bytes(comparison_rules)
    player = bridge / 'src/s2c/player.rs'
    original_player = subprocess.check_output(['git', '-C', str(bridge), 'show',
                                               'HEAD:src/s2c/player.rs'])
    marker = b'    let vec_serverpos = mc_client.position().unwrap();'
    if original_player.count(marker) != 1:
        raise ValueError('BridgeTest position reconciliation changed')
    # Azalea's simulated player keeps falling even when the Minecraft world
    # ticks are frozen. Retain server teleports, but stop that simulation
    # from pulling the spectator camera away from its measured pose.
    comparison_player = original_player.replace(marker,
        b'    if std::env::var("GOANNA_COMPARISON_CAMERA").ok().as_deref() == Some("1") { return; }\n' + marker)
    if player.read_bytes() not in (original_player, comparison_player):
        raise ValueError('Unexpected edits in the bridge position handling')
    player.write_bytes(comparison_player)
    dirty = subprocess.check_output(['git', '-C', str(bridge), 'diff', '--name-only'],
                                    text=True).splitlines()
    if dirty != ['extra_data/item_texture_map.json', 'src/s2c/defs.rs', 'src/s2c/player.rs']:
        raise ValueError('Unexpected edits in the BridgeTest build copy: ' + str(dirty))
    env = dict(os.environ, MINECRAFT_DATA_REPO_PATH=str(data),
               CARGO_TARGET_DIR=str(root / 'bridge-target'))
    subprocess.run([args.cargo, '+' + TOOLCHAIN, 'build', '--release', '--locked',
                    '-j', str(args.jobs), '--manifest-path', str(bridge / 'Cargo.toml')],
                   env=env, check=True)
    binary = root / 'bridge-target/release/bridgetest'
    with binary.open('rb') as stream:
        sha = hashlib.file_digest(stream, 'sha256').hexdigest()
    record = {'bridge_revision': BRIDGE_REV, 'minecraft_data_revision': DATA_REV,
              'toolchain': TOOLCHAIN, 'binary_sha256': sha,
              'overlay': {'minecraft:scute': entries['minecraft:scute']},
              'comparison_privileges': ['fly', 'noclip'],
              'comparison_camera_env': 'GOANNA_COMPARISON_CAMERA=1',
              'cargo_lock_sha256': hashlib.sha256((bridge / 'Cargo.lock').read_bytes()).hexdigest()}
    (root / 'bridge-build.json').write_text(json.dumps(record, indent=2) + '\n')
    print(binary)


if __name__ == '__main__':
    main()
