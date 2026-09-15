"""Hand authored height and smoothness for mcl_core_dirt_podzol_top.

The 16 px art is one hue throughout (row means confirmed the same warm
orange-brown top to bottom, no band the way the side face has), which
matches the brief: this whole face is the litter mat, not mat over a
visible soil patch. Connected regions of near identical colour
(lib.segments, tolerance 0.05) find one dominant patch of 179 texels at
the mat's own darkest, commonest shade, plus three dozen tiny one to five
texel clusters, all of them brighter than the mat. That is litter as it
actually lies: a continuous bed of decayed needle and leaf fragments, with
individual twigs and leaf edges catching the light as small proud flecks
rather than a drawn stone or clod anywhere in it.

Below the texel this script adds the mat's own structure, needles: thin
overlapping strands, not the round grain default_dirt uses. Two crossed
streak fields, one blurred long in x and one long in y (lib.blur only
blurs both axes together, so the streaks use a small hand written
single-axis version of the same wrapped box filter), stand in for tangled
needles lying in every direction, at a texel or two wide and roughly a
native texel long, which is the scale loose litter actually breaks into.

mcl_core_dirt_podzol_side.py shares this needle build verbatim (function
and seeds) for its own top band, so the two faces read as one material
rather than two different textures that happen to be similar colours.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_dirt_podzol_top"
CLS = "soil"
SIZE = lib.SIZE


def blur_axis(field, radius, axis):
    """Wrapped box blur along one axis only, lib.blur's method kept apart
    per axis so a streak can be long one way and thin the other."""
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def needle_detail(size, seed):
    """Tangled litter texture: two streak fields crossed at right angles,
    two length scales each so it is not one uniform weave, plus a fine
    isotropic dusting for the loam between the pieces. Returned roughly
    -1..1. Shared verbatim (same function, same seed) between the top and
    side scripts so the podzol block reads as one material.
    """
    long_x = blur_axis(lib.white_noise(size, seed), 12, axis=1)
    long_x += 0.6 * blur_axis(lib.white_noise(size, seed + 1), 5, axis=1)
    long_y = blur_axis(lib.white_noise(size, seed + 2), 12, axis=0)
    long_y += 0.6 * blur_axis(lib.white_noise(size, seed + 3), 5, axis=0)
    streaks = long_x + long_y
    streaks /= np.abs(streaks).mean() * 3.0
    dust = lib.blur(lib.white_noise(size, seed + 4), 1)
    return 0.75 * streaks + 0.35 * dust


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print("lib.class_of reads:", lib.class_of(STEM))

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:10], "...")
    mat_label = int(np.argmax(sizes))
    print(f"mat region: label {mat_label}, {sizes[mat_label]} texels, lum {region_lum[mat_label]:.3f}")

    # Target height: the mat itself is a shallow, fairly flat bed (it is
    # ground cover, not clods), the small brighter clusters sit a little
    # proud as visible litter pieces.
    lo, hi = region_lum.min(), region_lum.max()
    norm_lum = (region_lum - lo) / max(hi - lo, 1e-6)
    target = 0.38 + 0.22 * norm_lum
    target[mat_label] = 0.36

    labels_hi = lib.warp_labels(labels, amp=4.0)
    edges = lib.region_edges(labels_hi)
    max_dist = 3  # litter fragments are small, a narrower crown than a soil clod
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 0.8 * (narrow - wide)

    needles = needle_detail(SIZE, seed=51) * 0.09
    pits = lib.blur(lib.white_noise(SIZE, seed=55), 2) * 0.03

    height = lib.normalise01(layout + needles + pits, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: the mat is uniformly dull, no worn high face the way a
    # stone or a plank has, with a touch of variation from a needle's own
    # sheen versus the duller crumb between pieces.
    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=56, gain=0.55)
    smooth = 0.30 * t + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 7.0
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
