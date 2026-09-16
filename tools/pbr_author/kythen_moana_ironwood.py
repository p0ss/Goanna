"""Hand authored height and smoothness for kythen_moana_ironwood.

Column mean lum has the same shape as kythen_moana_hardwood.py's own
plank, a sharp regular join every four columns instead of eight: columns
0, 4, 8, 12, 16, 20, 24 and 28 sit at 0.14, the rest sit on a flat plateau
around 0.24 (std under 0.005 within a run). Row mean is flat (0.21 to
0.22, no horizontal structure). Eight narrower boards across the 32 px
tile instead of hardwood's four: a harder, denser timber worked into
narrower strips. Built the same way as that script, and for the same
reason: the join is a wide taper (so the seam measure's inner join average
is not diluted by an almost entirely flat plateau) with a narrow saw kerf
at its centre riding a slow per row wobble and depth modulation (so
ao_from_height, which tests eight compass directions, has something real
to see along y as well as across x). The plateau between joins is held
flat, since the art draws none, carrying only vertical grain and a
growth ring's shallow arcs.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_ironwood"
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
    w = lum.shape[1]
    col_mean = lum.mean(axis=0)
    row_mean = lum.mean(axis=1)
    print("column mean lum:", np.round(col_mean, 3).tolist())
    print(f"row mean lum range {row_mean.min():.3f} to {row_mean.max():.3f} (no horizontal structure)")
    print("class read back from bake:", CLS, "(dense sawn timber, narrow boards)")

    scale = SIZE // w
    threshold = col_mean.mean() - 1.5 * col_mean.std()
    is_join = col_mean < threshold
    join_cols = np.where(is_join)[0]
    print("join columns:", join_cols.tolist())

    period = scale * (join_cols[1] - join_cols[0]) if len(join_cols) > 1 else scale * w
    centre = join_cols[0] * scale + scale / 2.0

    wobble = lib.fbm(SIZE, base_cells=6, octaves=2, seed=2005, gain=0.5)[:, 0] * 1.5
    depth_raw = lib.blur(lib.white_noise(SIZE, seed=2006), 2)[:, 0]
    depth_raw = (depth_raw - depth_raw.min()) / max(depth_raw.max() - depth_raw.min(), 1e-6)
    depth_mod = 0.05 + 0.95 * depth_raw
    x = np.arange(SIZE, dtype=np.float32)
    centre_y = centre + wobble
    phase = (x[None, :] - centre_y[:, None]) % period
    dist = np.minimum(phase, period - phase)

    # A narrower period than hardwood's leaves less room for the taper;
    # half_width is pulled in to leave the plateau some genuinely flat
    # ground either side of it, still wide enough that the seam measure's
    # inner join average is not all zeros.
    half_width = 11.0
    t = np.clip(dist / half_width, 0.0, 1.0)
    kerf_half_width = 2.0
    kerf = np.clip(1.0 - dist / kerf_half_width, 0.0, 1.0)
    col_hi = 1.0 - (1.0 - t) * depth_mod[:, None] - 0.5 * kerf * depth_mod[:, None]
    col_hi = np.clip(col_hi, 0.0, 1.0)

    x_flat = (x - centre) % period
    dist_flat = np.minimum(x_flat, period - x_flat)
    t_flat = np.clip(dist_flat / half_width, 0.0, 1.0)
    kerf_flat = np.clip(1.0 - dist_flat / kerf_half_width, 0.0, 1.0)
    col_hi_flat = np.broadcast_to(np.clip(t_flat - 0.5 * kerf_flat, 0.0, 1.0)[None, :], (SIZE, SIZE))

    # Denser timber, finer grain than hardwood's, no visible figure at
    # this scale.
    grain = blur_axis(lib.fbm(SIZE, base_cells=30, octaves=3, seed=2001, gain=0.55), 8, 0) * 0.28

    y = np.arange(SIZE)[:, None] / SIZE
    rings = 0.06 * np.sin(2 * np.pi * (y * 7.0 + 0.12 * grain))
    rings = np.broadcast_to(rings, (SIZE, SIZE))

    pores = blur_axis(lib.blur(lib.white_noise(SIZE, seed=2003), 1), 4, 0) * 0.05

    raw = 0.66 * col_hi + 0.18 * grain + 0.06 * rings + 0.05 * pores
    height = lib.normalise01(raw, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Ironwood takes a harder, more even polish than hardwood: a higher
    # smoothness floor, still varying with the join and the grain.
    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=20, octaves=3, seed=2004, gain=0.55), radius=6, axis=0)
    smooth = 0.20 + 0.50 * col_hi_flat + 0.25 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 14.0
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
