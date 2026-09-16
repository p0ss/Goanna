"""Hand authored LabPBR height and smoothness for kythen_siku_blubber.

The 32 px art (cultures/siku/materials.json: "mottle", base blubber_yellow,
accent bone_white, cells 11) is "blubber and rendered oil", three shades
0.016 apart, near flat, no drawn region to segment. Read the same way
kythen_siku_skin_family.py's own hides are, a smoothly upscaled guide from
the art's own mottling plus fine grain, held in a narrow band: soft fat,
nearly flat, matte to slightly greasy rather than glossy, class "leaves"
(lib.class_of's own read, a plausible one, fat scatters light the way a
leaf does).
"""

import sys

import lib

GAME = "kythen"
STEM = "kythen_siku_blubber"
CLS = "leaves"
SIZE = lib.SIZE


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    lo, hi = float(lum.min()), float(lum.max())
    norm_lum = (lum - lo) / max(hi - lo, 1e-6)
    print(f"lum min {lo:.3f} max {hi:.3f} mean {lum.mean():.3f}")
    print("lib.class_of reads:", lib.class_of(STEM, GAME))

    guide = lib.upscale(norm_lum, smooth=True)
    guide = lib.blur(guide, 3)

    grain = lib.blur(lib.white_noise(SIZE, seed=151), 1)
    fine = lib.fbm(SIZE, base_cells=30, octaves=2, seed=152, gain=0.5)
    shape = 0.5 * (guide - 0.5) + 0.35 * fine + 0.15 * grain
    height = lib.band(shape, 0.07)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=36, octaves=2, seed=153, gain=0.5)
    smooth = 0.15 * zscore(shape) + 0.35 * zscore(variation)
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 3.5
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
