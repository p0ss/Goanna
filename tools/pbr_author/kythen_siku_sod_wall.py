"""Hand authored LabPBR height and smoothness for kythen_siku_sod_wall.

The 32 px art is masonry, course 8 and stone_width 16 in
cultures/siku/materials.json's own recipe: four courses of two turves, eight
to the node. The recipe's own note: "Turves cut with a knife and laid in
courses, which is what masonry draws and what a sod wall actually is."
mortar is moss_green, lighter and greener than the tundra_brown and
peat_dark base and accent, the grass showing at the seam where the turf
faces were laid in. Cut with a knife, so the grid is kept straight, no
lib.warp_labels, the same reasoning kythen_siku_snow_block.py gives its
own knife cut blocks.

fine_detail=1.0 on the pack call, for the same reason
kythen_siku_dry_stone.py needed it: a real joint only a handful of texels
wide is exactly the "texel scale grain" pack()'s default damping exists to
suppress, and here it is the one deliberate feature, not noise.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_siku_sod_wall"
CLS = "soil"
SIZE = lib.SIZE


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("row means:", np.round(lum.mean(axis=1), 3))
    print("lib.class_of reads:", lib.class_of(STEM, GAME))

    h, w = rgb.shape[:2]
    course, stone_width = 8, 16  # cultures/siku/materials.json's own numbers
    rows, cols = h // course, w // stone_width  # 4, 2
    print(f"masonry grid: {rows} courses x {cols} turves = {rows * cols} turves")

    r32 = np.arange(h)[:, None] // course
    c32 = np.arange(w)[None, :] // stone_width
    block_id = (r32 * cols + c32) + np.zeros((h, w), dtype=int)
    labels_hi = np.kron(block_id, np.ones((SIZE // h, SIZE // w), dtype=int))

    edges = lib.region_edges(labels_hi)
    max_dist = 3  # narrow, steep taper: kythen_siku_dry_stone.py's own finding, ao_from_height
    # only occludes within its own radius and a wide taper spreads the rise too thin to read.
    dist = lib.distance_to_edge(edges, max_dist=max_dist).astype(np.float32)
    # A dead straight, axis aligned joint gives ao_from_height's 8 search directions no
    # gradient along four of them (tangent to the join), so only the two or three roughly
    # perpendicular ones ever see a rise and occlusion reads about half what a warped edge of
    # the same depth gives (checked by hand: 0.54 straight against 0.24 warped at the same
    # max_dist and depth). A cut turf edge is never perfectly straight at the texel scale
    # either, so a little fine jitter on the distance field earns that roughness honestly.
    dist = dist + lib.blur(lib.white_noise(SIZE, seed=74), 1) * 1.6
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    joint = -(1.0 - t) * 2.0  # a real course joint, turf laid on turf, not a fine crack

    grain = lib.fbm(SIZE, base_cells=26, octaves=3, seed=71, gain=0.55) * 0.12
    pits = lib.blur(lib.white_noise(SIZE, seed=72), 1) * 0.10
    shape = 1.1 * t + joint + grain + pits
    height = lib.band(shape, 0.46)
    print(f"height sd {height.std():.4f}")

    # Smoothness: the recipe's own 0.18, with the seam rougher (loose cut
    # turf edge) than the settled face, plus the wall's own grubby variation.
    variation = lib.fbm(SIZE, base_cells=22, octaves=3, seed=73, gain=0.55)
    smooth = 0.45 * t + 0.5 * zscore(variation)
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 30.0
    fine_detail = 1.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, fine_detail=fine_detail, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}, fine_detail={fine_detail}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    # seam_n is expected to miss, the same structural reason
    # kythen_siku_dry_stone.py's own does: stone_width 16 gives only two
    # turves across, so only two column joins on the whole tile are ever
    # more than background noise, and the wrap join (one of those two)
    # always reads large against a mean diluted by roughly 250 near flat
    # interior joins, however gently the joint itself is built.
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
