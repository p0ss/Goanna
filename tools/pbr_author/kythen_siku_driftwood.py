"""Hand authored LabPBR height and smoothness for kythen_siku_driftwood.

The 32 px art (cultures/siku/materials.json: "bark", base driftwood_grey,
accent driftwood_dark, fissure 5, furrow 0.55, wander 1.2, cells 8) has a
column mean that dips every six or seven texels (checked by hand: local
minima at columns 0, 7, 13, 19, 26, a period of about 6.4), the same
column furrow read default_tree.py and kythen_bark_family.py give their
own bark: five weathered log strips lying side by side, not a plank
floor's straight joints. wander 1.2 is the lowest of the batch's own bark
recipes, so the furrows are kept close to straight, only lightly warped.

The recipe's own note: "silvered, checked and shot through with old
cracks", so on top of the furrow columns a scatter of short, unblurred
crack slots is cut into the height directly (fissure 5), open grain from
sun and salt rather than a fresh cut plank's clean face.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_siku_driftwood"
CLS = "wood"
SIZE = lib.SIZE


def furrow_columns(lum, margin_frac=0.35):
    """Furrow columns from the art's own column means, wrap aware: a column
    within margin_frac of the darkest column is a furrow, everything else
    belongs to whichever ridge run it sits inside."""
    w = lum.shape[1]
    col_mean = lum.mean(axis=0)
    spread = float(col_mean.max() - col_mean.min())
    margin = margin_frac * max(spread, 1e-6)
    is_furrow = col_mean < (col_mean.min() + margin)
    col_id = np.zeros(w, dtype=int)
    next_id, cur = 0, None
    for x in range(w):
        if is_furrow[x]:
            col_id[x] = -1
            cur = None
        else:
            if cur is None:
                cur = next_id
                next_id += 1
            col_id[x] = cur
    if not is_furrow[0] and not is_furrow[-1] and col_id[0] != col_id[-1]:
        col_id[col_id == col_id[-1]] = col_id[0]
    return col_id, is_furrow


def hard_cracks(size, n, seed, length_range, depth, width=2):
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    half = width // 2
    for _ in range(n):
        cy, cx = rng.integers(0, size), rng.integers(0, size)
        length = rng.integers(length_range[0], length_range[1] + 1)
        for i in range(length):
            for w_ in range(-half, width - half):
                y = (cy + i) % size
                x = (cx + w_) % size
                field[y, x] = 1.0
    return field * depth


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("col means:", np.round(lum.mean(axis=0), 3))
    print("lib.class_of reads:", lib.class_of(STEM, GAME))

    col_id, is_furrow = furrow_columns(lum)
    print(f"furrow columns: {int(is_furrow.sum())} of {lum.shape[1]}, ridge runs: {col_id.max() + 1}")

    n_runs = col_id.max() + 1
    run_lum = np.array([lum[:, col_id == r].mean() for r in range(n_runs)])
    lo, hi = run_lum.min(), run_lum.max()
    ridge_target = 0.55 + 0.30 * (run_lum - lo) / max(hi - lo, 1e-6)

    labels16 = np.broadcast_to(col_id[None, :], lum.shape).copy()
    labels_hi = np.kron(labels16, np.ones((SIZE // lum.shape[0], SIZE // lum.shape[1]), dtype=int))
    furrow_hi = np.kron(np.broadcast_to(is_furrow[None, :], lum.shape).astype(np.float32),
            np.ones((SIZE // lum.shape[0], SIZE // lum.shape[1]))) > 0.5

    edges = lib.region_edges(labels_hi)
    max_dist = 5
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    ridge_id = np.clip(labels_hi, 0, n_runs - 1)
    ridge_step = ridge_target[ridge_id]
    step = np.where(furrow_hi, 0.30, ridge_step)
    layout = lib.blur(step, 2)  # one shared ramp at every crossing, wood_wander is light so
    # this stays close to the block's own furrow columns rather than tracking them exactly

    grain = lib.fbm(SIZE, base_cells=6, octaves=3, seed=181, gain=0.55) * 0.08  # wander 1.2
    cracks = hard_cracks(SIZE, 26, seed=182, length_range=(10, 40), depth=0.30)
    pores = lib.blur(lib.white_noise(SIZE, seed=183), 1) * 0.05

    height = lib.normalise01(layout + grain + pores - cracks, 0.5, 99.5)
    height = lib.band(height, 0.34)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=184, gain=0.55)
    smooth = 0.5 * t - 0.5 * cracks + 0.4 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 22.0
    fine_detail = 1.0  # kythen_siku_dry_stone.py's own finding: the crack slots are only
    # two texels wide, exactly what pack()'s default damping exists to flatten.
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, fine_detail=fine_detail, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}, fine_detail={fine_detail}")
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
