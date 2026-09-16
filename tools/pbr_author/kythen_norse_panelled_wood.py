"""Norse panelled wood: boards in a frame, the frame proud.

32 px art, nine shades, and four columns standing well clear of the rest:
0, 8, 16 and 24 at 0.345 to 0.367, against every other column's 0.52 to
0.61, evenly spaced every eight columns. Four vertical posts framing three
panel bays of seven columns each (the tile wraps, so bay 4 and bay 1 sit
either side of the same post pair). Row means carry no such signal (0.52
to 0.57 throughout), so the framing here is posts only, no horizontal
rail, unlike kythen_habesha_timber_laced.py's full lattice.

The posts read darker than the panel fill, the way weathered exposed
framing often reads darker than the infill boards it shelters, but the
frame is still built proud (kythen_habesha_timber_laced.py gives the same
reading for its own darker timber lacing): a structural decision about
what stands off the wall, not a read of which colour is which height.
Fill panels stay flat at their own brightness-derived level with ordinary
vertical board grain, since a post-only frame implies the infill boards
run the same way the posts do.

Only four joints (the "few furrow groups" case kythen_norse_riven_plank.py
and kythen_norse_roof_timber.py both hit) means a plain wide blur for the
layout step, not default_tree.py's sharpened unsharp-mask one, with the
posts' own proud edge and a handful of unblurred splits carrying the
ambient occlusion instead.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_panelled_wood"
SIZE = lib.SIZE
SEED = 9201


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
    row_mean = lum.mean(axis=1)
    print("column mean:", np.round(col_mean, 3).tolist())
    print("column spread %.3f  row spread %.3f" %
            (col_mean.max() - col_mean.min(), row_mean.max() - row_mean.min()))

    margin = 0.20 * (col_mean.max() - col_mean.min())
    is_post = col_mean < (col_mean.min() + margin)
    post_cols = np.where(is_post)[0]
    print("post columns:", post_cols.tolist())

    col_id = np.zeros(n, dtype=int)
    next_id = 0
    cur_id = None
    for x in range(n):
        if is_post[x]:
            col_id[x] = -(1 + list(post_cols).index(x))
            cur_id = None
        else:
            if cur_id is None:
                cur_id = next_id
                next_id += 1
            col_id[x] = cur_id
    print("column ids:", col_id.tolist())

    panel_lum = {}
    for b in set(col_id.tolist()):
        cols = np.where(col_id == b)[0]
        panel_lum[b] = lum[:, cols].mean()
    panel_means = np.array([v for k, v in panel_lum.items() if k >= 0])
    lo, hi = panel_means.min(), panel_means.max()
    panel_target = {}
    for b, m in panel_lum.items():
        panel_target[b] = 0.80 if b < 0 else 0.48 + 0.14 * (m - lo) / max(hi - lo, 1e-6)
    remap = {c: i for i, c in enumerate(sorted(panel_target.keys()))}
    col_id_shifted = np.vectorize(remap.get)(col_id)
    target = np.array([panel_target[c] for c in sorted(panel_target.keys())])

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

    is_post_hi = np.repeat(is_post, scale)[None, :].repeat(SIZE, axis=0)

    # Panel fill: ordinary vertical board grain, since the posts running
    # y imply the infill boards run the same way.
    grain_src = lib.fbm(SIZE, base_cells=20, octaves=3, seed=SEED + 2, gain=0.55)
    grain = blur_axis(grain_src, radius=12, axis=0) * 0.18
    # Post grain: tighter, since a hewn post is squarer stock than a wide
    # board.
    post_grain_src = lib.fbm(SIZE, base_cells=26, octaves=2, seed=SEED + 4, gain=0.5)
    post_grain = blur_axis(post_grain_src, radius=6, axis=0) * 0.05
    detail = np.where(is_post_hi, post_grain, grain)

    pores = lib.blur(lib.white_noise(SIZE, seed=SEED + 3), 1) * 0.03

    rng = np.random.default_rng(SEED + 6)
    tears = np.zeros((SIZE, SIZE), dtype=np.float32)
    for _ in range(9):
        cy = rng.integers(0, SIZE)
        cx = rng.integers(0, SIZE)
        length = rng.integers(10, 22)
        depth = rng.uniform(0.35, 0.65)
        for i in range(length):
            y = (cy + i) % SIZE
            x = (cx + rng.integers(-1, 2)) % SIZE
            tears[y, x] = max(tears[y, x], depth)

    height = lib.normalise01(layout + detail + pores - tears, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=20, octaves=3, seed=SEED + 5, gain=0.55), radius=10, axis=0)
    smooth = 0.5 * t + 0.45 * directional_rough
    smooth = np.where(is_post_hi, smooth + 0.04, smooth)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 18.0
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
