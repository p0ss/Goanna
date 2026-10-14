#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Install the isolated Java 26.2 comparison client and local test server."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
import json
from pathlib import Path
import subprocess
import time
import urllib.request
import zipfile

VERSION = '26.2'
LOADER = '0.19.5'
IRIS = '1.11.4+26.2-fabric'
SODIUM = 'mc26.2-0.9.2-fabric'
VERSION_URL = ('https://piston-meta.mojang.com/v1/packages/'
               '91ef51b7d36ca092c5c02aba42f0f40c7cc1db84/26.2.json')


def fetch(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'Goanna-comparison/0.1'})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return response.read()
        except (OSError, http.client.HTTPException):
            if attempt == 3:
                raise
            time.sleep(2 ** attempt)


def metadata(url):
    return json.loads(fetch(url))


def digest(path, algorithm='sha256'):
    with Path(path).open('rb') as source:
        return hashlib.file_digest(source, algorithm).hexdigest()


def download(url, path, expected=None, algorithm='sha1'):
    path = Path(path)
    if path.exists() and (expected is None or digest(path, algorithm) == expected):
        return path
    data = fetch(url)
    if expected and hashlib.new(algorithm, data).hexdigest() != expected:
        raise ValueError('Checksum mismatch: ' + url)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.part')
    temporary.write_bytes(data)
    temporary.replace(path)
    return path


def allowed(entry):
    """Evaluate Mojang rules for this Linux x86_64 installation."""
    result = not entry.get('rules')
    for rule in entry.get('rules', []):
        system = rule.get('os', {})
        if system.get('name', 'linux') != 'linux':
            continue
        if system.get('arch', 'x86_64') not in ('x86_64', 'amd64'):
            continue
        if rule.get('features'):
            continue
        result = rule['action'] == 'allow'
    return result


def library(root, item):
    if not allowed(item):
        return None
    artifact = item.get('downloads', {}).get('artifact')
    if artifact:
        return download(artifact['url'], root / artifact['path'], artifact['sha1'])
    group, name, version = item['name'].split(':')
    relative = '/'.join((group.replace('.', '/'), name, version,
                         name + '-' + version + '.jar'))
    return download(item.get('url', 'https://libraries.minecraft.net/') + relative,
                    root / relative)


def install_mod(root, project, version):
    versions = metadata('https://api.modrinth.com/v2/project/' + project + '/version')
    selected = next(v for v in versions if v['version_number'] == version)
    artifact = next(f for f in selected['files'] if f['primary'])
    path = download(artifact['url'], root / artifact['filename'],
                    artifact['hashes']['sha512'], 'sha512')
    return {'version': version, 'path': str(path), 'sha256': digest(path),
            'dependencies': selected['dependencies']}


def write_once(path, content):
    if not path.exists():
        path.write_text(content)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, default=Path('build/minecraft'))
    ap.add_argument('--java', type=Path, required=True)
    ap.add_argument('--accept-eula', action='store_true',
                    help='record your acceptance of https://www.minecraft.net/eula')
    args = ap.parse_args()
    root, java = args.root.resolve(), args.java.resolve()
    root.mkdir(parents=True, exist_ok=True)
    java_version = subprocess.check_output([str(java), '-version'], stderr=subprocess.STDOUT,
                                           text=True)
    if 'version "25' not in java_version:
        ap.error('Minecraft 26.2 requires Java 25; provide its bin/java')
    client, server = root / 'client', root / 'server'
    for directory in (client / 'mods', client / 'config', server, root / 'config', root / 'assets'):
        directory.mkdir(parents=True, exist_ok=True)
    version = metadata(VERSION_URL)
    (root / 'version.json').write_text(json.dumps(version, indent=2) + '\n')
    jars = {}
    for kind in ('client', 'server'):
        entry = version['downloads'][kind]
        jars[kind] = download(entry['url'], root / (kind + '.jar'), entry['sha1'])
    fabric = metadata('https://meta.fabricmc.net/v2/versions/loader/' + VERSION + '/' +
                      LOADER + '/profile/json')
    (root / 'fabric.json').write_text(json.dumps(fabric, indent=2) + '\n')
    with ThreadPoolExecutor(max_workers=8) as pool:
        classpath = list(pool.map(lambda item: library(root / 'libraries', item),
                                  version['libraries'] + fabric['libraries']))
    classpath = [str(p) for p in classpath if p] + [str(jars['client'])]
    print('Downloaded client, server and libraries', flush=True)
    index = version['assetIndex']
    index_path = download(index['url'], root / 'assets/indexes' /
                          (index['id'] + '.json'), index['sha1'])
    objects = json.loads(index_path.read_text())['objects']
    hashes = sorted({v['hash'] for v in objects.values()})
    def asset(sha):
        return download('https://resources.download.minecraft.net/' + sha[:2] + '/' + sha,
                        root / 'assets/objects' / sha[:2] / sha, sha)
    with ThreadPoolExecutor(max_workers=8) as pool:
        for _ in pool.map(asset, hashes):
            pass
    print('Downloaded %d asset objects' % len(hashes), flush=True)
    mods = {name: install_mod(client / 'mods', name, version)
            for name, version in (('iris', IRIS), ('sodium', SODIUM))}
    textures = root / 'data/bridgetest/textures'
    with zipfile.ZipFile(jars['client']) as archive:
        prefix = 'assets/minecraft/textures/'
        for name in archive.namelist():
            if not name.startswith(prefix) or name.endswith('/'):
                continue
            target = textures / name[len(prefix):]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(name))
    write_once(root / 'config/bridgetest.toml', '''[net]
mc_server = "127.0.0.1:25585"
luanti_port = 30985
local_only = true
[auth]
allow_random_user = false
online_mode = false
microsoft_email = ""
[media]
texture_pack_res = 16
''')
    write_once(server / 'server.properties', '''server-ip=127.0.0.1
server-port=25585
online-mode=false
enforce-secure-profile=false
enable-rcon=false
gamemode=creative
force-gamemode=true
spawn-protection=0
view-distance=8
simulation-distance=4
level-seed=20261014
max-players=4
pause-when-empty-seconds=-1
motd=Goanna local shader comparison
''')
    if args.accept_eula:
        (server / 'eula.txt').write_text('eula=true\n')
    write_once(client / 'options.txt', '''fullscreen:false
pauseOnLostFocus:false
enableVsync:false
maxFps:60
renderDistance:8
simulationDistance:4
bobView:false
entityShadows:false
soundCategory_master:0.0
onboardAccessibility:false
skipMultiplayerWarning:true
''')
    write_once(client / 'config/iris.properties', 'enableShaders=false\n')
    manifest = {'minecraft': VERSION, 'java': str(java), 'java_version': java_version.strip(),
                'fabric': LOADER, 'main_class': fabric['mainClass'], 'classpath': classpath,
                'asset_index': index['id'], 'mods': mods,
                'jars': {k: {'path': str(v), 'sha256': digest(v)} for k, v in jars.items()},
                'libraries': [{'path': p, 'sha256': digest(p)} for p in classpath]}
    with zipfile.ZipFile(jars['client']) as archive:
        manifest['formats'] = json.loads(archive.read('version.json'))
    (root / 'installation.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('Installed comparison environment in ' + str(root))


if __name__ == '__main__':
    main()
