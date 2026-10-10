#!/usr/bin/env python3
"""Materialize a classification review into a treatment-specific manifest."""

import argparse
import json
from pathlib import Path

import pbr_bake


def stems_in(node):
    return [tile[:-4] for tile in node.get("tiles", []) if tile.endswith(".png")]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--sources", required=True)
    parser.add_argument("--review", required=True)
    parser.add_argument("--treatment", required=True,
                        help="comma-separated treatments to retain")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    nodes = json.loads(Path(args.manifest).read_text())
    sources = json.loads(Path(args.sources).read_text())
    wanted = {value.strip() for value in args.treatment.split(",") if value.strip()}
    reviews = pbr_bake.load_classification_review(args.review, sources)

    selected = {stem for stem in sources
                if reviews.get(stem, {}).get("treatment") in wanted}
    filtered = []
    for node in nodes:
        tiles = [tile for tile in node.get("tiles", [])
                 if tile.endswith(".png") and tile[:-4] in selected]
        if not tiles:
            continue
        record = dict(node)
        record["tiles"] = tiles
        filtered.append(record)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(filtered, indent=2, sort_keys=True) + "\n")
    out.with_suffix(".sources.json").write_text(json.dumps(
        {stem: sources[stem] for stem in sorted(selected)},
        indent=2, sort_keys=True) + "\n")
    print(f"wrote {len(selected)} textures in {len(filtered)} records to {out}")


if __name__ == "__main__":
    main()
