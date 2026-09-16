"""Hand authored LabPBR height and smoothness for kythen_norse_slag_heap,
a heap of glassy furnace slag lumps with smooth facets.

The 32 px art has seven shades falling into three near equal groups: dark
(0.198 to 0.228, 37.1%), mid (0.268 to 0.286, 30.6%) and light (0.330 to
0.337, 32.2%). lib.segments at tolerance 0.06 finds one big connected mid
tone region (661 texels) plus a great many smaller flecks and clumps, up
to 127 texels, of the darker and lighter shades. Read as slag: the dark
clumps are shadowed valleys between lumps, the light clumps are the
lumps' own glassy facets catching the light, angular rather than rounded,
so the warp amplitude here is lower than a rounded cobble would get.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_slag_heap"
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

    tolerance = 0.06
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:15])

    baseline = 0.5
    valley = region_lum < 0.25
    facet = region_lum > 0.30
    print(f"valley flecks: {int(valley.sum())}, facet flecks: {int(facet.sum())}, "
          f"mid flecks: {int(n - valley.sum() - facet.sum())}")
    target = np.where(valley, 0.15, np.where(facet, 0.85, baseline))

    # Lower amplitude than a rounded cobble: slag facets are flat planed
    # surfaces, not water rounded stones.
    labels_hi = lib.warp_labels(labels, amp=3.0, seed=101, cells=10)
    edges = lib.region_edges(labels_hi)
    max_dist = 3  # a narrow taper keeps facet edges reading as angular breaks
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    # Sparse, deep hollows, the same device kythen_firecountry_reed_peat.py
    # and kythen_norse_bog_ore.py use to get real ambient occlusion.
    hollow_field = lib.blur(lib.white_noise(lib.SIZE, seed=102), 2)
    hollow_cut = float(np.percentile(hollow_field, 30))
    hollows = np.where(hollow_field < hollow_cut, hollow_field - hollow_cut, 0.0) * 8.0

    grit = lib.fbm(lib.SIZE, base_cells=40, octaves=3, seed=103, gain=0.55) * 0.05
    height = lib.normalise01(layout + hollows + grit, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height, but weighted hard towards the facets: a
    # glassy fracture face is far smoother than the valley grit around it,
    # more contrast than an ordinary stone's worn/dust split.
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=104)
    smooth = 0.65 * height + 0.4 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 12
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
