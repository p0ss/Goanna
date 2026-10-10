"""Hand authored LabPBR height and smoothness for kythen_norse_grave_mound,
turf grown over a mound of stones.

The 32 px art has five shades. At tolerance 0.06, lib.segments finds one
big dark region (0.252, 563 texels, 55%), two large brighter regions
(0.347 to 0.349, 223 and 155 texels together over a third of the tile)
and a handful of small flecks (2 to 28 texels). Read as a grass mound: the
two big bright regions are the turfed mound itself, raised and catching
the light broadly, the dark region is the ground around its base, and the
small flecks are stones just breaking through the turf here and there.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_grave_mound"
CLS = "soil"


def label_regions(mask):
    h, w = mask.shape
    labels = np.zeros((h, w), dtype=int)
    next_id = 1
    for y in range(h):
        for x in range(w):
            if not mask[y, x] or labels[y, x] != 0:
                continue
            stack = [(y, x)]
            labels[y, x] = next_id
            while stack:
                cy, cx = stack.pop()
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = (cy + dy) % h, (cx + dx) % w
                    if not mask[ny, nx] or labels[ny, nx] != 0:
                        continue
                    labels[ny, nx] = next_id
                    stack.append((ny, nx))
            next_id += 1
    return labels, next_id


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

    labels, n = lib.segments(rgb, tolerance=0.06)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n}, sizes {sorted(sizes.tolist(), reverse=True)[:10]}")

    mound_mask = (region_lum[labels] > 0.30) & (sizes[labels] > 40)
    stone_mask = (region_lum[labels] > 0.30) & (sizes[labels] <= 40)
    print(f"mound texels: {int(mound_mask.sum())}, stone fleck texels: {int(stone_mask.sum())}")

    # A broad, soft rise for the turfed mound: warped so its own edge is
    # irregular, the way turf grows unevenly over an old cairn.
    mound_hi = lib.upscale(mound_mask.astype(np.float32)[..., None].repeat(3, -1))[..., 0]
    mound_hi = lib.blur(mound_hi, 4)

    # The stones are small proud bumps breaking through the turf.
    stone_hi = lib.upscale(stone_mask.astype(np.float32)[..., None].repeat(3, -1))[..., 0] > 0.5
    dist = lib.distance_to_edge((~stone_hi).astype(np.float32), max_dist=3)
    t = np.clip(dist / 3, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    stone_bump = t * 0.45

    hollow_field = lib.blur(lib.white_noise(lib.SIZE, seed=211), 2)
    hollow_cut = float(np.percentile(hollow_field, 26))
    hollow_mask = hollow_field < hollow_cut
    dist2 = lib.distance_to_edge(hollow_mask.astype(np.float32), max_dist=3)
    t2 = np.clip(dist2 / 3, 0.0, 1.0)
    t2 = t2 * t2 * (3 - 2 * t2)
    hollows = (t2 - 1.0) * 1.1

    grass = lib.fbm(lib.SIZE, base_cells=16, octaves=3, seed=212, gain=0.55) * 0.10
    height = lib.normalise01(0.5 * mound_hi + stone_bump + hollows + grass, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=213, gain=0.55)
    smooth = 0.4 * (height - height.mean()) + 0.6 * variation
    smooth = np.where(stone_hi, smooth - 0.10, smooth)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 5
    height = lib.band(height, 0.42)
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
