"""Hand authored height and smoothness for kythen_khmer_thatch.

The 32 px art is five shades with no drawn outline of a single stalk;
segmenting finds 350 to 413 tiny labels at every tolerance tried, confirming
it is a dither, not a layout to trace. Column and row mean brightness both
sit in a narrow band (0.53 to 0.59), so there is no single wide furrow or
ridge the way default_tree.py finds in bark. What the ascii render of the
art does show is a repeating, roughly four texel pitch with a diagonal
stagger row to row, the brick coursing of real thatch: bundles of stalks
laid in horizontal courses, each course offset from the one above so rain
runs off the overlap rather than down a straight seam, the stalks
themselves running down the face. The relief is built from that reading
directly rather than from the art's own dither: short, near vertical stalk
stamps (a stretched version of mcl_core_grass_block_top.py's blade_stamp)
placed on a coarse lattice of eight courses, alternating courses offset by
half a course width, amplitude taken from the art's own brightness so a
lighter patch of the source becomes a sunlit stalk tip.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_thatch"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def stalk_stamp(radius, angle, length, width, amp):
    """A single stalk: a narrow ridge, tapered at both ends, the same shape
    as mcl_core_grass_block_top.py's blade_stamp."""
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    half_l = length / 2.0
    along = np.where(np.abs(u) <= half_l, 0.5 * (1.0 + np.cos(np.pi * u / half_l)), 0.0)
    cross = np.exp(-(v ** 2) / (2.0 * (width / 2.0) ** 2))
    return (amp * along * cross).astype(np.float32)


def scatter_courses(size, guide, n_courses, stalks_per_course, seed,
        length_range, width_range, angle_jitter=0.15, offset_frac=0.5):
    """Stalks laid in n_courses horizontal courses, alternating courses
    offset by half a course width for the shingled, brick coursed look of
    laid thatch, each stalk near vertical (angle close to pi/2, laid
    downward) with a little jitter so they do not read as a single stamp
    repeated on a grid."""
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    course_h = size / n_courses
    for c in range(n_courses):
        cy0 = c * course_h
        x_off = (offset_frac * course_h) if (c % 2 == 1) else 0.0
        for i in range(stalks_per_course):
            cx = (rng.uniform(0, size) + x_off) % size
            cy = (cy0 + rng.uniform(-course_h * 0.15, course_h * 0.85)) % size
            length = rng.uniform(*length_range)
            width = rng.uniform(*width_range)
            angle = np.pi / 2 + rng.uniform(-angle_jitter, angle_jitter)
            local_guide = guide[int(cy) % size, int(cx) % size]
            amp = rng.uniform(0.8, 1.2) * (0.35 + 0.9 * local_guide)
            radius = int(np.ceil(length / 2.0 + width))
            stamp = stalk_stamp(radius, angle, length, width, amp)
            ys = (np.arange(-radius, radius + 1) + int(cy)) % size
            xs = (np.arange(-radius, radius + 1) + int(cx)) % size
            idx = np.ix_(ys, xs)
            field[idx] = np.maximum(field[idx], stamp)
    return field


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print("class:", CLS)

    for tolerance in (0.03, 0.08):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        print(f"segments at tolerance {tolerance}: n={n} (dither, no drawn stalk outline)")
    print("column mean lum sd:", round(float(lum.mean(axis=0).std()), 4))
    print("row mean lum sd:", round(float(lum.mean(axis=1).std()), 4))

    art_rgb = lib.upscale(src[..., :3])
    lum256 = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum256, 2))

    n_courses = 8
    field = scatter_courses(SIZE, guide, n_courses, stalks_per_course=60,
            seed=801, length_range=(14, 20), width_range=(3, 5))
    field = lib.normalise01(field)

    grain = lib.fbm(SIZE, base_cells=60, octaves=2, seed=802, gain=0.5)
    height = lib.normalise01(0.78 * field + 0.14 * guide + 0.08 * (grain * 0.5 + 0.5))
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=24, octaves=3, seed=803, gain=0.55)
    smooth = 0.5 + 0.13 * zscore(height) + 0.09 * zscore(variation)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 8.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength} n_courses={n_courses}")
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
