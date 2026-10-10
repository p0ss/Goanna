"""Hand authored LabPBR height and smoothness for kythen_siku_whale_bone.

The 32 px art (cultures/siku/materials.json: "bark", base bone_white,
accent bone_shadow, fissure 3, furrow 0.35, wander 1.6, flake 0.2, cells 7)
reads the same column furrow structure kythen_siku_driftwood.py's own bark
does: "the bark recipe because a weathered bone is longitudinally grained
and pitted, which is what bark draws", the recipe's own note, "this
material is where every other package writes timber". Built the same way
as driftwood, furrow columns plus fine crack slots, but held far
shallower (a rib is smooth polished bone, not open weathered grain) and
banded nearly flat, per the brief.

lib.class_of reads "stone" (bone sounds and wears like stone underfoot,
a reasonable footstep read), whose packed ceiling (0.12 + 0.25 = 0.37) is
well under the "high smoothness" the brief asks for, so keep_mean=False
carries the authored mean (about 0.68) through untouched, the same lever
kythen_siku_soapstone.py uses for its own worked stone. Lower than
kythen_siku_ivory.py's own (about 0.78): the recipe's own surface.smooth
is 0.4 against ivory's 0.7, a rafter that has weathered outdoors rather
than a carved tusk kept indoors, so it stays smooth but not glassy.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_siku_whale_bone"
CLS = "stone"
SIZE = lib.SIZE


def furrow_columns(lum, margin_frac=0.35):
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

    labels16 = np.broadcast_to(col_id[None, :], lum.shape).copy()
    labels_hi = np.kron(labels16, np.ones((SIZE // lum.shape[0], SIZE // lum.shape[1]), dtype=int))
    furrow_hi = np.kron(np.broadcast_to(is_furrow[None, :], lum.shape).astype(np.float32),
            np.ones((SIZE // lum.shape[0], SIZE // lum.shape[1]))) > 0.5

    edges = lib.region_edges(labels_hi)
    max_dist = 5
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = np.where(furrow_hi, 0.35, 0.60)
    layout = lib.blur(step, 2)

    grain = lib.fbm(SIZE, base_cells=7, octaves=3, seed=201, gain=0.55) * 0.10  # wander 1.6
    cracks = hard_cracks(SIZE, 16, seed=202, length_range=(8, 26), depth=0.20)  # fissure 3, sparser than driftwood's own
    pores = lib.blur(lib.white_noise(SIZE, seed=203), 1) * 0.04

    height = lib.normalise01(layout + grain + pores - cracks, 0.5, 99.5)
    height = lib.band(height, 0.10)  # nearly flat, per the brief
    print(f"height sd {height.std():.4f}")

    # Smoothness: authored directly at a high mean rather than the class
    # level, keep_mean=False, see module docstring.
    variation = lib.fbm(SIZE, base_cells=22, octaves=3, seed=204, gain=0.55)
    shape = 0.4 * t - 0.5 * cracks + 0.5 * variation
    z = (shape - shape.mean()) / (shape.std() + 1e-6)
    smooth = np.clip(0.68 + 0.12 * z, 0.05, 0.95)
    print(f"pre pack smooth mean {smooth.mean():.4f} sd {smooth.std():.4f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 6.0
    keep_mean = False
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, keep_mean=keep_mean, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}, keep_mean={keep_mean}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    # tilt and ao are expected to miss the stone band: the brief calls
    # this smooth polished bone held nearly flat, the polished face case
    # the brief allows to miss it and say why.
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
