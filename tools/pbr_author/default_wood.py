"""Hand authored height and smoothness for default_wood.

The 16 px art carries eight grey shades in two clusters: 0.212, 0.252,
0.286, 0.309 sit close together and 0.355, 0.391, 0.434, 0.458 sit close
together, with the widest gap in the whole shade ladder, 0.046, between the
two clusters. Rows 3, 7, 11 and 15 use only the dark cluster; every other
row mixes in the light cluster too. That is an even period of four, which
is the classic layout for this texture: four equal boards, three texels
tall each, with a one texel joint between them (rows 4 to 6, 8 to 10, 12 to
14 and, wrapping, 0 to 2). Row 8 happens to be a single flat shade (0.309,
the dark cluster's own top shade) but it sits inside board C, not on a
joint period, and every other row in that board carries the usual two
cluster mix, so it reads as a clean patch of grain rather than a second
joint; the tile is not forced to repeat it.

The grain itself is open and wavy: unlike the tight, evenly spaced streaks
of a conifer, oak-style grain (this is Luanti's original default plank)
wanders more per streak and the streaks are fewer and broader.
"""

import sys

import numpy as np

import lib

STEM = "default_wood"
CLS = lib.class_of(STEM)
SIZE = lib.SIZE


def blur_axis(field, radius, axis):
    """Wrapped box blur along one axis only, to stretch a feature along the
    other axis. lib.blur does both axes; grain needs only one."""
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print("row means:", np.round(lum.mean(axis=1), 3).tolist())

    # Joint rows found from the dark/light shade split above, not a region
    # search: the joints repeat with period four, so they are given
    # directly rather than guessed row by row.
    joint_rows = [3, 7, 11, 15]
    row_is_joint = np.zeros(16, dtype=bool)
    row_is_joint[joint_rows] = True
    print("joint rows:", joint_rows)

    # Collapse the non joint rows into contiguous boards, wrapping row 15
    # back to row 0, the same way mcl_core_planks_big_oak.py does.
    board_id = np.zeros(16, dtype=int)
    next_id = 0
    cur_id = None
    for y in range(16):
        if row_is_joint[y]:
            board_id[y] = -(1 + joint_rows.index(y))
            cur_id = None
        else:
            if cur_id is None:
                cur_id = next_id
                next_id += 1
            board_id[y] = cur_id
    n_boards = len(set(board_id[board_id >= 0].tolist()))
    print("board rows and ids:", board_id.tolist())

    labels16 = np.broadcast_to(board_id[:, None], (16, 16)).copy()
    board_target = {}
    board_lum = {}
    for b in set(board_id.tolist()):
        rows = np.where(board_id == b)[0]
        board_lum[b] = lum[rows].mean()
    board_means = np.array([v for k, v in board_lum.items() if k >= 0])
    lo, hi = board_means.min(), board_means.max()
    for b, m in board_lum.items():
        if b < 0:
            board_target[b] = 0.08
        else:
            board_target[b] = 0.62 + 0.25 * (m - lo) / max(hi - lo, 1e-6)
    target = np.array([board_target[b] for b in range(-len(joint_rows), n_boards)])
    labels16_shifted = labels16 + len(joint_rows)

    labels_hi = np.kron(labels16_shifted, np.ones((16, 16), dtype=int))
    edges = lib.region_edges(labels_hi)
    max_dist = 4  # boards here are three texels, 48 px, tighter than big oak's widest
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    # Groove by blurring across the step, an unsharp mask (blur minus a
    # wider blur) to steepen it without kinking the slope at the crossing,
    # the same reasoning as the oak script's own comment on this.
    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 0.9 * (narrow - wide)

    # A gentle board crown, faded to nothing at the joints.
    crown = lib.fbm(SIZE, base_cells=3, octaves=2, seed=21) * 0.24
    layout = layout + crown * t

    # Open, wavy oak grain: wider streaks than a conifer, more low
    # frequency wander, so blur_axis uses a longer axis run than spruce
    # gets and a coarser base cell count.
    grain_src = lib.fbm(SIZE, base_cells=18, octaves=3, seed=22, gain=0.6)
    grain = blur_axis(grain_src, radius=12, axis=1) * 0.32

    pores_src = lib.blur(lib.white_noise(SIZE, seed=23), 1)
    pores = blur_axis(pores_src, radius=4, axis=1) * 0.035

    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = blur_axis(lib.fbm(SIZE, base_cells=16, octaves=3, seed=24, gain=0.6), radius=9, axis=1)
    smooth = 0.5 * t + 0.5 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 20.0
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
