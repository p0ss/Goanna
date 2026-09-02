#!/usr/bin/env python3
"""Deploy tools/pbr_bake.py's output as a server-side texture override.

A worldmod's textures/ directory is served to every connecting client as
ordinary media, and a texture with the same name as one the game already
ships overrides it by mod load order, standard Luanti behaviour, no
protocol change, nothing Goanna-specific: a vanilla client sees the same
upscaled art. This is the same mechanism tools/pbr_pack.py's own docstring
already documents for authored companions ("drop that mod in a world's
worldmods"); this tool does the copying and, unlike a plain companion pack,
also renames the baked albedo over the game's own filename, so the base
texture array and its companions end up the same size (see
GoannaTexture::godotArraySuffixed's exact-dimension check).

    tools/pbr_deploy.py --baked /path/to/baked_bulk \\
        --mod /path/to/world/worldmods/goanna_pbr_deploy

Only deploys a stem with a complete triple (_albedo, _n, _s) on disk, so a
partial or still-running bake is safe to deploy from.
"""

import argparse
import os
import shutil
import sys


def mod_name(mod_dir):
    """A Luanti mod name for this directory.

    Luanti rejects a mod whose name is not [a-z0-9_] outright: it refuses the
    mod at load and, because a worldmod that fails to load stops the server
    starting, the whole world with it. This used to be the directory's own
    basename, so deploying to anything hyphenated (baked/pack-mineclonia-v2,
    which is what the bake directories are actually called) wrote
    "name = pack-mineclonia-v2" and produced a world no server would open:
    ModError, "Only characters [a-z0-9_] are allowed".
    """
    base = os.path.basename(os.path.normpath(mod_dir)).lower()
    name = "".join(c if c.isalnum() or c == "_" else "_" for c in base)
    # A leading digit is legal in a mod name; an empty one is not.
    return name or "goanna_pbr"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baked", required=True, help="a tools/pbr_bake.py --out directory")
    ap.add_argument("--mod", required=True,
            help="worldmod directory to write into (created if missing); "
                 "install it under a world's worldmods/ to serve it")
    args = ap.parse_args()

    stems = set()
    for f in os.listdir(args.baked):
        if f.endswith("_n.png"):
            stems.add(f[:-len("_n.png")])

    textures = os.path.join(args.mod, "textures")
    os.makedirs(textures, exist_ok=True)
    if not os.path.exists(os.path.join(args.mod, "mod.conf")):
        with open(os.path.join(args.mod, "mod.conf"), "w") as f:
            f.write("name = %s\n" % mod_name(args.mod))
    if not os.path.exists(os.path.join(args.mod, "init.lua")):
        with open(os.path.join(args.mod, "init.lua"), "w") as f:
            f.write("-- Textures only: overrides the game's own art with "
                    "tools/pbr_bake.py's baked albedo, plus its _n/_s "
                    "companions, served as ordinary media like any other "
                    "mod texture.\n")
    # This mod is served to every client that connects, so it is distribution,
    # and the textures in it are derivative works of the game's own art. That
    # art is routinely not under the same licence as the game's code: Mineclonia
    # is GPL-3.0 but its textures are CC BY-SA 4.0, mostly verbatim from Pixel
    # Perfection by XSSheep and Pixel Perfection Legacy by Nova Wostra. A
    # share-alike term travels with them and needs the attribution to travel
    # too, so carry the bake's own ATTRIBUTION.md across rather than shipping a
    # folder of PNGs with no provenance.
    src_attr = os.path.join(args.baked, "ATTRIBUTION.md")
    if os.path.exists(src_attr):
        shutil.copyfile(src_attr, os.path.join(args.mod, "ATTRIBUTION.md"))
    else:
        print("WARNING: %s has no ATTRIBUTION.md; these textures are derivative "
              "works and should not be served without one" % args.baked)

    deployed = skipped = 0
    for stem in sorted(stems):
        albedo = os.path.join(args.baked, stem + "_albedo.png")
        n = os.path.join(args.baked, stem + "_n.png")
        s = os.path.join(args.baked, stem + "_s.png")
        if not (os.path.exists(albedo) and os.path.exists(n) and os.path.exists(s)):
            skipped += 1
            continue
        shutil.copyfile(albedo, os.path.join(textures, stem + ".png"))
        shutil.copyfile(n, os.path.join(textures, stem + "_n.png"))
        shutil.copyfile(s, os.path.join(textures, stem + "_s.png"))
        deployed += 1
    print("deployed %d, skipped %d (incomplete triple)" % (deployed, skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
