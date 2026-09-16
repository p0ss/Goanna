"""Hand authored LabPBR height and smoothness for kythen_norse_moraine_subsoil,
gravelly clay left behind by retreating ice.

The 32 px art has five shades. The mid shade (0.517, 385 texels) is one
broad connected matrix, the clay itself; a darker shade (0.475, 107 plus
smaller clumps) sits in patches within it, and a brighter shade (0.582,
scattered clumps up to 43 texels) pokes through here and there. Read as
gravelly clay: the bright clumps are small stones sitting proud of the
clay, the dark patches are damp low spots in the clay between them.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_moraine_subsoil"
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

    pebble_mask = lum > 0.55
    print(f"pebble texels: {int(pebble_mask.sum())} ({pebble_mask.mean()*100:.1f}%)")
    damp_mask = lum < 0.49
    print(f"damp texels: {int(damp_mask.sum())} ({damp_mask.mean()*100:.1f}%)")

    labels, n_pebbles = label_regions(pebble_mask)
    print(f"pebbles found: {n_pebbles - 1}")

    labels_hi = lib.warp_labels(labels, amp=3.0, seed=161, cells=8)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    pebble_bump = np.where(labels_hi > 0, t, 0.0) * 0.20

    # Sparse, flat floored hollows for real occlusion in the damp low
    # spots (the same device kythen_norse_mire.py uses).
    hollow_field = lib.blur(lib.white_noise(lib.SIZE, seed=162), 2)
    hollow_cut = float(np.percentile(hollow_field, 26))
    hollow_mask = hollow_field < hollow_cut
    dist2 = lib.distance_to_edge(hollow_mask.astype(np.float32), max_dist=3)
    t2 = np.clip(dist2 / 3, 0.0, 1.0)
    t2 = t2 * t2 * (3 - 2 * t2)
    hollows = (t2 - 1.0) * 1.1

    grit = lib.fbm(lib.SIZE, base_cells=26, octaves=3, seed=163, gain=0.55) * 0.06
    height = lib.normalise01(pebble_bump + hollows + grit, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=164, gain=0.55)
    smooth = 0.4 * (height - height.mean()) + 0.6 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 5
    height = lib.band(height, 0.36)
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
