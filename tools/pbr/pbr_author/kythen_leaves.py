"""Hand authored height and smoothness for kythen_leaves, a cut-out.

The 16 px art is 80.5 percent opaque, luminance 0.29 to 0.41 in the leaf
body, with the remaining texels fully transparent, scattered gaps rather
than a handful of big holes (a light-catching canopy gap look, not one
carved shape). This draws through the scissor shader, no parallax march,
so its relief only has to read right under direct shading: the opaque body
gets soft lobed mounds, peaking away from every cut edge, and the alpha
is kept as drawn.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_leaves"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    alpha = src[..., 3]
    lum = lib.luminance(rgb)
    opaque = alpha > 0.5
    print(f"opaque fraction {opaque.mean():.3f}")
    print(f"opaque lum min {lum[opaque].min():.3f} max {lum[opaque].max():.3f} mean {lum[opaque].mean():.3f}")

    # The cut-out boundary itself, opaque against transparent, warped so
    # the gaps read as irregular light gaps in foliage rather than the
    # square holes the alpha channel actually draws.
    is_leaf = opaque.astype(int)
    labels_hi = lib.warp_labels(is_leaf, size=SIZE, amp=3.0, seed=81, cells=10)
    leaf_mask = labels_hi == 1
    edges = lib.region_edges(labels_hi)
    max_dist = 5
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    # A guide from the art's own shading inside the leaf body: a lighter
    # texel is already the artist's own highlight, so it becomes a slightly
    # higher lobe crown.
    guide = lib.upscale(lum, smooth=False)
    guide = lib.normalise01(np.where(lib.upscale(opaque.astype(np.float32)) > 0.5, guide, guide.mean()))

    layout = 0.30 + 0.35 * t * (0.5 + 0.5 * guide)
    layout = np.where(leaf_mask, layout, 0.15)  # cut away anyway; kept low and tidy

    lobes = lib.fbm(SIZE, base_cells=14, octaves=3, seed=82, gain=0.55) * 0.14
    veins = lib.blur(lib.white_noise(SIZE, seed=83), 1) * 0.05
    height = lib.normalise01(layout + lobes * t + veins, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: a leaf's waxy top is a touch smoother at the lobe crowns,
    # rougher toward the cut edge, with its own variation on top.
    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=84, gain=0.55)
    smooth = 0.5 * t + 0.5 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src)  # RGBA, keeps the cut-out alpha

    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 12.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, cls,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, cls)
    for line in lines:
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
