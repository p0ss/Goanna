"""Hand authored LabPBR height and smoothness for kythen_habesha_scoria_cut.

The 32 px art has the same four grey shades as kythen_habesha_scoria_rubble
(0.229, 0.311, 0.327, 0.339, sd 0.045) but a very different layout: no row
or column is uniformly dark (checked explicitly, none of the 32 rows or 32
columns is all darkest-shade), so there is no dressing joint or mortar
course here. Segmenting at tolerance 0.05 instead gives 185 small regions,
the largest matrix chunk only 144 texels and the darkest shade broken into
36 separate clusters of 5 to 35 texels scattered across the face. That is a
fairly flat, fairly uniform block face with scattered darker pit texels,
not a jointed layout: a scoria block cut flat by a mason, still showing the
small vesicle pits the rough stone had before it was dressed. class_of
reads "stone", which is used for lib.pack and lib.check.

Built the way mcl_core_iron_ore.py drops a nodule into a matrix, except the
feature goes down instead of up: the darkest shade (29.5 percent of the
tile, distinct from the next shade up by a clean 0.08 gap) is a pit mask,
tapered to a shallow dimple floor with lib.distance_to_edge, and everything
else stays close to the baseline face. Per the brief, this dressed surface
is not warped: mask and labels go through a straight lib's own factor
upscale (np.repeat, never np.kron) at their own pixel positions, not
lib.warp_labels, so the pit edges stay exactly where the art drew them
rather than turning into scribbles.

The resulting mean tilt, 30.6 degrees, lands inside the stone band on its
own, without lib.band and without inflating the pits past what the art
shows: at normal_strength 18 the un-banded pit depth alone (roughly 30
percent of the face recessed by a real, if shallow, dimple) is enough. This
is not the flat-face exception the brief allows for: the pits are real
structure the art draws, not fabricated relief, so they are left to read as
what they are rather than squashed into a band to force a "dressed and
flat" look the art does not actually show. The fine shading the other two
shades draw within the matrix (0.311 against 0.327) is not treated as more
height, per the rule that fine tonal variation belongs in smoothness: it
rides into the smoothness field instead, from the source luminance itself.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_scoria_cut"
CLS = lib.class_of(STEM, GAME)


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}, class_of reads {CLS}")

    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} "
          f"mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    dark = lum <= 0.27
    full_rows = [r for r in range(src.shape[0]) if dark[r].all()]
    full_cols = [c for c in range(src.shape[1]) if dark[:, c].all()]
    print(f"dark texels: {int(dark.sum())} of {dark.size}, "
          f"full dark rows {full_rows}, full dark columns {full_cols} "
          "(none of either: no dressing joint, this is a flat face with "
          "scattered pits)")

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    print(f"segments: n={n} tolerance={tolerance}, "
          f"largest region {int(sizes.max())} texels of {sizes.sum()}")

    # The pit mask, straight from the art at its own pixel positions: no
    # lib.warp_labels here, this is a dressed face and the brief is
    # explicit that scoria_cut's layout is not warped. np.repeat is an
    # exact nearest upscale, never np.kron, matching the technique
    # default_stone_brick.py uses for its own straight mortar geometry.
    factor = lib.SIZE // src.shape[0]
    pit_hi = np.repeat(np.repeat(dark, factor, axis=0), factor, axis=1).astype(np.float32)

    max_dist = 3  # a shallow vesicle dimple, not a mortar groove
    dist = lib.distance_to_edge(pit_hi, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    pit_depth = 0.35  # a real but modest dip: this is a dressed face, not rough rubble
    layout = (0.5 - pit_depth) + pit_depth * t

    # Fine tooling marks from dressing the face, and a scatter of pores:
    # both texel scale, kept at pack()'s default fine_detail so they stay
    # grain rather than structure.
    tooling = lib.fbm(lib.SIZE, base_cells=48, octaves=3, seed=771, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=772), 1) * 0.04
    height = lib.normalise01(layout + tooling + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height (the pits gather dust and stay rough, the
    # face is what wears smooth) plus the source art's own fine shading
    # between its two matrix shades, upscaled at its own pixel positions
    # (no warp here either) so the mid tone variation the art draws becomes
    # smoothness spread rather than invented extra height.
    lum_hi = lib.upscale(lum)
    rough_noise = lib.fbm(lib.SIZE, base_cells=18, octaves=3, seed=773)
    smooth = 0.55 * height + 0.4 * rough_noise + 0.5 * (lum_hi - lum_hi.mean())
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 18
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
