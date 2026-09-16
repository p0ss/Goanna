"""Hand authored height and smoothness for kythen_khmer_floodplain_clay.

The 32 px art has seven shades, its darkest (0.315) sitting in small and
mid sized patches (segments at tolerance 0.05: a 646 texel, 63 percent
background plus fragments from 12 to 37 texels, all at that one darkest
shade) against a lighter, gently mottled plate. That is dried floodplain
clay: a smooth, nearly flat surface broken by a network of fine shrinkage
cracks, not a crumb of clods. The two parts are built separately: the plate
is a tight band around a blurred, upscaled reading of the art's own
brightness (the same sweep default_sand.py uses for a broad, structureless
surface), and the cracks are the darkest texels alone, warped for an
organic edge and cut straight down without the crack mask's own blur, so
each crack keeps a real, steep walled trench even though the plate around
it barely moves. A soft blurred crack edge was tried first and left the
ambient occlusion at 0.5 to 0.8 regardless of depth or band width: the
horizon based occlusion needs a wall that rises within a texel or two, not
a gradual slope, so the mask is warped for shape but never blurred for
softness.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_floodplain_clay"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print("class:", CLS)

    for tolerance in (0.03, 0.05):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        sizes = np.bincount(labels.ravel())
        print(f"segments at tolerance {tolerance}: n={n} sizes={sorted(sizes.tolist(), reverse=True)[:8]}")

    # The crack mask: the art's own darkest shade, one crack fragment per
    # segments run above, warped for an organic edge (natural cracking, not
    # a drawn joint) but not blurred, so the wall stays steep enough for the
    # ambient occlusion to see it.
    dark_thresh = lum.min() + 0.02
    dark_mask_native = (lum < dark_thresh).astype(int)
    frac = float(dark_mask_native.mean())
    print(f"dark texels under {dark_thresh:.3f}: {frac * 100:.1f}% of the art")
    crack_mask = lib.warp_labels(dark_mask_native, amp=2.0, seed=41)
    crack = crack_mask.astype(np.float32)

    # The plate: a broad sweep of the art's own brightness, the same
    # reasoning default_sand.py gives for a surface with no drawn regions,
    # plus fine grain, held in a tight band since the plate itself is flat.
    sweep16 = lib.blur(lum, 1)
    sweep = lib.upscale(sweep16, smooth=True)
    sweep = lib.normalise01(sweep)
    grain = lib.fbm(SIZE, base_cells=60, octaves=2, seed=511, gain=0.5)
    dust = lib.blur(lib.white_noise(SIZE, seed=512), 1)
    flat = lib.normalise01(0.5 * sweep + 0.3 * grain + 0.2 * dust, 0.5, 99.5)
    flat_band_hw = 0.12
    flat = lib.band(flat, flat_band_hw)

    crack_depth = 0.6
    height = np.clip(flat - crack * crack_depth, 0.0, 1.0)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=24, octaves=3, seed=513, gain=0.55)
    # The plate wears smooth; the crack itself is a fresh, rough break.
    smooth = 0.5 * (1.0 - crack) + 0.4 * variation - 0.15 * crack
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 18.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength} flat_band_hw={flat_band_hw} crack_depth={crack_depth}")
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
