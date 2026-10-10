#!/usr/bin/env python3
"""Build a reproducible PBR intake manifest from a conventional texture pack."""

import argparse
import json
from pathlib import Path

from PIL import Image

from pbr_community_select import material_class


CLASS_NODE = {
    "metal": ("default_metal_footstep", "normal", {}),
    "glass": ("default_glass_footstep", "glasslike", {}),
    "wood": ("default_wood_footstep", "normal", {"wood": 1}),
    "organic": ("default_grass_footstep", "plantlike", {"flora": 1}),
    "sand": ("default_sand_footstep", "normal", {}),
    "gravel": ("default_gravel_footstep", "normal", {}),
    "soil": ("default_dirt_footstep", "normal", {}),
    "snow": ("default_snow_footstep", "normal", {}),
    "ice": ("default_ice_footstep", "normal", {}),
    "cloth": ("default_cloth_footstep", "normal", {}),
    "stone": ("default_hard_footstep", "normal", {}),
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pack", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--release", required=True, type=int)
    parser.add_argument("--media-license", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    root = Path(args.pack)
    selected = {}
    for path in sorted(root.rglob("*.png")):
        stem = path.stem
        if stem.endswith(("_n", "_s")):
            continue
        try:
            with Image.open(path) as image:
                width, height = image.size
        except OSError:
            continue
        if min(width, height) < 8 or max(width, height) > 512:
            continue
        relative = str(path.relative_to(root))
        item = selected.setdefault(stem, {
            "package": args.package,
            "release": args.release,
            "media_license": args.media_license,
            "source": relative,
            "class": material_class(stem, args.package),
            "size": [width, height],
            "collisions": [],
        })
        if item["source"] != relative:
            item["collisions"].append(relative)

    nodes = []
    for kind, (sound, drawtype, groups) in CLASS_NODE.items():
        tiles = [stem + ".png" for stem, item in selected.items()
                 if item["class"] == kind]
        if tiles:
            nodes.append({"name": f"goanna_intake:{args.package}_{kind}",
                          "tiles": sorted(tiles), "sound_footstep": sound,
                          "drawtype": drawtype, "groups": groups})

    out = Path(args.out)
    out.write_text(json.dumps(nodes, indent=2, sort_keys=True) + "\n")
    out.with_suffix(".sources.json").write_text(json.dumps(
        selected, indent=2, sort_keys=True) + "\n")
    print(f"wrote {len(selected)} textures in {len(nodes)} material groups to {out}")


if __name__ == "__main__":
    main()
