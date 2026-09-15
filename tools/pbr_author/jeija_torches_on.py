"""Hand authored height and smoothness for jeija_torches_on.

A lit redstone torch. Most of the 16 px tile is a real gap (alpha zero);
the drawn torch is four bands of texel, told apart by their own colour
rather than a layout invented here: a warm orange core two texels wide at
rows 6 and 7 (the flame, R well above G and B), a neutral grey rim around
it at rows 5 to 8 (R equal to G equal to B, the ash the flame sits in), a
second neutral grey band at row 10, four texels wide where the stick
above and below it is only two (the binding wrapped around the stick,
bulging past it), and a warm brown stick two texels wide everywhere else
opaque (R above G above B, real wood, not the flame's neat R over flat
G equals B).

The flame texels carry emission, brightest at the core and fading through
the ash rim to nothing; nothing else on the torch glows.
"""

import sys

import numpy as np

import lib

STEM = "jeija_torches_on"
CLS = "wood"
SIZE = lib.SIZE
SEED = 9100
NORMAL_STRENGTH = 55.0
HOLE_FLOOR = 0.02


def main(out_dir):
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    alpha = src[..., 3]
    opaque = alpha > 0.5
    warm = rgb[..., 0] - rgb[..., 1]  # R - G: near zero for grey, high for orange
    core16 = opaque & (warm > 0.20)
    wood16 = opaque & (warm > 0.03) & (warm <= 0.20)
    ash16 = opaque & ~core16 & ~wood16
    print("%s: %d core, %d wood, %d ash, %d transparent" % (
            STEM, core16.sum(), wood16.sum(), ash16.sum(), (~opaque).sum()))

    target16 = np.zeros(alpha.shape, dtype=np.float32)
    target16[ash16] = 0.55
    target16[core16] = 0.92
    target16[wood16] = 0.42
    base = lib.upscale(target16)
    narrow = lib.blur(base, 2)
    wide = lib.blur(base, 4)
    height = narrow + 0.4 * (narrow - wide)  # round the stick and the head off

    grain = lib.fbm(SIZE, base_cells=30, octaves=2, seed=SEED, gain=0.5) * 0.03
    height = height + grain

    alpha_soft = lib.blur(lib.upscale(alpha), 1)
    height = height * alpha_soft + HOLE_FLOOR * (1.0 - alpha_soft)
    height = lib.normalise01(height, 0.3, 99.7)

    variation = lib.fbm(SIZE, base_cells=20, octaves=2, seed=SEED + 1, gain=0.5)
    smooth = 0.5 * height + 0.5 * (variation * 0.5 + 0.5)

    # Emission: full strength at the core, fading through the ash rim,
    # nothing on the stick or the background.
    emission16 = np.zeros(alpha.shape, dtype=np.float32)
    emission16[core16] = np.clip((warm[core16] - 0.20) / 0.25 + 0.6, 0.0, 1.0)
    emission16[ash16] = 0.15
    emission = lib.blur(lib.upscale(emission16), 1) * alpha_soft

    albedo = lib.upscale(src)
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=NORMAL_STRENGTH, emission=emission)
    print("normal_strength", NORMAL_STRENGTH)
    for k, v in m.items():
        print("  %s %.4f" % (k, v))
    lines = lib.check(m, CLS)
    print("\n".join(lines))
    # tilt is measured over the whole 256 map; the torch draws on well
    # under a tenth of it, the rest a flat, transparent floor, so the mean
    # sits far below the wood band no matter how the drawn texels are
    # shaped. See the docstring for how little of the tile is opaque.
    print("note %d of 256 source texels are opaque (%.0f%%); the tilt mean is diluted by the rest" % (
            opaque.sum(), 100.0 * opaque.mean()))
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main(out_dir)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
