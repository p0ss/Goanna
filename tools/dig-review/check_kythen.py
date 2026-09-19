#!/usr/bin/env python3
"""Check Goanna's v3 damage port against a live Kythen checkout.

`goanna_radial_form_test` is pinned to `tools/dig-review/reference_v3.json`,
a copy of what Kythen's own `tools/dig-review/generate_reference.lua`
produces from `mods/kythen/core/radial_form.lua`. That copy is GENERATED and
committed so the test needs no Kythen checkout to run; this script is the
other half, for when one is available: it re-runs the real generator against
a live Kythen tree, so a check here is against the Lua ITSELF, not against
whatever was last copied over, and it says plainly whether the committed copy
has drifted.

Usage:
    tools/dig-review/check_kythen.py /path/to/Kythen
    tools/dig-review/check_kythen.py /path/to/Kythen --update

Kythen is read only here, as everywhere else in this repository: nothing in
this script writes to it. `--update` overwrites Goanna's OWN committed copy
with the fresh output when it differs; without it, a stale copy is reported
and left alone.
"""
import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

GOANNA_ROOT = Path(__file__).resolve().parents[2]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
            formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('kythen', type=Path, help='path to a Kythen checkout (read only)')
    ap.add_argument('--generator', default='tools/dig-review/generate_reference.lua',
            help='Kythen-relative path to the reference generator')
    ap.add_argument('--committed', default='tools/dig-review/reference_v3.json',
            help='Goanna-relative path to the committed reference copy')
    ap.add_argument('--binary', default='build/goanna_radial_form_test',
            help='Goanna-relative path to the built native test')
    ap.add_argument('--update', action='store_true',
            help="overwrite the committed copy when it is stale (Kythen stays untouched either way)")
    a = ap.parse_args()

    generator = a.kythen / a.generator
    if not generator.is_file():
        sys.exit(f'{generator} does not exist: is --kythen a Kythen checkout, '
                'and is it on a branch with the v3 damage rule (form/damage or later)?')

    print(f'Running {a.generator} from {a.kythen} through luajit...')
    result = subprocess.run(['luajit', str(generator)], cwd=a.kythen,
            capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f'generate_reference.lua failed:\n{result.stderr}')
    fresh = result.stdout

    committed_path = GOANNA_ROOT / a.committed
    committed = committed_path.read_text() if committed_path.is_file() else None
    stale = committed != fresh

    with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f:
        f.write(fresh)
        fresh_path = Path(f.name)

    binary_path = GOANNA_ROOT / a.binary
    if not binary_path.is_file():
        sys.exit(f'{binary_path} does not exist. Build it first: '
                'cmake --build build --target goanna_radial_form_test')
    print('Running the native port against the FRESH reference (not the committed copy)...')
    test = subprocess.run([str(binary_path), str(fresh_path)])

    if stale:
        if committed is None:
            print(f'{a.committed} does not exist yet.')
        else:
            print(f'{a.committed} is STALE: it differs from what {a.kythen} '
                    'generates right now.')
        if a.update:
            committed_path.write_text(fresh)
            print(f'Updated {a.committed} from the fresh generator output. '
                    'Review the diff before committing it: it is generated, never hand edited.')
        else:
            print(f'Re-run with --update to refresh it, or copy it yourself: '
                    f'cp {fresh_path} {committed_path}')
    else:
        print(f'{a.committed} matches {a.kythen} exactly.')

    if test.returncode != 0:
        sys.exit('goanna_radial_form_test FAILED against the fresh reference: '
                'the C++ port itself has drifted from radial_form.lua, not just the committed copy.')
    if stale and not a.update:
        sys.exit(1)
    print('check_kythen: the native port matches Kythen, and the committed reference is current.')


if __name__ == '__main__':
    main()
