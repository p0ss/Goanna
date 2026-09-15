"""Hand authored height and smoothness for mcl_core_planks_birch.

Excluding columns 0, 1 and 15 (see below), rows 3, 7, 11 and 15 average
0.34 to 0.35 against 0.46 to 0.55 everywhere else, the same period of four
default_wood has: four boards, three texels tall, joints at 3, 7, 11 and
15.

Column 1 is a second, independent feature: it sits at 0.32 to 0.375 in
every single row, joint row or not, where the rest of that row is
typically 0.05 to 0.25 higher. Column 15 is the opposite, 0.55 to 0.58 in
every row, the brightest column there is. Neither tracks the board bands
at all, so this is not grain, it is a board end: the right hand edge of
one board (bright, catching the light along the full height of the tile)
sitting right next to the end grain of the next board starting (a narrow
dark reveal at column 1, with column 0 as the lit face just before it).
Boards laid in a running pattern show exactly this, an end joint partway
across the width as well as the long joints across it.

Birch grain itself is fine and pale: many thin streaks, low contrast,
unlike oak's few wide wavy ones or spruce's tighter but bolder ones.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_planks_birch"
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
    print("col means:", np.round(lum.mean(axis=0), 3).tolist())
    print("row means, columns 2 to 14 only:", np.round(lum[:, 2:15].mean(axis=1), 3).tolist())

    joint_rows = [3, 7, 11, 15]
    row_is_joint = np.zeros(16, dtype=bool)
    row_is_joint[joint_rows] = True
    print("joint rows:", joint_rows)
    print("board end column: 1")

    # Row bands first, exactly as default_wood builds them.
    row_board_id = np.zeros(16, dtype=int)
    next_id = 0
    cur_id = None
    for y in range(16):
        if row_is_joint[y]:
            row_board_id[y] = -(1 + joint_rows.index(y))
            cur_id = None
        else:
            if cur_id is None:
                cur_id = next_id
                next_id += 1
            row_board_id[y] = cur_id
    n_boards = len(set(row_board_id[row_board_id >= 0].tolist()))
    print("board rows and ids:", row_board_id.tolist())

    # Then cut the board end in: column 1 gets its own id wherever the row
    # is not already a joint (a joint row is already at the groove floor,
    # so there is nothing to cut into it).
    VSEAM = -(len(joint_rows) + 1)
    labels16 = np.broadcast_to(row_board_id[:, None], (16, 16)).copy()
    for y in range(16):
        if not row_is_joint[y]:
            labels16[y, 1] = VSEAM

    board_lum = {}
    for b in set(row_board_id.tolist()):
        if b < 0:
            continue
        rows = np.where(row_board_id == b)[0]
        # Columns 0, 1 and 15 carry the board end and its highlight, not
        # the board's own brightness, so they are left out of the level.
        board_lum[b] = lum[rows][:, 2:15].mean()
    board_means = np.array(list(board_lum.values()))
    lo, hi = board_means.min(), board_means.max()

    unique_ids = sorted(set(labels16.ravel().tolist()))
    target_by_id = {}
    for u in unique_ids:
        if u < 0:
            target_by_id[u] = 0.08  # every joint and the board end alike
        else:
            target_by_id[u] = 0.62 + 0.25 * (board_lum[u] - lo) / max(hi - lo, 1e-6)
    id_to_idx = {u: i for i, u in enumerate(unique_ids)}
    idx16 = np.vectorize(id_to_idx.get)(labels16)
    target = np.array([target_by_id[u] for u in unique_ids])

    labels_hi = np.kron(idx16, np.ones((16, 16), dtype=int))
    edges = lib.region_edges(labels_hi)
    max_dist = 4  # boards here are three texels, 48 px, the same as default_wood
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 0.9 * (narrow - wide)

    crown = lib.fbm(SIZE, base_cells=3, octaves=2, seed=41) * 0.20
    layout = layout + crown * t

    # Fine, pale grain: a high base cell count for many thin streaks and a
    # low amplitude, since birch shows little contrast between one streak
    # and the next.
    grain_src = lib.fbm(SIZE, base_cells=40, octaves=2, seed=42, gain=0.5)
    grain = blur_axis(grain_src, radius=16, axis=1) * 0.12

    pores_src = lib.blur(lib.white_noise(SIZE, seed=43), 1)
    pores = blur_axis(pores_src, radius=3, axis=1) * 0.025

    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = blur_axis(lib.fbm(SIZE, base_cells=32, octaves=2, seed=44, gain=0.5), radius=12, axis=1)
    smooth = 0.5 * t + 0.5 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # The nearest upscale of this art has a real wrap discontinuity in both
    # directions: the board end at column 1 sits right beside the tile's
    # own left/right wrap, and the joint rows sit right beside its
    # top/bottom wrap, each next to the brightest values in the texture
    # (column 15, row 0). That is the art's own board end and long joint
    # doing their job at the one place, the tile edge, where the check
    # measures it hardest; it is not fixable from height or smoothness and
    # not fixable without repainting, so this uses the bake's own soft
    # upscale, the documented alternative for a surface where it reads
    # better than the nearest one.
    albedo = lib.load_baked_albedo(STEM)

    normal_strength = 23.0
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
