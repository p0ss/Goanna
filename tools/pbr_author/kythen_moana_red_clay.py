"""Hand authored height and smoothness for kythen_moana_red_clay.

The 32 px art has four shades in a narrow 0.122 span, hue r-g positive
everywhere (0.13 to 0.22, a warm red throughout, no separate tint to split
on), so there is no colour boundary to read, only a brightness one. The
darkest shade (0.242, 14 percent of the tile) sits as a scatter of small,
irregular clusters rather than a single large patch, a fine shrinkage crack
network rather than clods. This is the same reading kythen_khmer_floodplain_
clay.py gives its own dried clay plate, and it is built the same way: a
tight band around a blurred, upscaled reading of the art's own brightness
for the nearly flat plate, and the darkest texels alone, warped for an
organic edge and cut straight down without blurring the mask itself, so the
crack keeps a real, steep walled trench even though the plate barely moves.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_red_clay"
CLS = "soil"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    hue_rg = rgb[..., 0] - rgb[..., 1]
    print(f"hue(r-g) min {hue_rg.min():.3f} max {hue_rg.max():.3f} (a steady warm red, no separate tint)")
    print("class_of reads:", lib.class_of(STEM, GAME))

    for tolerance in (0.03, 0.05):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        sizes = np.bincount(labels.ravel())
        print(f"segments at tolerance {tolerance}: n={n} sizes={sorted(sizes.tolist(), reverse=True)[:8]}")

    # The crack mask: the art's own darkest shade, warped for an organic
    # edge (natural cracking, not a drawn joint) but not blurred, so the
    # wall stays steep enough for the horizon based ambient occlusion to
    # see it.
    dark_thresh = lum.min() + 0.02
    dark_mask_native = (lum < dark_thresh).astype(int)
    frac = float(dark_mask_native.mean())
    print(f"dark texels under {dark_thresh:.3f}: {frac * 100:.1f}% of the art")
    crack_mask = lib.warp_labels(dark_mask_native, amp=2.0, seed=961)
    crack = crack_mask.astype(np.float32)

    # The plate: a broad sweep of the art's own brightness, the same
    # reasoning default_sand.py gives a surface with no drawn regions, plus
    # fine grain, held in a tight band since the plate itself is nearly
    # flat.
    sweep32 = lib.blur(lum, 1)
    sweep = lib.upscale(sweep32, smooth=True)
    sweep = lib.normalise01(sweep)
    grain = lib.fbm(SIZE, base_cells=55, octaves=2, seed=962, gain=0.5)
    dust = lib.blur(lib.white_noise(SIZE, seed=963), 1)
    flat = lib.normalise01(0.5 * sweep + 0.3 * grain + 0.2 * dust, 0.5, 99.5)
    flat_band_hw = 0.14
    flat = lib.band(flat, flat_band_hw)

    crack_depth = 0.55
    height = np.clip(flat - crack * crack_depth, 0.0, 1.0)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=24, octaves=3, seed=964, gain=0.55)
    # The plate wears smooth; the crack itself is a fresh, rougher break.
    smooth = 0.5 * (1.0 - crack) + 0.4 * variation - 0.15 * crack
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 20.0
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
