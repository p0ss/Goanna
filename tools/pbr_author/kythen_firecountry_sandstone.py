"""Hand authored height and smoothness for kythen_firecountry_sandstone.

Row means over the 32 px art show the same signature as
mcl_core_sandstone_normal.py's own side face: bedded rock, not a mottled
slab or separate stones. Rows 0 to 3 sit high, 0.60 to 0.64, then it dips
through rows 4 to 25 (mostly 0.53 to 0.59, with a single sharp low point at
row 22, 0.534), and rows 26 to 31 recover to 0.59 to 0.61. That reads as
one broad, harder bed capping the top of the tile, a softer, more eroded
body below it, and a single joint line cut into that body at row 22. The
same per row profile technique as the Mineclonia worked example applies
here: the height comes from each row's own mean, continuous across the
tile's full width, with the art's own per texel pattern folded in on top
as detail, never as a second layer of domes.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_sandstone"
CLS = "sand"
SIZE = lib.SIZE
ART = 32

GRAIN_SEED = 161
PORES_SEED = 162


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    row_lum = lum.mean(axis=1)
    print("row means:", np.round(row_lum, 3).tolist())

    lo, hi = row_lum.min(), row_lum.max()
    row_target = 0.15 + 0.70 * (row_lum - lo) / max(hi - lo, 1e-6)

    step = np.repeat(row_target, SIZE // ART).astype(np.float32)
    profile = np.tile(step[:, None], (1, SIZE))

    rounded = lib.blur(profile, radius=3)
    fall = np.clip(rounded - np.roll(rounded, -1, axis=0), 0.0, None)
    fall = fall / max(fall.max(), 1e-6)
    stratum = rounded - 0.05 * fall

    dash = (lum - lum.mean(axis=1, keepdims=True)).astype(np.float32)
    dash_hi = np.repeat(np.repeat(dash, SIZE // ART, axis=0), SIZE // ART, axis=1)
    dash_hi = lib.blur(dash_hi, radius=1)

    grain = lib.fbm(SIZE, base_cells=44, octaves=3, seed=GRAIN_SEED, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=PORES_SEED), 1) * 0.05
    height = lib.normalise01(stratum + dash_hi * 0.35 + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=24, octaves=3, seed=173, gain=0.55)
    smooth = 0.5 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 9.0
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
