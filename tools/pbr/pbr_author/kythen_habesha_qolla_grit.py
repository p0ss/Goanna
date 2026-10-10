"""Hand authored LabPBR height and smoothness for kythen_habesha_qolla_grit.

The 32 px art is ten close grey shades, luminance 0.213 to 0.580, spread
0.082. At the tolerance segments.py needs to find real cobble or brick
regions (0.05 and up) the low and mid shades chain transitively through
one another into a single 455 texel blob, an artefact of the shades being
close together rather than a drawn background. At a tight tolerance
(0.03) that chaining stops: 377 regions come back, median size one texel,
the largest just 81. That is the honest read of this art: it is already
drawn at grain scale, texel by texel, brighter texels standing for grain
tops catching the light and darker texels for the shadowed gaps between
them, with no single continuous background the way default_stone_brick's
mortar sits in one. So the grain regions are taken at the tight tolerance
and each is kept small by a tight max_dist on its own taper, rather than
by doming a whole chained blob as one shape.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_qolla_grit"
CLS = "soil"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    print(f"lib.class_of reads: {lib.class_of(STEM, GAME)}")

    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments tol={tolerance}: n={n}, median size {np.median(sizes):.1f}, "
          f"sizes(top12) {sorted(sizes.tolist(), reverse=True)[:12]}")

    # Continuous target height from each region's own mean brightness: no
    # binary gap/dome split, because the art itself has no clean two tone
    # split, just a spread of ten close shades. Darkest texels (the small
    # shadow specks between grains) sink lowest, the brightest grain tops
    # rise highest, everything else scales in between.
    lo, hi = lum.min(), lum.max()
    target = 0.15 + 0.75 * (region_lum - lo) / max(hi - lo, 1e-6)
    print(f"region target height: min {target.min():.3f} max {target.max():.3f}")

    labels_hi = lib.warp_labels(labels, amp=4.0, seed=51, cells=16)
    edges = lib.region_edges(labels_hi)
    max_dist = 3  # tight: grains are one to a few art texels across (24 map
                  # texels at most), a tight taper keeps each patch its own
                  # small dome instead of one region reading as one big lump
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: small domed grain tops, shared gap floor at the seams

    baseline = 0.14  # shared floor along every grain boundary, the packed dust between grains
    layout = baseline + (target[labels_hi] - baseline) * t

    # Grain scale structure below the region shapes: a scatter of small
    # bumps and pits so a big fused patch of grain-top texels still reads
    # as many individual grains, not one smooth undulation. This is real
    # relief, not the fine detail the packer already damps, so it carries
    # a healthy amplitude of its own.
    grain = lib.fbm(lib.SIZE, base_cells=48, octaves=3, seed=52, gain=0.55) * 0.12
    grit_pits = lib.blur(lib.white_noise(lib.SIZE, seed=53), 1) * 0.10
    height = lib.normalise01(layout + grain + grit_pits, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness carries most of the grit's own character: loose, granular,
    # ungraded material has a wide spread of polish from texel to texel far
    # beyond what the height alone would give. It still follows height (a
    # grain top wears smoother than the dust in the gap) with the surface's
    # own coarse variation on top.
    rough_noise = lib.fbm(lib.SIZE, base_cells=26, octaves=3, seed=54, gain=0.6)
    fine_rough = lib.blur(lib.white_noise(lib.SIZE, seed=55), 1)
    smooth = 0.35 * height + 0.45 * rough_noise + 0.35 * fine_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 5
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
