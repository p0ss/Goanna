"""Hand authored LabPBR height and smoothness for kythen_habesha_weyna_loam.

The 32 px art is five grey shades, luminance 0.213 to 0.327. Segmenting it
(tolerance 0.06) finds a background at the darkest shade, 0.225, chaining
through 577 of the 1024 texels everywhere in the tile, and eight separate
lighter regions at 0.311 to 0.318, thirty three texels apiece on average,
up to 138. Those eight are real clod shapes, not texel noise: substantial,
individually bounded patches, unlike default_gravel's dozens of one to
four texel pebbles or qolla_grit's near single texel grains. This is
tilled soil with real lumps in it, so each clod is domed with
lib.warp_labels for a rounded, irregular silhouette, natural soil being
exactly what warping is for, with the dark background as the groove
between them.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_weyna_loam"
CLS = "soil"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    print(f"lib.class_of reads: {lib.class_of(STEM, GAME)}")

    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    tolerance = 0.06
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments tol={tolerance}: n={n}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))

    # Clean gap in region brightness: the background sits at 0.225 to
    # 0.229, every clod region at 0.311 or above.
    gap = region_lum <= 0.27
    dome = ~gap
    print(f"gap regions: {int(gap.sum())} of {n}, {int(sizes[gap].sum())} texels; "
          f"clod regions: {int(dome.sum())}, {int(sizes[dome].sum())} texels, "
          f"sizes {sorted(sizes[dome].tolist(), reverse=True)}")

    baseline = 0.12
    dlo, dhi = region_lum[dome].min(), region_lum[dome].max()
    target = np.where(gap, 0.10,
            0.55 + 0.40 * (region_lum - dlo) / max(dhi - dlo, 1e-6))

    labels_hi = lib.warp_labels(labels, amp=7.0, seed=81, cells=10)
    edges = lib.region_edges(labels_hi)
    # A wide taper (tried up to 12) rounds the crown nicely to the eye but
    # spreads the slope so thin that lib.ao_from_height's six texel search
    # never finds a wall steep enough to occlude: ao min stayed above 0.6
    # regardless of how far the search radius was pushed out. A narrower
    # taper keeps a real rounded shoulder on each clod while the fall into
    # the groove is steep enough to self shadow.
    max_dist = 4
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: rounds a clod's silhouette, lets the groove sink cleanly
    layout = baseline + (target[labels_hi] - baseline) * t

    # Tilled earth texture below the clod shapes: coarse crumb structure on
    # the clod tops themselves, finer dust settling in the grooves.
    crumb = lib.fbm(lib.SIZE, base_cells=30, octaves=3, seed=82, gain=0.55) * 0.07
    dust = lib.blur(lib.white_noise(lib.SIZE, seed=83), 1) * 0.06
    height = lib.normalise01(layout + crumb + dust, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the grooves hold moisture and dust and
    # stay rough, the clod tops are what dries and cakes smoother. The
    # soil's own patchy variation rides on top.
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=84, gain=0.55)
    smooth = 0.5 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 13
    # No lib.band here: this stem is meant to have real depth, unlike the
    # flat threshing floor and salt crust, so the height keeps the full
    # 0..1 range normalise01 gives it.
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
