"""Hand authored height and smoothness for mcl_mud.

The 16 px art is per texel dither, eight grey-brown shades within a narrow
0.079 span, and no two neighbouring texels reliably hold the same shade:
lib.segments only starts finding anything bigger than a few stray texels
past tolerance 0.025 (29 regions, biggest 90), and by 0.03 it has already
collapsed to one 237 texel blob with a handful of specks, a sudden jump
rather than the gradual settling a real drawn region would show. That is
grain, the same conclusion default_sand.py reaches for its own art, not
a drawing of lumps or cracks, so this script follows its pattern: no
segments, no warp_labels, no region_edges, because there is no region to
turn into a groove. Blurring the native art (radius 2, a third of the 16
px width) still leaves a broad sweep, standard deviation 0.007 against
0.029 raw, faint but real, wide low mounds of wet mud a shade lighter or
darker than their neighbours, packed a little differently underfoot. Bare
of that, everything else here is soft, rounded lumps and a wet sheen, no
sharp edge anywhere, which is exactly the brief.

lib.class_of(STEM) reads back "cloth": mud has no needle name ("dirt",
"soil") in NAME_HINTS for the level based fallback to catch, so it lands
on the class whose smoothness level (0.08) is closest to the old bake's
own mean, tied with sand and broken alphabetically. Cloth's tilt band, 6
to 14 degrees, and its unjointed AO rule both suit smooth wet mud with no
sharp features better than soil's 15 to 25 degrees and required joints
would, so this script keeps it.
"""

import sys

import numpy as np

import lib

STEM = "mcl_mud"
CLS = "cloth"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print("lib.class_of reads:", lib.class_of(STEM), "(tie with sand at the old bake's own level, cloth's low tilt "
          "band and unjointed AO rule suit mud better; see docstring)")

    for tolerance in (0.01, 0.02, 0.025, 0.03):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        sizes = np.bincount(labels.ravel())
        print(f"segments at tolerance {tolerance}: n={n} biggest={int(sizes.max())} "
              f"(dither, not drawn lumps, see docstring)")

    # The sweep: the same blur-then-smooth-upscale default_sand.py uses,
    # a little softer since mud's own raw dither is already the smallest
    # of the soil family's (sd 0.029 against dirt's 0.075).
    sweep16 = lib.blur(lum, 2)
    print(f"sweep sd at native res: {sweep16.std():.4f} (raw art sd {lum.std():.4f})")
    sweep = lib.upscale(sweep16, smooth=True)
    sweep = lib.normalise01(sweep)

    # The lumps: broad, rounded, a few texels across, wet mud settling
    # under its own weight rather than breaking into clods. Two octaves so
    # it is not one lump size, at a coarser base than sand's own grain
    # since these are lumps, not sand's individual grains.
    lumps = lib.fbm(SIZE, base_cells=14, octaves=2, seed=71, gain=0.55)

    # A wet sheen: fine, low amplitude ripples, the skin that forms on
    # standing mud, plus a very light dusting so it is not perfectly
    # smooth under the sheen.
    sheen = lib.fbm(SIZE, base_cells=48, octaves=2, seed=72, gain=0.5)
    dust = lib.blur(lib.white_noise(SIZE, seed=73), 1)

    height = lib.normalise01(0.28 * sweep + 0.48 * lumps + 0.14 * sheen + 0.10 * dust, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: mostly a flat, wet gloss (cloth's own level is low,
    # 0.08), but the spread the check wants comes from the lumps, not the
    # sheen: a lump's own crown holds standing water and reads a touch
    # smoother than the dip beside it, which drains, plus the material's
    # own grubby variation independent of the height.
    variation = lib.fbm(SIZE, base_cells=30, octaves=3, seed=74, gain=0.55)
    smooth = 0.30 * (height - height.mean()) + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 3.6
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength)
    print(f"normal_strength={normal_strength}")
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
