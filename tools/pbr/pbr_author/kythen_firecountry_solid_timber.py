"""Hand authored height and smoothness for kythen_firecountry_solid_timber.

Column means give a clean period of four: columns 0, 4, 8, 12, 16, 20, 24
and 28 sit at 0.21 to 0.22, every other column at 0.35, flat across every
row (row means barely move, 0.309 to 0.326). That is eight vertical
planks, three texels wide each, with a one texel joint between them, the
same layout default_wood.py's own horizontal boards use, turned ninety
degrees: this is a wall of upright timber staves rather than stacked
boards. The boards themselves carry almost no brightness difference from
each other (all close to 0.35), so unlike default_wood.py's own oak there
is no per board tint to read off the art, only the joint pattern and the
grain running the length of each stave.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_solid_timber"
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
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    col_means = lum.mean(axis=0)
    print("col means:", np.round(col_means, 3).tolist())
    print("row means:", np.round(lum.mean(axis=1), 3).tolist())

    joint_cols = [0, 4, 8, 12, 16, 20, 24, 28]
    col_is_joint = np.zeros(ART, dtype=bool)
    col_is_joint[joint_cols] = True
    print("joint columns:", joint_cols)

    board_id = np.zeros(ART, dtype=int)
    next_id = 0
    cur_id = None
    for x in range(ART):
        if col_is_joint[x]:
            board_id[x] = -(1 + joint_cols.index(x))
            cur_id = None
        else:
            if cur_id is None:
                cur_id = next_id
                next_id += 1
            board_id[x] = cur_id
    n_boards = len(set(board_id[board_id >= 0].tolist()))
    print("board columns and ids:", board_id.tolist())

    labels32 = np.broadcast_to(board_id[None, :], (ART, ART)).copy()
    target = {}
    for b in set(board_id.tolist()):
        target[b] = 0.02 if b < 0 else 0.65

    labels_hi = np.kron(labels32 + len(joint_cols), np.ones((SIZE // ART, SIZE // ART), dtype=int))
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step_map = np.array([target[b] for b in range(-len(joint_cols), n_boards)])
    step = step_map[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 0.9 * (narrow - wide)

    # A gentle stave crown, faded to nothing at the joints, and grain
    # running the length of each stave (the y axis of this side texture).
    crown = lib.fbm(SIZE, base_cells=3, octaves=2, seed=291) * 0.22
    layout = layout + crown * t

    grain_src = lib.fbm(SIZE, base_cells=16, octaves=3, seed=292, gain=0.55)
    grain = blur_axis(grain_src, radius=14, axis=0) * 0.26

    pores_src = lib.blur(lib.white_noise(SIZE, seed=293), 1)
    pores = blur_axis(pores_src, radius=4, axis=0) * 0.03

    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = blur_axis(lib.fbm(SIZE, base_cells=16, octaves=3, seed=294, gain=0.6), radius=9, axis=0)
    smooth = 0.5 * t + 0.5 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 17.0
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
