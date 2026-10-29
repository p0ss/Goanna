#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Prepare pinned upstream games and a committed Kindred preview for hosting."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import zipfile


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mineclonia', type=Path, required=True)
    parser.add_argument('--voxelibre', type=Path, required=True)
    parser.add_argument('--kindred-repo', type=Path, required=True)
    parser.add_argument('--kindred-revision', required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--base-url', required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    pins = [
        ('mineclonia', 'Mineclonia', '0.123.1', args.mineclonia,
         '0363b120cedc10bc101a94b7a340435c242eaad434ad1b9a846fc49a9d85eb2a',
         'https://codeberg.org/mineclonia/mineclonia/archive/52a43e5c4b1877d8301231eda3e28e6b41380f87.zip'),
        ('mineclone2', 'VoxeLibre', '0.92.3', args.voxelibre,
         '4c3b3cacdd745c870a4330df20672b3418ac3c22dd20909faa3af4d15d14f3f5',
         'https://github.com/VoxeLibre/VoxeLibre/archive/a523240fb89713ffa6302696e8275bbd7de3bd49.zip'),
    ]
    rows = []
    for ident, title, version, source, expected, upstream in pins:
        if sha(source) != expected:
            raise ValueError('upstream hash mismatch: ' + str(source))
        with zipfile.ZipFile(source) as z:
            roots = {n.split('/')[0] for n in z.namelist()}
            if len(roots) != 1 or next(iter(roots)) + '/game.conf' not in z.namelist():
                raise ValueError('not a game archive: ' + str(source))
        target = args.out / (title.lower() + '-' + version + '.zip')
        if target.resolve() != source.resolve():
            target.write_bytes(source.read_bytes())
        rows.append(dict(id=ident, title=title, version=version, kind='game',
                         url=args.base_url.rstrip('/') + '/' + target.name,
                         sha256=sha(target), bytes=target.stat().st_size,
                         upstream=upstream))
    commit = subprocess.check_output(['git', 'rev-parse', args.kindred_revision + '^{commit}'],
                                    cwd=args.kindred_repo, text=True).strip()
    paths = ['mods/' + n for n in ('kindred', 'kindred_creatures', 'kindred_world', 'kindred_cultures')]
    paths += ['LICENSE', 'ATTRIBUTION.md']
    blob = subprocess.check_output(['git', 'archive', commit, *paths], cwd=args.kindred_repo)
    target = args.out / ('kindred-holdfast-preview-' + commit[:12] + '.zip')
    with tarfile.open(fileobj=io.BytesIO(blob)) as source, zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as dest:
        def write(name, data):
            entry = zipfile.ZipInfo('kindred_holdfast/' + name, (2026, 10, 29, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            dest.writestr(entry, data)
        for member in source:
            if member.isfile():
                write(member.name.removeprefix('mods/'), source.extractfile(member).read())
        write('modpack.conf', b'name = kindred_holdfast\ntitle = Kindred Holdfast (preview)\n')
        write('PREVIEW.md', ('# Kindred Holdfast preview\n\nRequires Mineclonia 0.123.1 and Luanti 5.17.\nUse a fresh world. Saved worlds may not migrate between previews.\n\nSource revision: ' + commit + '\n').encode())
    rows.append(dict(id='kindred_holdfast', title='Kindred Holdfast (preview)', version=commit[:12],
                     kind='modpack', requires='mineclonia',
                     url=args.base_url.rstrip('/') + '/' + target.name,
                     sha256=sha(target), bytes=target.stat().st_size,
                     upstream='Kindred repository commit ' + commit))
    (args.out / 'catalogue.json').write_text(json.dumps(rows, indent=2) + '\n')
    (args.out / 'SHA256SUMS').write_text(''.join(r['sha256'] + '  ' + r['url'].rsplit('/', 1)[1] + '\n' for r in rows))
    print(json.dumps(rows, indent=2))


if __name__ == '__main__':
    main()
