"""Hand authored height and smoothness for kythen_wood, a plank floor.

The 16 px art carries a background of grain shading and one flat shade,
0.363, sitting 0.13 below the nearest board colour, appearing in exactly
four full width rows, 3, 7, 11 and 15, a regular four row period (row 15
is a joint and row 0 goes straight back to board colour, so the tile has
no seam kink). That is the joint between boards, not a dark patch of
grain. Between the joints the four boards (rows 0 to 2, 4 to 6, 8 to 10,
12 to 14) alternate a lighter and a darker average shade, the way real
floorboards come from different parts of the tree.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_wood"
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
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    row_mean = lum.mean(1)
    print("row mean lum:", np.round(row_mean, 3))

    row_is_joint = row_mean < (row_mean.min() + 0.03)
    joint_rows = np.where(row_is_joint)[0]
    print("joint rows:", joint_rows.tolist())

    board_id = np.zeros(16, dtype=int)
    next_id = 0
    cur_id = None
    for y in range(16):
        if row_is_joint[y]:
            board_id[y] = -(1 + list(joint_rows).index(y))
            cur_id = None
        else:
            if cur_id is None:
                cur_id = next_id
                next_id += 1
            board_id[y] = cur_id
    if not row_is_joint[0] and not row_is_joint[-1] and board_id[0] != board_id[-1]:
        board_id[board_id == board_id[-1]] = board_id[0]
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
    max_dist = 5  # crown fade half width; boards are 48 hires texels tall
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 0.9 * (narrow - wide)

    # A slow, wide bulge crowns each board like a real one cupped slightly
    # across its face, faded to nothing at the joints so it does not
    # reopen the matched-slope crossing there.
    crown = lib.fbm(SIZE, base_cells=4, octaves=2, seed=71) * 0.26
    layout = layout + crown * t

    # Grain: fibres running the length of the board, along x. An isotropic
    # field blurred along x only stretches its blobs into streaks without
    # changing their spacing along y, which the joints already set.
    grain_src = lib.fbm(SIZE, base_cells=24, octaves=3, seed=72, gain=0.55)
    grain = blur_axis(grain_src, radius=14, axis=1) * 0.28

    pores_src = lib.blur(lib.white_noise(SIZE, seed=73), 1)
    pores = blur_axis(pores_src, radius=4, axis=1) * 0.035

    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows the joint (t), not height's own absolute jump
    # between a bright board and a dark joint, so it seams correctly at
    # every one of the four joints including the one on the wrap.
    directional_rough = blur_axis(lib.fbm(SIZE, base_cells=20, octaves=3, seed=74, gain=0.55), radius=10, axis=1)
    smooth = 0.5 * t + 0.5 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 22.0
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
