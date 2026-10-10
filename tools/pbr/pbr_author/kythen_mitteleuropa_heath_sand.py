"""Hand authored height and smoothness for kythen_mitteleuropa_heath_sand.

The 32 px art dithers across six grey shades (sd 0.089, wider than
drift_sand's two) and lib.segments only collapses to one dominant region
(726 of 1024 texels) at a loose tolerance of 0.08, with real patches still
under that: a vertical streak of the lightest shade near the middle of the
tile and a darker patch beside it. That reads as heath sand does, granular
throughout but with broader dune-like drifts on top of the grain, so the
sweep here carries more of the height than drift_sand's does, and the sweep
itself keeps a touch more of its own shape (less blur) so those drifts
survive the upscale.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_heath_sand"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("class:", CLS)

    for tolerance in (0.03, 0.05, 0.08):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        sizes = np.bincount(labels.ravel())
        print(f"segments at tolerance {tolerance}: n={n} biggest={int(sizes.max())}")

    # The sweep keeps more shape than drift_sand's (blur radius 2 rather
    # than 3), so the drifts visible in the art's own patches survive.
    sweep32 = lib.blur(lum, 2)
    print(f"sweep sd at native res: {sweep32.std():.4f} (raw art sd {lum.std():.4f})")
    sweep = lib.upscale(sweep32, smooth=True)
    sweep = lib.normalise01(sweep)

    grain = lib.fbm(SIZE, base_cells=80, octaves=2, seed=831, gain=0.5)
    dust = lib.blur(lib.white_noise(SIZE, seed=832), 1)

    height = lib.normalise01(0.35 * sweep + 0.42 * grain + 0.23 * dust, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=36, octaves=3, seed=833, gain=0.55)
    smooth = 0.25 * (height - height.mean()) + 0.6 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 2.5
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
