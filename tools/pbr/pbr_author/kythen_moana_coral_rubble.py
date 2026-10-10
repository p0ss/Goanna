"""Hand authored height and smoothness for kythen_moana_coral_rubble.

The 32 px art has luminance 0.622 to 0.880, sd 0.067, seven shades with no
clean gap splitting a shadow group from a lit group the way
kythen_moana_coral_gravel's own gravel does: the dominant shade (0.725, 49
percent of the tile) sits in the middle of the range, not at either end.
lib.segments (tolerance 0.03) finds 163 regions with a graduated spread of
sizes (322, 85, 72, 53, 36...), not a many-small-pebble reading: a few
sizeable, irregularly shaped chunks of broken coral rather than a graded
bed, the reading kythen_habesha_basalt_country.py gives its own rock face.
class_of reads soil, in line with kythen_habesha_scoria_rubble.py's own
"loose lumps" reasoning; this is angular rubble, coarser and larger than
the gravel, so it is built the basalt_country way, each chunk's own target
height off its own brightness with a low frequency crown, but scaled to
soil's shallower tilt band rather than a rock face's.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_coral_rubble"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print(f"lib.class_of reads: {CLS}")

    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}, sizes {sorted(sizes.tolist(), reverse=True)[:10]}")

    baseline = 0.10
    lo, hi = region_lum.min(), region_lum.max()
    target = 0.55 + 0.40 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=6.0, seed=841)
    edges = lib.region_edges(labels_hi)
    max_dist = 4  # a real gap between chunks, narrow relative to their size
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    wobble = lib.fbm(SIZE, base_cells=30, octaves=2, seed=842) * 1.0
    dist = np.clip(dist + wobble, 0.0, max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = baseline + (target[labels_hi] - baseline) * t

    # Coral rubble's own knobbly, pitted surface, isotropic like basalt's
    # vesicles since a broken coral chunk has no preferred grain direction.
    knobbles = lib.fbm(SIZE, base_cells=18, octaves=3, seed=843, gain=0.55) * 0.22

    grit = lib.fbm(SIZE, base_cells=44, octaves=3, seed=844, gain=0.55) * 0.06
    pores = lib.blur(lib.white_noise(SIZE, seed=845), 1) * 0.05
    pit_field = lib.blur(lib.white_noise(SIZE, seed=846), 1)
    pit_cut = float(np.percentile(pit_field, 1.0))
    deep_pit = np.where(pit_field < pit_cut, (pit_field - pit_cut) * 8.0, 0.0)

    height = lib.normalise01(layout + knobbles + grit + pores + deep_pit, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=847)
    smooth = 0.5 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 8.0
    # Held in a band scaled to soil's shallower depth: basalt_country's own
    # full strength suits a rock face, not this soil classed rubble.
    height = lib.band(height, 0.30)
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
