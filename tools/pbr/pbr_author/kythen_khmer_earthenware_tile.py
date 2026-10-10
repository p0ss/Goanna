"""Hand authored height and smoothness for kythen_khmer_earthenware_tile.

The 32 px art is a barrel tile roof, courses of overlapping curved tiles.
Every even row (0, 2, 4, ... 30) is the darkest shade across its whole
width, the shadowed gap where one course overlaps the next; every odd row
is a tile ridge, and within it the darkest shade recurs every four columns
(0, 4, 8, ... 28), a butt joint between one tile and the next along the
course, with the two lighter shades between them shading each tile's own
rounded cross section, dark at the edge, brightest at the crown.

That is the whole barrel shape already drawn in the art's own greyscale,
so the height here comes straight from a smooth upscale of the art's
luminance rather than an invented profile: hardened_clay_family.py takes
its mottle the same way, just as one term among several, where here it is
the material's real geometry and carries most of the relief. The column
joints get their own narrow groove on top, since a bilinear upscale alone
softens a butt joint more than a roof tile's rough overlap should be.
lib.class_of reads "stone" back from the bake, kept: a fired earthenware
tile is a ceramic, the same call hardened_clay_family.py makes.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_earthenware_tile"
CLS = "stone"
SIZE = lib.SIZE
ART = 32
REP = SIZE // ART


def main(out_dir):
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.4f} max {lum.max():.4f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 4).tolist())))
    print("row1 (a ridge row):", np.round(lum[1], 3).tolist())
    print(f"class_of reads: {lib.class_of(STEM, GAME)} (kept)")

    # A wrapped blur on a nearest upscale rather than lib.upscale's own
    # smooth=True bilinear resize: PIL's resize does not know the tile
    # wraps, so it treated the join between the art's last row and its
    # first as two unrelated edges and the barrel shape came out with a
    # seam energy over eight. lib.blur wraps by construction (it is built
    # from np.roll), so rounding the nearest upscale's hard steps this way
    # keeps the same shape genuinely periodic.
    norm_lum = (lum - lum.min()) / max(lum.max() - lum.min(), 1e-6)
    barrel = lib.blur(lib.upscale(norm_lum), 1)

    # A narrow groove at every tile's own butt joint, column period four
    # art texels, on top of the smooth barrel shape: real overlap tiles
    # sit slightly proud of their neighbour's edge, not blended into it.
    # This has to stay at the art's own drawn columns (0, 4, 8, ... 28),
    # unlike kythen_khmer_gold_leaf.py's invented lap grid, which had no
    # art position to keep faith with.
    joint_cols = np.array([c % 4 == 0 for c in range(ART)])
    joint_hi = np.tile(np.repeat(joint_cols, REP), (SIZE, 1))
    dist = lib.distance_to_edge(joint_hi.astype(np.float32), max_dist=2)
    joint_groove = 1.0 - (np.clip(dist / 2.0, 0.0, 1.0) ** 2)

    # Fine terracotta grain and pore texture, damped at the joint groove so
    # its floor stays a clean line rather than filled with noise.
    grain = lib.fbm(SIZE, base_cells=40, octaves=3, seed=821, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=822), 1) * 0.04
    fine = (grain + pores) * (1.0 - 0.6 * joint_groove)

    # The groove is scaled by the barrel's own local height: carved only
    # where there is a ridge to carve into. Applied at a flat rate it also
    # cut into the already low valley floor, which only pushed the whole
    # map's minimum lower without adding any local contrast there, and
    # left the ridge joint, the one place a real overlap tile actually
    # steps down against its neighbour, comparatively shallow once
    # normalise01 remapped the stretched range.
    layout = barrel - 0.85 * joint_groove * barrel + fine
    height = lib.normalise01(layout, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the shadowed valley and the joint gather
    # dust and moss, the tile crown is what sheds water and wears smooth.
    rough_noise = lib.fbm(SIZE, base_cells=26, octaves=3, seed=823, gain=0.55)
    smooth = 0.55 * height + 0.45 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 13.0
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
