# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Resolve one shader and texture profile for both comparison clients."""

import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import zipfile


def unpack(source, destination):
    source, destination = Path(source).resolve(), Path(destination)
    if source.is_dir():
        shutil.copytree(source, destination)
    else:
        destination.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(source) as archive:
            for entry in archive.infolist():
                parts = PurePosixPath(entry.filename)
                if parts.is_absolute() or '..' in parts.parts or '\\' in entry.filename:
                    raise ValueError('Unsafe archive path: ' + entry.filename)
            archive.extractall(destination)


def fingerprint(directory):
    result = hashlib.sha256()
    for file in sorted(Path(directory).rglob('*')):
        if file.is_file():
            result.update(str(file.relative_to(directory)).encode() + b'\0')
            result.update(file.read_bytes())
    return result.hexdigest()


def option_file(path, updates, separator=':'):
    path = Path(path)
    values = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if separator in line and not line.startswith('#'):
                key, value = line.split(separator, 1)
                values[key] = value
    values.update(updates)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(''.join(k + separator + str(v) + '\n' for k, v in values.items()))


def prepare(root, out, job):
    profile = out / 'profile'
    profile.mkdir()
    env = {'GOANNA_SHADERPACK': '', 'GOANNA_SHADERPACK_OPTIONS': '',
           'GOANNA_PACK': '', 'GOANNA_TEXTURE_MAP': ''}
    result = {'shader': None, 'resource': None, 'shader_options': job.get('shader_options', {})}
    iris = {'enableShaders': 'false'}
    if job.get('shader_pack'):
        unpack(job['shader_pack'], profile / 'shader')
        candidates = [p.parent for p in (profile / 'shader').rglob('shaders') if p.is_dir()]
        if len(candidates) != 1:
            raise ValueError('Shader pack must contain exactly one shaders directory')
        shader = candidates[0]
        target = root / 'client/shaderpacks/comparison'
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(shader, target)
        options = job.get('shader_options', {})
        for key, value in options.items():
            if any(c in str(key) + str(value) for c in '\n\r,='):
                raise ValueError('Shader options must be single NAME=value pairs')
        (target.parent / 'comparison.txt').write_text(''.join(
            '%s=%s\n' % (k, str(v).lower() if isinstance(v, bool) else v)
            for k, v in sorted(options.items())))
        iris.update(enableShaders='true', shaderPack='comparison')
        env['GOANNA_SHADERPACK'] = str(shader)
        env['GOANNA_SHADERPACK_OPTIONS'] = ','.join(
            '%s=%s' % (k, str(v).lower() if isinstance(v, bool) else v)
            for k, v in sorted(options.items()))
        result['shader'] = {'source': str(Path(job['shader_pack']).resolve()),
                            'sha256_tree': fingerprint(shader)}
    option_file(root / 'client/config/iris.properties', iris, '=')
    resource_names = []
    if job.get('resource_pack'):
        unpack(job['resource_pack'], profile / 'resource')
        resource = profile / 'resource'
        if not (resource / 'pack.mcmeta').is_file():
            raise ValueError('Resource pack needs pack.mcmeta at its root')
        # Geometry mappings are embedded in BridgeTest's binary. A texture
        # profile must not silently pretend to apply changed block models.
        assets = resource / 'assets/minecraft'
        if any((assets / name).exists() for name in ('models', 'blockstates')):
            raise ValueError('Model-changing packs need regenerated BridgeTest mappings')
        textures = assets / 'textures'
        if not textures.is_dir():
            raise ValueError('Resource pack has no Minecraft textures')
        bridge_data = profile / 'data/bridgetest'
        shutil.copytree(root / 'data/bridgetest/textures', bridge_data / 'textures')
        shutil.copytree(textures, bridge_data / 'textures', dirs_exist_ok=True)
        (bridge_data / 'bridgetest_assets').symlink_to(root / 'data/bridgetest/bridgetest_assets',
                                                    target_is_directory=True)
        overrides = profile / 'goanna-textures'
        overrides.mkdir()
        for file in sorted(textures.rglob('*')):
            if file.is_file():
                flat = str(file.relative_to(textures)).replace('/', '-')
                if (overrides / flat).exists():
                    raise ValueError('Flattened texture name collision: ' + flat)
                shutil.copyfile(file, overrides / flat)
        env['GOANNA_PACK'] = str(overrides)
        result['bridge_data'] = str(profile / 'data')
        target = root / 'client/resourcepacks/comparison'
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(resource, target)
        resource_names = ['file/comparison']
        result['resource'] = {'source': str(Path(job['resource_pack']).resolve()),
                              'sha256_tree': fingerprint(resource)}
    option_file(root / 'client/options.txt', {'resourcePacks': json.dumps(resource_names),
                                             'incompatibleResourcePacks': '[]'})
    return env, result
