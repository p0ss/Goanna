"""Hand authored LabPBR height and smoothness for kythen_norse_charcoal_pit,
charcoal lumps in ash, matte, with a few glowing embers.

The 32 px art has seven shades, most of the tile the low, dark charcoal
tones (0.212 to 0.320) in a fragmented dither (253 regions at tolerance
0.06, no single dominant blob), read the way default_gravel.py reads its
own loose, ungraded stones: many small lumps, not a few big ones. The
brightest shade (0.405, 63 texels, 6.2%) is scattered separately and
reads as the only lit material here, embers still glowing among the
charcoal, so it drives lib.pack's emission field rather than any of the
height or smoothness work.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_charcoal_pit"
CLS = "soil"


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

    ember_mask = lum > 0.40
    print(f"ember texels: {int(ember_mask.sum())} ({ember_mask.mean()*100:.1f}%)")

    tolerance = 0.06
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}, sizes {sorted(sizes.tolist(), reverse=True)[:10]}")

    baseline = 0.20
    lo, hi = region_lum.min(), region_lum.max()
    target = 0.10 + 0.55 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=4.0, seed=221, cells=10)
    edges = lib.region_edges(labels_hi)
    max_dist = 2  # charcoal lumps are small and loose, a tight taper for real ao
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    grit = lib.fbm(lib.SIZE, base_cells=36, octaves=3, seed=222, gain=0.55) * 0.05
    ash = lib.blur(lib.white_noise(lib.SIZE, seed=223), 1) * 0.05

    # Sparse, flat floored hollows for real occlusion (kythen_norse_mire.py's
    # own device): the gaps between loose charcoal lumps go deeper than the
    # region taper alone gives them.
    hollow_field = lib.blur(lib.white_noise(lib.SIZE, seed=225), 2)
    hollow_cut = float(np.percentile(hollow_field, 28))
    hollow_mask = hollow_field < hollow_cut
    dist2 = lib.distance_to_edge(hollow_mask.astype(np.float32), max_dist=3)
    t2 = np.clip(dist2 / 3, 0.0, 1.0)
    t2 = t2 * t2 * (3 - 2 * t2)
    hollows = (t2 - 1.0) * 1.3

    height = lib.normalise01(0.35 * layout + grit + ash + hollows, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Charcoal is matte throughout, no shine anywhere; the ash between
    # lumps stays a touch rougher than the lumps themselves.
    variation = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=224, gain=0.55)
    smooth = 0.3 * (height - height.mean()) + 0.7 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])
    ember_hi = lib.blur(lib.upscale(ember_mask.astype(np.float32)[..., None].repeat(3, -1))[..., 0], 1)
    emission = np.clip(ember_hi * 1.4, 0.0, 1.0)

    normal_strength = 4
    height = lib.band(height, 0.36)
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0], emission=emission)
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
