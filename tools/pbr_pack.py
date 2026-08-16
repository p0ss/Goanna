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

Check the licence of any pack before redistributing what this produces. The
output is derived from the pack's own maps, so its terms follow: some packs
that look permissive are not, and a few carry restrictions on redistribution
that a converted copy inherits.
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


# Luanti games prefix texture names by mod ("default_cobble.png",
# "mcl_core_sandstone_top.png") while packs written for Minecraft use the
# block's own name ("cobblestone"). Stripping the prefix and applying a few
# well-known synonyms pairs most of them.
PREFIXES = ("default_", "mcl_core_", "mcl_", "mtg_")
SYNONYMS = {
    "cobble": "cobblestone", "mossycobble": "mossy_cobblestone",
    "tree": "oak_log", "tree_top": "oak_log_top",
    "wood": "oak_planks", "junglewood": "jungle_planks",
    "jungletree": "jungle_log", "jungletree_top": "jungle_log_top",
    "acacia_tree": "acacia_log", "acacia_tree_top": "acacia_log_top",
    "birchtree": "birch_log", "birchtree_top": "birch_log_top",
    "sprucetree": "spruce_log", "sprucetree_top": "spruce_log_top",
    "darktree": "dark_oak_log", "darktree_top": "dark_oak_log_top",
    "brick_block": "bricks", "stonebrick": "stone_bricks",
    "stone_andesite": "andesite", "stone_diorite": "diorite",
    "stone_granite": "granite", "obsidian_block": "obsidian",
}


def strip_prefix(name):
    for p in PREFIXES:
        if name.startswith(p):
            return name[len(p):]
    return name


def suggest(pack_dir, game_dir):
    """Print candidate mapping lines for review. Never write them directly:
    a wrong pair silently dresses one block in another's material."""
    blocks = {d for d in os.listdir(pack_dir)
            if os.path.isfile(os.path.join(pack_dir, d, "normal.png"))}
    targets = {}
    for root, _, files in os.walk(game_dir):
        for f in files:
            if not f.endswith(".png") or f.endswith("_n.png") or f.endswith("_s.png"):
                continue
            key = strip_prefix(f[:-4])
            targets.setdefault(key, set()).add(f)
    lines, ambiguous = [], 0
    for key, names in sorted(targets.items()):
        want = SYNONYMS.get(key, key)
        if want not in blocks:
            continue
        if len(names) > 1: # same stripped name in two mods: needs a human
            ambiguous += 1
            continue
        lines.append("%s %s" % (want, next(iter(names))))
    for line in lines:
        print(line)
    print("# %d candidates, %d ambiguous names skipped" % (len(lines), ambiguous),
            file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
            formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pack", required=True, help="PixelGraph source tree (a directory per block)")
    ap.add_argument("--game", required=True, help="game directory, to read each target texture's size")
    ap.add_argument("--map", help="lines of: <pack directory> <game texture>.png")
    ap.add_argument("--out", help="mod textures directory to write into")
    ap.add_argument("--suggest", action="store_true",
            help="print candidate mapping lines for review instead of composing")
    args = ap.parse_args()

    if args.suggest:
        suggest(args.pack, args.game)
        return
    if not args.out:
        sys.exit("--out is required unless --suggest is given")

    if not args.map:
        sys.exit("--map is required unless --suggest is given")
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
