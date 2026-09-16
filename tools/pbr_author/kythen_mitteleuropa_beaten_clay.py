"""Hand authored height and smoothness for kythen_mitteleuropa_beaten_clay.

The 32 px art has four shades and no drawn stones: its darkest two (0.236,
0.240) cover 42 percent of the tile in broad connected blobs, not a
network of thin cracks. Carving those blobs down as a literal depression
was tried first and left the ambient occlusion at 0.4 to 0.7 regardless of
depth: a broad low region has no wall close enough to itself for the
horizon based occlusion to see, only its own edge does, so a wide dark
patch reads as colour, not a hollow. That colour goes into the height only
as a broad brightness sweep, held in a tight band since this is a
compacted floor, nearly flat underfoot; the real depth on the tile is a
sparse scatter of small footworn dimples, native scale texels warped for
an organic edge and never blurred, the same reasoning
kythen_khmer_floodplain_clay.py gives for its own crack mask.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_beaten_clay"
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
        print(f"segments at tolerance {tolerance}: n={n} sizes_top={sorted(sizes.tolist(), reverse=True)[:6]}")

    dark_frac = float((lum < 0.25).mean())
    print(f"darkest two shades cover {dark_frac * 100:.1f}% of the art in broad blobs, not cracks")

    # The plate: a broad sweep of the art's own brightness, held tight.
    sweep32 = lib.blur(lum, 1)
    sweep = lib.upscale(sweep32, smooth=True)
    sweep = lib.normalise01(sweep)
    grain = lib.fbm(SIZE, base_cells=50, octaves=2, seed=851, gain=0.5)
    dust = lib.blur(lib.white_noise(SIZE, seed=852), 1)
    flat = lib.normalise01(0.5 * sweep + 0.3 * grain + 0.2 * dust, 0.5, 99.5)
    flat_band_hw = 0.14
    flat = lib.band(flat, flat_band_hw)

    # The dimples: sparse, native scale, warped for shape but not blurred,
    # so the wall rises within a texel or two and the ao sees it.
    rng = np.random.default_rng(855)
    dimple_native = (rng.uniform(0.0, 1.0, (src.shape[0], src.shape[0])) < 0.10).astype(int)
    dimples = lib.warp_labels(dimple_native, amp=1.5, seed=855).astype(np.float32)
    print(f"dimple fraction {dimples.mean():.3f}")

    dimple_depth = 0.5
    height = np.clip(flat - dimples * dimple_depth, 0.0, 1.0)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=854, gain=0.55)
    # A trodden floor wears smooth everywhere except the dimples, which
    # hold dust and stay rough.
    smooth = 0.65 + 0.4 * variation - 0.12 * dimples
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 14.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength} flat_band_hw={flat_band_hw} dimple_depth={dimple_depth}")
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
