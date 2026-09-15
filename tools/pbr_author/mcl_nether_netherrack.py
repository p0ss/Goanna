"""Hand authored LabPBR height and smoothness for mcl_nether_netherrack.

The 16 px art is seven shades of red brown, lum 0.200 to 0.412, sd 0.056,
with a clean gap between 0.255 and 0.338: below it is one broad shade
(0.255, 31 percent of the art, the rock's own floor) and four darker
shades (0.200 to 0.237, 44 percent) below that, and above the gap are two
brighter shades (0.338, 0.412, 25 percent). Netherrack is not crystalline
like the previous three stems: it is porous, riddled rock, so the dark
texels here read as pits cut into the floor rather than crystal grains
standing proud of it, and the bright texels are the untouched crust between
pits. Unlike the crystalline stones, the pitting does not stop at the
texel: real netherrack is pocked everywhere, so a heavier scatter of sub
texel pores runs across the whole tile, floor and crust alike.
"""
import sys

import numpy as np

import lib

STEM = "mcl_nether_netherrack"
CLS = "stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} "
          f"mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    # Connected regions of near identical colour. 0.03 keeps a pit's own
    # texels together: 95 regions, most one to seven texels, close to
    # gravel's own grain, which fits: a pit is a small feature the same
    # size as a pebble, just cut down instead of piled up.
    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))

    # Target height per region: the floor shade (0.255) is the untouched
    # rock and sits at the baseline; the four darker shades are pits, cut
    # down further the darker they are; the two brighter shades are crust
    # that has not pitted, raised further the brighter.
    baseline = 0.45
    pit = region_lum < 0.245
    crust = region_lum > 0.30
    floor = ~pit & ~crust
    print(f"pit: {int(pit.sum())}, crust: {int(crust.sum())}, "
          f"floor: {int(floor.sum())} of {n}")
    plo, phi = region_lum[pit].min(), region_lum[pit].max()
    clo, chi = region_lum[crust].min(), region_lum[crust].max()
    target = np.where(pit,
            0.32 - 0.22 * (phi - region_lum) / max(phi - plo, 1e-6),
            np.where(crust,
                    0.56 + 0.14 * (region_lum - clo) / max(chi - clo, 1e-6),
                    baseline))

    labels_hi = lib.warp_labels(labels)
    edges = lib.region_edges(labels_hi)
    max_dist = 2  # pits run one to a few texels across, the same tight taper as gravel's pebbles
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: rounds a square texel into a pit or a raised crust patch
    layout = baseline + (target[labels_hi] - baseline) * t

    # Sub texel structure: netherrack is pocked everywhere, not just where
    # the art shows a dark texel, so a strong scatter of fine pores runs
    # over the whole tile, floor and crust alike, heavier than any of the
    # crystalline stones carry, plus a little grit riding under it.
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=81), 1) * 0.10
    grit = lib.fbm(lib.SIZE, base_cells=44, octaves=3, seed=82, gain=0.55) * 0.05
    height = lib.normalise01(layout + pores + grit, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height only loosely here: netherrack is rough
    # everywhere, pits and crust alike, so the height term is kept small
    # and the material's own noisy variation, porous and ungraded, carries
    # most of the spread. pack() moves the mean to the class level.
    rough_noise = lib.fbm(lib.SIZE, base_cells=24, octaves=3, seed=83)
    smooth = 0.30 * height + 0.65 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the pit and crust edges the height field lines
    # up with.
    albedo = lib.upscale(src[..., :3])

    normal_strength = 20
    # Held in a band scaled to the surface's real depth: full range
    # domes read as rubble under a grazing lamp on the ramp.
    height = lib.band(height, 0.22)
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
