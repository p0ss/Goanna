"""Hand authored height and smoothness for kythen_moana_coral_country.

The 32 px art has nine shades, sd 0.088, with two dominant middle tones
(0.622 and 0.725, 65 percent of the tile combined) flanked by a darker
fringe (0.516, 0.59, 0.702, ten percent) and a lighter fringe (0.791 up to
0.88, 26 percent). lib.segments (tolerance 0.03) finds 328 regions with no
dominant background, sizes graded from 17 to 51 texels: a porous rock face
of many small pits and knobs on one continuous matrix, the same reading
default_stone.py gives Mineclonia's own mottled stone. Built the same way:
only the darkest fringe is cut down as real pits, only the lightest fringe
is raised as real knobs, the two middle tones stay the untouched matrix,
held in a band since the brief calls this face nearly flat overall.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_coral_country"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print(f"lib.class_of reads: {CLS}")

    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:15])

    baseline = 0.5
    pit = region_lum < 0.60
    knob = region_lum > 0.75
    print(f"pit regions: {int(pit.sum())}, knob regions: {int(knob.sum())}, "
          f"matrix regions: {int(n - pit.sum() - knob.sum())}")
    plo, phi = region_lum[pit].min(), region_lum[pit].max()
    klo, khi = region_lum[knob].min(), region_lum[knob].max()
    target = np.where(pit, 0.30 - 0.10 * (region_lum - plo) / max(phi - plo, 1e-6),
            np.where(knob, 0.62 + 0.16 * (region_lum - klo) / max(khi - klo, 1e-6), baseline))

    labels_hi = lib.warp_labels(labels, amp=4.0, seed=821)
    edges = lib.region_edges(labels_hi)
    max_dist = 4  # soft pits and knobs, not outlined pieces
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    # Sub texel structure: fine coral pore grain, denser than default_stone's
    # own coarser crystal grain, since a coral surface is finely porous
    # throughout, not just at the drawn pits.
    grain = lib.fbm(SIZE, base_cells=50, octaves=3, seed=822, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=823), 1) * 0.06
    # A scatter of real, steep walled pore holes on top of the drawn
    # layout: the horizon based ambient occlusion needs a wall rising
    # within a texel or two, and the drawn pit fringe alone was too shallow
    # once the band pulled it back toward the flat matrix.
    pit_field = lib.blur(lib.white_noise(SIZE, seed=825), 1)
    pit_cut = float(np.percentile(pit_field, 8.0))
    deep_pores = np.where(pit_field < pit_cut, (pit_field - pit_cut) * 3.0, 0.0)
    height = lib.normalise01(layout + grain + pores + deep_pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=824)
    smooth = 0.5 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 32
    # Held in a band scaled to the surface's real depth: nearly flat
    # overall, full range domes read as rubble under a grazing lamp.
    height = lib.band(height, 0.48)
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
