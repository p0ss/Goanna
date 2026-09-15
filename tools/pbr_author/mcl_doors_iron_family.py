"""Shared build for the iron door family: mcl_doors_door_iron_lower,
mcl_doors_door_iron_upper, mcl_doors_door_iron_side_lower and
mcl_doors_door_iron_side_upper.

The art is a riveted plate already shaded as one: four columns of bright
peaks (source columns 1, 3, 12 and 14, mirrored left and right) climb and
dip row by row, each local peak a rivet catching the light; two bands of
rows sit visibly darker than their neighbours (rows 5 to 6 and 13 to 14 on
the lower half), a welded seam running the plate's width; the outer
columns are darker again, the door's own frame. mcl_doors_door_iron_upper
cuts a small four slot grille through the plate (alpha zero). The source
art for the side textures is, texel for texel, the same drawing as the
front (mcl_doors_door_iron_side_lower is a byte identical file to
mcl_doors_door_iron_lower; side_upper has the same shading and the same
alpha mask as upper, only the colour behind the punched out grille
differs), so one build serves all four: the relief is read from the
plate's own shading, not invented separately for a face that draws
nothing different.
"""

import numpy as np

import lib

SIZE = lib.SIZE
RIVET_COLS = (1, 3, 12, 14)
HOLE_FLOOR = 0.05


def _base_plate(lum16):
    # The art is already an AO pass over a riveted plate: bright is a
    # rivet or a high point, dark is a seam or the frame's own recess, so
    # the base relief follows the luminance percentile directly.
    lum01 = lib.normalise01(lum16, 1, 99)
    base = lib.upscale(lum01)
    narrow = lib.blur(base, 1)
    wide = lib.blur(base, 3)
    return narrow + 0.5 * (narrow - wide)


def _seam_rows(lum16, alpha16):
    h = lum16.shape[0]
    row_mean = np.array([lum16[y][alpha16[y] > 0.5].mean() if (alpha16[y] > 0.5).any() else np.nan
            for y in range(h)])
    valid = row_mean[~np.isnan(row_mean)]
    thresh = valid.mean() - 0.05
    return np.nan_to_num(row_mean, nan=1.0) < thresh


def _rivet_centres(lum16, alpha16):
    """A rivet is a texel in one of the known rivet columns, opaque,
    brighter than its own row's plate level and at least as bright as its
    neighbours above and below (wrapped): one dome per local peak, found
    from the art rather than placed on a made up grid."""
    h = lum16.shape[0]
    centres = []
    for c in RIVET_COLS:
        for y in range(h):
            if alpha16[y, c] < 0.5:
                continue
            v = lum16[y, c]
            up = lum16[(y - 1) % h, c]
            down = lum16[(y + 1) % h, c]
            if v >= 0.66 and v >= up and v >= down:
                centres.append((y, c))
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
    for (y, c) in centres:
        cy = int((y + 0.5) * sy) + int(rng.integers(-1, 2))
        cx = int((c + 0.5) * sy) + int(rng.integers(-1, 2))
        ys = (np.arange(-radius, radius + 1) + cy) % size
        xs = (np.arange(-radius, radius + 1) + cx) % size
        idx = np.ix_(ys, xs)
        field[idx] = field[idx] + stamp
    return field


def build(stem, out_dir, seed, normal_strength, rivet_amp=0.28, rivet_radius=7, seam_depth=0.10):
    src = lib.load_source(stem)
    rgb = src[..., :3]
    alpha = src[..., 3]
    lum = lib.luminance(rgb)
    h16 = lum.shape[0]
    print("%s: row means %s" % (stem, np.round(
            [lum[y][alpha[y] > 0.5].mean() if (alpha[y] > 0.5).any() else -1.0 for y in range(h16)], 3)))

    base = _base_plate(lum)

    seam_mask16 = _seam_rows(lum, alpha)
    print("%s: seam rows %s" % (stem, np.where(seam_mask16)[0].tolist()))
    seam_full = np.repeat(seam_mask16.astype(np.float32), SIZE // h16)
    seam_soft = lib.blur(np.broadcast_to(seam_full[:, None], (SIZE, SIZE)).copy(), 2)
    height = base - seam_depth * seam_soft

    centres = _rivet_centres(lum, alpha)
    print("%s: %d rivet centres" % (stem, len(centres)))
    height = _stamp_rivets(height, centres, h16, SIZE, rivet_radius, rivet_amp, seed)

    # Fine brushed steel structure, far under a rivet's own size.
    grain = lib.fbm(SIZE, base_cells=48, octaves=2, seed=seed + 5, gain=0.5) * 0.02
    height = height + grain

    alpha_soft = lib.blur(lib.upscale(alpha), 1)
    height = height * alpha_soft + HOLE_FLOOR * (1.0 - alpha_soft)
    height = lib.normalise01(height, 0.3, 99.7)

    # Smoothness: the plate wears smooth, the seams and the rivet shadows
    # stay duller, and brushed steel carries its own fine variation.
    variation = lib.fbm(SIZE, base_cells=30, octaves=2, seed=seed + 6, gain=0.5)
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
