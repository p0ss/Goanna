"""Hand authored LabPBR height and smoothness for kythen_siku_gneiss.

The 32 px art (cultures/siku/materials.json: "bark", base rock_grey, accent
gneiss_pink, wander 4.5, fissure 5) is three flat shades: 700 texels of the
grey matrix, 267 of a middle blend, 57 of the bright pink accent, the
recipe's own note explaining why "bark" (blocktex.py's meandering band
field) was used rather than "planks": "a plank's edge is hard and its
width is constant, and a gneiss band's is neither". wander 4.5 is the
highest of any bark recipe in this batch (driftwood 1.2, whale_bone 1.6,
sinew 1.6), so the pink band is read the same way kythen_stone.py reads
its own flecks, segments warped harder than usual, a profile across the
face that wanders rather than a straight ridge.

lib.class_of reads "gravel" here (a level heuristic coincidence: this
stem's packed smoothness happened to land nearest gravel's own bucket),
overridden to "stone": gneiss is solid banded rock, not sorted pebbles.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_siku_gneiss"
CLS = "stone"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print("lib.class_of reads:", lib.class_of(STEM, GAME), "- overridden to stone, see module docstring")

    tolerance = 0.01
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:10])

    baseline = 0.42
    lo, hi = region_lum.min(), region_lum.max()
    band_mask = region_lum > (lo + 0.55 * (hi - lo))
    print(f"band flecks: {int(band_mask.sum())} of {n}, {int(sizes[band_mask].sum())} texels")
    target = np.where(band_mask, 0.85, baseline)

    # wander 4.5, the highest amplitude warp in this batch: the pink band
    # meanders hard rather than tracking the texel grid at all closely.
    labels_hi = lib.warp_labels(labels, size=SIZE, amp=10.0, seed=171, cells=6)
    edges = lib.region_edges(labels_hi)
    max_dist = 3  # narrow, steep taper: kythen_siku_dry_stone.py's own finding, ao_from_height
    # only occludes within its own radius and a wide taper spreads the rise too thin to read.
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    grain = lib.fbm(SIZE, base_cells=36, octaves=3, seed=172, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=173), 1) * 0.05
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    height = lib.band(height, 0.38)
    print(f"height sd {height.std():.4f}")

    # Smoothness follows the band the way kythen_stone.py's own grain
    # does: the pink crystal seam a touch smoother than the grey matrix,
    # with the recipe's own patchy variation on top.
    variation = lib.fbm(SIZE, base_cells=22, octaves=3, seed=174, gain=0.55)
    smooth = 0.45 * t + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 52.0
    fine_detail = 1.0  # kythen_siku_dry_stone.py's own finding: the band taper is only a
    # few texels wide, exactly the scale pack()'s default 0.35 damping exists to flatten.
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, fine_detail=fine_detail, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}, fine_detail={fine_detail}")
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
