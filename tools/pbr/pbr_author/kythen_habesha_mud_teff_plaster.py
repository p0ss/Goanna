"""Hand authored height and smoothness for kythen_habesha_mud_teff_plaster.

The 32 px art is a tan and brown mottle, luminance 0.47 to 0.67.
lib.segments (tolerance 0.05) finds one dominant 448 texel matrix, the
smoothed mud plaster itself, and a scatter of smaller patches from 39 texels
down to single texels: the straw (teff stalk) flecks worked into the render.
The brief calls the plaster nearly flat with the flecks slightly proud, so
the base is built the way hardened_clay.py reads a fired tile, a smoothly
upscaled mottle held in a narrow band, and only the segmented fleck regions
are lifted a little above that plane, never the full class depth a joint
would get.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_mud_teff_plaster"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print(f"lib.class_of reads: {CLS}")

    lo, hi = float(lum.min()), float(lum.max())
    norm_lum = (lum - lo) / max(hi - lo, 1e-6)
    mottle = lib.blur(lib.upscale(norm_lum, smooth=True), 3)

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    matrix = int(np.argmax(sizes))
    print(f"segments: n={n} tolerance={tolerance}, matrix region {matrix} size {sizes[matrix]}, "
          f"sizes top10 {sorted(sizes.tolist(), reverse=True)[:10]}")

    # Straw flecks: every region that is not the plaster matrix itself,
    # lifted a little above the plane, brighter flecks (dried straw) more
    # than darker ones (a shadowed stalk lying flatter).
    is_fleck = np.ones(n, dtype=bool)
    is_fleck[matrix] = False
    fleck_target = 0.15 + 0.55 * (region_lum - region_lum.min()) / max(region_lum.max() - region_lum.min(), 1e-6)

    labels_hi = lib.warp_labels(labels, amp=3.0, seed=181)  # straw flecks sit naturally, a light warp
    fleck_hi = is_fleck[labels_hi]
    fleck_val_hi = fleck_target[labels_hi]
    edges = lib.region_edges(labels_hi)
    max_dist = 2  # small, thin flecks
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    flecks = np.where(fleck_hi, fleck_val_hi * t, 0.0)

    ripple = lib.fbm(SIZE, base_cells=40, octaves=2, seed=182, gain=0.5)
    grain = lib.blur(lib.white_noise(SIZE, seed=183), 2)

    field = 0.28 * mottle + 0.22 * ripple + 0.35 * flecks + 0.15 * grain
    field = (field - field.mean()) / max(float(field.std()), 1e-6)
    height = lib.band(field, 0.15)

    # One real deep pit, a genuine gouge in the render, not the flecks'
    # ordinary shallow proud texture.
    hole_field = lib.blur(lib.white_noise(SIZE, seed=184), 1)
    hole_cut = float(np.percentile(hole_field, 0.3))
    holes = np.where(hole_field < hole_cut, (hole_field - hole_cut) * 2.6, 0.0)
    height = np.clip(height + holes, 0.0, 1.0)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=24, octaves=3, seed=185, gain=0.55)
    smooth = 0.30 * (height - height.mean()) + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 34.0
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
