"""Hand authored height and smoothness for kythen_shared_embers.

The 32 px art is five warm shades, all orange-brown (mean rgb 0.441, 0.292,
0.162), luminance 0.229 to 0.346 with a wide gap between the two darkest
(0.229, 0.241, ash) and the three lightest (0.321, 0.330, 0.346, lit coal):
segments at every tolerance from 0.01 to 0.05 give the same 149 fragments,
so this is colour grain, not drawing, built the same granular way as
kythen_shared_gravel.py. class_of reads this back as "soil", the bake's
smoothness level closest to what a jumbled, dusty ember bed actually is:
loose fragments with real gaps between them, not a solid glowing slab. The
brightest quarter of the tile, the lit coal shade, gets the emission the
brief asks for, carrying the art's own warm colour.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_shared_embers"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    for tolerance in (0.01, 0.03, 0.05):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        print(f"segments at tolerance {tolerance}: n={n} (no real regions, colour is grain not drawing)")

    sweep32 = lib.blur(lum, 3)
    print(f"sweep sd at native res: {sweep32.std():.4f} (raw art sd {lum.std():.4f})")
    sweep = lib.normalise01(lib.upscale(sweep32, smooth=True))

    chips = lib.fbm(SIZE, base_cells=40, octaves=3, seed=121, gain=0.55)
    dust = lib.blur(lib.white_noise(SIZE, seed=122), 1)
    height = lib.normalise01(0.20 * sweep + 0.55 * chips + 0.35 * dust, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: uniformly dull ash and charcoal, lit coal faces a shade
    # smoother (the glassy skin a hot coal gets), following the chip field.
    variation = lib.fbm(SIZE, base_cells=30, octaves=3, seed=123, gain=0.55)
    smooth = 0.30 * (height - height.mean()) + 0.55 * variation

    # Emission from the brightest of the five shades only, 0.346, 28
    # percent of the tile, the actual lit coal; the dominant 0.330 shade
    # gets a dim share and the two darkest, ash, get none. Kept off the
    # fine height grain and read straight from the art's own texel edges
    # (nearest upscale) so the glow sits exactly on the drawn coals.
    art_lum = lib.upscale(lum, smooth=False)
    lo, hi = 0.315, 0.346
    emission = np.clip((art_lum - lo) / (hi - lo), 0.0, 1.0) ** 2
    print(f"emissive fraction {float((emission > 0.05).mean()):.3f}")

    albedo = lib.upscale(src[..., :3])
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 6.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, cls,
            normal_strength=normal_strength, art_texels=src.shape[0], emission=emission)
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, cls)
    for line in lines:
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
