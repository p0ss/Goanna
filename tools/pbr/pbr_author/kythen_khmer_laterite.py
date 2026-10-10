"""Hand authored height and smoothness for kythen_khmer_laterite.

The 32 px art is a coursed ashlar again, the same running bond geometry as
kythen_khmer_hearth_stone.py and kythen_khmer_sandstone_good.py but at a
larger module: the darkest shade (0.217) forms a full width joint row every
eight rows and, within each eight row course, one joint column every
sixteen texels, the offset stepping by four texels a course, giving two
big stones a course, eight in the tile. That is large laterite block work,
coarser than the dressed sandstone.

lib.class_of reads "stone" back from the bake, kept. What makes laterite
laterite rather than plain ashlar is what happens inside each block: three
more shades (0.300 dominant, 0.314 rare, 0.338 common) scattered through
the block faces with no pattern lib.segments can turn into regions, which
is the real signature of a "pitted porous block": laterite is a weathered
ironstone full of small voids where roots and water channels once ran, not
a stone with a drawn crack network. So each block gets a flat base from
the joint mask, the same technique as the other coursed stems, and its
relief comes mostly from a dense field of small pits (denser than
kythen_khmer_hearth_stone.py's soot patches, sparser than the crack lines
a jointed rubble would need), the art's own per texel shade folded in as a
weak guide rather than a hard layout.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_laterite"
CLS = "stone"
SIZE = lib.SIZE
ART = 32
REP = SIZE // ART


def label_blocks(mortar_mask):
    """Copied from kythen_khmer_hearth_stone.py's label_stones."""
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

    mortar_mask = lum < 0.22
    print(f"joint texels: {int(mortar_mask.sum())} of {ART * ART}")

    labels, n_blocks = label_blocks(mortar_mask)
    sizes = [int((labels == i).sum()) for i in range(n_blocks)]
    print(f"blocks found: {n_blocks}, sizes {sizes}")

    block_lum = np.array([lum[labels == i].mean() for i in range(n_blocks)])
    lo, hi = lum[~mortar_mask].min(), lum[~mortar_mask].max()
    block_target = 0.55 + 0.15 * (block_lum - lo) / max(hi - lo, 1e-6)
    target_dict = {-1: 0.10}
    for i in range(n_blocks):
        target_dict[i] = float(block_target[i])

    mortar_hi = np.repeat(np.repeat(mortar_mask, REP, axis=0), REP, axis=1)
    labels_hi = np.repeat(np.repeat(labels, REP, axis=0), REP, axis=1)

    max_dist = 2  # a real joint between large blocks, kept narrow for the
                  # ao a jointed surface needs, the same call the other
                  # coursed stems make
    dist = lib.distance_to_edge(mortar_hi.astype(np.float32), max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for lbl, val in target_dict.items():
        target_map[labels_hi == lbl] = val
    layout = target_map * t

    # The block's own faint shade pattern as a weak guide (blurred, since
    # the raw texel data is not a layout to trust literally, just a hint
    # of where the ironstone happened to weather a little more) plus a
    # dense field of small pits, blurred just enough to round an edge,
    # then only the deepest slice kept so pits stay small and numerous
    # rather than a wash of soft noise.
    shade_hint = lib.upscale(lum - lum.mean(), smooth=True)
    pit_field = lib.blur(lib.white_noise(SIZE, seed=801), 1)
    pit_cut = float(np.percentile(pit_field, 35))
    pits = np.where(pit_field < pit_cut, pit_field - pit_cut, 0.0)
    fine = 0.10 * shade_hint + 0.55 * pits + 0.10 * lib.blur(lib.white_noise(SIZE, seed=802), 2)
    fine = fine * (0.3 + 0.7 * t)  # a clean, deep joint floor

    height = lib.normalise01(layout + fine, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=26, octaves=3, seed=803, gain=0.55)
    smooth = 0.45 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 26.0
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
