"""Hand authored LabPBR height and smoothness for kythen_mitteleuropa_stone_flag.

The 32 px art carries five grey shades. The brightest, 0.786, appears
nowhere except two full width rows, 0 and 16: two courses of sixteen
texels each. Within the top course (rows 1 to 15) the same shade also runs
full height down columns 0 and 16, splitting it into two flags, columns 1
to 15 and 17 to 31. Within the bottom course (rows 17 to 31) the full
height joints sit at columns 8 and 24 instead, offset by eight texels from
the course above, the running bond stagger a real flagged floor is laid
with. Four large flags in all, each about fifteen texels square: big flat
flagstones with thin joints between them, not small dressed ashlar blocks.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_stone_flag"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def label_blocks(mortar_mask):
    """Connected components of the texels that are not mortar, 4 connected
    and wrapped. Every course here has two full height joint columns, so
    the wrap never merges two flags into one; no seam cut is needed."""
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

    mortar_mask = lum >= 0.7
    print(f"mortar texels: {int(mortar_mask.sum())} of {lum.size}")

    labels, n_blocks = label_blocks(mortar_mask)
    sizes = [int((labels == i).sum()) for i in range(n_blocks)]
    print(f"flags found: {n_blocks}, sizes {sizes}")

    # Target height per flag off its own mean brightness, normalised across
    # the whole face so a whisker of difference between two similar flags
    # never invents a step the art never drew.
    flag_lum = np.array([lum[labels == i].mean() for i in range(n_blocks)])
    lo, hi = lum[~mortar_mask].min(), lum[~mortar_mask].max()
    flag_target = 0.55 + 0.35 * (flag_lum - lo) / max(hi - lo, 1e-6)
    target_dict = {-1: 0.08}
    for i in range(n_blocks):
        target_dict[i] = float(flag_target[i])

    up = SIZE // lum.shape[0]
    mortar_hi = np.repeat(np.repeat(mortar_mask, up, axis=0), up, axis=1)
    labels_hi = np.repeat(np.repeat(labels, up, axis=0), up, axis=1)

    max_dist = 4  # thin joint, a few map texels either side
    dist = lib.distance_to_edge(mortar_hi.astype(np.float32), max_dist=max_dist)
    wobble = lib.fbm(SIZE, base_cells=28, octaves=2, seed=831) * 1.0
    dist = np.where(mortar_hi, 0.0, np.clip(dist + wobble, 0.0, max_dist))
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for lbl, val in target_dict.items():
        target_map[labels_hi == lbl] = val
    layout = target_map * t

    # A flag this big (fifteen art texels, most of the tile) saturates the
    # taper's own bevel and leaves a dead flat crown in the middle; a wide,
    # low bulge rounds that off the way a real flagstone crowns.
    crown = lib.fbm(SIZE, base_cells=4, octaves=2, seed=832) * 0.06
    layout = layout + crown * t

    tooling = lib.fbm(SIZE, base_cells=44, octaves=3, seed=833, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=834), 1) * 0.04
    pit_field = lib.blur(lib.white_noise(SIZE, seed=835), 1)
    pit_cut = float(np.percentile(pit_field, 0.4))
    deep_pit = np.where(pit_field < pit_cut, (pit_field - pit_cut) * 9.0, 0.0)

    height = lib.normalise01(layout + tooling + pores + deep_pit, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    rough_noise = lib.fbm(SIZE, base_cells=18, octaves=3, seed=836)
    smooth = 0.55 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 42.0
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
