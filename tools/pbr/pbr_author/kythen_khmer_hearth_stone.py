"""Hand authored height and smoothness for kythen_khmer_hearth_stone.

The 32 px art draws a clean running bond ashlar: the brightest shade
(0.782, unstained stone) forms a full width joint row every four rows (0,
4, 8, ... 28) and, within each course, a joint column every eight texels,
the offset stepping by two texels each course (8, 6, 4, 2, 8, 6, 4, 2, ...)
the way a real running bond staggers its heads. That gives four stones a
course, 32 stones in the tile, each a flood filled region of the darker,
sootier shades (0.097 to 0.315) the way default_brick.py finds its bricks
from the mortar mask, the same technique here since the geometry is
identical, just at twice the resolution.

"A flat soot stained stone" describes the material, not a single slab: a
hearth built from small coursed stones, some scrubbed clean near the
unstained joint colour, some black with soot right by the fire. Each
stone's own mean darkness sets both how sooty (lower, rougher) or clean
(higher, smoother) it reads, following default_brick.py's own brick_target
construction.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_hearth_stone"
CLS = "stone"
SIZE = lib.SIZE
ART = 32
REP = SIZE // ART


def label_stones(mortar_mask):
    """Connected components of the non mortar texels, 4 connected and
    wrapped: a stone is whatever the joint network encloses. Copied from
    default_brick.py's label_bricks, which this art's geometry matches
    exactly (a running bond with the offset stepping every course), single
    joint column safety net included even though every course here carries
    four."""
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

    mortar_mask = lum > 0.5  # the one bright, unstained shade
    print(f"joint texels: {int(mortar_mask.sum())} of {ART * ART}")

    labels, n_stones = label_stones(mortar_mask)
    sizes = [int((labels == i).sum()) for i in range(n_stones)]
    print(f"stones found: {n_stones}, sizes {sizes}")

    stone_lum = np.array([lum[labels == i].mean() for i in range(n_stones)])
    lo, hi = lum[~mortar_mask].min(), lum[~mortar_mask].max()
    # A cleaner stone (closer to the unstained shade) sits a little proud
    # and catches more light; a sootier one sits lower, following
    # default_brick.py's own brick_target construction.
    stone_target = 0.45 + 0.45 * (stone_lum - lo) / max(hi - lo, 1e-6)
    target_dict = {-1: 0.06}
    for i in range(n_stones):
        target_dict[i] = float(stone_target[i])

    mortar_hi = np.repeat(np.repeat(mortar_mask, REP, axis=0), REP, axis=1)
    labels_hi = np.repeat(np.repeat(labels, REP, axis=0), REP, axis=1)

    max_dist = 3  # narrow, steep joint, the same reasoning as the brick
                  # and stucco script: a wide taper never gets the ao a
                  # jointed surface needs.
    dist = lib.distance_to_edge(mortar_hi.astype(np.float32), max_dist=max_dist)
    wobble = lib.fbm(SIZE, base_cells=40, octaves=2, seed=761) * 1.0
    dist = np.where(mortar_hi, 0.0, np.clip(dist + wobble, 0.0, max_dist))
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for lbl, val in target_dict.items():
        target_map[labels_hi == lbl] = val
    layout = target_map * t

    # Each stone a slight, uneven dome, a stone that was never dressed
    # perfectly flat.
    crown = lib.fbm(SIZE, base_cells=8, octaves=2, seed=762) * 0.06
    layout = layout + crown * t

    # Fine texture, damped right at the joint so the groove stays a clean,
    # deep floor for its own self shadow.
    grain = lib.fbm(SIZE, base_cells=40, octaves=3, seed=763, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=764), 1) * 0.05
    layout = layout + (grain + pores) * (0.3 + 0.7 * t)

    height = lib.normalise01(layout, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows the stone's own target (soot is dull, unstained
    # stone wears smoother) with the joint kept rough.
    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=765, gain=0.55)
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
