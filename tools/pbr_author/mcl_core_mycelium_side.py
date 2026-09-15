"""Hand authored height and smoothness for mcl_core_mycelium_side.

Row means split this art into three bands: rows 0 to 3 sit at 0.37 to 0.39,
the same range mcl_core_mycelium_top's own art sits in, a pale mycelium
mat. Rows 4 to 7 dip hard, down to 0.288 at row 6, drawn mostly in two
shades (0.238, 0.298) that are otherwise almost absent from the rest of
the texture, bar a texel or two of dither bleeding across into row 3 and
row 8: a dark undercut, the shadowed lip where the mat overhangs the soil.
Row means come back up over rows 8 to 15, sitting 0.32 to 0.38, on shades
that match default_dirt's own four (0.284, 0.322, 0.367, 0.418) almost
exactly, the same soil. So the brief's own reading is right: this is dirt
with a pale band along the top, and a shadow line is what joins them.

The dirt half of the map is built exactly the way default_dirt.py
builds its own height: lib.segments on the whole art, a target per region
from its own brightness, the narrow/wide blur unsharp layout, then lumps,
grit and pits noise at the same scale. The mat band reuses
mcl_core_mycelium_top's own bump scatter. A three way row label (mat,
undercut, dirt) goes through lib.warp_labels so the boundary between them
is irregular rather than a straight cut, and the blend weight between the
three fields comes from lib.blur on each label's own mask, which wraps: the
seam between row 255 (deep soil) and row 0 (the mat) gets exactly the same
soft treatment as every other join in the map, not a hand carved exception.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_mycelium_side"
CLS = "leaves"
SIZE = lib.SIZE


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def bump_stamp(radius, amp):
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    r = np.sqrt(dx ** 2 + dy ** 2)
    dome = np.where(r <= radius, 0.5 * (1.0 + np.cos(np.pi * r / max(radius, 1))), 0.0)
    return (amp * dome).astype(np.float32)


def scatter_bumps(size, guide, n, seed, radius_range):
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    radius = rng.integers(radius_range[0], radius_range[1] + 1, n)
    jitter = rng.uniform(0.8, 1.2, n)
    for i in range(n):
        local_guide = guide[cy[i], cx[i]]
        amp = jitter[i] * (0.35 + 0.95 * local_guide)
        r = int(radius[i])
        stamp = bump_stamp(r, amp)
        ys = (np.arange(-r, r + 1) + cy[i]) % size
        xs = (np.arange(-r, r + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
    return field


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("row means:", np.round(lum.mean(axis=1), 3).tolist())

    # --- the dirt body, exactly default_dirt.py's own method -----------
    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}, largest region {int(sizes.max())} texels")
    lo, hi = region_lum.min(), region_lum.max()
    target = 0.15 + 0.65 * (region_lum - lo) / max(hi - lo, 1e-6)

    dirt_labels_hi = lib.warp_labels(labels, seed=27)
    edges = lib.region_edges(dirt_labels_hi)
    dist = lib.distance_to_edge(edges, max_dist=4)
    t = np.clip(dist / 4.0, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    step = target[dirt_labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    dirt_layout = narrow + 1.1 * (narrow - wide)

    lumps = lib.fbm(SIZE, base_cells=10, octaves=3, seed=81, gain=0.55) * 0.30
    grit = lib.blur(lib.white_noise(SIZE, seed=82), 1) * 0.05
    pits = lib.blur(lib.white_noise(SIZE, seed=83), 2) * 0.04
    dirt_height = lib.normalise01(dirt_layout + lumps + grit + pits, 0.5, 99.5)
    print(f"dirt sub-height sd {dirt_height.std():.3f}")

    # --- the mycelium cap, mcl_core_mycelium_top.py's own method -------
    art_rgb = lib.upscale(src[..., :3])
    art_lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(art_lum, 2))
    bumps_fine = scatter_bumps(SIZE, guide, 1400, seed=511, radius_range=(2, 4))
    bumps_coarse = scatter_bumps(SIZE, guide, 400, seed=512, radius_range=(5, 8))
    bumps = np.maximum(bumps_fine, 0.7 * bumps_coarse)
    bumps = lib.normalise01(bumps)
    grain = lib.fbm(SIZE, base_cells=50, octaves=2, seed=513, gain=0.5)
    mat_height = lib.normalise01(0.68 * bumps + 0.20 * guide + 0.12 * (grain * 0.5 + 0.5))
    print(f"mat sub-height sd {mat_height.std():.3f}")

    # --- the three way row zone, warped and blurred so it wraps --------
    row_zone = np.zeros(16, dtype=int)
    row_zone[0:4] = 0    # mat
    row_zone[4:8] = 1    # undercut
    row_zone[8:16] = 2   # dirt
    zone_labels = np.broadcast_to(row_zone[:, None], (16, 16)).copy()
    zone_hi = lib.warp_labels(zone_labels, amp=5.0, seed=91)
    radius = 8
    w_mat = lib.blur((zone_hi == 0).astype(np.float32), radius)
    w_undercut = lib.blur((zone_hi == 1).astype(np.float32), radius)
    w_dirt = lib.blur((zone_hi == 2).astype(np.float32), radius)
    wsum = np.clip(w_mat + w_undercut + w_dirt, 1e-6, None)
    w_mat, w_undercut, w_dirt = w_mat / wsum, w_undercut / wsum, w_dirt / wsum
    print(f"zone weights mean: mat {w_mat.mean():.3f} undercut {w_undercut.mean():.3f} dirt {w_dirt.mean():.3f}")

    # The undercut is a groove: the shadowed lip beneath the mat, cut a
    # little below whichever of the two neighbouring fields it sits between.
    groove = 0.5 * (mat_height + dirt_height) - 0.16
    height = w_mat * mat_height + w_dirt * dirt_height + w_undercut * groove
    height = lib.normalise01(height, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height, blended the same way: the mat's own faint
    # sheen where it dominates, the dirt's own dusty variation where it
    # dominates, the groove reading rough like any recess.
    mat_variation = lib.fbm(SIZE, base_cells=22, octaves=3, seed=514, gain=0.55)
    mat_smooth = 0.5 + 0.13 * zscore(mat_height) + 0.09 * zscore(mat_variation)
    dirt_variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=84, gain=0.55)
    dirt_smooth = 0.45 * t + 0.55 * dirt_variation
    smooth = w_mat * mat_smooth + w_dirt * dirt_smooth + w_undercut * (0.3 * dirt_smooth)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 9.0
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
