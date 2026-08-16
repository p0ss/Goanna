#!/usr/bin/env python3
"""Compose LabPBR companion textures for a Luanti game from a PixelGraph pack.

Goanna reads authored material data from ordinary server media: beside a node
texture <name>.png it looks for <name>_n.png (tangent normal in RG, ambient
occlusion in B, height in A) and <name>_s.png (perceptual smoothness in R,
F0 or metalness in G, porosity in B, emission in A). That is the LabPBR
convention, so packs written for other engines can be reused.

Packs in PixelGraph source form keep those channels as separate files in a
directory per block, which is what this reads. Point it at that source tree,
at the game whose texture names you are targeting, and at a mapping file of
"<pack directory> <game texture>.png" lines; it writes the companions, scaled
to each target texture's own size, into a mod's textures directory. Serve them
by dropping that mod in a world's worldmods.

Nothing here is Goanna-specific: the output is a plain LabPBR pack.
"""

import argparse
import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("needs Pillow: pip install pillow")

DEFAULT_SMOOTHNESS = 56  # dull, for packs that do not author it
DIELECTRIC_F0 = 10       # LabPBR reserves 230 and above for metals


def target_sizes(game_dir, wanted):
    sizes = {}
    for root, _, files in os.walk(game_dir):
        for f in files:
            if f in wanted and f not in sizes:
                try:
                    sizes[f] = Image.open(os.path.join(root, f)).size
                except OSError:
                    pass
    return sizes


def compose(src_dir, size, out_dir, target):
    def load(name, mode="L"):
        path = os.path.join(src_dir, name)
        if not os.path.exists(path):
            return None
        return Image.open(path).convert(mode).resize(size, Image.LANCZOS)

    normal = load("normal.png", "RGB")
    if normal is None:
        return False
    w, h = size
    occlusion = load("occlusion.png") or Image.new("L", size, 255)
    height = load("height.png") or Image.new("L", size, 0)
    smooth = load("smooth.png") or Image.new("L", size, DEFAULT_SMOOTHNESS)
    porosity = load("porosity.png") or Image.new("L", size, 0)
    red, green, _ = normal.split()
    stem = target[:-4] if target.endswith(".png") else target
    Image.merge("RGBA", (red, green, occlusion, height)).save(
        os.path.join(out_dir, stem + "_n.png"))
    Image.merge("RGBA", (smooth, Image.new("L", size, DIELECTRIC_F0), porosity,
            Image.new("L", size, 255))).save(os.path.join(out_dir, stem + "_s.png"))
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__,
            formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pack", required=True, help="PixelGraph source tree (a directory per block)")
    ap.add_argument("--game", required=True, help="game directory, to read each target texture's size")
    ap.add_argument("--map", required=True, help="lines of: <pack directory> <game texture>.png")
    ap.add_argument("--out", required=True, help="mod textures directory to write into")
    args = ap.parse_args()

    pairs = []
    with open(args.map) as fh:
        for line in fh:
            line = line.split("#", 1)[0].split()
            if len(line) == 2:
                pairs.append((line[0], line[1]))
    if not pairs:
        sys.exit("mapping file has no usable lines")

    os.makedirs(args.out, exist_ok=True)
    sizes = target_sizes(args.game, {t for _, t in pairs})
    written = skipped = 0
    for src, target in pairs:
        src_dir = os.path.join(args.pack, src)
        if target not in sizes:
            print("no such game texture, skipping:", target)
            skipped += 1
        elif not os.path.isdir(src_dir):
            print("not in pack, skipping:", src)
            skipped += 1
        elif compose(src_dir, sizes[target], args.out, target):
            print("composed", target, sizes[target])
            written += 1
        else:
            print("no normal map, skipping:", src)
            skipped += 1
    print("wrote %d pairs, skipped %d" % (written, skipped))


if __name__ == "__main__":
    main()
