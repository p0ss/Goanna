#!/usr/bin/env python3
"""Build a source/albedo/PBR contact sheet, with failed maps first."""

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw


def index_sources(root):
    result = {}
    for path in sorted(Path(root).rglob("*.png")):
        result.setdefault(path.stem, path)
    return result


def fit(image, size):
    image = image.copy()
    image.thumbnail((size, size), Image.Resampling.NEAREST)
    tile = Image.new("RGB", (size, size), (28, 33, 39))
    if image.mode == "RGBA":
        tile.paste(image, ((size - image.width) // 2, (size - image.height) // 2), image)
    else:
        tile.paste(image.convert("RGB"), ((size - image.width) // 2,
                   (size - image.height) // 2))
    return tile


def channel(path, index):
    return Image.open(path).convert("RGBA").getchannel(index).convert("RGB")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baked", required=True)
    parser.add_argument("--sources", required=True)
    parser.add_argument("--quality-json")
    parser.add_argument("--out", required=True)
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--tile", type=int, default=128)
    args = parser.parse_args()
    baked = Path(args.baked)
    sources = index_sources(args.sources)
    priority = {}
    reasons = {}
    if args.quality_json:
        report = json.loads(Path(args.quality_json).read_text())
        for item in report.get("textures", []):
            priority[item["stem"]] = 0 if item.get("failures") else (
                1 if item.get("warnings") else 2)
            reasons[item["stem"]] = "; ".join(item.get("failures", []) +
                                                item.get("warnings", []))
    stems = [path.name[:-len("_n.png")] for path in baked.glob("*_n.png")]
    stems = sorted(stems, key=lambda stem: (priority.get(stem, 2), stem))[:args.limit]
    labels = ("source", "generated albedo", "normal", "height", "smoothness", "metal/F0")
    tile, label_h, title_h = args.tile, 42, 38
    width = len(labels) * tile
    height = title_h + len(stems) * (tile + label_h)
    sheet = Image.new("RGB", (width, max(height, title_h)), (20, 24, 29))
    draw = ImageDraw.Draw(sheet)
    for column, label in enumerate(labels):
        draw.text((column * tile + 5, 10), label, fill=(225, 230, 235))
    for row, stem in enumerate(stems):
        y = title_h + row * (tile + label_h)
        source = sources.get(stem)
        normal = baked / (stem + "_n.png")
        spec = baked / (stem + "_s.png")
        albedo = baked / (stem + "_albedo.png")
        images = [
            Image.open(source).convert("RGBA") if source else Image.new("RGB", (1, 1)),
            Image.open(albedo).convert("RGBA") if albedo.exists() else
                (Image.open(source).convert("RGBA") if source else Image.new("RGB", (1, 1))),
            Image.open(normal).convert("RGB"), channel(normal, 3),
            channel(spec, 0), channel(spec, 1),
        ]
        for column, image in enumerate(images):
            sheet.paste(fit(image, tile), (column * tile, y))
        colour = (255, 115, 105) if priority.get(stem) == 0 else (210, 215, 220)
        draw.text((5, y + tile + 3), stem, fill=colour)
        message = reasons.get(stem, "")
        if message:
            draw.text((5, y + tile + 18), message[:115], fill=(170, 175, 180))
    sheet.save(args.out)
    print("review sheet: %d textures, %s" % (len(stems), args.out))


if __name__ == "__main__":
    main()
