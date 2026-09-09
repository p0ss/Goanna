#!/usr/bin/env python3
"""Draft a classification review from a game's own definition dump.

A hand written review is the ideal, and for a game of a few hundred textures
it is also a fortnight of work. The definition dump already carries the
evidence a reviewer would use first: the drawtype says whether a face tiles
or is a cut-out billboard, and the footstep sound names the material. This
turns that into review records so a bake has bands and treatments, marks
every record as derived rather than judged, and leaves the per-texture
argument to a person.

What it does not do is decide anything the data does not say. Material comes
from tools/pbr_bake.py's own classifier, the bands are that module's
material defaults, and confidence stays moderate with review_required set,
so nothing here can be mistaken for an approved release record.
"""

import argparse
import json
from pathlib import Path

import pbr_bake

BILLBOARD_DRAWTYPES = {
    "plantlike", "plantlike_rooted", "firelike", "signlike", "torchlike",
    "raillike",
}
# A liquid's surface is the shader's, not a baked map's, and an airlike node
# has no face at all.
SKIP_DRAWTYPES = {"liquid", "flowingliquid", "airlike"}
TILING_DRAWTYPES = {
    "normal", "nodebox", "allfaces", "allfaces_optional", "glasslike",
    "glasslike_framed", "glasslike_framed_optional", "mesh",
}


def bands(material):
    """Smoothness band and relief from the bake's own material defaults."""
    centre = pbr_bake.CLASS_SPEC.get(material, pbr_bake.DEFAULT_SPEC)[0]
    relief = pbr_bake.CLASS_HEIGHT_DEPTH.get(
        material, pbr_bake.DEFAULT_HEIGHT_DEPTH)
    return round(max(0.02, centre * 0.4), 3), round(min(0.95, centre * 1.5), 3), relief


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--nodedefs", required=True)
    parser.add_argument("--itemdefs")
    parser.add_argument("--out", required=True)
    parser.add_argument("--review-version", required=True)
    parser.add_argument("--game", required=True,
                        help="name of the game, for the rationale")
    args = parser.parse_args()

    nodes = json.loads(Path(args.nodedefs).read_text())
    classes = pbr_bake.load_classes(args.nodedefs)
    textures = {}
    for node in nodes:
        drawtype = node.get("drawtype") or ""
        if drawtype in SKIP_DRAWTYPES:
            continue
        treatment = "billboard" if drawtype in BILLBOARD_DRAWTYPES else "terrain"
        for tile in node.get("tiles", []):
            if not tile.endswith(".png"):
                continue
            stem = tile[:-4]
            material = classes.get(stem, "default")
            # A stem on both a solid node and a plant is drawn as a cut-out
            # somewhere, and shallow relief on a cube is a smaller error than
            # deep relief on a sprite's alpha edge.
            existing = textures.get(stem)
            if existing and existing["treatment"] == "billboard":
                continue
            low, high, relief = bands(material)
            textures[stem] = {
                "primary_material": material,
                "secondary_materials": [],
                "metalness_policy": "predominant" if material == "metal" else "none",
                "smoothness_min": low,
                "smoothness_max": high,
                "relief_strength": relief,
                "treatment": treatment,
                "tiles": drawtype in TILING_DRAWTYPES,
                "confidence": 0.7,
                "rationale": "Derived from %s's own node registration: "
                             "drawtype %s and footstep sound. Bands are the "
                             "pipeline's material defaults, not a per texture "
                             "judgement." % (args.game, drawtype or "unset"),
                "review_required": True,
            }

    if args.itemdefs:
        items = json.loads(Path(args.itemdefs).read_text())
        for item in items:
            for tile in item.get("textures", []):
                if not tile.endswith(".png") or tile[:-4] in textures:
                    continue
                stem = tile[:-4]
                low, high, relief = bands("default")
                textures[stem] = {
                    "primary_material": "default",
                    "secondary_materials": [],
                    "metalness_policy": "none",
                    "smoothness_min": low,
                    "smoothness_max": high,
                    "relief_strength": relief,
                    "treatment": "item",
                    "tiles": False,
                    "confidence": 0.5,
                    "rationale": "An item icon in %s's registration with no "
                                 "node to take a material from. Neutral "
                                 "defaults until reviewed." % args.game,
                    "review_required": True,
                }

    document = {
        "schema_version": 1,
        "review_version": args.review_version,
        "reviewed_manifests": [Path(args.nodedefs).name] +
                              ([Path(args.itemdefs).name] if args.itemdefs else []),
        "resolution": "derived",
        "textures": dict(sorted(textures.items())),
    }
    Path(args.out).write_text(json.dumps(document, indent=2) + "\n")
    counts = {}
    for record in textures.values():
        key = (record["treatment"], record["primary_material"])
        counts[key] = counts.get(key, 0) + 1
    print(json.dumps({"textures": len(textures),
                      "by_treatment_and_material":
                          {"%s/%s" % k: v for k, v in sorted(counts.items())}},
                     indent=2))


if __name__ == "__main__":
    main()
