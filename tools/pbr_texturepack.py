#!/usr/bin/env python3
"""Deploy tools/pbr_bake.py's output as a client side texture pack.

The companion to tools/pbr_deploy.py, for the other half of the override
story. pbr_deploy builds a worldmod: the server serves it, every client that
connects gets it, and it is the right shape for dressing a base game. This
builds a texture pack instead: a directory the player points Goanna at, which
is searched by filename before anything the server sent
(SourceImageCache::insert's prefer_local, src/transplant/client/imagesource.cpp).

That is what lets a pack layer over a served bake rather than replace it. A
world serving the Mineclonia bake as a worldmod, with a Craft and Ruin pack
set as the player's texture pack, shows Craft and Ruin's art and material
maps for the stems the pack covers and the served Mineclonia bake everywhere
else, because the override is per filename and the pack is not obliged to be
complete.

    tools/pbr_texturepack.py --baked baked/craft_and_ruin \\
        --pack baked/craft_and_ruin-run/pack \\
        --out ~/.minetest/textures/craft_and_ruin_pbr

Unlike pbr_deploy this does not need, and does not want, the bake's albedo.
A texture pack already ships the art it is a pack of, so the diffuse stays
the artist's own file, byte for byte, and only the _n and _s companions are
added. That is what makes the result a PBR extension of a pack rather than a
different pack: on a vanilla client it is indistinguishable from the original,
because the companions are media a vanilla client has no use for.

Companions are written at the size of the texture they dress, not at the
bake's own resolution. GoannaTexture::godotArraySuffixed resizes a mismatched
companion to the base layer's size at load time anyway, so this changes no
pixel that reaches the screen; it is done here so the pack is the size a
16 px pack should be rather than carrying 256 px maps for 16 px art. The
filters match that function's, for the same reasons: _n interpolates because
it is a vector field, _s does not because its channels are categorical and
a value between two of them is a material that is in neither.
"""

import argparse
import os
import shutil
import sys

from PIL import Image


def companion_size(src_path):
    with Image.open(src_path) as im:
        return im.size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baked", required=True, help="a tools/pbr_bake.py --out directory")
    ap.add_argument("--pack", required=True,
            help="the texture pack the bake was made from; its own files are copied "
                 "across unchanged and the companions are written beside them")
    ap.add_argument("--out", required=True,
            help="texture pack directory to write (created if missing); install it "
                 "under Luanti's textures/ directory to have the menu list it")
    ap.add_argument("--full-size", action="store_true",
            help="keep companions at the bake's own resolution instead of the size "
                 "of the texture they dress. Only useful alongside a pack whose "
                 "diffuse has been upscaled to match; on an unmodified pack the "
                 "client scales them back down on load and nothing is gained")
    args = ap.parse_args()

    stems = set()
    for f in os.listdir(args.baked):
        if f.endswith("_n.png"):
            stems.add(f[:-len("_n.png")])

    os.makedirs(args.out, exist_ok=True)

    # The pack's own tree, unchanged, subdirectories and all. getTextureDirs
    # is a recursive walk (luanti/src/client/texturepaths.cpp), so a pack that
    # sorts its art into per mod folders is found the same as a flat one, and
    # keeping the layout keeps the diff against the upstream pack readable for
    # anyone who wants to send this back to its author.
    copied = 0
    sources = {}
    for root, _, files in os.walk(args.pack):
        if ".git" in root.split(os.sep):
            continue
        rel = os.path.relpath(root, args.pack)
        dst_dir = os.path.join(args.out, rel) if rel != "." else args.out
        os.makedirs(dst_dir, exist_ok=True)
        for f in files:
            shutil.copy2(os.path.join(root, f), os.path.join(dst_dir, f))
            copied += 1
            if f.endswith(".png"):
                sources[f[:-4]] = (os.path.join(root, f), dst_dir)

    # Serving or publishing this is distribution of a derivative work, so the
    # bake's provenance travels with it. See docs/materials.md: the art a bake
    # reads is routinely not under the game's or the pack's code licence, and
    # a share alike term needs its attribution to travel too.
    src_attr = os.path.join(args.baked, "ATTRIBUTION.md")
    if os.path.exists(src_attr):
        shutil.copyfile(src_attr, os.path.join(args.out, "ATTRIBUTION.md"))
    else:
        print("WARNING: %s has no ATTRIBUTION.md; these maps are derivative works "
              "and should not be published without one" % args.baked)

    if not os.path.exists(os.path.join(args.out, "texture_pack.conf")):
        with open(os.path.join(args.out, "texture_pack.conf"), "w") as f:
            f.write("name = %s\n" % os.path.basename(os.path.normpath(args.out)))

    written = orphaned = 0
    for stem in sorted(stems):
        n = os.path.join(args.baked, stem + "_n.png")
        s = os.path.join(args.baked, stem + "_s.png")
        if not (os.path.exists(n) and os.path.exists(s)):
            continue
        if stem not in sources:
            # A baked stem the pack itself does not carry. Nothing in the pack
            # will ever ask for it, so writing it would only pad the download.
            orphaned += 1
            continue
        src_path, dst_dir = sources[stem]
        size = companion_size(src_path)
        for path, suffix, resample in ((n, "_n", Image.BILINEAR), (s, "_s", Image.NEAREST)):
            with Image.open(path) as im:
                if not args.full_size and im.size != size:
                    im = im.resize(size, resample)
                im.save(os.path.join(dst_dir, stem + suffix + ".png"))
        written += 1

    print("copied %d pack files, wrote %d companion pairs, skipped %d baked stems "
          "the pack does not carry" % (copied, written, orphaned))
    return 0


if __name__ == "__main__":
    sys.exit(main())
