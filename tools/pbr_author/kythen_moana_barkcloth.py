"""Hand authored height and smoothness for kythen_moana_barkcloth.

The 32 px art is one flat colour, lum 0.791 everywhere, standard deviation
0.000: no dither, no printed pattern, fully opaque. There is nothing to
segment and nothing to read a layout from; this is a plain undecorated
panel of tapa (bark cloth), beaten from paper mulberry bark with a ridged
wooden mallet. A real sheet like this carries the beater's own crosshatch
of very fine parallel ridges in two directions (the felted bark fibre
itself, not a printed kupesi pattern, which this art does not draw) and a
few broad, shallow folds from being carried or hung. Both are built rather than read, since the art gives no layout to read,
and kept modest: normal_strength 5.5 on a field of drape, beater ridges
and fibre fuzz reaches the cloth class's own tilt target (6 to 14 degrees)
without ever approaching a mortar joint's worth of relief.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_barkcloth"
CLS_READ = lib.class_of(STEM, GAME)
CLS = "cloth"
SIZE = lib.SIZE


def blur_axis(field, radius, axis):
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    lum = lib.luminance(src[..., :3])
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.4f}")
    print("flat panel, no dither, no printed pattern; class read back from bake:",
          CLS_READ, "used here:", CLS, "(a beaten fibre cloth, not foliage)")

    # Broad, shallow folds, the sheet's own drape.
    folds = lib.fbm(SIZE, base_cells=5, octaves=2, seed=1101, gain=0.55)

    # The beater's crosshatch: fine ridges in two directions, the felted
    # bark fibre itself, each stretched long and thin along its own axis.
    beat_a = blur_axis(lib.fbm(SIZE, base_cells=70, octaves=2, seed=1102, gain=0.5), radius=10, axis=1)
    beat_b = blur_axis(lib.fbm(SIZE, base_cells=70, octaves=2, seed=1103, gain=0.5), radius=10, axis=0)
    beat = 0.5 * beat_a + 0.5 * beat_b

    # Fine fibre pores under the beater ridges.
    fuzz = lib.blur(lib.white_noise(SIZE, seed=1104), 1)

    raw = 0.40 * folds + 0.40 * beat + 0.20 * fuzz
    height = lib.normalise01(raw, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=40, octaves=3, seed=1105, gain=0.55)
    smooth = 0.5 + 0.14 * zscore(beat) + 0.10 * zscore(variation)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 5.5
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
