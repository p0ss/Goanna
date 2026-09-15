"""Hand authored height and smoothness for mcl_core_coarse_dirt.

The 16 px art has seven grey-brown shades, all one hue (every shade's RGB
triplet sits on the same warm brown, only lightness moves, so this is dirt
dither, not a second material painted in). The two brightest shades, 0.483
and 0.563, sit apart from the rest by a wide gap (0.065, the largest step
in the shade ladder) and cover 55 of 256 texels: the small stones the
brief describes, sitting in a loose crumb of soil that runs from 0.284 to
0.418. Connected regions of near identical colour (lib.segments, tolerance
0.05) find 133 small patches, most of them one to ten texels, which is the
right grain for stones a few texels across rather than the single large
patch a clay or dirt-clod block would show.

lib.class_of(STEM) reads back "leaves" for this stem: the pack's existing
_s.png (not yet hand authored) carries a subsurface scattering byte of
about 160, which decodes to the leaves class. That is a stray result from
an earlier automated classification pass, not a property of this art: the
source is a flat warm brown dither with no green in it anywhere (checked
RGB per shade below), and the brief is explicit that this is dirt with
stones in it. Using "leaves" here would set the smoothness level to a
glossy 0.30 and add leaf-like backlighting to a soil block, which the
README's own "dirt" row does not describe and which nothing in the art
supports. This script uses "soil", matching its coarse-dirt family and the
brief's own description, and prints the class_of reading for the record.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_coarse_dirt"
CLS = "soil"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print("lib.class_of reads:", lib.class_of(STEM), "(stray leaves SSS on the old bake; using soil, see docstring)")

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:12], "...")
    print(f"{int((sizes == 1).sum())} of {n} regions are a single texel")

    # A stone is a region whose own colour sits in the bright cluster
    # (0.45 falls in the 0.065 gap between the soil shades and the two
    # brightest ones, so it is a clean cut, not an arbitrary pick).
    is_stone_region = region_lum >= 0.45
    print(f"{int(is_stone_region.sum())} of {n} regions read as stone "
          f"({100 * lum[is_stone_region[labels]].size / lum.size:.1f}% of texels)" if is_stone_region.any() else "no stone regions")

    # Target height per region: soil runs low to mid, stones sit distinctly
    # higher, a real dome breaking the surface rather than just the
    # brightest end of the soil's own range.
    lo, hi = region_lum.min(), region_lum.max()
    norm_lum = (region_lum - lo) / max(hi - lo, 1e-6)
    target = np.where(is_stone_region, 0.62 + 0.28 * norm_lum, 0.12 + 0.38 * norm_lum)

    labels_hi = lib.warp_labels(labels)
    edges = lib.region_edges(labels_hi)
    max_dist = 4
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    # Same unsharp trick as default_dirt.py: a blur of the region step
    # shares one ramp either side of a boundary, which a tapered-from-edge
    # version would not, and that matters exactly at the wrap seam.
    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 1.1 * (narrow - wide)

    # Lumpiness above the segmented regions, coarser than default_dirt's
    # (base_cells 8 against its 10): "coarse" dirt reads as a chunkier
    # crumb, not just more stones.
    lumps = lib.fbm(SIZE, base_cells=8, octaves=3, seed=41, gain=0.55) * 0.32

    # Structure below the texel: grit a touch coarser than default_dirt's,
    # and sparse pits in the soil, not on the stones (a stone's face is
    # worn, not pitted).
    grit = lib.blur(lib.white_noise(SIZE, seed=42), 1) * 0.06
    is_stone_hi = is_stone_region[labels_hi]
    pits = lib.blur(lib.white_noise(SIZE, seed=43), 2) * 0.05 * (~is_stone_hi)

    height = lib.normalise01(layout + lumps + grit + pits, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows t the way default_dirt.py's does (recesses rough,
    # region tops a touch smoother), plus a flat offset raising the stones
    # above the soil: a stone's worn face takes a polish loose crumb never
    # gets, per the brief.
    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=44, gain=0.55)
    stone_bonus = 0.30 * is_stone_hi.astype(np.float32)
    smooth = 0.40 * t + 0.45 * variation + stone_bonus
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 15.0
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
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
