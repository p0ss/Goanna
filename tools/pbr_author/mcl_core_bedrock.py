"""Hand authored LabPBR height and smoothness for mcl_core_bedrock.

The 16 px art carries five grey shades, 0.205 to 0.408, an even 0.045 to
0.05 apart, mean 0.30. Unlike default_stone's fine one and two texel flecks,
this art's same shade patches run up to 22 texels: a coarse, blotchy rock,
not a fine grained one. The darkest shade, 0.205, is the minority, 26 of 256
texels, sitting as small irregular clusters inside the lighter body rather
than a scattered fine speckle, which is what a deep pit looks like on a
coarse rock: a real hole, not a fleck of shadow.
"""
import sys

import numpy as np

import lib

STEM = "mcl_core_bedrock"
CLS = "stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} "
          f"mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    # Connected regions of near identical colour. 0.02 separates all five
    # shades (their steps are 0.045 to 0.05 apart) and gives 74 regions, one
    # at 22 texels and most others three to nine: the coarse, blotchy patches
    # this rock is built from, not the one and two texel flecks of
    # default_stone.
    tolerance = 0.02
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))

    # Target height per region: the darkest shade only is a real pit, deeper
    # than default_stone's (0.05 against 0.15), because this rock reads as
    # coarser and rougher than a dressed stone block. The lightest shade
    # only is the weathered high point; the three shades between stay the
    # matrix, same as default_stone's own middle two.
    pit = region_lum < 0.23
    grain_mask = region_lum > 0.38
    print(f"pit regions: {int(pit.sum())} ({int(sizes[pit].sum())} texels), "
          f"grain regions: {int(grain_mask.sum())} ({int(sizes[grain_mask].sum())} texels), "
          f"matrix regions: {int(n - pit.sum() - grain_mask.sum())} "
          f"({int(sizes[~pit & ~grain_mask].sum())} texels)")
    baseline = 0.45
    target = np.where(pit, 0.05, np.where(grain_mask, 0.8, baseline))

    labels_hi = lib.warp_labels(labels, amp=8.0)
    edges = lib.region_edges(labels_hi)
    max_dist = 4  # coarse blotches, several texels across; wider than default_stone's tight fleck taper
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: broad rounded pits and knobs, not square ones
    layout = baseline + (target[labels_hi] - baseline) * t

    # Sub texel structure: coarser mineral grain than default_stone's, and
    # deeper pores, since this is the roughest stone in the pack.
    grain = lib.fbm(lib.SIZE, base_cells=28, octaves=3, seed=51, gain=0.55) * 0.06
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=52), 2) * 0.06
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the pits are where dust and damp sit and
    # stay rough, the weathered high points are what wears smooth. This
    # rock's own patchy variation rides on top; pack() moves the mean to the
    # class level, the spread is ours to set.
    rough_noise = lib.fbm(lib.SIZE, base_cells=22, octaves=3, seed=53)
    smooth = 0.5 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the pit and knob edges the height field lines
    # up with.
    albedo = lib.upscale(src[..., :3])

    normal_strength = 45
    # Held in a band scaled to the surface's real depth: full range
    # domes read as rubble under a grazing lamp on the ramp.
    height = lib.band(height, 0.22)
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength)
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    for line in lib.check(m, CLS):
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")


if __name__ == "__main__":
    main()
