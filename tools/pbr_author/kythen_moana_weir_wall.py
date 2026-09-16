"""Hand authored height and smoothness for kythen_moana_weir_wall.

The 32 px art draws a clean running bond of small coursed stone: the
brightest shade (0.725, 34 percent of the tile) forms a full width joint
row every four rows (0, 4, 8, ... 28) and, within each course, a joint
column every eight texels, the offset stepping by two texels each course
(0, 6, 4, 2, repeating), the same geometry kythen_khmer_hearth_stone.py
finds in its own soot stained hearth, just doubled in row count (eight
courses here against hearth_stone's four). That gives four stones a
course, 32 stones in the tile, each a flood filled region of the two
darker shades (0.59, 0.622) the way default_brick.py finds its bricks from
the mortar mask. A weir wall is a stacked stone wall holding back water, so
each stone's own target height follows its own brightness the way hearth_
stone's soot reading does, and the joint is kept a real, steep groove so
water worn moss and grit can sit in it.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_weir_wall"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE
ART = 32
REP = SIZE // ART


def label_stones(mortar_mask):
    """Connected components of the non mortar texels, 4 connected and
    wrapped, copied from kythen_khmer_hearth_stone.py's label_stones: every
    course here carries four joint columns, but the single joint column
    safety net is kept regardless, cheap insurance against a course that
    turns out to have only one."""
    h, w = mortar_mask.shape
    full_rows = [r for r in range(h) if mortar_mask[r].all()]
    seam_cut_rows = set()
    if full_rows:
        fr = sorted(full_rows)
        for i in range(len(fr)):
            r0, r1 = fr[i], fr[(i + 1) % len(fr)]
            body = []
            r = (r0 + 1) % h
            while r != r1:
                body.append(r)
                r = (r + 1) % h
            if not body:
                continue
            full_cols = [c for c in range(w) if all(mortar_mask[r, c] for r in body)]
            if len(full_cols) == 1:
                seam_cut_rows.update(body)

    labels = np.full((h, w), -1, dtype=int)
    next_id = 0
    for y in range(h):
        for x in range(w):
            if mortar_mask[y, x] or labels[y, x] >= 0:
                continue
            stack = [(y, x)]
            labels[y, x] = next_id
            while stack:
                cy, cx = stack.pop()
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = (cy + dy) % h, (cx + dx) % w
                    if dy == 0 and cy in seam_cut_rows and abs(nx - cx) != 1:
                        continue
                    if mortar_mask[ny, nx] or labels[ny, nx] >= 0:
                        continue
                    labels[ny, nx] = next_id
                    stack.append((ny, nx))
            next_id += 1
    return labels, next_id


def main(out_dir):
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print(f"lib.class_of reads: {CLS}")

    mortar_mask = lum > 0.68  # the one bright joint shade
    print(f"joint texels: {int(mortar_mask.sum())} of {ART * ART}")

    labels, n_stones = label_stones(mortar_mask)
    sizes = [int((labels == i).sum()) for i in range(n_stones)]
    print(f"stones found: {n_stones}, sizes {sizes}")

    stone_lum = np.array([lum[labels == i].mean() for i in range(n_stones)])
    lo, hi = lum[~mortar_mask].min(), lum[~mortar_mask].max()
    stone_target = 0.45 + 0.45 * (stone_lum - lo) / max(hi - lo, 1e-6)
    target_dict = {-1: 0.06}
    for i in range(n_stones):
        target_dict[i] = float(stone_target[i])

    mortar_hi = np.repeat(np.repeat(mortar_mask, REP, axis=0), REP, axis=1)
    labels_hi = np.repeat(np.repeat(labels, REP, axis=0), REP, axis=1)

    max_dist = 3  # narrow, steep joint: the ao a jointed surface needs
    dist = lib.distance_to_edge(mortar_hi.astype(np.float32), max_dist=max_dist)
    wobble = lib.fbm(SIZE, base_cells=40, octaves=2, seed=981) * 1.0
    dist = np.where(mortar_hi, 0.0, np.clip(dist + wobble, 0.0, max_dist))
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for lbl, val in target_dict.items():
        target_map[labels_hi == lbl] = val
    layout = target_map * t

    # Each stone a slight, uneven dome, a stone never dressed perfectly
    # flat.
    crown = lib.fbm(SIZE, base_cells=8, octaves=2, seed=982) * 0.06
    layout = layout + crown * t

    grain = lib.fbm(SIZE, base_cells=40, octaves=3, seed=983, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=984), 1) * 0.05
    layout = layout + (grain + pores) * (0.3 + 0.7 * t)

    height = lib.normalise01(layout, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=985, gain=0.55)
    smooth = 0.55 * height + 0.45 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 18.0
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
