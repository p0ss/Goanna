"""Hand authored height and smoothness for kythen_tree_top, the cut end.

Unlike Mineclonia's default_tree_top, this art draws no separate bark band
at the tile edge: the outer one and two texel border reads (0.632, 0.491,
0.319) in mean RGB, the same warm tan as the general sawn face (0.630,
0.489, 0.317), no darker ring there at all. What the art does draw is
three concentric growth rings, one exact darker shade (0.439, 0.329,
0.204, luminance 0.344) against the lighter face, 60 of 256 texels,
arranged with row for row mirror symmetry about the tile's centre: the
signature of rings at fixed radius, not a scatter. There is no drawn bark,
so none is invented here; the relief follows the rings the art actually
has, kept faint, plus a smoothest heartwood centre and no radial cracks
(a real risk of a pinch point this art gives no reason to add).
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_tree_top"
SIZE = lib.SIZE
SEED = 501  # shared with kythen_tree.py, the side of the same log


def smoothstep(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3 - 2 * x)


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")

    edge_mask = np.zeros((16, 16), dtype=bool)
    edge_mask[0, :] = edge_mask[-1, :] = edge_mask[:, 0] = edge_mask[:, -1] = True
    print("edge mean rgb", rgb[edge_mask].mean(0).round(3), "interior mean rgb", rgb[~edge_mask].mean(0).round(3),
          "(near identical: no drawn bark band, unlike Mineclonia's tree_top)")

    is_ring = (lum < 0.40).astype(int)
    print(f"growth ring texels: {is_ring.sum()} / 256")

    # A gentle organic bend, a real growth ring is not a mathematically
    # perfect circle, but not the amount a bark boundary gets: these rings
    # are already regular in the art.
    ring_warp_amp = 4.0
    labels_hi = lib.warp_labels(is_ring, size=SIZE, amp=ring_warp_amp, seed=SEED, cells=10)
    ring_mask = labels_hi == 1
    edges = lib.region_edges(labels_hi)
    ring_max_dist = 4
    dist = lib.distance_to_edge(edges, max_dist=ring_max_dist)
    t = smoothstep(dist / ring_max_dist)
    ring_fade = t * ring_mask
    interior_fade = t * (~ring_mask)

    # Faint: the brief for this stem, and this art gives no reason for a
    # deep groove, only a colour band. A small step, unsharpened into a
    # matched-slope ramp the way the joint scripts build theirs.
    target_ring, target_face = 0.42, 0.54
    step = np.where(labels_hi == 1, target_ring, target_face).astype(np.float32)
    narrow = lib.blur(step, 2)
    wide = lib.blur(step, 4)
    layout = narrow + 0.9 * (narrow - wide)

    # Faint concentric wobble on top of the drawn rings, radius from the
    # block's own centre, so the relief is not perfectly circular either.
    yy, xx = np.indices((SIZE, SIZE)).astype(np.float32)
    cy = cx = (SIZE - 1) / 2.0
    r = np.sqrt((yy - cy) ** 2 + (xx - cx) ** 2)
    wobble = lib.fbm(SIZE, base_cells=6, octaves=2, seed=SEED + 11) * 3.0
    fine_rings = np.sin((r + wobble) * 0.10) * 0.015
    layout = layout + fine_rings * interior_fade

    pores = lib.blur(lib.white_noise(SIZE, seed=SEED + 4), 1) * 0.02
    height = lib.normalise01(layout + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: the face a touch smoother than the rings, with a bonus at
    # the pith so the heartwood is the smoothest point on the map, and a
    # directional field for its own spread.
    directional_rough = lib.fbm(SIZE, base_cells=18, octaves=3, seed=SEED + 5, gain=0.55)
    centre_bonus = np.exp(-(r / (SIZE * 0.12)) ** 2)
    smooth = 0.62 - 0.24 * ring_fade + 0.22 * directional_rough + 0.22 * centre_bonus
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 30.0
    height = lib.band(height, 0.4)
    m = lib.pack(STEM, out_dir, albedo, height, smooth, cls,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, cls)
    for line in lines:
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
