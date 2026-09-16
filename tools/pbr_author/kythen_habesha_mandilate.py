"""Hand authored LabPBR height and smoothness for kythen_habesha_mandilate.

The 32 px art is a clean 4 by 4 grid of 8 texel panels: row and column
means confirm it (rows and columns 0, 8, 16, 24 average 0.49, every other
row and column averages 0.70 to 0.81), a single texel wide seam both ways,
identical in all sixteen panels. That grid, and lib.class_of reading
"leaves" rather than "stone", say this is not dressed masonry: the packed
bake gave it leaves' smoothness level and its subsurface scattering byte,
which only ever means something that is thin and fibrous enough to pass
light, not a stone tile. Read together, this is a woven mat: panels of
reed or grass matting stitched edge to edge, "mandil" being the plain
cloth a Habesha floor or wall covering is made from. Each panel's own
gradient, brighter away from its top left corner, is the mat's own weave
catching the light rather than anything the joints are doing, and is left
to the ordinary taper away from the seam to reproduce. The seam is stitched
and shallow, not a mortar groove, and the grid is a manufactured layout, so
it gets no warp.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_mandilate"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


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
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("row means:", np.round(lum.mean(axis=1), 3))
    print("col means:", np.round(lum.mean(axis=0), 3))
    print(f"lib.class_of reads: {CLS}")

    h, w = lum.shape
    rows = np.arange(h) % 8 == 0
    cols = np.arange(w) % 8 == 0
    seam = rows[:, None] | cols[None, :]
    print(f"seam texels: {int(seam.sum())} of {lum.size}, panels 4x4 of 8x8")

    up = SIZE // h
    seam_hi = np.repeat(np.repeat(seam, up, axis=0), up, axis=1)

    # No warp: a woven mat is stitched to a grid by hand, but the panels and
    # their seam are a manufactured, straight edged layout, not a natural
    # silhouette to round off.
    max_dist = 10  # a shallow, fairly wide taper: a stitched mat seam, not a mortar joint
    dist = lib.distance_to_edge(seam_hi.astype(np.float32), max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    seam_level = 0.30
    panel_level = 0.62
    layout = seam_level + (panel_level - seam_level) * t

    # The weave itself: coarse parallel strands one way, a finer cross
    # thread the other, at a scale below the panel but above the texel,
    # the way a rush or reed mat is actually built.
    warp_strand = blur_axis(lib.fbm(SIZE, base_cells=32, octaves=2, seed=81), radius=3, axis=1) * 0.10
    weft_strand = blur_axis(lib.fbm(SIZE, base_cells=48, octaves=2, seed=82), radius=2, axis=0) * 0.06
    fibre = lib.blur(lib.white_noise(SIZE, seed=83), 1) * 0.05

    height = lib.normalise01(layout + warp_strand + weft_strand + fibre, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    # Smoothness follows the seam: the stitched groove collects dust and
    # stays rough, the panel faces are what a foot polishes, plus the
    # mat's own dry, uneven sheen.
    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=84, gain=0.55)
    smooth = 0.5 * t + 0.5 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 15.0
    # A mat, not a stone joint: held in a band scaled to the weave's real
    # relief rather than stretched to leaves' full class depth.
    height = lib.band(height, 0.38)
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
