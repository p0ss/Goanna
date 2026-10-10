"""Hand authored LabPBR height and smoothness for kythen_siku_lichen_crust.

The 32 px art (cultures/siku/materials.json: "mat", base lichen colours,
cover implicitly high) is another real cut-out like
kythen_siku_frost_boil.py's own frost boil, but thinner at the rim rather
than sparse by holes: the recipe's own note says so directly, "under
about 0.75 cover the holes become the landmark", and 92.6 percent of this
tile sits above alpha 0.5, a near solid crust with only its own edges
fading rather than a scatter of gaps. Read as a growth layer over rock,
lib.class_of's own "leaves" (a lichen crust does scatter light through
its own thin body, an SSS read that fits), the same class
kythen_siku_skin_family.py settles its own hides on.
"""

import sys

import lib

GAME = "kythen"
STEM = "kythen_siku_lichen_crust"
CLS = "leaves"
SIZE = lib.SIZE


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    alpha = src[..., 3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print(f"alpha: opaque share {(alpha > 0.5).mean():.3f}")
    print("lib.class_of reads:", lib.class_of(STEM, GAME))

    opaque = lib.upscale(alpha, smooth=True)
    lo, hi = float(lum.min()), float(lum.max())
    norm_lum = (lum - lo) / max(hi - lo, 1e-6)
    guide = lib.upscale(norm_lum, smooth=True)
    guide = lib.blur(guide, 2)

    patches = lib.fbm(SIZE, base_cells=14, octaves=3, seed=251, gain=0.55)
    grain = lib.blur(lib.white_noise(SIZE, seed=252), 1)

    shape = 0.35 * (guide - 0.5) + 0.35 * patches + 0.15 * grain + 0.30 * (opaque - 0.5)
    height = lib.band(shape, 0.09)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=24, octaves=2, seed=253, gain=0.5)
    smooth = 0.15 * zscore(shape) + 0.35 * zscore(variation)
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(src)  # RGBA, keeps the mat's own transparency
    normal_strength = 5.0
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
