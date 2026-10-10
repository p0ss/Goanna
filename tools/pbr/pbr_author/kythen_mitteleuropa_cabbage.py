"""Hand authored height and smoothness for kythen_mitteleuropa_cabbage.

The 32 px art is RGBA with a real binary alpha (checked: only 0.0 and 1.0
appear, 88 percent of the tile opaque), scattered as small gaps rather than
one cut silhouette, so this is a crop top seen from directly above: broad
olive green cabbage leaves overlapping into a canopy, with small punched
through gaps where the light reaches down between them. lib.class_of reads
"leaves" on its own, which fits. The relief is built from rounded lobe
stamps, broader and shorter than a grass blade, scattered denser and
taller where the art is lighter, with the alpha gaps carved down as real
holes so the wall around each one is sharp: the same reasoning the soil
scripts in this batch use for their own small sharp features, and here it
doubles as the true shape of the art's own cut.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_cabbage"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def lobe_stamp(radius, angle, length, width, amp):
    """A single cabbage leaf lobe: broader and shorter than a grass blade,
    a raised half cosine along its length, gaussian across its width."""
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    half_l = length / 2.0
    # Clamp before the power, not after: cos of the raw u can go negative
    # past half_l, and a negative base to a fractional power is a NaN
    # numpy warns about even though np.where later discards it. Floating
    # point can still land a shade under zero right at the clamped tips,
    # so the cosine itself is clipped again before the power.
    u_clamped = np.clip(u, -half_l, half_l)
    cos_along = np.clip(np.cos(0.5 * np.pi * u_clamped / half_l), 0.0, 1.0)
    along = np.where(np.abs(u) <= half_l, cos_along ** 0.7, 0.0)
    cross = np.exp(-(v ** 2) / (2.0 * (width / 2.0) ** 2))
    return (amp * along * cross).astype(np.float32)


def scatter_lobes(size, guide, n, seed, length_range, width_range):
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
        stamp = lobe_stamp(radius, angle[i], length[i], width[i], amp)
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

    lobes_fine = scatter_lobes(SIZE, guide, 500, seed=931, length_range=(14, 22), width_range=(10, 16))
    lobes_coarse = scatter_lobes(SIZE, guide, 220, seed=932, length_range=(24, 36), width_range=(16, 24))
    lobes = np.maximum(lobes_fine, 0.8 * lobes_coarse)
    lobes = lib.normalise01(lobes)

    grain = lib.fbm(SIZE, base_cells=40, octaves=2, seed=933, gain=0.5)
    base = 0.70 * lobes + 0.18 * guide + 0.12 * (grain * 0.5 + 0.5)
    base = lib.normalise01(base)

    # The art's own alpha holes, warped for an organic edge but not
    # blurred, carved down for real: a gap in the canopy is a real gap,
    # not a shading trick.
    hole_native = (alpha < 0.5).astype(int)
    holes = lib.warp_labels(hole_native, amp=1.5, seed=934).astype(np.float32)
    print(f"hole fraction {holes.mean():.3f}")

    hole_depth = 0.45
    height = np.clip(base - holes * hole_depth, 0.0, 1.0)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=935, gain=0.55)
    smooth = 0.5 + 0.13 * (height - height.mean()) / (height.std() + 1e-6) \
            + 0.09 * (variation - variation.mean()) / (variation.std() + 1e-6)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Alpha kept: this is a real cut-out, small gaps punched through the
    # canopy, not a shading device.
    albedo = lib.upscale(src)

    normal_strength = 12.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength} hole_depth={hole_depth}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    lines.append("note leaves class is not jointed, ao_min is uncapped by lib.check; "
            "kept low anyway (%.2f) by the holes' own sharp walls" % m["ao_min"])
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
