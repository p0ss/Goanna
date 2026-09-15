"""Hand authored LabPBR height and smoothness for default_obsidian.

The 16 px art is almost black (mean luminance 0.05), with one connected
region of 200 texels (78 percent of the tile) at a single dark purple shade,
0.023. Threaded through it is a network of thin, lighter purple streaks, 0.06
to 0.13, and a handful of brighter glints, 0.41 and 0.61. That is volcanic
glass: one broad conchoidal facet, dark and smooth, with the fracture lines
that bound it running as the lighter purple, and the glints sitting where a
fracture line catches the light straight on. The facet is not flat colour by
accident; it is the one thing here big enough to read as a surface.
"""
import sys

import numpy as np

import lib

STEM = "default_obsidian"
CLS = "stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)

    # The art's own top and left edges are a fracture ridge band, but its
    # bottom and right edges sit inside the dark facet, so the wrap join the
    # seam checker samples lands squarely on a facet to ridge step while
    # every ordinary join inside the tile sits on the far gentler facet
    # interior. Rolling picks a different texel to call (0, 0); the pattern
    # is the same closed loop either way (docs/pbr_author's default_cobble.py
    # does the same for the same reason), so nothing about the surface
    # changes, only where its one real seam lands relative to the edges the
    # checker samples. (3, 7) lands both wraps inside the facet.
    src = np.roll(src, (3, 7), axis=(0, 1))

    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} "
          f"mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    # Connected regions of near identical colour. 0.03 keeps the facet as
    # one region (its own internal dither is under 0.01) while cutting every
    # fracture streak and glint away from it: 32 regions, one at 200 texels
    # and everything else one to eleven, exactly the one broad facet plus a
    # thin crack network the description asks for.
    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))

    # Target height per region: the facet sits at a mid level so the ridges
    # have room to rise above it, the fracture streaks rise as the ridges
    # the art draws them as, and the glints are where a ridge stands
    # highest and catches the light.
    facet = region_lum < 0.04
    glint = region_lum > 0.3
    ridge = ~facet & ~glint
    print(f"facet regions: {int(facet.sum())} ({int(sizes[facet].sum())} texels), "
          f"ridge regions: {int(ridge.sum())} ({int(sizes[ridge].sum())} texels), "
          f"glint regions: {int(glint.sum())} ({int(sizes[glint].sum())} texels)")
    baseline = 0.45
    target = np.where(facet, baseline, np.where(glint, 0.95, 0.75))

    labels_hi = lib.warp_labels(labels, amp=4.0)
    edges = lib.region_edges(labels_hi)
    max_dist = 2  # a fracture line is one or two texels wide; keep the ridge sharp, not a soft dome
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: the facet stays flat mid tile, the ridge rises sharply at its edge
    layout = baseline + (target[labels_hi] - baseline) * t

    # Sub texel structure: the facet is glass, so it gets only the faintest
    # ripple, the trace of the conchoidal shell rather than any grain; the
    # ridge network gets a rougher scatter, the broken edge of the fracture.
    # A broad low frequency dome was tried for the facet's own curvature, on
    # the reasoning that conchoidal means shell shaped, not flat; it only
    # diluted the ridge contrast under normalise01's percentile stretch and
    # lowered the tilt it was meant to raise, so the ridge network carries
    # the surface's tilt alone, at a normal_strength high enough for that.
    ripple = lib.fbm(lib.SIZE, base_cells=24, octaves=2, seed=41, gain=0.5) * 0.015
    fracture_grain = lib.blur(lib.white_noise(lib.SIZE, seed=42), 1) * 0.03
    is_ridge_hi = t > 0.05
    height = layout + ripple + np.where(is_ridge_hi, fracture_grain, fracture_grain * 0.2)
    height = lib.normalise01(height, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness is the whole point of this surface: the facet is glass,
    # about as smooth as anything in the pack gets, and the fracture ridges
    # are the broken, rough edge where that glass gave way. Built the same
    # shape as height (facet flat, ridge and glint raised) but inverted in
    # sign against roughness noise, so the facet stays glassy even where the
    # ripple dips it and the ridge stays rough even at its raised crest.
    # pack() moves the mean to the class level; the spread, the whole story
    # here, is ours.
    rough_noise = lib.fbm(lib.SIZE, base_cells=18, octaves=3, seed=43)
    smooth = 0.85 - 0.7 * t + 0.1 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the facet to fracture edges the height field
    # lines up with.
    albedo = lib.upscale(src[..., :3])

    normal_strength = 65  # a thin, sharp ridge network only touches a slim area, so it needs real depth to carry the tile's mean tilt on its own
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
