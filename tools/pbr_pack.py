#!/usr/bin/env python3
"""Compose LabPBR companion textures for a Luanti game from a PixelGraph pack.

Goanna reads authored material data from ordinary server media: beside a node
texture <name>.png it looks for <name>_n.png (tangent normal in RG, ambient
occlusion in B, height in A) and <name>_s.png (perceptual smoothness in R,
F0 or metalness in G, porosity in B, emission in A). That is the LabPBR
convention, so packs written for other engines can be reused.

Packs come in two shapes and both are read here: already-packed LabPBR, a
flat directory of <block>_n.png and <block>_s.png beside each texture, and
PixelGraph source form, a directory per block holding the channels as
separate files. Point it at either,
at the game whose texture names you are targeting, and at a mapping CSV of
"pack_block,game_texture" rows; it writes the companions, scaled to each
target texture's own size, into a mod's textures directory. Serve them by
dropping that mod in a world's worldmods.

Mappings live in tools/pbr_maps/<pack>-<game>.csv, one per pack and game,
because coverage and block naming differ by pack.

Nothing here is Goanna-specific: the output is a plain LabPBR pack.

Check the licence of any pack before redistributing what this produces. The
output is derived from the pack's own maps, so its terms follow: some packs
that look permissive are not, and a few carry restrictions on redistribution
that a converted copy inherits.
"""

import argparse
import csv
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


def pack_form(pack_dir):
    """"packed" for a flat LabPBR directory, "source" for PixelGraph form."""
    for name in os.listdir(pack_dir):
        if name.endswith("_n.png"):
            return "packed"
        if os.path.isfile(os.path.join(pack_dir, name, "normal.png")):
            return "source"
    sys.exit("no LabPBR files or PixelGraph block directories in " + pack_dir)


def packed_blocks(pack_dir):
    # "_inventory" variants are for item rendering, not the node's own faces
    return {n[:-6] for n in os.listdir(pack_dir)
            if n.endswith("_n.png") and not n[:-6].endswith("_inventory")}


def compose_packed(pack_dir, block, size, out_dir, target):
    """Already LabPBR: only the size has to change. The normal map tolerates
    resampling, but the specular channels are discrete (a metal index, an
    emission flag), so averaging them would invent materials that are not
    in the pack: it is resized by nearest neighbour."""
    stem = target[:-4] if target.endswith(".png") else target
    wrote = False
    for suffix, filt in (("_n", Image.LANCZOS), ("_s", Image.NEAREST)):
        src = os.path.join(pack_dir, block + suffix + ".png")
        if not os.path.exists(src):
            continue
        Image.open(src).convert("RGBA").resize(size, filt).save(
                os.path.join(out_dir, stem + suffix + ".png"))
        wrote = True
    return wrote


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


def mod_prefixes(game_dir):
    """The prefix set a game actually uses, read off the mods on disk.

    Luanti mods namespace their media with the mod name, so the mod
    directories give the exact prefixes rather than a guess. Read the mod
    names themselves, not their textures directories: VoxeLibre keeps
    nearly every texture in one game-level directory while still using the
    per-mod naming. It matters:
    Mineclonia splits its blocks across mcl_flowers, mcl_nether, mcl_ocean
    and dozens more, while Minetest Game keeps nearly everything in default.
    Guessing a second segment would strip default_dry_grass down to grass
    and pair the savanna grass block with Minecraft's short grass plant.
    """
    names = set()
    for root, _, files in os.walk(game_dir):
        if "init.lua" in files or "mod.conf" in files:
            names.add(os.path.basename(root) + "_")
    return sorted(names, key=len, reverse=True)
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


def strip_prefix(name, prefixes=PREFIXES):
    for p in prefixes:
        if name.startswith(p) and len(name) > len(p):
            return name[len(p):]
    return name


def suggest(pack_dir, game_dir):
    """Print candidate mapping lines for review. Never write them directly:
    a wrong pair silently dresses one block in another's material."""
    if pack_form(pack_dir) == "packed":
        blocks = packed_blocks(pack_dir)
    else:
        blocks = {d for d in os.listdir(pack_dir)
                if os.path.isfile(os.path.join(pack_dir, d, "normal.png"))}
    prefixes = mod_prefixes(game_dir) + list(PREFIXES)
    targets = {}
    for root, _, files in os.walk(game_dir):
        for f in files:
            if not f.endswith(".png") or f.endswith("_n.png") or f.endswith("_s.png"):
                continue
            base = f[:-4]
            # Both, because a mod may share its name with a block: stripping
            # the tnt mod's prefix off tnt_side.png would leave "side".
            for key in {strip_prefix(base, prefixes), base}:
                targets.setdefault(key, set()).add(f)
    rows, ambiguous = [], []
    for key, names in sorted(targets.items()):
        want = SYNONYMS.get(key, key)
        if want not in blocks:
            continue
        if len(names) > 1:
            # Several mods ship a texture of this name. Often every one of
            # them is worth dressing, since each is a distinct node; but a
            # crystal stone and a plain one want different materials, so
            # offer them rather than picking or dropping silently.
            ambiguous.append((want, sorted(names)))
            continue
        rows.append((want, next(iter(names))))
    out = csv.writer(sys.stdout, lineterminator="\n")
    out.writerow(("pack_block", "game_texture"))
    out.writerows(rows)
    for want, names in ambiguous:
        for n in names:
            print("#? %s,%s" % (want, n))
    print("# %d candidates, %d names offered for a choice (#?)"
            % (len(rows), sum(len(n) for _, n in ambiguous)), file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
            formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pack", required=True, help="PixelGraph source tree (a directory per block)")
    ap.add_argument("--game", required=True, help="game directory, to read each target texture's size")
    ap.add_argument("--map", help="mapping CSV with pack_block,game_texture rows")
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
    with open(args.map, newline="") as fh:
        for row in csv.reader(fh):
            if not row or row[0].lstrip().startswith("#") or len(row) < 2:
                continue
            if row[0].strip() == "pack_block": # header
                continue
            pairs.append((row[0].strip(), row[1].strip()))
    if not pairs:
        sys.exit("mapping CSV has no usable rows")

    os.makedirs(args.out, exist_ok=True)
    sizes = target_sizes(args.game, {t for _, t in pairs})
    form = pack_form(args.pack)
    written = skipped = 0
    for src, target in pairs:
        if target not in sizes:
            print("no such game texture, skipping:", target)
            skipped += 1
            continue
        if form == "packed":
            ok = compose_packed(args.pack, src, sizes[target], args.out, target)
        else:
            src_dir = os.path.join(args.pack, src)
            ok = os.path.isdir(src_dir) and compose(src_dir, sizes[target], args.out, target)
        if ok:
            written += 1
        else:
            print("not in pack, skipping:", src)
            skipped += 1
    print("form: %s" % form)
    print("wrote %d pairs, skipped %d" % (written, skipped))


if __name__ == "__main__":
    main()
