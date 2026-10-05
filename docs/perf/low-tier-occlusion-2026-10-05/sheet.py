#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Contact sheets from run.py's frames: one sheet per pose, the tier's
variants side by side, each labelled with its variant and the profile
values the client held, plus a centre crop at full resolution.

    sheet.py OUT/<tier>/frames DEST
"""

import json
import pathlib
import sys

from PIL import Image, ImageDraw


def label(img, text):
    d = ImageDraw.Draw(img)
    d.rectangle((0, 0, img.width, 22), fill=(0, 0, 0))
    d.text((6, 5), text, fill=(255, 255, 255))


def main(frames, dest):
    frames, dest = pathlib.Path(frames), pathlib.Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    poses = {}
    for png in sorted(frames.glob("*.png")):
        pose, _, variant = png.stem.partition("-")
        poses.setdefault(pose, []).append((variant, png))
    for pose, shots in poses.items():
        tiles, crops = [], []
        for variant, png in shots:
            img = Image.open(png).convert("RGB")
            meta = json.loads(png.with_suffix(".settings.json").read_text())
            held = meta.get("held", {})
            text = "%s  parallax %g short %g micro %g  tod %.3f" % (
                variant, held.get("mat_parallax", {}).get("value", -1),
                held.get("mat_parallax_short", {}).get("value", -1),
                held.get("mat_micro_shadow", {}).get("value", -1), meta.get("tod", -1))
            w, h = img.width, img.height
            crop = img.crop((w // 2 - 200, h // 2 - 150, w // 2 + 200, h // 2 + 150))
            crop = crop.resize((800, 600), Image.NEAREST)
            small = img.resize((w // 2, h // 2), Image.LANCZOS)
            label(small, text)
            label(crop, text + "  (centre, 2x)")
            tiles.append(small)
            crops.append(crop)
        for kind, imgs in (("full", tiles), ("crop", crops)):
            sheet = Image.new("RGB", (sum(i.width for i in imgs), max(i.height for i in imgs)))
            x = 0
            for i in imgs:
                sheet.paste(i, (x, 0))
                x += i.width
            sheet.save(dest / ("%s-%s.png" % (pose, kind)))
            print(dest / ("%s-%s.png" % (pose, kind)))


if __name__ == "__main__":
    main(*sys.argv[1:])
