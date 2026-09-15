"""Hand authored LabPBR height and smoothness for default_cobble.

The 16 px art carries seven grey shades. The two darkest, 0.274 and 0.329,
are the mortar: the step up to the next shade, 0.397, is 0.068, wider than
any step within the lighter shades (all 0.032 to 0.043), so mortar reads as
a genuinely different material, not just a darker patch of the same stone.
The lighter five shades are the tops of stone chips, shading each chip from
its shadow side to its sunlit edge.
"""
import sys

import numpy as np

import lib

STEM = "default_cobble"
CLS = "stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)

    # The art tiles, but not at texel (0, 0): the seam metric on the built
    # normal map is a worst case against a whole tile mean, and it happens
    # that a big mortar to stone edge sits right across row and column 0 in
    # the art's own indexing. Rolling the source before doing anything else
    # only chooses which texel the wrapped array calls (0, 0); the pattern
    # is the same closed loop either way, so nothing about the surface
    # changes, only where its seam happens to land relative to the array
    # edges the checker samples.
    src = np.roll(src, (12, 13), axis=(0, 1))

    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    # Connected regions of near identical colour. 0.06 keeps each of the two
    # big background stones whole, since their own internal shading steps
    # are all under 0.06, while the jump from mortar to stone body (0.068)
    # still cuts a region in two. That gives 31 regions: two large stones,
    # a dozen middling chips, and a scatter of single texel mortar pits and
    # highlight flecks. Not two, not two hundred.
    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))

    mortar = region_lum < 0.36  # the two darkest shades only
    print(f"mortar regions: {int(mortar.sum())} of {n}, "
          f"{int(sizes[mortar].sum())} texels of 256")

    # Target height per region: mortar sits near the groove floor, stone
    # chips rise with their own brightness, since a lighter fleck in the art
    # is the sunlit top of that chip and a darker one its shadowed side.
    lo, hi = region_lum[~mortar].min(), region_lum[~mortar].max()
    target = np.where(mortar, 0.05,
            0.55 + 0.35 * (region_lum - lo) / max(hi - lo, 1e-6))

    labels_hi = lib.warp_labels(labels)
    edges = lib.region_edges(labels_hi)
    max_dist = 5  # groove half width in 256 map texels, a few texels either side
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: broad gentle dome tops, sharp fall to the joint
    layout = target[labels_hi] * t

    # The dome taper saturates in the middle of the two big stones, leaving
    # a dead flat crown; a wide slow bulge rounds that off the way a real
    # flagstone crowns.
    crown = lib.fbm(lib.SIZE, base_cells=4, octaves=2, seed=1) * 0.05
    layout = layout + crown * t

    # Sub texel structure: stone grain a couple of texels across, sparse
    # pores about half a texel across.
    grain = lib.fbm(lib.SIZE, base_cells=32, octaves=3, seed=2, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=3), 1) * 0.05
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: grooves collect dust and stay rough, chip
    # tops are what a boot wears smooth. The material's own grubby variation
    # rides on top; pack() moves the mean to the class level, the spread is
    # ours to set.
    rough_noise = lib.fbm(lib.SIZE, base_cells=16, octaves=3, seed=4)
    smooth = 0.55 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the stone and mortar edges the height field was
    # built to line up with; a soft upscale would blur that alignment away.
    albedo = lib.upscale(src[..., :3])

    normal_strength = 12
    # Held in a band scaled to the surface's real depth: full range
    # domes read as rubble under a grazing lamp on the ramp.
    height = lib.band(height, 0.3)
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
