"""Hand authored height and smoothness for kythen_firecountry_bark_sheet.

Column means show exactly two furrows: columns 0 and 16 sit at 0.26, every
other column sits at 0.46 to 0.49, splitting the tile into two bark
panels of sixteen columns each. This is a flattened sheet of bark, cut
from the tree and laid out, with a seam down each side where one sheet's
edge meets the next: the same reading default_tree.py gives its own log
side, a narrow, nearly flat channel column rather than a drawn stone, so
the same furrow construction applies here, straight edges (not warped,
this is a cut and dressed sheet) and fibre running the length of the
sheet, the y axis of this texture.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_bark_sheet"
CLS = "wood"
SIZE = lib.SIZE
ART = 32


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
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    col_means = lum.mean(axis=0)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("col means:", np.round(col_means, 3).tolist())

    furrow_cols = [0, 16]
    is_furrow = np.zeros(ART, dtype=bool)
    is_furrow[furrow_cols] = True
    print("furrow columns:", furrow_cols)

    col_id = np.zeros(ART, dtype=int)
    next_id = 0
    cur_id = None
    for x in range(ART):
        if is_furrow[x]:
            col_id[x] = -(1 + furrow_cols.index(x))
            cur_id = None
        else:
            if cur_id is None:
                cur_id = next_id
                next_id += 1
            col_id[x] = cur_id
    n_panels = len(set(col_id[col_id >= 0].tolist()))
    print("column ids:", col_id.tolist())

    labels32 = np.broadcast_to(col_id[None, :], (ART, ART)).copy()
    panel_lum = {}
    for c in set(col_id.tolist()):
        cols = np.where(col_id == c)[0]
        panel_lum[c] = col_means[cols].mean()
    panel_means = np.array([v for k, v in panel_lum.items() if k >= 0])
    lo, hi = panel_means.min(), panel_means.max()
    panel_target = {}
    for c, m in panel_lum.items():
        if c < 0:
            panel_target[c] = 0.0
        else:
            panel_target[c] = 0.55 + 0.30 * (m - lo) / max(hi - lo, 1e-6)
    target = np.array([panel_target[c] for c in range(-len(furrow_cols), n_panels)])
    labels16_shifted = labels32 + len(furrow_cols)

    labels_hi = np.kron(labels16_shifted, np.ones((SIZE // ART, SIZE // ART), dtype=int))
    edges = lib.region_edges(labels_hi)
    max_dist = 6
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 2)
    wide = lib.blur(step, 4)
    layout = narrow + 0.6 * (narrow - wide)

    # A slow bulge crowns each panel, faded to nothing at the furrows.
    crown = lib.fbm(SIZE, base_cells=4, octaves=2, seed=321) * 0.18
    layout = layout + crown * t

    # Grain: bark fibre running the length of the sheet (y), plus a little
    # fine cracking across the panel tops only.
    grain_src = lib.fbm(SIZE, base_cells=20, octaves=3, seed=322, gain=0.55)
    grain = blur_axis(grain_src, radius=14, axis=0) * 0.32

    crack_src = lib.blur(lib.white_noise(SIZE, seed=323), 1)
    crack = blur_axis(crack_src, radius=3, axis=1) * 0.05 * t

    pores_src = lib.blur(lib.white_noise(SIZE, seed=324), 1)
    pores = blur_axis(pores_src, radius=8, axis=0) * 0.03

    height = lib.normalise01(layout + grain + crack + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=16, octaves=3, seed=325, gain=0.55), radius=8, axis=0)
    smooth = 0.55 * t + 0.45 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 30.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
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
