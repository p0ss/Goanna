"""Hand authored height and smoothness for kythen_khmer_plank_timber.

The 32 px art carries five grey shades, and the darkest (0.185) occurs only
in columns 0, 4, 8, ... 28, never anywhere else: eight vertical boards,
four texels wide, running the full height of the tile. That is
mcl_core_planks_big_oak.py's own board and joint geometry turned ninety
degrees, boards standing rather than lying, so the grain here runs along y
instead of x and the joint is a column, not a row.

Each board's own mean brightness sets its target height, the same
construction mcl_core_planks_big_oak.py uses, and the crown, grain and pore
terms are that script's own transposed onto the other axis.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_plank_timber"
CLS = "wood"
SIZE = lib.SIZE
ART = 32
REP = SIZE // ART


def blur_axis(field, radius, axis):
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def main(out_dir):
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.4f} max {lum.max():.4f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 4).tolist())))
    print(f"class_of reads: {lib.class_of(STEM, GAME)} (kept)")

    joint_col = np.array([c % 4 == 0 for c in range(ART)])
    print("joint columns:", np.where(joint_col)[0].tolist())
    board_col = np.array([c % 4 for c in range(ART)])  # 0 is joint, 1..3 body

    board_lum = {}
    for b in range(8):
        cols = [c for c in range(ART) if c % 4 != 0 and c // 4 == b]
        board_lum[b] = lum[:, cols].mean()
    vals = np.array(list(board_lum.values()))
    lo, hi = vals.min(), vals.max()
    board_target = {b: 0.62 + 0.25 * (v - lo) / max(hi - lo, 1e-6) for b, v in board_lum.items()}
    print("board targets:", {k: round(v, 3) for k, v in board_target.items()})

    labels16 = np.zeros(ART, dtype=int)
    for c in range(ART):
        labels16[c] = -1 if c % 4 == 0 else (1 + c // 4)
    target = {-1: 0.08}
    target.update({1 + b: v for b, v in board_target.items()})
    target_row = np.array([target[labels16[c]] for c in range(ART)])
    labels_hi = np.tile(np.repeat(labels16, REP)[None, :], (SIZE, 1))

    edges = lib.region_edges(labels_hi)
    max_dist = 5
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step_row = np.repeat(target_row, REP)
    step = np.tile(step_row[None, :], (SIZE, 1))
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 3)
    layout = narrow + 1.3 * (narrow - wide)

    # A slow bulge across each board's own width, the board cupped a
    # little across its face like a real sawn board.
    crown = lib.fbm(SIZE, base_cells=3, octaves=2, seed=831) * 0.24
    layout = layout + crown * t

    # Grain running the length of the board, along y.
    grain_src = lib.fbm(SIZE, base_cells=24, octaves=3, seed=832, gain=0.55)
    grain = blur_axis(grain_src, radius=14, axis=0) * 0.26

    pores_src = lib.blur(lib.white_noise(SIZE, seed=833), 1)
    pores = blur_axis(pores_src, radius=4, axis=0) * 0.035

    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = blur_axis(lib.fbm(SIZE, base_cells=20, octaves=3, seed=834, gain=0.55), radius=10, axis=0)
    smooth = 0.5 * t + 0.5 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 15.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=ART)
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
    lines = main(out_dir)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
