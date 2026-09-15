"""Hand authored height and smoothness for mcl_core_stonebrick_carved.

Unlike mcl_core_stonebrick_cracked.py and mcl_core_stonebrick_mossy.py,
this art carries no joint at all: thresholding it the way
default_stone_brick.py finds its mortar turns up only a scatter of one and
two texel flecks that do not line up into a row or a column at any cut
tried (0.35 to 0.42), nothing like the clean full width lines the other two
variants share. This is one dressed face with a design engraved into it,
not a course of brick.

lib.segments at tolerance 0.06 (looser than default_stone_brick.py's own
mortar cut, because this art shades its design in broad sweeps rather than
brick sized patches) finds nine regions: a large light frame (137 texels),
a large mid tone field (70), and seven small dark shapes, which is the
carving read as regions rather than brick. Each region's own mean shade
becomes its target height, dark recessed and light proud of a flat
mid level face, with a small warp and a narrow taper so the design keeps
crisp edges rather than reading as another set of cobblestones.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_stonebrick_carved"
CLS = "stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")

    tolerance = 0.06
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = [int((labels == i).sum()) for i in range(n)]
    print(f"segments: n={n} tolerance={tolerance} sizes {sorted(sizes, reverse=True)}")

    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    lo, hi = lum.min(), lum.max()
    # Both sides of a flat 0.5 datum: the darkest shapes cut in, the
    # lightest stand proud, matching a chiselled face rather than a set of
    # domes rising from one groove floor.
    region_target = 0.2 + 0.65 * (region_lum - lo) / max(hi - lo, 1e-6)

    # A small warp keeps the design's own silhouette (crisp edges asked
    # for) rather than default_cobble's rounded, organic one; the taper is
    # correspondingly narrow, a bevel rather than a groove.
    labels_hi = lib.warp_labels(labels, amp=0.0, seed=31, cells=14)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    flat = 0.5
    target_map = region_target[labels_hi]
    layout = flat + (target_map - flat) * t

    # Fine tooling marks and pores, the same scale as default_stone_brick.py
    # uses for its own dressed face, so this sits beside the other stone
    # brick variants as the same stone.
    tooling = lib.fbm(lib.SIZE, base_cells=48, octaves=3, seed=23, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=24), 1) * 0.04
    height = lib.normalise01(layout + tooling + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the recessed engraving gathers dust and
    # stays rough, the proud dressed face is what wears smooth.
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=25)
    smooth = 0.55 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 25
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
