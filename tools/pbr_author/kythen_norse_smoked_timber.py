"""Norse smoked timber: dark boards with grain.

32 px art, seven shades, all dark (lum 0.089 to 0.330): a smoke-blackened
timber face. Two columns stand well clear of the rest: column 0 at 0.156
and column 16 at 0.163, against every other column's 0.228 to 0.264, the
same evenly spaced two-board joint kythen_norse_roof_timber.py's art
shows. Unlike that hewn beam, the fill here is ordinary streaky wood
grain (default_tree.py's own along-grain read), not chunky adze facets, so
this stays with plain vertical grain rather than roof_timber's facet
stamps.

Only two joints means the same "few furrow groups" seam problem
kythen_norse_riven_plank.py and kythen_norse_roof_timber.py both hit: the
layout step is a plain wide blur, not the sharpened unsharp-mask step
default_tree.py's own furrow uses, and the joint's depth for ambient
occlusion comes from a handful of unblurred splits rather than the blur.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_smoked_timber"
SIZE = lib.SIZE
SEED = 9101


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

    margin = 0.30 * (col_mean.max() - col_mean.min())
    is_joint = col_mean < (col_mean.min() + margin)
    joint_cols = np.where(is_joint)[0]
    print("joint columns:", joint_cols.tolist())

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
    print("column ids:", col_id.tolist())

    board_lum = {}
    for b in set(col_id.tolist()):
        cols = np.where(col_id == b)[0]
        board_lum[b] = lum[:, cols].mean()
    board_means = np.array([v for k, v in board_lum.items() if k >= 0])
    lo, hi = board_means.min(), board_means.max()
    board_target = {}
    for b, m in board_lum.items():
        board_target[b] = 0.06 if b < 0 else 0.55 + 0.25 * (m - lo) / max(hi - lo, 1e-6)
    remap = {c: i for i, c in enumerate(sorted(board_target.keys()))}
    col_id_shifted = np.vectorize(remap.get)(col_id)
    target = np.array([board_target[c] for c in sorted(board_target.keys())])

    scale = SIZE // n
    labels16 = np.broadcast_to(col_id_shifted[None, :], (n, n)).copy()
    labels_hi = lib.warp_labels(labels16, size=SIZE, amp=0.0, seed=SEED, cells=10)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    layout = lib.blur(step, max_dist)

    crown = lib.fbm(SIZE, base_cells=4, octaves=2, seed=SEED + 1) * 0.12
    layout = layout + crown * t

    grain_src = lib.fbm(SIZE, base_cells=22, octaves=3, seed=SEED + 2, gain=0.55)
    grain = blur_axis(grain_src, radius=14, axis=0) * 0.24
    pores_src = lib.blur(lib.white_noise(SIZE, seed=SEED + 3), 1)
    pores = blur_axis(pores_src, radius=4, axis=0) * 0.03

    rng = np.random.default_rng(SEED + 6)
    tears = np.zeros((SIZE, SIZE), dtype=np.float32)
    for _ in range(5):
        cy = rng.integers(0, SIZE)
        cx = rng.integers(0, SIZE)
        length = rng.integers(12, 28)
        depth = rng.uniform(0.30, 0.55)
        for i in range(length):
            y = (cy + i) % SIZE
            x = (cx + rng.integers(-1, 2)) % SIZE
            tears[y, x] = max(tears[y, x], depth)

    height = lib.normalise01(layout + grain + pores - tears, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=20, octaves=3, seed=SEED + 5, gain=0.55), radius=10, axis=0)
    smooth = 0.5 * t + 0.45 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 28.0
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
