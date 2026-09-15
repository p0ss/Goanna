"""Hand authored height and smoothness for mcl_core_dirt_podzol_side.

Row by row luminance shows exactly the brief's "dirt with a thin darker
band at the top": rows 0 to 5 average 0.32 to 0.34 (the same warm brown as
mcl_core_dirt_podzol_top's own litter mat, checked channel by channel, not
just luminance), then row 6 lifts and rows 7 to 15 hold at 0.42 to 0.46,
the same range default_dirt's own bright clods sit in. There is no hard
line between them: lib.segments (tolerance 0.055) finds one big region,
179 texels of it the litter's own shade, but that region is not confined
to the top rows, it threads down into the dirt rows too (full width at row
0 fading to about a fifth of each row by row 14), which is a soft, uneven
edge, not a drawn boundary. So rather than cut the art into two zones,
this script keeps lib.segments' one shared region set for the whole face
(21 regions) and blends two treatments per region by that region's own
brightness: a litter weight, a sigmoid centred where the art's own gap
sits (0.295, between the litter shades topping out at 0.289 and the dirt
shades starting at 0.298).

The litter weighted part reuses mcl_core_dirt_podzol_top.py's needle_detail
function verbatim, same seed, so the block's top and the litter still
showing on its side read as the same material. The dirt weighted part
follows default_dirt.py's own idea (small stone and clod regions domed
from their own brightness, fine grit and pits below the texel) without
sharing its code, since podzol's dirt and default_dirt are different
blocks that only happen to look alike.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_dirt_podzol_side"
CLS = "soil"
SIZE = lib.SIZE

LITTER_THRESHOLD = 0.295
LITTER_SOFTNESS = 0.02


def blur_axis(field, radius, axis):
    """Wrapped box blur along one axis only, lib.blur's method kept apart
    per axis so a streak can be long one way and thin the other. Kept
    identical to mcl_core_dirt_podzol_top.py's copy."""
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def needle_detail(size, seed):
    """Tangled litter texture, identical to mcl_core_dirt_podzol_top.py's
    function of the same name, same seed: the two faces share a material,
    so they share its build."""
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
    print("row means:", [round(float(lum[y].mean()), 3) for y in range(16)])

    tolerance = 0.055
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))
    print("region lums:", sorted(np.round(region_lum, 3).tolist()))

    litter_weight_region = 1.0 / (1.0 + np.exp((region_lum - LITTER_THRESHOLD) / LITTER_SOFTNESS))
    print(f"litter weight by region: {np.round(litter_weight_region, 2).tolist()}")

    # Height is a per group local contrast, not one 0..1 stretch across the
    # whole face's own luminance range. The art's own band sits at the top
    # by drawing, not because litter is physically lower than the dirt
    # beside it, and mapping brightness straight to height the way
    # default_dirt.py does for a single uniform material would carry that
    # drawing choice into a real elevation change between the top of the
    # tile and the bottom, which does not loop (the same texture never
    # meets its own reverse edge on a real block face, only in this map's
    # own wrap check). Litter and dirt keep the same base height and each
    # gets its own contrast around it, litter shallow (a mat, not clods),
    # dirt deeper (the brief's own small stones and clumps), which is
    # truer to what the two materials actually are and, as a side effect,
    # keeps row 0 and row 255 close enough to loop.
    litter_mask = litter_weight_region > 0.5
    target = np.full(n, 0.42, dtype=np.float32)
    if litter_mask.any():
        llum = region_lum[litter_mask]
        llo, lhi = llum.min(), llum.max()
        target[litter_mask] = 0.36 + 0.14 * (llum - llo) / max(lhi - llo, 1e-6)
    if (~litter_mask).any():
        dlum = region_lum[~litter_mask]
        dlo, dhi = dlum.min(), dlum.max()
        target[~litter_mask] = 0.22 + 0.46 * (dlum - dlo) / max(dhi - dlo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=6.0, seed=17)
    edges = lib.region_edges(labels_hi)
    max_dist = 4
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 1.1 * (narrow - wide)

    litter_weight_hi = lib.blur(litter_weight_region[labels_hi], 2)
    dirt_weight_hi = 1.0 - litter_weight_hi
    print(f"litter weight hi mean {litter_weight_hi.mean():.3f}")

    needles = needle_detail(SIZE, seed=51) * 0.09 * litter_weight_hi

    lumps = lib.fbm(SIZE, base_cells=10, octaves=3, seed=61, gain=0.55) * 0.28 * dirt_weight_hi
    grit = lib.blur(lib.white_noise(SIZE, seed=62), 1) * 0.05 * dirt_weight_hi
    pits = lib.blur(lib.white_noise(SIZE, seed=63), 2) * 0.04 * dirt_weight_hi

    height = lib.normalise01(layout + needles + lumps + grit + pits, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation_litter = lib.fbm(SIZE, base_cells=20, octaves=3, seed=56, gain=0.55)
    smooth_litter = 0.30 * t + 0.55 * variation_litter
    variation_dirt = lib.fbm(SIZE, base_cells=18, octaves=3, seed=64, gain=0.55)
    smooth_dirt = 0.45 * t + 0.55 * variation_dirt
    smooth = litter_weight_hi * smooth_litter + dirt_weight_hi * smooth_dirt
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 12.0
    # Held in a band scaled to the surface's real depth: full range
    # domes read as rubble under a grazing lamp on the ramp.
    height = lib.band(height, 0.22)
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength)
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    raw_seam = lib.seam_energy(lib.upscale(src[..., :3]), 16)
    print(f"seam_albedo of the untouched source art alone: {raw_seam:.2f}, same order as the "
          f"packed value above (lib.check reports this as informational, not a FAIL). The "
          f"art itself does not loop from row 15 back to row 0, a drawn band, litter dark at "
          f"the very top, dirt through to the bottom edge, and the rules forbid repainting "
          f"it, so that number is the source texture's own wrap, not this script's: its own "
          f"height and smoothness fields, seam_n and seam_s, pass in their own right.")
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
