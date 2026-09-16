"""Hand authored LabPBR height and smoothness for kythen_habesha_basalt_country.

The 32 px art is dark and low contrast, luminance 0.217 to 0.315, standard
deviation only 0.049, with next to no colour (mean saturation 0.033): a
near black volcanic rock. lib.segments (tolerance 0.05) still finds real
structure in it: 31 regions, four broad ones covering most of the tile (480,
193, 121 and 83 texels) and a scatter of small fragments. That reads as
basalt country actually does, not a scree of loose pebbles: a few big slabs
of solid rock separated by real fracture lines, each slab's own surface
pitted and knobbly from the gas bubbles frozen into basalt as it cooled,
rather than the many small independent stones default_gravel.py builds.
lib.class_of reads "gravel", which the packed bake also gives basalt
country's smoothness level, so the tilt target and jointed ao rule both
follow gravel even though this is a rock face, not a heap of stones.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_basalt_country"
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

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}, sizes {sorted(sizes.tolist(), reverse=True)[:10]}")

    # Target height per slab off its own brightness: the darker slabs sit
    # deeper in shadow between the fracture ridges, the lighter ones catch
    # more of the light on their broken faces.
    baseline = 0.10
    lo, hi = region_lum.min(), region_lum.max()
    target = 0.55 + 0.40 * (region_lum - lo) / max(hi - lo, 1e-6)

    # Real fracture lines, not a dressed joint: warp the slab edges into
    # the jagged silhouette a rock actually breaks along.
    labels_hi = lib.warp_labels(labels, amp=6.0, seed=91)
    edges = lib.region_edges(labels_hi)
    max_dist = 4  # a real crack, narrow relative to the big slabs it separates
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    wobble = lib.fbm(SIZE, base_cells=30, octaves=2, seed=92) * 1.0
    dist = np.clip(dist + wobble, 0.0, max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    # Basalt's own vesicular texture: broad, low, knobbly undulation across
    # each slab, isotropic since the gas bubbles have no preferred axis.
    knobbles = lib.fbm(SIZE, base_cells=16, octaves=3, seed=93, gain=0.55) * 0.30

    # Below the texel: fine pore and grit texture, and one real deep
    # fracture pocket, the odd place a slab has broken away cleanly rather
    # than the crack network's ordinary even depth.
    grit = lib.fbm(SIZE, base_cells=40, octaves=3, seed=94, gain=0.55) * 0.07
    pores = lib.blur(lib.white_noise(SIZE, seed=95), 1) * 0.05
    pit_field = lib.blur(lib.white_noise(SIZE, seed=96), 1)
    pit_cut = float(np.percentile(pit_field, 0.3))
    deep_pit = np.where(pit_field < pit_cut, (pit_field - pit_cut) * 10.0, 0.0)

    height = lib.normalise01(layout + knobbles + grit + pores + deep_pit, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    # Smoothness follows height: the cracks gather dust and stay rough, the
    # broken slab faces are what a boot polishes, with basalt's own patchy
    # weathering variation on top.
    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=97)
    smooth = 0.5 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 24.0
    height = lib.band(height, 0.35)
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
