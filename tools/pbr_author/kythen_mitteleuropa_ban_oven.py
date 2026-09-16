"""Hand authored LabPBR height and smoothness for kythen_mitteleuropa_ban_oven.

The 32 px art carries four warm clay shades, only four raw RGB triplets in
the whole tile, all a similar warm brown (no black, no orange or red ember
colour anywhere: R minus B never exceeds 0.33 of full scale on any texel,
which is the ordinary warmth of a clay body, not a lit coal). The
brightest shade runs full width every eight rows (0, 8, 16, 24) and, within
each seven texel course, full height every eight columns too (0, 8, 16,
24): a mortar grid in both directions, four courses of four blocks each,
sixteen clay blocks in all. There is no darker recess anywhere in the tile
that reads as a firebox mouth, and no warm ember colour to read an
emission mask from the way default_furnace_front.py finds one in its own
art: this texture is the oven's built clay or brick body, not its mouth, so
no mouth is carved and no emission is set. The blocks read as hand made
clay bricks rather than dressed ashlar, given a little more irregularity
than kythen_mitteleuropa_ashlar's fine dressed joints.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_ban_oven"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def label_blocks(mortar_mask):
    """Connected components of the texels that are not mortar, 4 connected
    and wrapped. Every course here has several full height joint columns,
    so the wrap never merges two blocks into one; no seam cut is needed."""
    h, w = mortar_mask.shape
    labels = np.full((h, w), -1, dtype=int)
    next_id = 0
    for y in range(h):
        for x in range(w):
            if mortar_mask[y, x] or labels[y, x] >= 0:
                continue
            stack = [(y, x)]
            labels[y, x] = next_id
            while stack:
                cy, cx = stack.pop()
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = (cy + dy) % h, (cx + dx) % w
                    if mortar_mask[ny, nx] or labels[ny, nx] >= 0:
                        continue
                    labels[ny, nx] = next_id
                    stack.append((ny, nx))
            next_id += 1
    return labels, next_id


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    # The art tiles, but not at texel (0, 0): the mortar grid sits right on
    # rows and columns 0, so the seam metric's single wrap comparison lands
    # exactly on a joint's own steepest point rather than an ordinary block
    # interior, the same false alarm default_cobble.py's docstring
    # describes. Rolling by half a block moves the wrap into a block's own
    # body instead; the surface is the same closed loop either way.
    src = np.roll(src, (4, 4), axis=(0, 1))
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    r_minus_b = (src[..., 0] - src[..., 2])
    print(f"R minus B max {float(r_minus_b.max()):.3f} (ordinary clay warmth, no ember found)")
    print(f"lib.class_of reads: {CLS}")

    mortar_mask = lum >= 0.55
    print(f"mortar texels: {int(mortar_mask.sum())} of {lum.size}")

    labels, n_blocks = label_blocks(mortar_mask)
    sizes = [int((labels == i).sum()) for i in range(n_blocks)]
    print(f"blocks found: {n_blocks}, sizes {sizes}")

    block_lum = np.array([lum[labels == i].mean() for i in range(n_blocks)])
    lo, hi = lum[~mortar_mask].min(), lum[~mortar_mask].max()
    block_target = 0.55 + 0.30 * (block_lum - lo) / max(hi - lo, 1e-6)
    target_dict = {-1: 0.08}
    for i in range(n_blocks):
        target_dict[i] = float(block_target[i])

    # A little warp, more than the dressed ashlar stem but far less than
    # the rubble core: hand made clay blocks, not fitted rubble.
    labels_hi = lib.warp_labels(labels, amp=2.0, seed=941, cells=14)
    edges = lib.region_edges(labels_hi)
    max_dist = 2
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    wobble = lib.fbm(SIZE, base_cells=34, octaves=2, seed=942) * 0.9
    dist = np.clip(dist + wobble, 0.0, max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for lbl, val in target_dict.items():
        target_map[labels_hi == lbl] = val
    layout = target_map * t

    crown = lib.fbm(SIZE, base_cells=8, octaves=2, seed=943) * 0.08
    layout = layout + crown * t
    tooling = lib.fbm(SIZE, base_cells=44, octaves=3, seed=944, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=945), 1) * 0.05

    height = lib.normalise01(layout + tooling + pores, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=946)
    smooth = 0.5 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 26.0
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
