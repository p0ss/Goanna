"""Hand authored LabPBR height and smoothness for kythen_siku_melt_water.

The 32 px art (cultures/siku/materials.json: "mottle", base lead_water,
accent ice_deep, cells 9, surface.smooth 0.9) is "melt water standing on
the ice". lib.segments (tolerance 0.02) finds the same shape
kythen_siku_ice_family.py's own glacier_ice does off the same "mottle"
recipe: two dominant colour cells (498 and 441 texels of 1024) plus a
scatter of small fragments, the standing water's own colour banding
rather than a partition invented here.

lib.class_of reads "soil" (a level heuristic coincidence off the old
bake, not a claim that standing water is dirt), overridden to "ice": this
is water sitting still and smooth on top of ice, and lib.CLASS_SPEC has
no water entry of its own, but "ice" (high packed smoothness, dielectric
F0, real scattering) is the nearest thing this game's material table has
to a still, reflective liquid, the way kythen_siku_ice_family.py's own
four ices are built.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_siku_melt_water"
CLS = "ice"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    h, w = rgb.shape[:2]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("lib.class_of reads:", lib.class_of(STEM, GAME), "- overridden to ice, see module docstring")

    tolerance = 0.02
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance} top sizes {sorted(sizes.tolist(), reverse=True)[:6]}")

    scale = SIZE // h
    labels_hi = np.kron(labels, np.ones((scale, scale), dtype=int))
    edges = lib.region_edges(labels_hi)
    dist = lib.distance_to_edge(edges, max_dist=4)
    t = np.clip(dist / 4, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    lo, hi = float(region_lum.min()), float(region_lum.max())
    target = -1.0 + 2.0 * (region_lum - lo) / max(hi - lo, 1e-6)
    step = target[labels_hi]
    layout = lib.blur(step, 3)
    grain = lib.blur(lib.white_noise(SIZE, seed=261), 1)
    shape = layout + 0.08 * grain
    height = lib.band(shape, 0.04)  # nearly flat, standing water
    print(f"height sd {height.std():.4f}")

    # keep_mean=False to carry the recipe's own surface.smooth (0.9)
    # through directly, the same lever kythen_siku_ice_family.py's own
    # four stems use rather than trusting the class level.
    variation = lib.fbm(SIZE, base_cells=20, octaves=2, seed=262, gain=0.5)
    z = (variation - variation.mean()) / (variation.std() + 1e-6)
    zt = (t - t.mean()) / (t.std() + 1e-6)
    smooth = np.clip(0.90 + 0.07 * zt + 0.09 * z, 0.05, 0.95)
    print(f"pre pack smooth mean {smooth.mean():.4f} sd {smooth.std():.4f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 4.0
    keep_mean = False
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, keep_mean=keep_mean, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}, keep_mean={keep_mean}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    # tilt is expected to miss: still water is held nearly flat on
    # purpose, the same glassy face case kythen_siku_ice_family.py's own
    # clear_ice, glacier_ice and sea_ice miss and explain.
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
