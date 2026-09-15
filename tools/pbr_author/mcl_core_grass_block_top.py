"""Hand authored height and smoothness for mcl_core_grass_block_top.

The art is a dithered mat of four grey levels with no regions to segment:
it is a photograph of grass seen from directly above, not a drawing of
individual blades, so there is nothing for lib.segments to find. What it is
telling us is where the light gets in. A lawn seen from above is a felt of
overlapping blade tips: the lighter texels are tips catching light and
standing proud, the darker texels are the gaps between blades where the eye
reaches down towards the soil. The relief here is built from that reading:
many short, narrow ridges at random angles, a finer scale than the art's own
16 px texel, standing taller where the art is lighter and shorter where it
is darker.
"""

import sys

import numpy as np

import lib

SIZE = lib.SIZE


def zscore(field):
    """Zero mean, unit spread, so components combine by a chosen weight
    instead of by whatever scale a noise function happened to come out at.
    Kept local because pack() clips smoothness to 0..1 before it re-centres
    the mean, so an unscaled, off-centre smooth field can lose its spread
    to that first clip rather than to the class level shift."""
    return (field - field.mean()) / (field.std() + 1e-6)


def blade_stamp(radius, angle, length, width, amp):
    """A single blade: a narrow ridge, raised cosine along its length so it
    tapers to nothing at both tips, gaussian across its width so it is
    rounded rather than a knife edge."""
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    half_l = length / 2.0
    along = np.where(np.abs(u) <= half_l, 0.5 * (1.0 + np.cos(np.pi * u / half_l)), 0.0)
    cross = np.exp(-(v ** 2) / (2.0 * (width / 2.0) ** 2))
    return (amp * along * cross).astype(np.float32)


def scatter_blades(size, guide, n, seed, length_range, width_range):
    """Places n blades at random positions and angles, taller where guide
    (the art's own brightness) is higher, combined by maximum so a tall
    blade is not drowned by the average of everything under it."""
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
        amp = jitter[i] * (0.35 + 0.95 * local_guide)
        radius = int(np.ceil(length[i] / 2.0 + width[i]))
        stamp = blade_stamp(radius, angle[i], length[i], width[i], amp)
        ys = (np.arange(-radius, radius + 1) + cy[i]) % size
        xs = (np.arange(-radius, radius + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
    return field


def build(out_dir):
    stem = "mcl_core_grass_block_top"
    src = lib.load_source(stem)
    print("source", stem, src.shape)
    lum16 = lib.luminance(src[..., :3])
    print("source luminance min %.3f mean %.3f max %.3f sd %.3f" %
          (lum16.min(), lum16.mean(), lum16.max(), lum16.std()))
    print("four grey levels, no distinct regions: a dithered mat, not a drawing")

    art_rgb = lib.upscale(src[..., :3])
    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 2))

    # Two blade populations, a finer and a coarser one, so the mat does not
    # read as one repeated stamp size.
    blades_fine = scatter_blades(SIZE, guide, 2600, seed=401, length_range=(6, 12), width_range=(2, 3))
    blades_coarse = scatter_blades(SIZE, guide, 900, seed=402, length_range=(12, 22), width_range=(3, 5))
    blades = np.maximum(blades_fine, 0.75 * blades_coarse)
    blades = lib.normalise01(blades)

    # Grain inside the mat itself: the fine crinkle of individual blade
    # surfaces, well under a blade's own width.
    grain = lib.fbm(SIZE, base_cells=48, octaves=2, seed=403, gain=0.5)

    height = 0.72 * blades + 0.18 * guide + 0.10 * (grain * 0.5 + 0.5)
    height = lib.normalise01(height)

    # Smoothness follows height: blade tips catch a slight wax sheen, the
    # gaps down to soil are matte. A second, unrelated noise gives it its
    # own texture rather than being a rescaled copy of height. Both are
    # z scored before combining and centred on 0.5 so the spread survives
    # pack()'s own 0..1 clip.
    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=404, gain=0.55)
    smooth = 0.5 + 0.13 * zscore(height) + 0.09 * zscore(variation)

    albedo = lib.upscale(src[..., :3])
    normal_strength = 5.5
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
