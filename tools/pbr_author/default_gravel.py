"""Hand authored LabPBR height and smoothness for default_gravel.

The 16 px art has nine grey shades and the widest spread of the three
stems, standard deviation 0.105 against stone's 0.045. There is a clean
gap in the shade list between 0.399 and 0.489, splitting it five shades
low (0.216 to 0.399) and four high (0.489 to 0.673): the low group is the
gaps between pebbles, sitting in shadow, and the high group is pebble tops
catching the light. Unlike cobble there is no single large background
slab; nearly every texel is its own small pebble or its own small gap.
"""
import sys

import numpy as np

import lib

STEM = "default_gravel"
CLS = "gravel"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)

    # As with default_cobble, this only chooses which texel the wrapped
    # array calls (0, 0). The gravel is a closed loop of pebbles and gaps
    # either way; this phase keeps a big pebble-to-gap edge off row and
    # column 0, where the seam checker would otherwise read it as a defect.
    src = np.roll(src, (12, 10), axis=(0, 1))

    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} "
          f"mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    # Connected regions of near identical colour. 0.05 keeps a pebble's own
    # texels together without bridging pebble to pebble: 123 regions, most
    # one to four texels, a few chains up to fourteen. Real gravel is
    # exactly this, a great many small stones, not a dozen big ones.
    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))

    # Target height per region: the low shade group is a true gap, cut down
    # near the floor regardless of exactly how dark; the high shade group is
    # a pebble dome, its own height rising with its own brightness so a
    # sunlit pebble stands taller than a merely lit one.
    baseline = 0.12
    gap = region_lum <= 0.42
    dome = ~gap
    print(f"gap regions: {int(gap.sum())} of {n}, {int(sizes[gap].sum())} texels; "
          f"dome regions: {int(dome.sum())}, {int(sizes[dome].sum())} texels")
    dlo, dhi = region_lum[dome].min(), region_lum[dome].max()
    target = np.where(gap, 0.08,
            0.55 + 0.40 * (region_lum - dlo) / max(dhi - dlo, 1e-6))

    labels_hi = lib.warp_labels(labels)
    edges = lib.region_edges(labels_hi)
    max_dist = 3  # pebbles are one to four texels across, a tight taper keeps each one a distinct small dome
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: rounds a square texel into a dome, or lets a gap sink cleanly
    layout = baseline + (target[labels_hi] - baseline) * t

    # Sub texel structure: grit a couple of texels across on the pebble
    # tops, and a scatter of finer pores and dirt down in the gaps. Gravel
    # is rougher grained than dressed stone, so both sit a shade stronger
    # than the equivalent layers in default_stone.
    grit = lib.fbm(lib.SIZE, base_cells=40, octaves=3, seed=31, gain=0.55) * 0.08
    dirt = lib.blur(lib.white_noise(lib.SIZE, seed=32), 1) * 0.08
    height = lib.normalise01(layout + grit + dirt, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the gaps hold dust and stay rough, pebble
    # tops are what a boot rounds smooth. Gravel's own variation, loose and
    # ungraded, rides on top; pack() moves the mean to the class level, the
    # spread is ours to set.
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=33)
    smooth = 0.5 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the pebble and gap edges the height field lines
    # up with.
    albedo = lib.upscale(src[..., :3])

    normal_strength = 26
    # Held in a band scaled to the surface's real depth: full range
    # domes read as rubble under a grazing lamp on the ramp.
    height = lib.band(height, 0.3)
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
