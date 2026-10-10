"""Hand authored height and smoothness for kythen_khmer_bronze.

The 32 px art is one flat bronze shade, no layout at all, the same
situation as kythen_khmer_gold_leaf.py. The brief names this stem metal
too, overriding lib.class_of's guess ("stone", another level readback
artefact): metal_mask covers the whole face and the class passed to
lib.pack is "metal".

Cast bronze keeps the mould's own texture (fine casting sand pits and
shallow flow marks) and, once fitted, a patina: duller, mottled blotches
where copper has oxidised, brighter where a hand or the weather has kept a
spot polished. That patina is a roughness story more than a height one, so
it drives the smoothness field, while the height carries the caster's own
shallow surface. keep_mean=False for the same reason as the gold leaf
script: bronze's own duller, more varied level must not be dragged onto
gold leaf's by the packer's shared "metal" class mean.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_bronze"
CLS = "metal"
SIZE = lib.SIZE


def main(out_dir):
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print(f"class_of reads: {lib.class_of(STEM, GAME)}, overridden to {CLS} per the brief")

    # Casting texture: shallow sand pits from the mould, coarser and
    # deeper than gold leaf's beating marks, since bronze is cast, not
    # hammered thin, plus tool marks where the casting was fettled and
    # chased by hand.
    pit_field = lib.blur(lib.white_noise(SIZE, seed=741), 1)
    pit_cut = float(np.percentile(pit_field, 25))
    pits = np.where(pit_field < pit_cut, pit_field - pit_cut, 0.0)

    # Broad, slow flow marks from the pour, and the chasing tool's own
    # coarser strokes on top: bronze fittings are worked by hand after
    # casting, which is real relief, not a texel scale flourish.
    flow = lib.fbm(SIZE, base_cells=8, octaves=3, seed=742, gain=0.55)
    chasing = lib.fbm(SIZE, base_cells=16, octaves=3, seed=745, gain=0.55)

    field = 0.40 * flow + 0.35 * chasing + 0.35 * pits
    field = (field - field.mean()) / max(float(field.std()), 1e-6)
    height = lib.normalise01(field, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    metal_mask = np.full((SIZE, SIZE), True)

    # Patina: broad mottled patches, duller where oxidised, a shade
    # brighter on the raised, more handled high points. Slightly rough
    # overall, per the brief, well below gold leaf's polished level.
    patina = lib.fbm(SIZE, base_cells=10, octaves=3, seed=743, gain=0.55)
    fine = lib.fbm(SIZE, base_cells=34, octaves=3, seed=744, gain=0.5)
    smooth = 0.35 + 0.15 * (height - height.mean()) + 0.28 * patina + 0.10 * fine
    smooth = np.clip(smooth, 0.05, 0.7)
    print(f"pre pack smooth mean {smooth.mean():.3f} sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 18.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, metal_mask=metal_mask,
            keep_mean=False, art_texels=src.shape[0])
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
