"""Hand authored height and smoothness for kythen_mitteleuropa_orchard_and_nuts.

The 32 px art is RGBA with a real binary alpha (only 0.0 and 1.0, 90
percent opaque), the same shape of cut as kythen_mitteleuropa_cabbage.py's
own art: small gaps scattered through an otherwise solid canopy, not one
cut silhouette. The colour is different from the cabbage though, warmer
and more varied (orange brown bark and nut tones alongside a few green
patches rather than one steady olive), consistent with a mixed orchard
seen from above rather than a single crop, so it is read the same way, a
crop top canopy, but with rounder, larger clumps standing in for tree
crowns rather than cabbage's own broad leaf lobes. lib.class_of reads
"leaves" on its own, which fits.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_orchard_and_nuts"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def clump_stamp(radius, angle, length, width, amp):
    """A single canopy clump: rounder than a cabbage lobe, a raised half
    cosine along its length, gaussian across its width. The angle argument
    is clamped before the power so a negative cosine past the stamp's own
    edge never reaches a fractional power (numpy warns on that NaN even
    though it is discarded by the where below)."""
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    half_l = length / 2.0
    u_clamped = np.clip(u, -half_l, half_l)
    # cos of the clamped angle is mathematically 0 to 1, but floating
    # point can still land a shade under zero right at the tips, and a
    # negative base to a fractional power is a NaN numpy warns about even
    # though the where below discards it, so clip again after the cos.
    cos_along = np.clip(np.cos(0.5 * np.pi * u_clamped / half_l), 0.0, 1.0)
    along = np.where(np.abs(u) <= half_l, cos_along ** 0.7, 0.0)
    cross = np.exp(-(v ** 2) / (2.0 * (width / 2.0) ** 2))
    return (amp * along * cross).astype(np.float32)


def scatter_clumps(size, guide, n, seed, length_range, width_range):
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    angle = rng.uniform(0.0, np.pi, n)
    length = rng.uniform(*length_range, n)
    width = rng.uniform(*width_range, n)
    jitter = rng.uniform(0.8, 1.2, n)
    for i in range(n):
        local_guide = guide[cy[i], cx[i]]
        amp = jitter[i] * (0.4 + 0.9 * local_guide)
        radius = int(np.ceil(max(length[i], width[i]) / 2.0 + 1))
        stamp = clump_stamp(radius, angle[i], length[i], width[i], amp)
        ys = (np.arange(-radius, radius + 1) + cy[i]) % size
        xs = (np.arange(-radius, radius + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
    return field


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    alpha = src[..., 3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("alpha unique values:", sorted(set(np.round(alpha.ravel(), 3).tolist())))
    opaque_frac = float((alpha > 0.5).mean())
    print(f"opaque fraction {opaque_frac:.3f}, class: {CLS}")

    guide = lib.normalise01(lib.blur(lib.upscale(lum, smooth=True), 2))

    clumps_fine = scatter_clumps(SIZE, guide, 350, seed=941, length_range=(16, 26), width_range=(14, 22))
    clumps_coarse = scatter_clumps(SIZE, guide, 150, seed=942, length_range=(28, 42), width_range=(22, 32))
    clumps = np.maximum(clumps_fine, 0.8 * clumps_coarse)
    clumps = lib.normalise01(clumps)

    grain = lib.fbm(SIZE, base_cells=36, octaves=2, seed=943, gain=0.5)
    base = 0.68 * clumps + 0.20 * guide + 0.12 * (grain * 0.5 + 0.5)
    base = lib.normalise01(base)

    hole_native = (alpha < 0.5).astype(int)
    holes = lib.warp_labels(hole_native, amp=1.5, seed=944).astype(np.float32)
    print(f"hole fraction {holes.mean():.3f}")

    hole_depth = 0.45
    height = np.clip(base - holes * hole_depth, 0.0, 1.0)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=945, gain=0.55)
    smooth = 0.5 + 0.13 * (height - height.mean()) / (height.std() + 1e-6) \
            + 0.09 * (variation - variation.mean()) / (variation.std() + 1e-6)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src)

    normal_strength = 11.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength} hole_depth={hole_depth}")
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
