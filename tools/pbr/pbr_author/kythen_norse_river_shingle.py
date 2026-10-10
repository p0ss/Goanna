"""Hand authored LabPBR height and smoothness for kythen_norse_river_shingle,
rounded pebbles from a riverbed.

The 32 px art has five shades: one broad connected matrix (0.517, 554
texels, over half the tile) and a scatter of darker clumps (0.472 to
0.478, up to 65 texels) and a few brighter clumps (0.582, up to 29
texels). Read the way default_gravel.py reads its own art: the darker
clumps are the shadowed gaps between pebbles, the matrix and the bright
clumps together are the pebbles themselves, rounded and sitting close
together the way river worn stone does, the bright clumps taller where
they catch more light.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_river_shingle"
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

    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:15])

    baseline = 0.15
    gap = region_lum <= 0.49
    dome = ~gap
    print(f"gap regions: {int(gap.sum())} of {n}, {int(sizes[gap].sum())} texels; "
          f"dome regions: {int(dome.sum())}, {int(sizes[dome].sum())} texels")
    dlo, dhi = region_lum[dome].min(), region_lum[dome].max()
    target = np.where(gap, 0.08, 0.55 + 0.40 * (region_lum - dlo) / max(dhi - dlo, 1e-6))

    labels_hi = lib.warp_labels(labels, amp=5.0, seed=171, cells=10)
    edges = lib.region_edges(labels_hi)
    max_dist = 1  # a narrow taper gives each pebble's rim a real edge for the ao pass to read
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    grit = lib.fbm(lib.SIZE, base_cells=40, octaves=3, seed=172, gain=0.55) * 0.07
    silt = lib.blur(lib.white_noise(lib.SIZE, seed=173), 1) * 0.06
    height = lib.normalise01(layout + grit + silt, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=174)
    smooth = 0.5 * height + 0.5 * rough_noise
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
