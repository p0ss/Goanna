"""Hand authored height and smoothness for mcl_core_sandstone_normal.

This is the side face: the 16 px art draws horizontal strata, not a mottled
slab or a set of separate stones. Row means make the bedding obvious (row 4
dips to 0.518, rows 5 to 6 rise to 0.70, row 7 dips to 0.487, row 8 rises to
0.696, row 10 dips to 0.502, row 11 rises to 0.680, row 15 dips to 0.502,
everything else sits 0.61 to 0.64). That is bedded rock: the dark rows are
the joints between deposits, the bright rows are the deposits themselves.

An earlier version of this script ran lib.segments over the art and domed
each region it found as its own bump. The art draws its strata as broken
dashes (a bed is not one flat shade across all sixteen columns), so that
approach domed each dash separately, and the bed lines came out as ledges
that stopped partway across the block, mortar that does not go all the way
down. Real sandstone strata run the full width of a block, so the height
here starts from each row's own mean luminance, a profile along y with no
column in it at all, and only after that stratum profile is built does the
art's own per texel pattern (the dashes) and the fine grain get added, as
small detail on top, never as a second set of domes.

The three sandstone faces (this one, _top, _bottom) share their fine grain
and pore noise, same base_cells and same seeds (61 and 62), so the block
reads as one stone rather than three unrelated surfaces.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_sandstone_normal"
CLS = "sand"
SIZE = lib.SIZE

# Shared across the three sandstone faces, so the grain reads as one stone.
GRAIN_SEED = 61
PORES_SEED = 62


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    row_lum = lum.mean(axis=1)
    print("row means:", np.round(row_lum, 3).tolist())

    # Target height per row, straight off its own brightness: the darkest
    # rows are the joints between beds and sit low, the brightest rows are
    # the harder, less weathered beds and sit high. This is the whole
    # stratum profile, no columns involved, so a bed spans the full width.
    lo, hi = row_lum.min(), row_lum.max()
    row_target = 0.15 + 0.70 * (row_lum - lo) / max(hi - lo, 1e-6)

    # Nearest upscale along y only, replicating each art row across the
    # texels it covers. 256 is an exact multiple of the art's 16 rows, so
    # this stays periodic on its own; tiling it across x gives the full
    # width band the brief asks for.
    step = np.repeat(row_target, SIZE // 16).astype(np.float32)
    profile = np.tile(step[:, None], (1, SIZE))

    # Round the steps into a stratum profile: a broad wrapped blur softens
    # every row boundary into a gently curved bed face. The undercut at
    # each joint (the underside of the bed above erodes further than the
    # joint's own floor) comes from pushing the falling edges of the
    # profile a little further down than the blur alone gives; the rising
    # edges, leaving a joint into the next bed up, are left as the plain
    # soft round, since real strata do not overhang on that side.
    rounded = lib.blur(profile, radius=3)
    fall = np.clip(rounded - np.roll(rounded, -1, axis=0), 0.0, None)
    fall = fall / max(fall.max(), 1e-6)
    stratum = rounded - 0.05 * fall

    # The dashes: within one bed row the art is not a flat shade, it breaks
    # into brighter and darker patches along x. That pattern is real, but
    # it is texture on the bed face, not a second layer of domes, so it is
    # added here as each texel's own small deviation from its row's mean,
    # at the same grain scale as the noise below rather than as a region.
    dash = (lum - lum.mean(axis=1, keepdims=True)).astype(np.float32)
    dash_hi = np.repeat(np.repeat(dash, SIZE // 16, axis=0), SIZE // 16, axis=1)
    dash_hi = lib.blur(dash_hi, radius=1)

    # Fine grain inside each bed: mineral grain a couple of texels across,
    # and sparser pores about a texel across, shared with the other two
    # sandstone faces.
    grain = lib.fbm(SIZE, base_cells=44, octaves=3, seed=GRAIN_SEED, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=PORES_SEED), 1) * 0.05
    height = lib.normalise01(stratum + dash_hi * 0.35 + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the bed lines gather dust and stay rough,
    # the harder bright beds are what wears smooth. The face's own patchy
    # variation rides on top; pack() moves the mean to the class level.
    rough_noise = lib.fbm(SIZE, base_cells=24, octaves=3, seed=73, gain=0.55)
    smooth = 0.5 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the art's own texel edges.
    albedo = lib.upscale(src[..., :3])

    normal_strength = 9.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength)
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
