#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Compile the local capture mod against the installed, named 26.2 classes."""

import argparse
import json
from pathlib import Path
import subprocess
import zipfile


def build(root):
    root = Path(root).resolve()
    installation = json.loads((root / 'installation.json').read_text())
    source = Path(__file__).with_name('ComparisonMixin.java')
    classes = root / 'helper-classes'
    classes.mkdir(exist_ok=True)
    javac = Path(installation['java']).with_name('javac')
    subprocess.run([str(javac), '-proc:none', '--release', '25', '-cp',
                    ':'.join(installation['classpath']), '-d', str(classes), str(source)],
                   check=True)
    path = root / 'client/mods/goanna-comparison.jar'
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
        for file in classes.rglob('*.class'):
            archive.write(file, str(file.relative_to(classes)))
        archive.writestr('fabric.mod.json', json.dumps({
            'schemaVersion': 1, 'id': 'goanna_comparison', 'version': '0.1.0',
            'name': 'Goanna comparison control', 'environment': 'client',
            'license': 'LGPL-2.1-or-later', 'mixins': ['goanna-comparison.mixins.json'],
            'depends': {'fabricloader': '>=0.19.5', 'minecraft': '=26.2', 'java': '>=25'}}))
        archive.writestr('goanna-comparison.mixins.json', json.dumps({
            'required': True, 'package': 'org.goanna.comparison',
            'compatibilityLevel': 'JAVA_25', 'client': ['ComparisonMixin'],
            'injectors': {'defaultRequire': 1}}))
    print(path)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('build/minecraft'))
    build(parser.parse_args().root)
