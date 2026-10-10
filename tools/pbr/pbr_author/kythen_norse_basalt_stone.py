"""Hand authored LabPBR height and smoothness for kythen_norse_basalt_stone.

The 32 px art is a mottled dark grey with four shades (0.210 to 0.330,
mean 0.279, sd 0.040), the same shape as default_stone's own reading: no
drawn columns or joints, lib.segments finds no stone sized regions at any
tolerance (0.10 already collapses the whole tile to one region), only a
scatter of small flecks a texel or two across. Basalt is a columnar rock
by name, but this face carries no drawn column boundary to build from, and
the "No Voronoi" rule means inventing one would be a jigsaw nobody laid.
So this is read the way default_stone.py reads its own mottled slab: the
darkest shade is pitting, the lightest is raised mineral grain, the two
middle shades are the untouched matrix between. A first pass built only
the shallow dished pitting default_stone.py itself uses and could not get
ao min under 0.85 (real vesicular basalt is riddled with actual holes, not
just shading): a minority of the vesicles are cut down to a genuine flat
floored pit (kythen_norse_mire.py's own device) to give the packer's ao
pass a real edge to read, without turning the whole face into holes.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_basalt_stone"
CLS = "stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    cls_read = lib.class_of(STEM, GAME)
    print(f"lib.class_of reads: {cls_read}, using {CLS}")

    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:15])

    baseline = 0.5
    pit = region_lum < 0.25
    grain_mask = region_lum > 0.30
    print(f"pit flecks: {int(pit.sum())}, grain flecks: {int(grain_mask.sum())}, "
          f"matrix flecks: {int(n - pit.sum() - grain_mask.sum())}")
    # The 0.228 shade is a quarter of the whole face, not a handful of
    # isolated flecks, so it reads as a connected web of shallow vesicular
    # depressions between the raised grain, not point pits: deep and wide
    # enough for the packer's own ambient occlusion pass to see them.
    target = np.where(pit, 0.14, np.where(grain_mask, 0.82, baseline))

    labels_hi = lib.warp_labels(labels, amp=5.0, seed=41)
    edges = lib.region_edges(labels_hi)
    max_dist = 6  # wide, shallow vesicular dishing, not point pits
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    grain = lib.fbm(lib.SIZE, base_cells=44, octaves=3, seed=42, gain=0.55) * 0.06
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=43), 1) * 0.07

    # A few of the vesicles cut all the way to a real flat floored pit
    # (the device kythen_norse_mire.py and kythen_norse_soapstone.py use)
    # rather than every one being a shallow dish: real vesicular basalt
    # does have the odd hole punched clean through the crust, and it is
    # what finally gives the packer's ao pass something to bite on.
    hollow_field = lib.blur(lib.white_noise(lib.SIZE, seed=45), 2)
    hollow_cut = float(np.percentile(hollow_field, 14))
    hollow_mask = hollow_field < hollow_cut
    dist2 = lib.distance_to_edge(hollow_mask.astype(np.float32), max_dist=3)
    t2 = np.clip(dist2 / 3, 0.0, 1.0)
    t2 = t2 * t2 * (3 - 2 * t2)
    deep_vesicles = (t2 - 1.0) * 1.8

    height = lib.normalise01(0.2 * layout + 0.5 * grain + 0.5 * pores + deep_vesicles, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=44)
    smooth = 0.5 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 15
    height = lib.band(height, 0.40)
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
