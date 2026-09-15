"""Hand authored height and smoothness for mcl_core_planks_spruce.

The 16 px art has nine grey shades, and two rows, 7 and 15, are a single
flat shade each (0.191 to 0.193, min to max inside the row is 0.002): a
real joint, not shaded grain, painted as close to one flat tone as 16
colours allow. No other row comes near that flatness (the next tightest
row spans 0.013). That gives two boards, seven texels tall each, rows 8 to
14 and, wrapping, 0 to 6: spruce planks cut wider than the four narrow
boards of default_wood.

Row 5, columns 5 to 8, is a second, smaller dark patch, 0.223, a full two
shades under the 0.312 directly above it in row 4 and under the 0.265 to
0.278 either side of it in row 5 itself: a localised dip, not a band
running the row's width, so it reads as a knot rather than a joint. There
is only the one clear knot in this art; the rest of the darkening (row 3,
row 10) is broader and shallower and reads as ordinary grain waver.

Spruce grain is straight and tight: many closely spaced streaks with
little low frequency wander, unlike oak's fewer, wider, wavier ones.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_planks_spruce"
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


def torus_dist(size, cy, cx):
    """Wrapped distance from one map point, for a feature that sits away
    from the tile edge but should still tile correctly if it ever fell
    near one."""
    y = np.arange(size)[:, None]
    x = np.arange(size)[None, :]
    dy = np.abs(y - cy)
    dy = np.minimum(dy, size - dy)
    dx = np.abs(x - cx)
    dx = np.minimum(dx, size - dx)
    return np.sqrt(dy * dy + dx * dx)


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print("row means:", np.round(lum.mean(axis=1), 3).tolist())
    print("row ranges:", np.round(lum.max(axis=1) - lum.min(axis=1), 3).tolist())

    joint_rows = [7, 15]
    row_is_joint = np.zeros(16, dtype=bool)
    row_is_joint[joint_rows] = True
    print("joint rows:", joint_rows)

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
    max_dist = 8  # boards here are seven texels, 112 px, wider than default_wood's
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 0.9 * (narrow - wide)

    # A low, wide crown: these boards are broad enough to cup gently across
    # their whole face, but spruce planks read flatter than oak's, so the
    # amplitude stays modest.
    crown = lib.fbm(SIZE, base_cells=3, octaves=2, seed=31) * 0.16
    layout = layout + crown * t

    # Straight, tight grain: many thin streaks (a fine base cell count),
    # few octaves so the streaks do not wander far off straight, and a long
    # axis blur to draw each one out the length of the board.
    grain_src = lib.fbm(SIZE, base_cells=34, octaves=2, seed=32, gain=0.5)
    grain = blur_axis(grain_src, radius=18, axis=1) * 0.16

    pores_src = lib.blur(lib.white_noise(SIZE, seed=33), 1)
    pores = blur_axis(pores_src, radius=3, axis=1) * 0.03

    # The one clear knot: row 5, columns 5 to 8 of the source, centred at
    # (88, 112) once upscaled 16x, in board B (native rows 0 to 6). A knot
    # disturbs the straight grain around it: the wood there grew harder
    # than its surrounds and sits a little proud, with the grain swirling
    # rather than running straight, so it is rougher than the long grain
    # either side of it, not smoother.
    d = torus_dist(SIZE, 88, 112)
    knot_t = np.clip(1.0 - d / 22.0, 0.0, 1.0)
    knot_t = knot_t * knot_t * (3 - 2 * knot_t)
    knot_height = knot_t * 0.10
    knot_rough = knot_t  # used again below, subtracted from smoothness

    height = lib.normalise01(layout + grain + pores + knot_height, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = blur_axis(lib.fbm(SIZE, base_cells=28, octaves=2, seed=34, gain=0.5), radius=14, axis=1)
    smooth = 0.55 * t + 0.45 * directional_rough - 0.3 * knot_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # The nearest upscale of this art has a real wrap discontinuity: the
    # joint at row 15 sits right on the tile's own top/bottom seam, next
    # to the brightest row on either side of it (row 0 and row 14), so the
    # wrap is the single sharpest luminance step in the whole texture, by
    # design rather than by accident (that is what a joint at the tile
    # edge looks like). It is not fixable from height or smoothness, and
    # not fixable without repainting the art, so this uses the bake's own
    # soft upscale instead, the documented alternative in the README for a
    # surface where it reads better than the nearest upscale.
    albedo = lib.load_baked_albedo(STEM)

    normal_strength = 42.0
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
