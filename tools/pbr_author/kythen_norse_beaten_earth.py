"""Hand authored LabPBR height and smoothness for kythen_norse_beaten_earth,
a compacted earth floor, trodden flat.

The 32 px art has six shades in a dither with real clumpy structure, the
same shape default_dirt.py reads in its own art: at tolerance 0.03,
lib.segments finds 148 regions, the biggest 87 texels, thirty seven of
them a single texel, the rest small clumps of a handful of texels. That is
dirt's usual reading, small clods and grains rather than stones. Beaten
earth is that same ground trodden compacted, so the relief follows
default_dirt.py's own method (region height from brightness, rounded
crowns, an unsharp mask to keep matching slopes at the wrap) but held to a
narrower band: a trodden floor is flatter than loose ground.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_beaten_earth"
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

    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:15])
    print(f"{int((sizes == 1).sum())} of {n} regions are a single texel")

    lo, hi = region_lum.min(), region_lum.max()
    target = 0.25 + 0.5 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=4.0, seed=151)
    edges = lib.region_edges(labels_hi)
    max_dist = 3  # small, trodden clods, not loose loam
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 1.0 * (narrow - wide)

    # Sparse, flat floored hollows for real occlusion (see
    # kythen_norse_mire.py's own notes on why a graded dip undershoots).
    hollow_field = lib.blur(lib.white_noise(lib.SIZE, seed=152), 2)
    hollow_cut = float(np.percentile(hollow_field, 24))
    hollow_mask = hollow_field < hollow_cut
    dist2 = lib.distance_to_edge(hollow_mask.astype(np.float32), max_dist=3)
    t2 = np.clip(dist2 / 3, 0.0, 1.0)
    t2 = t2 * t2 * (3 - 2 * t2)
    hollows = (t2 - 1.0) * 0.9

    grit = lib.blur(lib.white_noise(lib.SIZE, seed=153), 1) * 0.04
    height = lib.normalise01(0.2 * layout + hollows + grit, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(lib.SIZE, base_cells=18, octaves=3, seed=154, gain=0.55)
    smooth = 0.45 * t + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 5
    height = lib.band(height, 0.30)
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
