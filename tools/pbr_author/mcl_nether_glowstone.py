"""Hand authored height and smoothness for mcl_nether_glowstone.

The 16 px art is only five discrete shades (0.405, 0.540, 0.655, 0.820,
0.921 luminance), no gradients at all, and lib.segments finds 96 same
shade patches, mostly two to a dozen texels, the darkest patches thin lines
between the brighter ones. That is a clustered crystalline block: the
bright cells are rounded lumps of glowing mineral, the dark lines are the
cracks and gaps between them, exactly the way the brief describes it.

lib.class_of reads this back as "glass" (mean smoothness 0.92), which is
the right call for a lit mineral with a hard, faceted surface rather than
a rough stone one, so the crystal faces stay smooth and the relief stays
shallow: a rounded warp and a soft taper give the lumps their dome, not a
deep groove.

Emission comes straight from the art's own luminance: every texel glows,
because every texel of glowstone is lit mineral, not lit mineral with dark
unlit gaps between, so the floor is a good third of full strength and only
the brightest cells reach the top.
"""

import sys

import numpy as np

import lib

STEM = "mcl_nether_glowstone"
CLS = "glass"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = [int((labels == i).sum()) for i in range(n)]
    print(f"segments: n={n} tolerance={tolerance} sizes {sorted(sizes, reverse=True)[:15]}")

    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    lo, hi = lum.min(), lum.max()
    # Dark gap texels sit low, bright crystal cells stand proud; the gaps
    # are cracks between lumps, not a deep groove cut into a face, so the
    # floor stays fairly high.
    region_target = 0.35 + 0.55 * (region_lum - lo) / max(hi - lo, 1e-6)

    # A rounded warp gives each cell an irregular, organic lump rather than
    # the art's own square patch, the same idea default_cobble.py domes its
    # stones with.
    labels_hi = lib.warp_labels(labels, amp=4.0, seed=51, cells=16)
    edges = lib.region_edges(labels_hi)
    max_dist = 4
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    target_map = region_target[labels_hi]
    layout = 0.35 * (1.0 - t) + target_map * t

    # A slow, broad bulge keeps the biggest lumps from reading flat topped,
    # and fine mineral grain sits inside each one.
    crown = lib.fbm(SIZE, base_cells=5, octaves=2, seed=52) * 0.05
    layout = layout + crown * t
    grain = lib.fbm(SIZE, base_cells=40, octaves=3, seed=53, gain=0.5) * 0.03
    height = lib.normalise01(layout + grain, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smooth crystal faces: high overall (pack moves the mean to the glass
    # class level, 0.92, above the byte's own 0.9 ceiling, so anything at
    # or above the mean clips flat there; the spread the check wants has
    # to come from the gaps reading distinctly rougher, a strong pull down
    # rather than a gentle one, or it is lost to the clip).
    rough_noise = lib.fbm(SIZE, base_cells=22, octaves=3, seed=54, gain=0.5)
    smooth = height - 0.55 * (1.0 - t) + 0.15 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    # Emission from the same luminance the height came from: the darkest
    # gap cells still glow at a third strength, the brightest lump faces
    # glow hardest, nothing at zero.
    lum_hi = lib.upscale(np.stack([lum] * 3, axis=-1))[..., 0]
    emission = 0.30 + 0.70 * lib.normalise01(lum_hi, 0.5, 99.5)
    print(f"emission min {emission.min():.3f} max {emission.max():.3f} mean {emission.mean():.3f}")

    normal_strength = 7.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, emission=emission)
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
