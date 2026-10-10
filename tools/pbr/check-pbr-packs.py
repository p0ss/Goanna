#!/usr/bin/env python3
"""Fail if a bundled PBR worldmod cannot be served by Luanti.

Usage: python3 tools/pbr/check-pbr-packs.py
"""
import pathlib
import sys

if sys.argv[1:2] in (["-h"], ["--help"]):
    print(__doc__)
    sys.exit(0)

ROOT = pathlib.Path(__file__).resolve().parents[2]
PACKS = ("minetest_game", "mineclonia")
errors = []

for pack in PACKS:
    root = ROOT / "pbr_packs" / pack
    textures = root / "textures"
    if not (root / "mod.conf").is_file() or not (root / "init.lua").is_file():
        errors.append(f"{pack}: missing mod.conf or init.lua")
        continue
    nested = [path for path in textures.rglob("*.png") if path.parent != textures]
    if nested:
        errors.append(f"{pack}: {len(nested)} PNGs are nested below textures/ and will not be served")
    normals = list(textures.glob("*_n.png"))
    specs = list(textures.glob("*_s.png"))
    if not normals or not specs:
        errors.append(f"{pack}: no root-level normal or material maps")
    normal_stems = {path.name[:-6] for path in normals}
    spec_stems = {path.name[:-6] for path in specs}
    missing_spec = normal_stems - spec_stems
    if missing_spec:
        errors.append(f"{pack}: {len(missing_spec)} normal maps have no _s companion")
    print(f"{pack}: {len(normals)} normals, {len(specs)} material maps")

if errors:
    for error in errors:
        print("ERROR:", error, file=sys.stderr)
    raise SystemExit(1)
print("bundled PBR pack layout: PASS")
