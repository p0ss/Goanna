"""Hand authored LabPBR height and smoothness for kythen_mitteleuropa_oak_board.

The 32 px art carries four grey shades. The darkest, 0.212, appears nowhere
except two full height columns, 0 and 16 (column means 0.215 and 0.216
against 0.33 to 0.34 everywhere else, a clean margin over 0.1): two sawn
boards standing side by side, each fifteen texels wide, joined at a vertical
seam rather than the horizontal board-to-board joint
mcl_core_planks_big_oak.py's floor draws. The boards are laid on end, so the
grain (the third shade, 0.317, in short streaks scattered across both
boards) runs the length of each board, which is the vertical axis here, the
same reasoning default_tree.py gives for a log's bark running down its
side rather than around it.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_oak_board"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def blur_axis(field, radius, axis):
    """Wrapped box blur along one axis only, to stretch grain along the
    other axis, the same helper default_tree.py and
    mcl_core_planks_big_oak.py use."""
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
    print(f"{STEM}: source shape {src.shape}, class_of reads {CLS}")

    # The art tiles, but not at texel (0, 0): both board joints (columns 0
    # and 16) sit right on the array's own column edges, so the seam
    # metric's single wrap comparison lands exactly at a joint's steepest
    # point while its "ordinary join" average is dragged down by the wide
    # flat board interiors elsewhere, the same false alarm
    # default_cobble.py's docstring describes for a mortar edge sitting on
    # row and column 0. Rolling the source by half a board width moves the
    # wrap into a board's own flat middle instead, the same closed loop
    # either way; nothing about the surface changes, only where its seam
    # happens to land.
    src = np.roll(src, 8, axis=1)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    col_mean = lum.mean(axis=0)
    print("column mean lum:", np.round(col_mean, 3))

    art = src.shape[0]
    margin = 0.06
    is_joint = col_mean < (col_mean.min() + margin)
    joint_cols = np.where(is_joint)[0]
    print("joint columns:", joint_cols.tolist())

    # Collapse into runs of columns, the wrap aware merge default_tree.py
    # uses for its own furrow columns: each joint its own id, each run of
    # board columns between joints one id.
    col_id = np.zeros(art, dtype=int)
    next_id = 0
    cur_id = None
    for x in range(art):
        if is_joint[x]:
            col_id[x] = -(1 + list(joint_cols).index(x))
            cur_id = None
        else:
            if cur_id is None:
                cur_id = next_id
                next_id += 1
            col_id[x] = cur_id
    if not is_joint[0] and not is_joint[-1] and col_id[0] != col_id[-1]:
        col_id[col_id == col_id[-1]] = col_id[0]
    n_boards = len(set(col_id[col_id >= 0].tolist()))
    print("column ids:", col_id.tolist())

    board_lum = {}
    for c in set(col_id.tolist()):
        if c < 0:
            continue
        cols = np.where(col_id == c)[0]
        board_lum[c] = col_mean[cols].mean()
    # Normalise off the whole face's own range, not the two board means
    # alone: those sit 0.334 and 0.341, a whisker apart, and stretching
    # that whisker across a target range on its own would invent a height
    # step the art never drew, the same trap default_stone_brick.py's own
    # docstring calls out for two similar blocks.
    lo, hi = lum[~is_joint[None, :].repeat(art, axis=0)].min(), lum[~is_joint[None, :].repeat(art, axis=0)].max()
    board_target = {c: 0.55 + 0.35 * (m - lo) / max(hi - lo, 1e-6) for c, m in board_lum.items()}

    # The joint is a real flat, low trench, not a v-shaped dip: a genuine
    # sawn board gap sits at one floor level along its whole width, the
    # same construction the ashlar and stone flag stems use for their own
    # single-art-texel mortar joints, which is what gives the groove the
    # ao a joint needs; an unsharp mask ramp with no flat floor (the
    # technique mcl_core_planks_big_oak.py uses for a much wider, several
    # texel joint) left this one with no sustained low point to occlude.
    up = SIZE // art
    joint_hi = np.repeat(is_joint, up)[None, :].repeat(SIZE, axis=0)
    col_id_hi = np.repeat(col_id, up)[None, :].repeat(SIZE, axis=0)
    max_dist = 2
    dist = lib.distance_to_edge(joint_hi.astype(np.float32), max_dist=max_dist)
    wobble = lib.fbm(SIZE, base_cells=30, octaves=2, seed=880) * 0.8
    dist = np.where(joint_hi, 0.0, np.clip(dist + wobble, 0.0, max_dist))
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    target_map = np.full(col_id_hi.shape, 0.08, dtype=np.float32)
    for c, val in board_target.items():
        target_map[col_id_hi == c] = val
    layout = target_map * t

    # Each board (fifteen texels, most of the tile) saturates its own
    # bevel early and is dead flat in the middle; a slow, wide bulge crowns
    # it like a board that has cupped slightly across its face, faded out
    # by t at the joints so it never reopens the matched slope there.
    # Kept modest next to the joint's own target contrast (0.08 up to
    # 0.87), so the groove stays the deepest thing on the map and the ao a
    # joint needs is not diluted away by a taller crown or grain elsewhere,
    # the same proportion the ashlar and stone flag stems keep.
    crown = lib.fbm(SIZE, base_cells=4, octaves=2, seed=881) * 0.05
    layout = layout + crown * t

    # Grain: fibres running the length of the board, which is down (y) for
    # a board standing on end. An isotropic field blurred along y only
    # stretches it into vertical streaks without touching the joint
    # spacing, which is already set along x.
    grain_src = lib.fbm(SIZE, base_cells=22, octaves=3, seed=882, gain=0.55)
    grain = blur_axis(grain_src, radius=16, axis=0) * 0.07

    # The art's own knots and streaks (the third shade), read directly as a
    # texel scale bump rather than reinvented: nearest upscaled so they sit
    # exactly where the art draws them, then blurred a little to round them
    # off, and stretched a touch along the grain the same way real grain
    # swells around a knot.
    knot_mask = (lum > (lum.min() + 0.5 * (lum.max() - lum.min()))) & ~is_joint[None, :].repeat(art, axis=0)
    knot_hi = lib.upscale(knot_mask.astype(np.float32))
    knots = blur_axis(lib.blur(knot_hi, 1), radius=3, axis=0) * 0.05

    pores_src = lib.blur(lib.white_noise(SIZE, seed=883), 1)
    pores = blur_axis(pores_src, radius=6, axis=0) * 0.02

    height = lib.normalise01(layout + grain + knots + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows the joint, not the raw height, the same reasoning
    # mcl_core_planks_big_oak.py gives: t already carries distance from the
    # nearest joint without also carrying height's own big jump in level.
    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=18, octaves=3, seed=884, gain=0.55), radius=12, axis=0)
    smooth = 0.5 * t + 0.5 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 30
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=art)
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
