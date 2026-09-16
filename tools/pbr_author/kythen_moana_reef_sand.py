"""Hand authored height and smoothness for kythen_moana_reef_sand.

The 32 px art sits between the other two moana sands, sweep sd 0.0135
against deep_sand's 0.029 and lagoon_sand's 0.0085, a moderate broad patch
signal. Its five raw shades are not evenly spread: 0.702 (175 texels) and
0.77 to 0.818 (840 texels) are the ordinary grain, but 0.725 is a thin band
of only nine texels sitting alone in the gap between them, and the
brightest shade, 0.818, is a real six percent cluster distinctly above the
rest rather than the top of a smooth ramp. Reef sand is coral sand with
shell fragments mixed through it, so that bright six percent is read as
shell flecks: small, sparse, proud of the ordinary grain and a touch
smoother, the way a broken shell catches more light and wears more
smoothly than a quartz grain. Everything else is built the same way as
default_sand.py, sweep plus grain plus dust.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_reef_sand"
CLS = "sand"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("class_of reads:", lib.class_of(STEM, GAME))
    shades, counts = np.unique(np.round(lum.ravel(), 3), return_counts=True)
    print("shades:", list(zip(shades.tolist(), counts.tolist())))

    for tolerance in (0.03, 0.05, 0.08):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        sizes = sorted(np.bincount(labels.ravel()).tolist(), reverse=True)
        print(f"segments at tolerance {tolerance}: n={n} sizes_top5={sizes[:5]}")

    sweep32 = lib.blur(lum, 2)
    print(f"sweep sd at native res: {sweep32.std():.4f} (raw art sd {lum.std():.4f})")
    sweep = lib.upscale(sweep32, smooth=True)
    sweep = lib.normalise01(sweep)

    grain = lib.fbm(SIZE, base_cells=85, octaves=2, seed=881, gain=0.5)
    dust = lib.blur(lib.white_noise(SIZE, seed=882), 1)

    height = lib.normalise01(0.20 * sweep + 0.52 * grain + 0.34 * dust, 0.5, 99.5)

    # Shell flecks: the art's own brightest, sparse cluster (the top shade,
    # about six percent of the tile), nearest upscaled so the flecks land
    # exactly where the art draws them, given a small proud bump on top of
    # the ordinary grain.
    fleck_native = (lum >= 0.80).astype(np.float32)
    print(f"fleck texels: {int(fleck_native.sum())} of {fleck_native.size}")
    fleck_hi = lib.upscale(fleck_native[..., None].repeat(3, -1))[..., 0]
    fleck_bump = lib.blur(fleck_hi, 1) * 0.10

    height = lib.normalise01(height + fleck_bump, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=40, octaves=3, seed=883, gain=0.55)
    # Ordinary grain stays uniformly rough; shell flecks read a touch
    # smoother, a broken shell face against a matte quartz grain.
    smooth = 0.24 * (height - height.mean()) + 0.58 * variation + 0.10 * fleck_hi
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 1.6
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
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
