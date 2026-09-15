"""Hand authored height and smoothness for farming_pumpkin_top.

Two features, both straight off this texture's own art. A small, sharply
darker cluster (lum <= 0.28, 3.1 percent of the tile) sits almost exactly
at the tile's centre (centroid row 6.75, column 7.1 of 16): the stem scar,
carved as a real pit rather than a shaded patch. The rest of the face is
the ends of the same four ribs farming_pumpkin_side.py finds running down
the sides, seen end on from above, so they read as four wedges radiating
from the centre rather than four vertical bands: the same groove columns
that texture finds (0, 4, 8 and 12 of 16, an even quarter turn apart)
become four grooves at 0, 90, 180 and 270 degrees around the centre here,
built with the same distance_to_edge and wobble technique, just measured
in angle instead of in x.
"""

import sys

import numpy as np

import lib
import farming_pumpkin_side as side

STEM = "farming_pumpkin_top"
CLS = "wood"
SIZE = lib.SIZE

GRAIN_SEED = side.GRAIN_SEED
PORES_SEED = side.PORES_SEED
STEM_LUM_THRESH = 0.28


def radial_rib_taper(valley, max_dist=8):
    """The same rib grooves as farming_pumpkin_side.py's own rib_taper,
    carried around the centre by angle instead of laid out along x, so the
    top reads as the same four ribs seen end on."""
    cy = cx = (SIZE - 1) / 2.0
    yy, xx = np.mgrid[0:SIZE, 0:SIZE]
    theta_frac = (np.arctan2(yy - cy, xx - cx) / (2.0 * np.pi)) % 1.0
    col_idx = np.floor(theta_frac * 16).astype(int) % 16
    groove_hi = np.isin(col_idx, valley)
    dist = lib.distance_to_edge(groove_hi.astype(np.float32), max_dist=max_dist)
    wobble = lib.fbm(SIZE, base_cells=48, octaves=2, seed=105) * (max_dist * 0.5)
    dist = np.where(groove_hi, 0.0, np.clip(dist + wobble, 0.0, max_dist))
    t = np.clip(dist / max_dist, 0.0, 1.0)
    return t * t * (3 - 2 * t)


def stem_taper(max_dist=4):
    top_src = lib.load_source(STEM)
    lum = lib.luminance(top_src[..., :3])
    mask = lum <= STEM_LUM_THRESH
    mask_hi = np.repeat(np.repeat(mask, SIZE // 16, axis=0), SIZE // 16, axis=1)
    dist = lib.distance_to_edge(mask_hi.astype(np.float32), max_dist=max_dist)
    s = np.clip(dist / max_dist, 0.0, 1.0)
    s = s * s * (3 - 2 * s)
    return 1.0 - s, mask


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")

    _, valley = side.rib_taper()
    print("valley columns (shared with the side face):", valley)
    rib_t = radial_rib_taper(valley)
    ribs = 0.15 * (1.0 - rib_t) + 0.75 * rib_t

    stem_t, stem_mask = stem_taper()
    print(f"stem texels: {int(stem_mask.sum())} of 256")
    stem_floor = 0.05
    layout = ribs * (1.0 - stem_t) + stem_floor * stem_t

    grain = lib.fbm(SIZE, base_cells=30, octaves=3, seed=GRAIN_SEED, gain=0.55) * 0.06
    pores = lib.blur(lib.white_noise(SIZE, seed=PORES_SEED), 1) * 0.03
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=103, gain=0.55)
    smooth = 0.55 * height + 0.5 * rough_noise - 0.2 * stem_t
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 15.0
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
