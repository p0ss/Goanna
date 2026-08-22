#!/usr/bin/env python3
"""Build the game-texture to Minecraft-path map Goanna uses to read an
unmodified Minecraft resource pack.

A Minecraft pack names its files the way Minecraft does, so a Luanti game
asking for `mcl_core_stone.png` finds nothing in it. The map is what closes
that gap: one line per game texture, naming the file inside the pack that
dresses it. With it, a player points Goanna at a pack they already own and it
works, with no conversion step and no second copy on disk.

The bulk of the data comes from kooostia16's mc_to_mineclonia, whose
`texture_maps/` are dedicated to the public domain under CC0 1.0, so they can
be used here without condition. Credited anyway, in the header this writes.

    git clone https://github.com/Kooostia16/mc_to_mineclonia
    tools/mc_texture_map.py --from-mc2mcl mc_to_mineclonia/texture_maps \\
        --game mineclonia --out project/texture_maps/mineclonia.csv

The output is deliberately a flat two column CSV rather than the nested JSON
it comes from: the C++ side reads it once at connect and wants no parser.

Only pairs with a Minecraft source are written. The source data enumerates
every texture in the game and leaves most blank, which is useful for tracking
what is still unmapped but is noise to the client.
"""

import argparse
import csv
import glob
import json
import os
import sys

CREDIT = ("# Game texture -> path inside a Minecraft resource pack.\n"
          "# Mapping data from https://github.com/Kooostia16/mc_to_mineclonia\n"
          "# by kooostia16, dedicated to the public domain under CC0 1.0.\n"
          "# Extended by hand; see docs/materials.md.\n"
          "#\n"
          "# A pack is the player's own. Goanna reads it in place and never\n"
          "# writes a converted copy: most Minecraft packs are under ordinary\n"
          "# copyright, and converting one for yourself is not redistributing it.\n")


def load_mc2mcl(d):
    """Flatten the per mod JSON files into one game_texture -> pack_path map."""
    out = {}
    for f in sorted(glob.glob(os.path.join(d, "*.json"))):
        try:
            data = json.load(open(f))
        except (OSError, ValueError) as e:
            print("skipping %s: %s" % (f, e))
            continue
        for _, entries in data.items():
            if not isinstance(entries, dict):
                continue
            for game_tex, pack_path in entries.items():
                if not pack_path or not isinstance(pack_path, str):
                    continue
                p = pack_path.strip()
                # Some entries name a bare item with no directory or suffix.
                # Those cannot be resolved against a pack, so drop them rather
                # than emit a line the client will silently fail to find.
                if not p.endswith(".png") or "/" not in p:
                    continue
                out[game_tex.strip()] = p
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from-mc2mcl", required=True,
            help="a checkout's texture_maps/ directory")
    ap.add_argument("--game", required=True, help="game name, recorded in the header")
    ap.add_argument("--out", required=True)
    ap.add_argument("--verify-pack", default="",
            help="a resource pack to check the pairs against, reporting how many "
                 "actually resolve; does not change the output")
    args = ap.parse_args()

    pairs = load_mc2mcl(args.from_mc2mcl)
    print("%d usable pairs" % len(pairs))

    if args.verify_pack:
        have = set()
        for root, _, files in os.walk(args.verify_pack):
            for f in files:
                if not f.lower().endswith(".png"):
                    continue
                rel = os.path.relpath(os.path.join(root, f), args.verify_pack)
                rel = rel.replace(os.sep, "/")
                if "/textures/" in rel:
                    have.add(rel.split("/textures/", 1)[1])
                have.add(f)
        hit = sum(1 for v in pairs.values() if v in have or os.path.basename(v) in have)
        print("  resolve against %s: %d (%.1f%%)"
                % (os.path.basename(os.path.normpath(args.verify_pack)),
                   hit, 100.0 * hit / max(len(pairs), 1)))

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", newline="") as f:
        f.write(CREDIT)
        f.write("# Game: %s\n" % args.game)
        w = csv.writer(f)
        w.writerow(["game_texture", "pack_path"])
        for k in sorted(pairs):
            w.writerow([k, pairs[k]])
    print("wrote", args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
