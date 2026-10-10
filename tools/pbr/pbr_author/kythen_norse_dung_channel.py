"""Hand authored LabPBR height and smoothness for kythen_norse_dung_channel,
a wet floor gutter, held flat.

The 32 px art carries almost no signal: three shades within 0.022 of each
other (0.212, 0.223, 0.234) in a fine dither, and lib.segments collapses
the whole tile to one region above tolerance 0.03. As with
kythen_norse_mire.py there is no layout to read; the surface is a wet,
trodden channel floor, held close to level with sparse, flat floored
hollows (the same distance_to_edge device that gave that stem real
occlusion) standing in for the puddled low spots a gutter collects.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_dung_channel"
CLS = "soil"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    cls_read = lib.class_of(STEM, GAME)
    print(f"lib.class_of reads: {cls_read}, using {CLS}")
    for tol in (0.02, 0.03, 0.06):
        labels, n = lib.segments(rgb, tolerance=tol)
        print(f"segments at tolerance {tol}: n={n}")

    # Sparse, flat floored puddle hollows: a binary mask with a short,
    # steep taper, not a graded dip (kythen_norse_mire.py's own notes on
    # why the graded version undershoots the ao target).
    hollow_field = lib.blur(lib.white_noise(lib.SIZE, seed=131), 2)
    hollow_cut = float(np.percentile(hollow_field, 24))
    hollow_mask = hollow_field < hollow_cut
    max_dist = 3
    dist = lib.distance_to_edge(hollow_mask.astype(np.float32), max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # 0 in a puddle, 1 on the trodden floor
    hollows = (t - 1.0) * 0.55

    ripple = lib.fbm(lib.SIZE, base_cells=10, octaves=3, seed=132, gain=0.55) * 0.05
    fuzz = lib.blur(lib.white_noise(lib.SIZE, seed=133), 1) * 0.03
    height = lib.normalise01(hollows + ripple + fuzz, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: mostly wet and fairly even, the puddled hollows slicker
    # than the trodden floor around them.
    variation = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=134, gain=0.55)
    smooth = 0.50 + 0.55 * variation
    smooth = np.where(hollow_mask, smooth + 0.10, smooth)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 4
    height = lib.band(height, 0.40)
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
