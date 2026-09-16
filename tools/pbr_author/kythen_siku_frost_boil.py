"""Hand authored LabPBR height and smoothness for kythen_siku_frost_boil.

The 32 px art (cultures/siku/materials.json: "mat", base silt_grey, accent
gravel_tan, cover 0.66, width 1.4, cells 14, rim 0.35) is a real cut-out,
not a full cube face: cultures/siku/materials.json's own note calls this
recipe "a stamped recipe with alpha, for a thin growth or deposit lying on
the ground and looked down on", and the alpha channel bears it out, 33.8
percent of the tile under 0.5, close to the recipe's own 1 minus cover
(0.34). "Patterned ground, a boil of bare silt inside a ring of stones":
the brief calls it a sorted circle of stones in mud, which is what the
alpha itself already draws, a stone ring around a mostly clear middle, so
albedo keeps the alpha (lib.upscale(src) with all four channels) and the
relief follows the art's own opaque texels rather than inventing a ring.
"""

import sys

import lib

GAME = "kythen"
STEM = "kythen_siku_frost_boil"
CLS = "gravel"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    alpha = src[..., 3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print(f"alpha: opaque share {(alpha > 0.5).mean():.3f} (recipe cover 0.66)")
    print("lib.class_of reads:", lib.class_of(STEM, GAME))

    opaque = lib.upscale(alpha, smooth=True)

    sweep16 = lib.blur(lum, 2)
    sweep = lib.upscale(sweep16, smooth=True)
    sweep = lib.normalise01(sweep)

    chips = lib.fbm(SIZE, base_cells=40, octaves=3, seed=241, gain=0.55)
    dust = lib.blur(lib.white_noise(SIZE, seed=242), 1)

    # Stone texels (where the art is opaque) stand proud of the silt
    # between them, the same gap reading kythen_siku_gravel_beach.py's
    # own pebbles use, only present where the art actually draws a stone.
    height = lib.normalise01(0.15 * sweep + 0.55 * chips + 0.20 * dust + 0.35 * opaque, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=28, octaves=3, seed=243, gain=0.55)
    smooth = 0.30 * (height - height.mean()) + 0.50 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(src)  # RGBA, keeps the mat's own transparency
    normal_strength = 11.5
    fine_detail = 1.0  # kythen_siku_dry_stone.py's own finding: the chip scale relief here
    # is only a couple of texels across, exactly what pack()'s default damping flattens.
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, fine_detail=fine_detail, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}, fine_detail={fine_detail}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
