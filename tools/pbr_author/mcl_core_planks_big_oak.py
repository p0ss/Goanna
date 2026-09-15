"""Hand authored height and smoothness for mcl_core_planks_big_oak.

The 16 px art carries five grey shades. Four of them sit 0.039 to 0.043
apart and shade the wood grain; the fifth, 0.209, is 0.087 below the
nearest of those and appears nowhere else but four full width rows, 3, 6,
11 and 15 (wrapping cleanly: row 15 is a joint and row 0 goes straight
back to board colour, so the tile has no seam). That is not a dark patch
of grain, it is the mortar of this material: the joint between one board
and the next. Between the joints the rows vary in brightness from streak
to streak, which is the grain running along the board, not a second row of
joints, so the boards here are the four horizontal strips those four
joint rows cut the tile into: 2, 4, 3 and 3 texels tall.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_planks_big_oak"
CLS = "wood"
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

    # Connected regions of near identical colour. 0.055 sits between the
    # 0.039 to 0.043 steps inside the grain and the 0.087 gap down to the
    # joint shade, so it keeps every grain streak welded to its board while
    # still cutting the joint rows out on their own.
    tolerance = 0.055
    labels, n = lib.segments(rgb, tolerance=tolerance)
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region mean lum:", np.round(region_lum, 3))

    is_joint_region = region_lum < (lum.min() + 0.03)
    row_is_joint = np.array([is_joint_region[labels[y]].mean() > 0.5 for y in range(16)])
    print("joint rows:", np.where(row_is_joint)[0].tolist())

    # Collapse to one label per board and one per joint row. Segments alone
    # also splits a board where its own grain jumps two shades at once (rows
    # 7/8 to 9/10 here), which is real brightness but not a second joint;
    # a board is one surface however its grain runs, so board rows are
    # merged by contiguous run, wrapping across row 15 to row 0.
    board_id = np.zeros(16, dtype=int)
    joint_rows = np.where(row_is_joint)[0]
    next_id = 0
    cur_id = None
    for y in range(16):
        if row_is_joint[y]:
            board_id[y] = -(1 + list(joint_rows).index(y))  # each joint its own id
            cur_id = None
        else:
            if cur_id is None:
                # A run starting right after a joint keeps the run's board id
                # even where it wraps past row 15 back to row 0.
                cur_id = next_id
                next_id += 1
            board_id[y] = cur_id
    # Stitch the wrap: if row 0 and row 15 are both board rows with no joint
    # between them they are the same run, but here row 15 is always a joint
    # so this is just a safety net for a differently painted plank art.
    if not row_is_joint[0] and not row_is_joint[-1] and board_id[0] != board_id[-1]:
        board_id[board_id == board_id[-1]] = board_id[0]
    n_boards = len(set(board_id[board_id >= 0].tolist()))
    print("board rows and ids:", board_id.tolist())

    labels16 = np.broadcast_to(board_id[:, None], (16, 16)).copy()
    # Target height per collapsed region: joints are the groove floor, board
    # tops rise a little with the board's own average brightness so the
    # lighter boards catch a touch more light, the way a real floor's boards
    # do not all come from the same part of the tree.
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
    # target is indexed from -len(joint_rows) up; shift labels16 to match
    labels16_shifted = labels16 + len(joint_rows)

    labels_hi = np.kron(labels16_shifted, np.ones((16, 16), dtype=int))
    edges = lib.region_edges(labels_hi)
    max_dist = 5  # crown fade half width in 256 map texels, boards are 32 to 64 wide
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep, 1 on flat board tops, 0 right at a joint

    # The plateau itself: a step per region (from target), turned into a
    # groove by blurring across the step rather than tapering each side
    # from its own edge. Tapering each side from zero at its own amplitude
    # (a joint at 0.08 next to a board at up to 0.87) meets the neighbour
    # with two different slopes either side of the same point: shallow
    # into the groove, steep out of it, a kink invisible inside the tile
    # but real at the one joint, row 15 to row 0, that lands on the wrap
    # seam. A blur turns every step into one shared ramp, same slope on
    # both sides of the crossing, so the wrap is no more of a kink than
    # any of the other three joints (seam_n on a blur(step, 1) alone comes
    # out 0.00). A single texel of blur is too soft a groove on its own for
    # the ambient occlusion a joint needs (ao_min stays above 0.5): an
    # unsharp mask, the blur minus a wider blur added back on top, steepens
    # the same ramp without touching its matched slope at the crossing,
    # since both terms are smooth there and a sum of two things that agree
    # in slope still agrees in slope.
    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 0.9 * (narrow - wide)

    # The widest board (4 native texels) saturates its bevel early and is
    # dead flat in the middle; a slow, wide bulge crowns it like a real
    # board that has cupped slightly across its face. Faded out by the same
    # t right at the joints, so it does not reopen the kink just smoothed.
    # The joint groove above is narrow by design, for the AO a joint needs,
    # so it only ever touches a sliver of the map; the crown and the grain
    # below are what actually carry the tile's mean tilt, since between
    # them they cover the whole board top, not just the few texels either
    # side of a joint.
    crown = lib.fbm(SIZE, base_cells=3, octaves=2, seed=11) * 0.28
    layout = layout + crown * t

    # Grain: fibres running the length of the board, along x. An isotropic
    # fbm field blurred along x only stretches its blobs into streaks
    # without changing their spacing along y, which is the direction the
    # joints already set.
    grain_src = lib.fbm(SIZE, base_cells=24, octaves=3, seed=12, gain=0.55)
    grain = blur_axis(grain_src, radius=14, axis=1) * 0.28

    # Structure below the texel: a fine scratch texture along the grain,
    # finer and fainter than the grain streaks themselves.
    pores_src = lib.blur(lib.white_noise(SIZE, seed=13), 1)
    pores = blur_axis(pores_src, radius=4, axis=1) * 0.035

    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows the joint, not the raw height: joints stay rough,
    # board tops wear smooth, and t (distance from the nearest joint,
    # already 0 there and 1 across the flat top) carries exactly that
    # without also carrying height's own big jump in absolute level from
    # one board to the next, which seams perfectly at every joint by
    # construction (seam_n above) but not in raw value, since a board at
    # 0.87 sits nowhere near a joint at 0.08 in absolute terms even once
    # the slope between them matches. A directional field, the same shape
    # of noise used for the height grain, adds the along the grain
    # streakiness a board actually has rather than an isotropic scatter.
    directional_rough = blur_axis(lib.fbm(SIZE, base_cells=20, octaves=3, seed=14, gain=0.55), radius=10, axis=1)
    smooth = 0.5 * t + 0.5 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the board and joint edges the height field lines
    # up with; a soft upscale would blur that alignment away.
    albedo = lib.upscale(src[..., :3])

    normal_strength = 22.0
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
