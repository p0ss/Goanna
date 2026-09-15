"""Hand authored height and smoothness for default_clay.

The 16 px art has five grey-buff shades in a narrow 0.118 span. Connected
regions of near identical colour (lib.segments, tolerance 0.03) find one
114 texel patch at the commonest mid shade and 38 smaller ones, from 15
texels down to 12 lone texels, which reads as the brief describes: a body
of clay one shade dominates, broken into blocky lumps by the brighter and
darker patches sitting in and around it, with the loose single texels
being where a crack runs a full texel wide. A looser tolerance (0.035)
collapses this to one 214 texel blob and a handful of specks, too little
structure left to carve a lump from; a tighter one (0.02) fragments it
into a hundred small regions, more than the art's own five shade steps can
really support. 0.03 is the point in between that keeps the lumps without
inventing more of them than the dither has.

lib.class_of(STEM) reads "soil" from the old bake, in line with the art:
the brief's fine cracks need the jointed AO rule (ao_min at or under 0.35)
that only stone, gravel, wood and soil get, and unfired clay dug from the
ground is a matte material like dirt, not a glossy one, so soil's tilt
band (15 to 25 degrees) suits blocky lumps with cracks between them well.
pack() moves every soil stem's mean smoothness onto the same class level
(0.05), which ties clay's own mean to coarse dirt's and podzol's: the
brief's "clay is smoother than dirt" is built here the same way this
script's coarse dirt sibling makes a stone read smoother than its soil,
inside one shared class level, not by shifting the level itself. Almost
all of a lump's own face sits at a high smooth value; only the thin crack
line between lumps drops rough, so the bulk of the surface reads smooth
and only the cracks read like dirt, rather than dirt's own broad,
evenly grubby crumb.
"""

import sys

import numpy as np

import lib

STEM = "default_clay"
CLS = "soil"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print("lib.class_of reads:", lib.class_of(STEM))

    for tolerance in (0.02, 0.025, 0.03, 0.035):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        sizes = np.bincount(labels.ravel())
        print(f"segments at tolerance {tolerance}: n={n} biggest={int(sizes.max())}")

    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"using tolerance {tolerance}: n={n}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))
    print(f"{int((sizes == 1).sum())} of {n} regions are a single texel (where a crack runs a full texel wide)")

    # Target height: a shallower range than dirt's own, blocky lumps
    # standing a little proud of the crack network between them rather
    # than dirt's own deep clods and recesses.
    lo, hi = region_lum.min(), region_lum.max()
    norm_lum = (region_lum - lo) / max(hi - lo, 1e-6)
    target = 0.30 + 0.45 * norm_lum

    # A wider warp than default_dirt.py's own default (10 texels against
    # 6): with only 39 regions against dirt's 133, clay's boundaries are
    # long and few, and lib.warp_labels' default amplitude bends them just
    # enough that one particular boundary can still land almost straight
    # across the tile and repeat itself at the wrap, a coincidence of this
    # art and this label count rather than anything wrong with the
    # technique (default_dirt.py's own many short boundaries average that
    # coincidence away on their own). A wider bend breaks it up; seed 13
    # was picked from a sweep of the wrap seam alone, looking for a low
    # value, not for a look, since a bend this size reads the same either
    # way, rounded lumps rather than square ones.
    labels_hi = lib.warp_labels(labels, amp=10.0, seed=13)
    edges = lib.region_edges(labels_hi)
    max_dist = 3  # a fine crack: narrower than default_dirt's own crown, not a hairline
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 1.1 * (narrow - wide)

    # Lumpiness above the segmented regions, gentle: these are blocky
    # lumps settled together, not a loose crumb.
    lumps = lib.fbm(SIZE, base_cells=9, octaves=2, seed=81, gain=0.5) * 0.14

    # Structure below the texel: clay is smooth, so this is a light
    # dusting rather than dirt's own grit, plus a scatter of very fine
    # hairline cracks too small for lib.segments to have found, using the
    # same distance field idea at a finer scale so they read as cracks
    # rather than noise.
    fine_cracks = lib.blur(lib.white_noise(SIZE, seed=82), 1)
    fine_cracks = np.where(fine_cracks < -0.55, fine_cracks + 0.55, 0.0) * 0.6
    dust = lib.blur(lib.white_noise(SIZE, seed=83), 1) * 0.03

    height = lib.normalise01(layout + lumps + fine_cracks + dust, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: high across most of a lump's own face, only the crack
    # (t near 0) drops it rough, plus the material's own light variation.
    variation = lib.fbm(SIZE, base_cells=22, octaves=3, seed=84, gain=0.55)
    smooth = 0.55 + 0.46 * (t - 0.5) + 0.26 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 10.5
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
