"""Hand authored LabPBR height and smoothness for mcl_farming_hayblock_top.

The same column alternation as mcl_farming_hayblock_side (odd columns
brighter, 0.531 to 0.587, even columns darker, 0.382 to 0.412, at every
position), the sixteen bundled stalks seen end on rather than along their
length: row means barely move (0.447 to 0.495 across all sixteen rows),
none of the side's two dark twine bands, since the twine wraps around the
bundle's length and never crosses its cut ends. Same stalks, same column
target as the side, sharing its warp seed so the two faces read as one
bundle, but no bands and a rounder, more isotropic mottling in place of the
side's lengthwise fibre streaks, since this is the stalks' cut ends, not
their sides.
"""
import sys

import numpy as np

import lib

STEM = "mcl_farming_hayblock_top"
CLS = "leaves"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    col_means = lum.mean(axis=0)
    print("col means:", np.round(col_means, 3).tolist())
    row_means = lum.mean(axis=1)
    print("row means:", np.round(row_means, 3).tolist())

    col_id = np.broadcast_to(np.arange(16)[None, :], (16, 16)).copy()
    col_hi = lib.warp_labels(col_id, amp=2.0, seed=91, cells=16)
    lo, hi = col_means.min(), col_means.max()
    col_target = 0.30 + 0.50 * (col_means - lo) / max(hi - lo, 1e-6)

    step = col_target[col_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 3)
    layout = narrow + 1.1 * (narrow - wide)

    # Cut ends: isotropic mottling rather than the side's lengthwise fibre,
    # plus a shallow dome per stalk so each end reads as a rounded stem
    # rather than a flat painted stripe.
    mottle = lib.fbm(SIZE, base_cells=28, octaves=3, seed=95, gain=0.55) * 0.10
    pores = lib.blur(lib.white_noise(SIZE, seed=96), 1) * 0.04
    dome = lib.fbm(SIZE, base_cells=16, octaves=1, seed=97) * 0.03
    layout = layout + mottle + pores + dome

    height = lib.normalise01(layout, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness does not chase every stalk boundary the way height does:
    # a cut end wears evenly regardless of which stalk it is, so the stalk
    # pattern only enters here heavily blurred, wide enough that no single
    # column edge, the one on the wrap included, stands out as a step.
    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=98, gain=0.55)
    col_wave = lib.blur(step, 10)
    smooth = 0.30 * (1 - col_wave) + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 12.0
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
