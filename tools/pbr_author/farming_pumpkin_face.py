"""Hand authored height and smoothness for farming_pumpkin_face.

The ribbed shell farming_pumpkin_side.py builds (its rib_taper is imported
from there directly, read off that texture's own column profile, so the
ribs line up with the other three faces), with the jack o'lantern's face
cut into it. Thresholding this art's own shading at lum <= 0.30 finds the
carved shape cleanly: two triangular eyes near the top and a wide, jagged
mouth across rows 9 to 12, 23.8 percent of the tile, nothing scattered
outside those shapes. That mask is used as drawn (a nearest upscale, not a
warp) because a knife cut has the edge the artist actually drew, not a
rounded, organic one, and it becomes a real recess, well below the rib
shell, with only a narrow bevel softening its own edge.

farming_pumpkin_face_light.py reuses this same cut mask for its own
geometry (its own art washes the cut out with the candle's glow, so its
own dark texels do not trace the shape the way this face's do), because
the carving is the same hole in the same shell whether or not there is a
light behind it.
"""

import sys

import numpy as np

import lib
import farming_pumpkin_side as side

STEM = "farming_pumpkin_face"
CLS = "wood"
SIZE = lib.SIZE

GRAIN_SEED = side.GRAIN_SEED
PORES_SEED = side.PORES_SEED
CUT_LUM_THRESH = 0.30


def cut_mask_16():
    """The carved shape, straight off farming_pumpkin_face's own art."""
    face_src = lib.load_source("farming_pumpkin_face")
    lum = lib.luminance(face_src[..., :3])
    return lum <= CUT_LUM_THRESH


def cut_taper(max_dist=3):
    """1 inside the carved cut, 0 a few texels clear of it, at map size:
    the same distance_to_edge taper a masonry joint uses, just built from
    a cut region instead of a mortar line."""
    mask = cut_mask_16()
    mask_hi = np.repeat(np.repeat(mask, SIZE // 16, axis=0), SIZE // 16, axis=1)
    dist = lib.distance_to_edge(mask_hi.astype(np.float32), max_dist=max_dist)
    s = np.clip(dist / max_dist, 0.0, 1.0)
    s = s * s * (3 - 2 * s)
    return 1.0 - s, mask, mask_hi


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")

    rib_t, valley = side.rib_taper()
    ribs = 0.10 * (1.0 - rib_t) + 0.85 * rib_t

    cut_t, mask, mask_hi = cut_taper()
    print(f"cut texels: {int(mask.sum())} of 256 ({mask.mean() * 100:.1f}%)")

    cut_floor = 0.05
    layout = ribs * (1.0 - cut_t) + cut_floor * cut_t

    grain = lib.fbm(SIZE, base_cells=30, octaves=3, seed=GRAIN_SEED, gain=0.55) * 0.06
    pores = lib.blur(lib.white_noise(SIZE, seed=PORES_SEED), 1) * 0.03
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height; the cut interior is freshly exposed flesh,
    # rougher than the shell's own rind.
    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=103, gain=0.55)
    smooth = 0.55 * height + 0.5 * rough_noise - 0.2 * cut_t
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 17.0
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
