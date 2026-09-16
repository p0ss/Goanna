"""Hand authored height and smoothness for kythen_khmer_sandstone_good.

The 32 px art draws the same running bond ashlar geometry as
kythen_khmer_hearth_stone.py: the darkest shade (0.496) forms a full width
joint row every four rows and a joint column every eight texels within a
course, the offset stepping by two texels course to course. Flood filling
the rest gives the dressed blocks, the same lib.class_of read as "sand"
this stem already carries: this is a finely dressed, tightly fitted
sandstone wall, not a rough rubble one, so the joint is a hairline, not a
mortar bed, and the whole relief stays at sand's own shallow tilt band (8
to 16 degrees) rather than stone's.

Each block's own mean brightness sets its height the way
kythen_khmer_hearth_stone.py's stones do, and a soft grain runs across
every block face, the fine mineral texture of a sandstone that
mcl_core_sandstone_normal.py also gives its own faces.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_sandstone_good"
CLS = "sand"
SIZE = lib.SIZE
ART = 32
REP = SIZE // ART


def label_blocks(mortar_mask):
    """Copied from kythen_khmer_hearth_stone.py's label_stones, the same
    running bond geometry."""
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
    print(f"class_of reads: {lib.class_of(STEM, GAME)} (kept)")

    mortar_mask = lum < 0.55  # the darkest shade is the hairline joint
    print(f"joint texels: {int(mortar_mask.sum())} of {ART * ART}")

    labels, n_blocks = label_blocks(mortar_mask)
    sizes = [int((labels == i).sum()) for i in range(n_blocks)]
    print(f"blocks found: {n_blocks}, sizes {sizes}")

    block_lum = np.array([lum[labels == i].mean() for i in range(n_blocks)])
    lo, hi = lum[~mortar_mask].min(), lum[~mortar_mask].max()
    block_target = 0.55 + 0.35 * (block_lum - lo) / max(hi - lo, 1e-6)
    target_dict = {-1: 0.15}
    for i in range(n_blocks):
        target_dict[i] = float(block_target[i])

    mortar_hi = np.repeat(np.repeat(mortar_mask, REP, axis=0), REP, axis=1)
    labels_hi = np.repeat(np.repeat(labels, REP, axis=0), REP, axis=1)

    # A wide, soft taper rather than a narrow one: the joint itself is
    # still a hairline (the mortar mask band), but a narrow taper next to
    # it put almost the whole map's row wise change right on the four rows
    # either side of the wrap, which is exactly where the tile's own joint
    # band sits (the art draws a joint on row 0), and the seam measure
    # read that coincidence as a bad tile even though it repeats correctly.
    # Spreading the same relief over a wider taper keeps the block still
    # reading as dressed and flat fronted while settling the measure.
    max_dist = 8
    dist = lib.distance_to_edge(mortar_hi.astype(np.float32), max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for lbl, val in target_dict.items():
        target_map[labels_hi == lbl] = val
    # A shallow fraction of each block's own target: sand class relief,
    # the same call mcl_core_sandstone_carved.py makes for its engraving.
    layout = target_map * t * 0.6

    grain = lib.fbm(SIZE, base_cells=44, octaves=3, seed=771, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=772), 1) * 0.05
    layout = layout + (grain + pores) * (0.4 + 0.6 * t)

    height = lib.normalise01(layout, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=24, octaves=3, seed=773, gain=0.55)
    smooth = 0.5 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 4.5
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
