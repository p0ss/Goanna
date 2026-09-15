"""Hand authored LabPBR height and smoothness for mcl_books_bookshelf_top.

Eight brown shades, the same dozen-shade plank palette default_bookshelf's
own frame uses (both stems are the same block, this is the plank seen from
above). Row means dip sharply and consistently every fourth row, 3, 7, 11
and 15 (0.235 to 0.281 against 0.31 to 0.41 either side), wrapping cleanly
since row 15 is a joint and row 0 goes straight back to board colour. Four
equal boards, three rows each, the same plank material as the frame below.
"""
import sys

import numpy as np

import lib

STEM = "mcl_books_bookshelf_top"
CLS = "wood"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("row means:", np.round(lum.mean(axis=1), 3).tolist())

    joint_rows = [3, 7, 11, 15]
    row_is_joint = np.zeros(16, dtype=bool)
    row_is_joint[joint_rows] = True
    board_id = np.zeros(16, dtype=int)
    cur = 0
    for y in range(16):
        board_id[y] = cur
        if row_is_joint[y]:
            cur += 1
    board_id[row_is_joint] = -1  # joints get their own flat low target
    print("board rows:", board_id.tolist())

    board_lum = {}
    for b in sorted(set(board_id[board_id >= 0].tolist())):
        board_lum[b] = lum[board_id == b].mean()
    lo, hi = min(board_lum.values()), max(board_lum.values())
    board_target = {b: 0.60 + 0.22 * (m - lo) / max(hi - lo, 1e-6) for b, m in board_lum.items()}
    board_target[-1] = 0.10
    # sorted(board_target) puts -1 first; remap board_id to that same order
    # so indexing target by labels16 lines up.
    order = sorted(board_target)
    remap = {b: i for i, b in enumerate(order)}
    row_label = np.array([remap[b] for b in board_id])
    labels16 = np.broadcast_to(row_label[:, None], (16, 16)).copy()
    target = np.array([board_target[b] for b in order])

    labels_hi = np.repeat(np.repeat(labels16, 16, axis=0), 16, axis=1)
    edges = lib.region_edges(labels_hi)
    max_dist = 4
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 0.9 * (narrow - wide)

    # A slow, wide crown, same seed as default_bookshelf's frame grain
    # family so the block reads as one plank material front and top.
    crown = lib.fbm(SIZE, base_cells=3, octaves=2, seed=54) * 0.24
    layout = layout + crown * t

    def blur_axis(field, radius, axis):
        if radius <= 0:
            return field
        k = 2 * radius + 1
        acc = np.zeros_like(field)
        for d in range(-radius, radius + 1):
            acc += np.roll(field, d, axis=axis)
        return acc / k

    grain_src = lib.fbm(SIZE, base_cells=24, octaves=3, seed=51, gain=0.55)
    grain = blur_axis(grain_src, radius=14, axis=1) * 0.24
    pores = blur_axis(lib.blur(lib.white_noise(SIZE, seed=52), 1), radius=4, axis=1) * 0.035

    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = blur_axis(lib.fbm(SIZE, base_cells=20, octaves=3, seed=55, gain=0.55), radius=10, axis=1)
    smooth = 0.5 * t + 0.5 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 26.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength)
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
