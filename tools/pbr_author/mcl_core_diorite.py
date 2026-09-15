"""Hand authored LabPBR height and smoothness for mcl_core_diorite.

The 16 px art is six shades of near neutral grey, lum 0.430 to 0.746, sd
0.075, the widest lum spread of the three crystalline stones but no strong
colour split the way granite has warm and cool grains. 80 percent of the
art (0.522, 0.582, 0.646) is one broad mid grey band: diorite's real
character, almost uniformly pale, with only a minority of darker biotite
flecks (0.430, 17 texels) and a smaller minority of bright quartz sparkle
(0.691, 0.746, 33 texels) breaking from it. As with granite both fleck
colours stand a little proud of the matte matrix band; there is just less
of the art given over to flecks here; diorite reads calmer than granite.
"""
import sys

import numpy as np

import lib

STEM = "mcl_core_diorite"
CLS = "stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} "
          f"mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    # Connected regions of near identical colour. 0.03 keeps a fleck's own
    # texels together: 90 regions, most one to eleven texels. Larger and
    # fewer than andesite's, smaller and more numerous than granite's,
    # which is the mid grain size the three stems are meant to span.
    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))

    # Target height per fleck: the broad 0.48 to 0.68 band is the matte
    # matrix and stays lowest; the dark biotite flecks and the bright
    # quartz sparkle both stand proud of it, the quartz higher because it
    # is what actually catches a highlight.
    baseline = 0.45
    dark_fleck = region_lum < 0.48
    light_fleck = region_lum > 0.66
    matrix = ~dark_fleck & ~light_fleck
    print(f"dark flecks: {int(dark_fleck.sum())}, light flecks: "
          f"{int(light_fleck.sum())}, matrix: {int(matrix.sum())} of {n}")
    target = np.where(dark_fleck, 0.60, np.where(light_fleck, 0.84, baseline))

    labels_hi = lib.warp_labels(labels)
    edges = lib.region_edges(labels_hi)
    max_dist = 2  # mid taper, between granite's coarse grains and andesite's fine ones
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: rounds a square fleck into a domed crystal face
    layout = baseline + (target[labels_hi] - baseline) * t

    # Sub texel structure: fine mineral grain across the matrix, and a
    # sparser scatter of pores under it, both modest, diorite being the
    # calmest of the three stems.
    grain = lib.fbm(lib.SIZE, base_cells=30, octaves=3, seed=51, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=52), 1) * 0.03
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the matrix stays matte, the proud flecks
    # are what a polish catches. Diorite's own variation rides on top;
    # pack() moves the mean, we owe the spread.
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=53)
    smooth = 0.55 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the fleck edges the height field lines up with.
    albedo = lib.upscale(src[..., :3])

    normal_strength = 33
    # Held in a band scaled to the surface's real depth: full range
    # domes read as rubble under a grazing lamp on the ramp.
    height = lib.band(height, 0.15)
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
