"""Hand authored height and smoothness for kythen_khmer_lead_roof.

The 32 px art is one flat grey, no layout to read at all: "flat sheets with
rolled seams" is a statement about how lead roofing is laid, not a pattern
the art draws, so the seams here are placed rather than found. lib.class_of
reads "stone" back from the bake, which this script keeps: the brief lists
bronze and gold leaf as the metal stems and leaves lead roofing out of that
clause on purpose, because weathered lead oxidises to a dull, matte grey
that behaves like a soft stone under the shader's dielectric model, not a
bright metal_mask reflection.

Real standing seam lead roofing is laid in sheets a few hundred millimetres
wide with a rolled, raised welt where one sheet meets the next, running the
length of the roof. Three such seams are placed at fixed x positions
(design, not noise) and each sheet face between them sags very slightly, a
soft, shallow dish rather than the flat plane a seam alone would leave, the
way a thin lead sheet does under its own weight.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_lead_roof"
CLS = "stone"
SIZE = lib.SIZE


def main(out_dir):
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print(f"class_of reads: {lib.class_of(STEM, GAME)} (kept: oxidised lead is matte, "
            "not the metal_mask clause the brief reserves for bronze and gold leaf)")

    # Three rolled seams, evenly spaced, each a rounded ridge about six
    # texels wide on the 256 map. A design feature, so it is placed with a
    # fixed function of x, not noise. Offset half a spacing from the tile
    # edge so the wrap join falls in a flat sheet face rather than through
    # a seam's own steep ramp, which the seam measure reads as a defect
    # even though the ramp is genuinely continuous (the same ramp appears
    # on both sides of every seam, the wrap included).
    x = np.arange(SIZE, dtype=np.float32)
    seam_x = np.array([SIZE / 6.0, SIZE / 2.0, 5.0 * SIZE / 6.0])
    seam_half_width = 6.0
    seam = np.zeros(SIZE, dtype=np.float32)
    tuck = np.zeros(SIZE, dtype=np.float32)
    for sx in seam_x:
        d = np.minimum(np.abs(x - sx), SIZE - np.abs(x - sx))
        bump = np.clip(1.0 - d / seam_half_width, 0.0, 1.0)
        bump = bump * bump * (3 - 2 * bump)
        seam = np.maximum(seam, bump)
        # The narrow tuck where the sheet folds under the roll: a real
        # crevice right beside the seam crown, not just a broad sag, so the
        # roll gets genuine self shadow.
        dt = np.minimum(np.abs(x - (sx + seam_half_width * 1.3)), SIZE - np.abs(x - (sx + seam_half_width * 1.3)))
        tb = np.clip(1.0 - dt / 2.0, 0.0, 1.0)
        tuck = np.maximum(tuck, tb * tb * (3 - 2 * tb))
    seam_profile = np.tile(seam[None, :], (SIZE, 1))
    tuck_profile = np.tile(tuck[None, :], (SIZE, 1))

    # Each sheet sags a little between its two seams: one slow cosine cycle
    # per sheet, near zero at the seams and lowest at the sheet's own
    # middle, giving the seam a genuine groove to sit in rather than a
    # bump on an otherwise dead flat face.
    cycles = 3.0
    sag = -0.5 * (1.0 - np.cos(2 * np.pi * cycles * (x - seam_x[0]) / SIZE))
    sag_profile = np.tile(sag[None, :], (SIZE, 1))

    # Fine texture: lead is soft and takes a granular, slightly hammered
    # surface, not a mirror.
    grain = lib.fbm(SIZE, base_cells=30, octaves=3, seed=721, gain=0.55)
    pores = lib.blur(lib.white_noise(SIZE, seed=722), 1)

    layout = 0.55 * seam_profile - 0.35 * tuck_profile + 0.30 * sag_profile + 0.15 * grain + 0.10 * pores
    height = lib.normalise01(layout, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height a little (the seam crown is what gets
    # walked and rained on, the sagging face gathers grime) plus lead's own
    # dull, even patina.
    rough_noise = lib.fbm(SIZE, base_cells=22, octaves=3, seed=723, gain=0.55)
    smooth = 0.35 * (height - height.mean()) + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 15.0
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
    lines = main(out_dir)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
