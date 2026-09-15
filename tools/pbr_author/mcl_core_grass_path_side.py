"""Hand authored height and smoothness for mcl_core_grass_path_side.

lib.class_of reports "leaves" for this stem too, for the same reason as
mcl_core_grass_path_top.py: the existing bake's subsurface byte was set
per node rather than per tile, and this node's top face pulled every one
of its tiles into the leaves bucket. The art is plainly dirt (warm and
cool browns, no green, no leaf shape), overridden to CLS = "soil".

The top row is fully transparent, alpha 0, the rest opaque: mcl_core:
grass_path is a nodebox 15/16 of the normal height (nodes_base.lua), and
this is the gap that leaves at its top. Kept in the albedo as the art
draws it (lib.upscale(src), all four channels), and worked around for the
height and segmentation below by using row 1's own colour in row 0's
place, since row 0's real colour, opaque white, is not paint, it is empty
space, and letting lib.segments see it as a texel of its own gave one
region a mean luminance of 1.0 and stretched every other region's target
into a sliver near zero.

Read row by row (mean luminance per source row) the art is not a flat
dither the way default_dirt.py's own four shades are: rows 1 to 5 run
warm and a little brighter (0.37 to 0.41), rows 6 and 7 drop to the
darkest in the tile (0.29 and 0.33), and rows 8 to 15 settle into a
cooler, more muted mid tone (0.33 to 0.38). That reads as three things,
not two: a trodden lip at the top, a shadowed crease where the lip steps
down, and ordinary dirt below, the same strata idea default_sandstone.py's
own bedding would use if this repository had one yet, a profile taken
across the whole row rather than a region. That profile is the base
height; default_dirt.py's own clod finding (lib.segments, its own warp
seed, its own lumps and grit seeds 21 and 22) sits on top of it for the
loose crumb texture within each band, and the same wear idea
mcl_core_grass_path_top.py uses damps that crumb where the lip itself is
brightest, because a trodden lip is compacted flatter, not rougher.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_grass_path_side"
CLS = "soil"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    alpha = src[..., 3]
    print(f"{STEM}: alpha min {alpha.min():.2f} max {alpha.max():.2f} "
          f"({int((alpha < 0.5).sum())} of 256 texels transparent)")
    print('class_of would say "leaves" (the old bake\'s per node '
          'classification); the art is plainly dirt, overridden to "soil"')

    # Row 0 is the node box's own 1/16 gap, opaque white in the file, not
    # paint; substituted with row 1's colour for segmentation and the row
    # profile below so it reads as a continuation of the dirt rather than
    # a blinding outlier. The true alpha and colour go into the albedo
    # further down, untouched.
    rgb_h = rgb.copy()
    rgb_h[0] = rgb_h[1]
    lum_h = lib.luminance(rgb_h)
    row_lum = lum_h.mean(axis=1)
    print("row means (row 0 substituted):", np.round(row_lum, 3).tolist())

    # The strata profile: a lip at the top, a shadowed crease where it
    # steps down, ordinary dirt below, continuous across the tile the way
    # a bedded stone's own row mean is, not tied to any one region.
    row_profile = np.repeat(row_lum, SIZE // 16)[:, None] * np.ones((1, SIZE), dtype=np.float32)
    row_profile = lib.blur(row_profile, 3)
    band = lib.normalise01(row_profile)

    # Same segmentation device as default_dirt.py, same tolerance, on the
    # row 0 substituted colour.
    tolerance = 0.05
    labels, n = lib.segments(rgb_h, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum_h[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:12], "...")

    labels_hi = lib.warp_labels(labels)  # default seed 7, shared with dirt
    target_clod = lib.normalise01(region_lum)
    step = target_clod[labels_hi]
    # Wider than default_dirt.py's own 1 and 2: at the tighter radii this
    # art's own two largest regions (45 texels each) met each other badly
    # across the wrap (clod layout seam energy 2.04); widened the same way
    # mcl_core_grass_path_top.py's own region step needed to be, spreading
    # the same real contrast over more texels (seam energy 1.57 at 4 and 8).
    narrow = lib.blur(step, 4)
    wide = lib.blur(step, 8)
    clod_layout = narrow + 1.1 * (narrow - wide)

    edges = lib.region_edges(labels_hi)
    dist = lib.distance_to_edge(edges, max_dist=4)
    t = np.clip(dist / 4.0, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    # Wear: the lip is compacted, so its own loose crumb is damped, the
    # same idea mcl_core_grass_path_top.py applies to its own worn patches.
    damp = 1.0 - 0.35 * band

    lumps = lib.fbm(SIZE, base_cells=10, octaves=3, seed=21, gain=0.55) * 0.16 * damp
    grit = lib.blur(lib.white_noise(SIZE, seed=22), 1) * 0.035 * damp
    # Deep, sparse and narrow, the same device mcl_core_grass_path_top.py
    # uses for the same reason: the band and clod_layout terms above are
    # each already stretched across their own 0 to 1 range before they are
    # combined, so a shallow pit loses almost all of its depth to the
    # final normalise01 below unless it is dug this deep to start with.
    pit_noise = lib.white_noise(SIZE, seed=25)
    pit_threshold = np.percentile(pit_noise, 85.0)
    pit_mask = np.clip((pit_noise - pit_threshold) / (pit_noise.max() - pit_threshold), 0.0, 1.0)
    pit_mask = lib.blur(pit_mask, 1)
    pits = -1.0 * pit_mask * damp

    height = lib.normalise01(0.55 * band + 0.45 * clod_layout + lumps + grit + pits, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows the region boundary and the fine variation the
    # same way default_dirt.py's does (seed 24), plus the lip's own wear:
    # compacted ground is worn smoother underfoot.
    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=24, gain=0.55)
    smooth = 0.30 * t + 0.40 * variation + 0.30 * band
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src)  # keeps the true alpha and colour, row 0 included

    normal_strength = 12.0  # tilt 23.3 deg at these amplitudes, want 15 to 25
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
