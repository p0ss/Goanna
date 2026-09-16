"""Hand authored LabPBR height and smoothness for kythen_habesha_aksumite_ashlar.

The 32 px art carries five grey shades. The darkest, 0.396, appears nowhere
except four full width rows: 0, 8, 16, 24, a clean running bond of four
courses, each seven texels of dressed stone plus one texel of mortar. Each
course also has exactly two full height mortar columns, 16 texels apart,
staggered by four texels from the course above (0 and 16, then 12 and 28,
then 8 and 24, then 4 and 20), so every course already carries two joints
and flood fill on the non mortar texels separates the two blocks in every
course cleanly, with none of default_stone_brick's single joint wrap
problem. This is dressed ashlar: flat faces, fine continuous joints, no
domed rubble.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_aksumite_ashlar"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def label_blocks(mortar_mask):
    """Connected components of the texels that are not mortar, 4 connected
    and wrapped. Every course here has two full height joint columns, so
    the wrap never merges two blocks into one the way default_stone_brick's
    single joint course does; no seam cut is needed."""
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
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print(f"lib.class_of reads: {CLS}")

    mortar_mask = lum <= 0.40
    print(f"mortar texels: {int(mortar_mask.sum())} of {lum.size}")

    labels, n_blocks = label_blocks(mortar_mask)
    sizes = [int((labels == i).sum()) for i in range(n_blocks)]
    print(f"blocks found: {n_blocks}, sizes {sizes}")

    # Target height per block, off its own mean brightness, the way a
    # lighter dressed face catches more light: the normalising range comes
    # from the whole face, not the handful of block means found, so a
    # whisker of difference between two similar blocks never invents a step
    # the art never drew.
    block_lum = np.array([lum[labels == i].mean() for i in range(n_blocks)])
    lo, hi = lum[~mortar_mask].min(), lum[~mortar_mask].max()
    block_target = 0.55 + 0.35 * (block_lum - lo) / max(hi - lo, 1e-6)
    target_dict = {-1: 0.08}
    for i in range(n_blocks):
        target_dict[i] = float(block_target[i])

    # Exact joint geometry from the mask, nearest upscaled so a joint meets
    # the mortar rows above and below by construction.
    up = SIZE // lum.shape[0]
    mortar_hi = np.repeat(np.repeat(mortar_mask, up, axis=0), up, axis=1)
    labels_hi = np.repeat(np.repeat(labels, up, axis=0), up, axis=1)

    max_dist = 3  # groove half width in 256 map texels, a real dressed joint
    dist = lib.distance_to_edge(mortar_hi.astype(np.float32), max_dist=max_dist)
    # Fine wobble on the groove's own edge, not on which side of it a texel
    # is: a joint dressed by hand can widen or narrow a touch, but a mortar
    # texel stays a mortar texel, so it can never pinch shut.
    wobble = lib.fbm(SIZE, base_cells=32, octaves=2, seed=61) * 0.8
    dist = np.where(mortar_hi, 0.0, np.clip(dist + wobble, 0.0, max_dist))
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: broad flat block tops, sharp fall to the joint

    target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for lbl, val in target_dict.items():
        target_map[labels_hi == lbl] = val
    layout = target_map * t

    # A very slight convex crown on each block, and fine dressing marks and
    # pores on top: flat where the art is flat, no domed rubble.
    crown = lib.fbm(SIZE, base_cells=5, octaves=2, seed=62) * 0.04
    layout = layout + crown * t
    tooling = lib.fbm(SIZE, base_cells=52, octaves=3, seed=63, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=64), 1) * 0.04
    # One genuinely deep pore, the odd chip a dressed block gets over the
    # years: a real narrow pit rather than the joint's broad even groove.
    pit_field = lib.blur(lib.white_noise(SIZE, seed=65), 1)
    pit_cut = float(np.percentile(pit_field, 0.3))
    deep_pit = np.where(pit_field < pit_cut, (pit_field - pit_cut) * 10.0, 0.0)

    height = lib.normalise01(layout + tooling + pores + deep_pit, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    # Smoothness follows height: the joint gathers dust and stays rough,
    # the dressed faces are what wears smooth, with the stone's own patchy
    # variation on top.
    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=66)
    smooth = 0.55 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 32.0
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
