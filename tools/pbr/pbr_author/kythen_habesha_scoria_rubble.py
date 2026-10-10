"""Hand authored LabPBR height and smoothness for kythen_habesha_scoria_rubble.

The 32 px art has only four grey shades, sd 0.048: 0.229 (39 percent of the
tile), 0.311 (13 percent), 0.327 (38 percent) and 0.339 (10 percent). It
segments (tolerance 0.05) into just seven dark regions carrying almost all
of the darkest shade, ranging from 12 to 175 texels, against 46 lighter
regions, the largest a single 257 texel blob. That is not the many-small-
pebble reading river_gravel gets from its own art: this is a few big,
irregularly shaped chunks of rock with a few big shadowed crevices between
them, exactly what lib.class_of reads back as "soil" rather than a graded
gravel bed, and exactly what the brief calls "loose lumps of scoria" rather
than soft dirt. The technique kept is still the gravel one (a gap group and
a dome group from a shade split, domed per region), because the art plainly
reads as lumps of stone and not as a smooth soil crumb; class_of's "soil"
is used for lib.pack and lib.check because that is the class the shader and
the ramp actually judge it against, and the surface is built to soil's
target band, not stone's or gravel's.

Because the lumps are large (up to sixteen source texels across) a single
distance-to-edge taper would leave their middles as flat plateaus, so each
gets its own low frequency crown, and vesicle-scale bump and pit noise on
top for scoria's own rough, bubbled surface. That noise is heavier than
river_gravel's: scoria is lighter and fuller of holes than a water worn
pebble, and the brief asks for lumps that are "rounded but not perfectly
smooth".
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_scoria_rubble"
CLS = lib.class_of(STEM, GAME)


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}, class_of reads {CLS}")

    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} "
          f"mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes (top 15):", sorted(sizes.tolist(), reverse=True)[:15])

    # 0.27 sits in the clean gap between the darkest shade (0.229, the
    # crevices) and the next one up (0.311, the lowest of the lump group).
    baseline = 0.08
    gap = region_lum <= 0.27
    dome = ~gap
    print(f"gap regions: {int(gap.sum())} of {n}, {int(sizes[gap].sum())} texels; "
          f"dome regions: {int(dome.sum())}, {int(sizes[dome].sum())} texels")
    dlo, dhi = region_lum[dome].min(), region_lum[dome].max()
    target = np.where(gap, baseline,
            0.55 + 0.35 * (region_lum - dlo) / max(dhi - dlo, 1e-6))

    # A wider warp than river_gravel's default: these lumps are craggy
    # chunks, not water rounded pebbles, so their silhouettes should read
    # less regular.
    labels_hi = lib.warp_labels(labels, amp=8.0, seed=217)
    edges = lib.region_edges(labels_hi)
    max_dist = 3  # a real crevice depth, steep enough to keep ao low
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    # A slow crown per lump so the biggest regions (up to sixteen source
    # texels across) round off instead of sitting as flat plateaus once the
    # narrow edge taper above has run its course.
    crown = lib.fbm(lib.SIZE, base_cells=6, octaves=2, seed=251) * 0.12
    layout = layout + crown * t

    # Vesicle scale bump and pit noise, heavier than a river pebble's: this
    # is light, bubbled scoria, not water smoothed stone.
    bump = lib.fbm(lib.SIZE, base_cells=16, octaves=3, seed=252, gain=0.55) * 0.10
    pit = lib.blur(lib.white_noise(lib.SIZE, seed=253), 1) * 0.06
    height = lib.normalise01(layout + bump + pit, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: crevices hold dust and stay rough, lump
    # tops wear smoother, with the material's own patchy variation on top.
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=254)
    smooth = 0.5 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 14
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
