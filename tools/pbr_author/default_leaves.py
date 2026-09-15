"""Hand authored height and smoothness for default_leaves.

The art is the ordinary oak canopy: a per-texel dither of five grey levels
with 29 percent of its texels punched to alpha zero, wider gaps than
mcl_core_leaves_big_oak's own 18 percent, so this canopy reads sparser and
more broken up. It is the same idea as that worked example even so: broad
overlapping lobes, no drawn outline of a single leaf to segment, so the
relief is built the way the art was, from many domes scattered so they
overlap, each standing taller where the art is lighter and lower where it
is darker, with a faint midrib and a shallow drop at its own rim. The alpha
holes are gaps through the whole canopy, not dim lobes, so they are carved
to the deepest points on the map regardless of what lobe would otherwise
sit there.
"""

import sys

import numpy as np

import lib

SIZE = lib.SIZE


def zscore(field):
    """Zero mean, unit spread, so components combine by a chosen weight
    instead of by whatever scale a noise function happened to come out at."""
    return (field - field.mean()) / (field.std() + 1e-6)


def lobe_stamp(radius, angle, amp, rim_frac=0.80, rim_depth=0.10,
        midrib_amp=0.20, midrib_sigma_frac=0.24):
    """A gentle dome (raised cosine, so it meets zero slope at its own rim),
    a raised midrib along a random axis through the centre, and a shallow
    groove just inside the rim where one lobe gives way to the next."""
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    r = np.sqrt(dx ** 2 + dy ** 2)
    dome = np.where(r <= radius, 0.5 * (1.0 + np.cos(np.pi * np.clip(r, 0, radius) / radius)), 0.0)
    rim_r0 = rim_frac * radius
    in_rim = (r > rim_r0) & (r <= radius)
    rim = np.zeros_like(dome)
    rim[in_rim] = -rim_depth * np.sin(np.pi * (r[in_rim] - rim_r0) / (radius - rim_r0))
    ca, sa = np.cos(angle), np.sin(angle)
    v = -dx * sa + dy * ca
    sigma = midrib_sigma_frac * radius
    midrib = midrib_amp * np.exp(-(v ** 2) / (2.0 * sigma ** 2)) * dome
    return (amp * (dome + rim + midrib)).astype(np.float32)


def scatter_lobes(size, guide, n, seed, radius_range):
    """Places n lobes at random positions, taller where guide (the art's
    own brightness) is higher, combined by maximum so a proud lobe is not
    averaged away by whatever else overlaps it."""
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    angle = rng.uniform(0.0, np.pi, n)
    radius = rng.integers(radius_range[0], radius_range[1] + 1, n)
    jitter = rng.uniform(0.85, 1.15, n)
    for i in range(n):
        local_guide = guide[cy[i], cx[i]]
        amp = jitter[i] * (0.4 + 0.9 * local_guide)
        stamp = lobe_stamp(int(radius[i]), angle[i], amp)
        r = int(radius[i])
        ys = (np.arange(-r, r + 1) + cy[i]) % size
        xs = (np.arange(-r, r + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
    return field


def build(out_dir):
    stem = "default_leaves"
    src = lib.load_source(stem)
    print("source", stem, src.shape)
    lum16 = lib.luminance(src[..., :3])
    alpha16 = src[..., 3]
    print("source luminance min %.3f mean %.3f max %.3f sd %.3f" %
          (lum16.min(), lum16.mean(), lum16.max(), lum16.std()))
    print("alpha: %d of 256 texels transparent (%.0f%%)" %
          ((alpha16 < 0.5).sum(), 100.0 * (alpha16 < 0.5).mean()))

    art_rgb = lib.upscale(src[..., :3])
    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 2))

    alpha256 = lib.upscale(src[..., 3])
    alpha_soft = lib.blur(alpha256, 2)

    # Bigger, sparser gaps than big_oak's own art (29 against 18 percent),
    # so the lobes get a touch more radius: a more open canopy is made of
    # bigger visible leaves, not the same leaves with more sky between.
    lobes_fine = scatter_lobes(SIZE, guide, 620, seed=601, radius_range=(7, 10))
    lobes_coarse = scatter_lobes(SIZE, guide, 230, seed=602, radius_range=(11, 17))
    lobes = np.maximum(lobes_fine, 0.8 * lobes_coarse)
    lobes = lib.normalise01(lobes)

    # Fine cuticle grain on the lobe faces, well under a lobe's own size.
    grain = lib.fbm(SIZE, base_cells=40, octaves=2, seed=603, gain=0.5)

    canopy = lib.normalise01(0.82 * lobes + 0.18 * guide + 0.08 * (grain * 0.5 + 0.5))

    # The holes go all the way down regardless of what lobe would otherwise
    # be there: a hole is a gap through the whole canopy, not a dim lobe.
    hole_floor = 0.03
    height = canopy * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)

    # Smoothness follows height (lobe faces smoother than the rim drops and
    # holes), plus its own independent variation. Both z scored and centred
    # on 0.5 so the spread survives pack()'s own 0..1 clip.
    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=604, gain=0.55)
    smooth = 0.5 + 0.12 * zscore(height) + 0.09 * zscore(variation)

    albedo = lib.upscale(src)
    normal_strength = 9.4
    metrics = lib.pack(stem, out_dir, albedo, height, smooth, "leaves",
                        normal_strength=normal_strength)
    lines = lib.check(metrics, "leaves")
    print("normal_strength", normal_strength)
    for k, v in metrics.items():
        print("  %s %.4f" % (k, v))
    print("\n".join(lines))
    preview_path = out_dir.rstrip("/") + "/" + stem + "_preview.png"
    lib.preview(out_dir, stem, preview_path)
    print("preview", preview_path)
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = build(out_dir)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
