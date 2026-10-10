"""Hand authored height and smoothness for kythen_moana_piled_lagoon_rock.

The 32 px art has only three shades, 0.516 to 0.622, sd 0.037, and no clean
gap splitting a shadow group from a lit one. lib.segments (tolerance 0.05)
finds 74 regions with a graduated spread of sizes (209, 158, 123, 103, 88,
45...), the same shape of result kythen_habesha_basalt_country.py finds in
its own rock face: a few sizeable, irregularly shaped rounded rocks rather
than a graded pebble bed. class_of reads stone, matching the brief's dry
stack of rounded rocks, no mortar, deep gaps between them, so this is built
the basalt_country way, each rock's own target height off its own
brightness with a low frequency crown for the biggest rocks, but with a
tighter crack taper and a real deep pocket added so the gaps between rocks
stay genuinely deep rather than basalt_country's own gentler fracture line.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_piled_lagoon_rock"
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

    baseline = 0.06
    lo, hi = region_lum.min(), region_lum.max()
    target = 0.55 + 0.40 * (region_lum - lo) / max(hi - lo, 1e-6)

    # A wider warp than basalt_country's own: piled rock is craggier and
    # more irregular than a broken slab face.
    labels_hi = lib.warp_labels(labels, amp=7.0, seed=951)
    edges = lib.region_edges(labels_hi)
    max_dist = 3  # a deep gap between piled rocks, steep enough to keep ao low
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    wobble = lib.fbm(SIZE, base_cells=26, octaves=2, seed=952) * 0.8
    dist = np.clip(dist + wobble, 0.0, max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    # A low frequency crown per rock so the biggest regions round off
    # rather than sitting as flat plateaus once the edge taper saturates.
    crown = lib.fbm(SIZE, base_cells=6, octaves=2, seed=953) * 0.14
    layout = layout + crown * t

    knobbles = lib.fbm(SIZE, base_cells=18, octaves=3, seed=954, gain=0.55) * 0.10
    pores = lib.blur(lib.white_noise(SIZE, seed=955), 1) * 0.05
    # A real deep pocket in the pile, not the crack network's own even
    # depth: where a gap between rocks opens right down.
    pocket_field = lib.blur(lib.white_noise(SIZE, seed=956), 1)
    pocket_cut = float(np.percentile(pocket_field, 2.0))
    deep_pocket = np.where(pocket_field < pocket_cut, (pocket_field - pocket_cut) * 9.0, 0.0)

    height = lib.normalise01(layout + knobbles + pores + deep_pocket, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=957)
    smooth = 0.5 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 18.0
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
