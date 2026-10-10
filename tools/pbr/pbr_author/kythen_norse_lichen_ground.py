"""Hand authored LabPBR height and smoothness for kythen_norse_lichen_ground,
rock with a crust of lichen growing over it in patches.

The 32 px art is a continuous mottle with real range (sd 0.085, 129
distinct shades), a photograph-like gradient rather than a drawing of
individual patches: lib.segments finds no clean regions even at a loose
tolerance (one 736 texel background plus a great many single and
double texel flecks). This is read the way mcl_core_grass_block_top.py
reads its own dithered mat: the brighter texels are lichen crust standing
a little proud of the rock, the darker texels are bare rock showing
through, a broad guide rather than individual stones.

The source PNG also carries a scattered, sub-25% alpha pattern (a texel
here and there at 0, no coherent shape lib.segments can find even at a
loose tolerance), noted here in case it matters elsewhere; it is not used
as a cut-out mask, since this is an ordinary opaque ground node and the
brief's own rule is that only a genuine cut-out keeps its alpha.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_lichen_ground"
CLS = "leaves"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    cls_read = lib.class_of(STEM, GAME)
    print(f"lib.class_of reads: {cls_read}, using {CLS}")
    labels, n = lib.segments(rgb, tolerance=0.1)
    sizes = np.bincount(labels.ravel())
    print(f"segments at tolerance 0.1: n={n}, sizes {sorted(sizes.tolist(), reverse=True)[:10]}")
    alpha = src[..., 3]
    print(f"alpha < 0.5 texels: {int((alpha < 0.5).sum())} of {alpha.size} "
          f"({(alpha < 0.5).mean()*100:.1f}%), not used (see docstring)")

    # A broad guide from the art's own brightness: lichen patches sit a
    # little higher, bare rock a little lower, no hard regions to key off.
    guide = lib.normalise01(lib.blur(lib.upscale(lum, smooth=True), 2))

    hollow_field = lib.blur(lib.white_noise(lib.SIZE, seed=241), 2)
    hollow_cut = float(np.percentile(hollow_field, 26))
    hollow_mask = hollow_field < hollow_cut
    dist = lib.distance_to_edge(hollow_mask.astype(np.float32), max_dist=3)
    t = np.clip(dist / 3, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    hollows = (t - 1.0) * 1.0

    crust = lib.fbm(lib.SIZE, base_cells=14, octaves=3, seed=242, gain=0.55) * 0.10
    grain = lib.blur(lib.white_noise(lib.SIZE, seed=243), 1) * 0.05
    height = lib.normalise01(0.3 * guide + hollows + crust + grain, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: lichen crust is dry and matte, rock underneath a touch
    # smoother where it shows through the lower, darker patches.
    variation = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=244, gain=0.55)
    smooth = 0.4 * (0.5 - guide) + 0.5 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 6
    height = lib.band(height, 0.36)
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
