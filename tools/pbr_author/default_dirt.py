"""Hand authored height and smoothness for default_dirt.

The 16 px art has four grey shades: 0.284, 0.322, 0.367 and 0.418, and no
drawn outline of a stone or a clod, only a per texel dither between them.
Connected regions of near identical colour (lib.segments, tolerance 0.05,
tight enough that only truly matching neighbours join) still find real
structure in that dither: one 37 texel patch of the commonest mid shade,
a dozen mid sized patches of 4 to 19 texels, and 33 lone texels, mostly
the darkest shade sitting on its own. That reads as dirt actually does:
a few small stones and clods a handful of texels across, sitting in a
loose crumb of soil, with the darkest texels the gaps between them rather
than a clod of their own. Height follows the shade directly, darkest low,
lightest high, each region rounded into its own low dome or pit rather
than the flat plateau the raw art would give it if upscaled unrounded.
"""

import sys

import numpy as np

import lib

STEM = "default_dirt"
CLS = "soil"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    # 0.05 is well under the roughly 0.09 gap between any two of the four
    # shades (Luanti's palette here steps by about 0.11 in raw channel
    # value each time), so a region only grows by matching, not by
    # crossing a shade boundary. That gives small, real clumps rather than
    # the two giant blobs a looser tolerance collapses everything into.
    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))
    print(f"{int((sizes == 1).sum())} of {n} regions are a single texel")

    # Target height per region, straight off its own brightness: the
    # darkest texels are the recesses between clods, the lightest are a
    # clod or stone's sunlit top, matching the rule the source planks and
    # cobble scripts use, that a lighter fleck in hand painted dirt is
    # already the artist's own highlight.
    lo, hi = region_lum.min(), region_lum.max()
    target = 0.15 + 0.65 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = np.kron(labels, np.ones((16, 16), dtype=int))
    edges = lib.region_edges(labels_hi)
    max_dist = 4  # crown fade half width; regions are 16 to 96 hires texels wide
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep, 1 mid region, 0 right at a boundary

    # The plateau: blur the region step rather than taper each region from
    # its own edge, for the same reason as the planks script, a step in
    # amplitude between two regions of very different brightness meets a
    # neighbour with two different slopes either side of the crossing, a
    # kink that is invisible except exactly at the wrap seam, where one of
    # these boundaries always lands. A blur shares one ramp, same slope on
    # both sides, everywhere including there. A single texel of blur alone
    # is too soft for the ambient occlusion small stones need, so an
    # unsharp mask (the narrow blur plus its own excess over a wider one)
    # steepens the ramp without touching the matched slope at its centre.
    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 1.1 * (narrow - wide)

    # Lumpiness at a scale above the segmented regions: real clods clump
    # a few texels across even where the art's own dither does not happen
    # to cross a shade boundary there. Isotropic, since a clod has no
    # preferred direction the way a plank's grain does.
    lumps = lib.fbm(SIZE, base_cells=10, octaves=3, seed=21, gain=0.55) * 0.30

    # Structure below the texel: fine grit, a little coarser than sand's,
    # and sparse small pits.
    grit = lib.blur(lib.white_noise(SIZE, seed=22), 1) * 0.05
    pits = lib.blur(lib.white_noise(SIZE, seed=23), 2) * 0.04

    height = lib.normalise01(layout + lumps + grit + pits, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows the region boundary the same way it follows the
    # joint on planks, from t rather than from height's own absolute jump
    # between a bright stone and a dark recess (which would seam badly at
    # whichever boundary the wrap happens to cross, the same reasoning as
    # the planks script). Recesses collect dust and stay rough; a stone's
    # own worn top is a touch smoother, with the material's grubby
    # variation from an independent noise field on top.
    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=24, gain=0.55)
    smooth = 0.45 * t + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the region edges the height field lines up with.
    albedo = lib.upscale(src[..., :3])

    normal_strength = 16.0
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
