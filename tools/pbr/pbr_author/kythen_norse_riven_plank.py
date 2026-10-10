"""Norse riven plank: split wood, rough torn grain.

32 px art, five shades, and a clean furrow signature: columns 0, 8, 16 and
24 sit at 0.212 to 0.213, well below every other column (0.286 to 0.308),
evenly spaced every eight columns, cutting the tile into four seven column
planks. The same column furrow read kythen_norse_stave_wall.py and
kythen_norse_driftwood.py give their own art, but riven wood is split by
hand along the grain, not sawn: the join is a tear, not a cut, so unlike
those two straight-edged scripts the joint boundary here is warped a
little (lib.warp_labels at a small amplitude), an irregular split line
rather than default_tree.py's dead straight furrow, and the grain itself
is built coarser and less blurred, standing proud in torn ridges rather
than running as smooth fibre streaks.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_riven_plank"
SIZE = lib.SIZE
SEED = 8901


def blur_axis(field, radius, axis):
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
    print(f"{STEM}: art shape {src.shape}")
    n = src.shape[0]
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print("lum min %.3f max %.3f mean %.3f sd %.3f" % (lum.min(), lum.max(), lum.mean(), lum.std()))
    col_mean = lum.mean(axis=0)
    print("column mean:", np.round(col_mean, 3).tolist())

    margin = 0.20 * (col_mean.max() - col_mean.min())
    is_joint = col_mean < (col_mean.min() + margin)
    joint_cols = np.where(is_joint)[0]
    print("joint columns:", joint_cols.tolist())

    # Board ids: each joint column its own id, each run between joints one
    # board id, wrap-aware the way default_tree.py's own column merge is.
    col_id = np.zeros(n, dtype=int)
    next_id = 0
    cur_id = None
    for x in range(n):
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
    print("column ids:", col_id.tolist())

    board_lum = {}
    for b in set(col_id.tolist()):
        cols = np.where(col_id == b)[0]
        board_lum[b] = lum[:, cols].mean()
    board_means = np.array([v for k, v in board_lum.items() if k >= 0])
    lo, hi = board_means.min(), board_means.max()
    board_target = {}
    for b, m in board_lum.items():
        board_target[b] = 0.06 if b < 0 else 0.55 + 0.30 * (m - lo) / max(hi - lo, 1e-6)
    remap = {c: i for i, c in enumerate(sorted(board_target.keys()))}
    col_id_shifted = np.vectorize(remap.get)(col_id)
    target = np.array([board_target[c] for c in sorted(board_target.keys())])

    scale = SIZE // n
    labels16 = np.broadcast_to(col_id_shifted[None, :], (n, n)).copy()
    # A riven split tears rather than cuts: a small warp on the joint
    # boundary gives it an irregular edge instead of default_tree.py's
    # dead straight furrow, which is right for a sawn or hewn edge but not
    # a hand split one.
    labels_hi = lib.warp_labels(labels16, size=SIZE, amp=2.5, seed=SEED, cells=10)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    # A plain wide blur, not the sharpened unsharp-mask step
    # mcl_core_planks_big_oak.py and default_tree.py use: with only four
    # joints spread this evenly (24 flat interior texels for every 8 of
    # joint), the ratio lib.seam_energy computes dilutes almost every
    # interior column join to near zero and reads even a correctly
    # tileable joint step as a seam failure, measured directly at 7.6 to
    # 8.7 on the unsharp version regardless of the joint's own warp. This
    # is the same "few furrow groups" problem kythen_bark_family.py's own
    # stepped_dish records and solves the same way, a plain blur over
    # edge_dist rather than a sharpened one; the joint's own real depth for
    # ambient occlusion comes from the unblurred tears below instead.
    step = target[labels_hi]
    layout = lib.blur(step, max(1, max_dist))

    # A slow crown, faded at the joints, the same board-cupping reasoning
    # mcl_core_planks_big_oak.py gives its own wide boards.
    crown = lib.fbm(SIZE, base_cells=4, octaves=2, seed=SEED + 1) * 0.14
    layout = layout + crown * t

    # Torn grain: coarser and less blurred than a sawn plank's smooth
    # fibre streaks (default_tree.py's own radius 14 at low frequency), so
    # individual splinters stand out rather than melting into a streak,
    # plus a scatter of short unblurred tears along the grain for real
    # depth an ordinary blur cannot give lib.pack's ao_from_height.
    grain_src = lib.fbm(SIZE, base_cells=30, octaves=3, seed=SEED + 2, gain=0.6)
    grain = blur_axis(grain_src, radius=5, axis=0) * 0.30

    rng = np.random.default_rng(SEED + 4)
    tears = np.zeros((SIZE, SIZE), dtype=np.float32)
    for _ in range(14):
        cy = rng.integers(0, SIZE)
        cx = rng.integers(0, SIZE)
        length = rng.integers(10, 26)
        depth = rng.uniform(0.35, 0.65)
        for i in range(length):
            y = (cy + i) % SIZE
            x = (cx + rng.integers(-1, 2)) % SIZE
            tears[y, x] = max(tears[y, x], depth)

    pores_src = lib.blur(lib.white_noise(SIZE, seed=SEED + 3), 1)
    pores = blur_axis(pores_src, radius=3, axis=0) * 0.05

    height = lib.normalise01(layout + grain + pores - tears, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows the joint (rough at the tear, smoother on a
    # board's worn face) plus the same torn, directional streakiness.
    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=26, octaves=3, seed=SEED + 5, gain=0.6), radius=5, axis=0)
    smooth = 0.45 * t + 0.55 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 20.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, cls,
            normal_strength=normal_strength, art_texels=n)
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
