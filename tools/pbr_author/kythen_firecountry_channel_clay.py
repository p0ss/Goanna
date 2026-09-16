"""Hand authored height and smoothness for kythen_firecountry_channel_clay.

The 32 px art draws a real crack network, not a mottled slab: printed as a
quantised grid, the darkest shade traces a branching web of thin lines
through a bright matrix, with occasional brighter facets between them, the
polygon shapes a dried clay pan cracks into. lib.segments (tolerance 0.03,
tight enough to keep the crack lines their own region rather than
bridging into the matrix) finds one 640 texel matrix and forty nine
smaller regions, the facets and the crack fragments the lines break into.
The construction follows default_clay.py's own reading of a comparable
crack network, blocky lumps a shade proud of the cracks between them, but
held far shallower: channel clay is a smooth, shallow, fine polygonal
crack, not blocky dug clay, so the relief is kept in a narrow band about
the middle rather than default_clay's own wider one.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_channel_clay"
CLS = "soil"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")

    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:15])
    print(f"{int((sizes == 1).sum())} of {n} regions are a single texel (a crack line a full texel wide)")

    # The facets themselves are held close to one level, held nearly flat
    # the way the brief asks: a dried pan's unbroken faces do not tilt,
    # only the crack between them drops away. Brightness still gives each
    # facet a small amount of its own relief, a fifth of the crack's own
    # depth below.
    lo, hi = region_lum.min(), region_lum.max()
    norm_lum = (region_lum - lo) / max(hi - lo, 1e-6)
    facet_level = 0.80 + 0.10 * norm_lum

    # A gentle warp: this clay pan cracked on its own, not along a drawn
    # grid, so its boundaries get the same organic bend default_clay.py
    # uses, at the ordinary amplitude since channel_clay's regions are
    # plentiful and short, not the long boundaries that needed a wider
    # bend there.
    labels_hi = lib.warp_labels(labels, amp=5.0, seed=201)
    edges = lib.region_edges(labels_hi)
    max_dist = 2  # a fine, shallow crack: narrower than default_clay's own
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = facet_level[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    facets = narrow + 1.0 * (narrow - wide)

    # The crack itself: a real notch, deep enough right at the line to
    # occlude, even though the facets either side of it stay close to
    # flat. This is what a real hairline crack does, a narrow real cut
    # in an otherwise undisturbed pan, not a general roughening of the
    # whole surface.
    crack_notch = (1.0 - t) ** 1.5 * 0.85
    layout = facets - crack_notch

    # Structure below the texel: a light dusting, this is a fired-smooth
    # pan face not a gritty dug clay, plus a scatter of hairline cracks
    # too small for lib.segments, the same device default_clay.py uses.
    fine_cracks = lib.blur(lib.white_noise(SIZE, seed=202), 1)
    fine_cracks = np.where(fine_cracks < -0.6, fine_cracks + 0.6, 0.0) * 0.5
    dust = lib.blur(lib.white_noise(SIZE, seed=203), 1) * 0.02

    height = np.clip(layout + fine_cracks + dust, 0.0, 1.0)
    print(f"height sd {height.std():.3f}")

    # Smoothness: high across most of a facet, only the crack line itself
    # drops rough, plus the clay's own faint variation.
    variation = lib.fbm(SIZE, base_cells=24, octaves=3, seed=204, gain=0.6)
    smooth = 0.5 + 0.35 * (t - 0.5) + 0.36 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    # A real, if narrow, groove at the crack itself; the facets it cuts
    # between are what stay held nearly flat, per the brief. The crack
    # network is dense enough on this art that the map's own mean tilt
    # still lands in the soil band even though any one facet barely
    # tilts at all.
    normal_strength = 13.0
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
