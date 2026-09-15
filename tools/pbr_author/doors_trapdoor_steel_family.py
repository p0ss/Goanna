"""Shared build for the steel trapdoor pair: doors_trapdoor_steel and
doors_trapdoor_steel_side.

Both are a riveted plate in the same five shades as the iron door: a dark
frame border, a mid tone plate and bright local peaks scattered over it
that read as individual rivet heads catching the light, not confined to
fixed columns the way the door's are. doors_trapdoor_steel cuts a dozen
small holes through the plate (alpha zero), a decorative perforation
rather than a grille. doors_trapdoor_steel_side is the plate's edge, a
band of the same shades running the width with no holes in it (its own
row 0 is a texel for texel match to its row 15, so the two ends of the
hinge side already agree without help from this script).
"""

import numpy as np

import lib

SIZE = lib.SIZE
HOLE_FLOOR = 0.05


def _base(lum16):
    lum01 = lib.normalise01(lum16, 1, 99)
    base = lib.upscale(lum01)
    narrow = lib.blur(base, 1)
    wide = lib.blur(base, 3)
    return narrow + 0.5 * (narrow - wide)


def _rivet_centres(lum16, alpha16, thresh=0.65):
    """A rivet is an opaque texel at least as bright as its four wrapped
    neighbours and above the threshold: a local peak, found from the art
    rather than placed on a made up grid."""
    h, w = lum16.shape
    centres = []
    for y in range(h):
        for x in range(w):
            if alpha16[y, x] < 0.5:
                continue
            v = lum16[y, x]
            if v < thresh:
                continue
            neigh = [lum16[(y + dy) % h, (x + dx) % w] for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1))]
            if v >= max(neigh):
                centres.append((y, x))
    return centres


def _dome_stamp(radius, amp, rim_frac=0.7, rim_depth=0.12):
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    r = np.sqrt(dx ** 2 + dy ** 2)
    dome = np.where(r <= radius, 0.5 * (1.0 + np.cos(np.pi * np.clip(r, 0, radius) / radius)), 0.0)
    rim_r0 = rim_frac * radius
    in_rim = (r > rim_r0) & (r <= radius)
    rim = np.zeros_like(dome)
    rim[in_rim] = -rim_depth * np.sin(np.pi * (r[in_rim] - rim_r0) / (radius - rim_r0))
    return (amp * (dome + rim)).astype(np.float32)


def _stamp_rivets(field, centres, h16, size, radius, amp, seed):
    rng = np.random.default_rng(seed)
    sy = size // h16
    stamp = _dome_stamp(radius, amp)
    for (y, x) in centres:
        cy = int((y + 0.5) * sy) + int(rng.integers(-1, 2))
        cx = int((x + 0.5) * sy) + int(rng.integers(-1, 2))
        ys = (np.arange(-radius, radius + 1) + cy) % size
        xs = (np.arange(-radius, radius + 1) + cx) % size
        idx = np.ix_(ys, xs)
        field[idx] = field[idx] + stamp
    return field


def build(stem, out_dir, seed, normal_strength, has_holes, rivet_amp=0.16, rivet_radius=5):
    src = lib.load_source(stem)
    rgb = src[..., :3]
    alpha = src[..., 3]
    lum = lib.luminance(rgb)
    h16 = lum.shape[0]

    base = _base(lum)
    centres = _rivet_centres(lum, alpha)
    print("%s: %d rivet centres" % (stem, len(centres)))
    height = _stamp_rivets(base, centres, h16, SIZE, rivet_radius, rivet_amp, seed)

    grain = lib.fbm(SIZE, base_cells=46, octaves=2, seed=seed + 5, gain=0.5) * 0.02
    height = height + grain

    if has_holes:
        alpha_soft = lib.blur(lib.upscale(alpha), 1)
        height = height * alpha_soft + HOLE_FLOOR * (1.0 - alpha_soft)
    height = lib.normalise01(height, 0.3, 99.7)

    variation = lib.fbm(SIZE, base_cells=28, octaves=2, seed=seed + 6, gain=0.5)
    smooth = 0.6 * height + 0.4 * (variation * 0.5 + 0.5)

    albedo = lib.upscale(src)
    m = lib.pack(stem, out_dir, albedo, height, smooth, "metal",
            normal_strength=normal_strength)
    return m


def report(stem, m):
    lines = lib.check(m, "metal")
    print("\n".join(lines))
    for k, v in m.items():
        print("  %s %.4f" % (k, v))
    return lines
