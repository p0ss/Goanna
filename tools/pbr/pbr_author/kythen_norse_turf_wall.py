"""Norse turf wall: stacked turf blocks in courses, soft edges.

32 px art, five shades, and a clean row signature the opposite way round
from this family's timber stems: rows 0, 8, 16 and 24 are entirely one
bright shade (0.448), against every other row's mix of 0.262 to 0.380,
evenly spaced every eight rows. Four horizontal courses of seven rows
each, the cut, slightly lighter edge of one turf course showing above the
darker sod of the block below it, exactly the way a stacked turf wall
reads: laid in courses, not built from vertical members the way this
family's other timber stems are.

Only four course lines (the same "few row groups" seam problem
kythen_norse_smoked_timber.py and kythen_norse_roof_timber.py hit on their
own column joints) means a plain wide blur for the layout step, and turf
is soft edged besides, a cut sod line, not a masonry joint, so the blur
here is wider again than any of this family's timber joints. The ambient
occlusion a soil class still needs comes from a handful of unblurred
splits, the same recovery those two scripts use.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_turf_wall"
SIZE = lib.SIZE
SEED = 9501


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    n = src.shape[0]
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print("lum min %.3f max %.3f mean %.3f sd %.3f" % (lum.min(), lum.max(), lum.mean(), lum.std()))
    row_mean = lum.mean(axis=1)
    print("row mean:", np.round(row_mean, 3).tolist())
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)

    margin = 0.20 * (row_mean.max() - row_mean.min())
    is_course = row_mean > (row_mean.max() - margin)
    course_rows = np.where(is_course)[0]
    print("course lines (rows):", course_rows.tolist())

    row_id = np.zeros(n, dtype=int)
    next_id = 0
    cur_id = None
    for y in range(n):
        if is_course[y]:
            row_id[y] = -(1 + list(course_rows).index(y))
            cur_id = None
        else:
            if cur_id is None:
                cur_id = next_id
                next_id += 1
            row_id[y] = cur_id
    print("row ids:", row_id.tolist())

    block_lum = {}
    for b in set(row_id.tolist()):
        rows = np.where(row_id == b)[0]
        block_lum[b] = lum[rows, :].mean()
    block_means = np.array([v for k, v in block_lum.items() if k >= 0])
    lo, hi = block_means.min(), block_means.max()
    block_target = {}
    for b, m in block_lum.items():
        block_target[b] = 0.68 if b < 0 else 0.30 + 0.18 * (m - lo) / max(hi - lo, 1e-6)
    remap = {c: i for i, c in enumerate(sorted(block_target.keys()))}
    row_id_shifted = np.vectorize(remap.get)(row_id)
    target = np.array([block_target[c] for c in sorted(block_target.keys())])

    scale = SIZE // n
    labels16 = np.broadcast_to(row_id_shifted[:, None], (n, n)).copy()
    labels_hi = np.repeat(np.repeat(labels16, scale, axis=0), scale, axis=1)

    step = target[labels_hi]
    # A wide, plain blur: soft turf edges, not a masonry joint, and only
    # four course lines, the same "few groups" reasoning that pushed
    # kythen_norse_smoked_timber.py and kythen_norse_roof_timber.py away
    # from a sharpened unsharp-mask step.
    layout = lib.blur(step, 10)

    # Clumpy soil texture inside a block: isotropic mottling rather than a
    # directional grain, since turf is soil and root mat, not fibrous
    # timber.
    clumps = lib.fbm(SIZE, base_cells=18, octaves=3, seed=SEED + 2, gain=0.55) * 0.10
    pores = lib.blur(lib.white_noise(SIZE, seed=SEED + 3), 1) * 0.04

    rng = np.random.default_rng(SEED + 6)
    tears = np.zeros((SIZE, SIZE), dtype=np.float32)
    for _ in range(6):
        cy = rng.integers(0, SIZE)
        cx = rng.integers(0, SIZE)
        length = rng.integers(8, 20)
        depth = rng.uniform(0.25, 0.45)
        vertical = rng.uniform() < 0.5
        for i in range(length):
            if vertical:
                y = (cy + i) % SIZE
                x = (cx + rng.integers(-1, 2)) % SIZE
            else:
                y = (cy + rng.integers(-1, 2)) % SIZE
                x = (cx + i) % SIZE
            tears[y, x] = max(tears[y, x], depth)

    height = lib.normalise01(layout + clumps + pores - tears, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=SEED + 4, gain=0.55)
    smooth = 0.4 * height + 0.5 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 14.0
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
