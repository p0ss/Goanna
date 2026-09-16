"""Hand authored height and smoothness for kythen_khmer_stucco.

The 32 px art is one flat shade, no variation at all: a lime render with
nothing left for lib.segments or a mortar mask to find. lib.class_of reads
"soil" back from the bake, which is an artefact of the level readback (the
bake's own smoothness happened to sit nearer soil's level than stone's) and
not a material judgement, so this script overrides to "stone": a lime
render on masonry is a hard, fired-or-cured surface like hardened_clay's
ceramic tile, not dug earth, and hardened_clay_family.py makes the same
call for the same reason.

Because the art gives no layout, the whole field is procedural: a broad,
shallow undulation from the render being trowelled by hand, sparser small
pits where the lime has weathered, and fine grain. Kept in a narrow band
(lib.band) rather than stretched to the byte, the same call
hardened_clay_family.py makes for a fired tile: a render is a flat
manufactured face and the class's full stone depth would turn its faint
texture into pumice.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_stucco"
CLS = "stone"
SIZE = lib.SIZE


def main(out_dir):
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print(f"class_of would read: {lib.class_of(STEM, GAME)}, overridden to {CLS} "
            f"(a cured render is a hard manufactured face, not dug earth)")

    # Broad, hand trowelled undulation: a couple of low frequency waves,
    # nothing sharp.
    trowel = lib.fbm(SIZE, base_cells=5, octaves=2, seed=711, gain=0.5)

    # Sparse small pits where the render has weathered off a high spot,
    # the same construction as hardened_clay_family.py's kiln flaws: white
    # noise, blurred to round the pit edge, then only the deepest few
    # percent kept so pits stay sparse.
    pit_field = lib.blur(lib.white_noise(SIZE, seed=712), 1)
    pit_cut = float(np.percentile(pit_field, 5))
    pits = np.where(pit_field < pit_cut, pit_field - pit_cut, 0.0)

    # Fine grain: the sand in the lime mix.
    grain = lib.blur(lib.white_noise(SIZE, seed=713), 2)

    field = 0.55 * trowel + 0.20 * pits + 0.25 * grain
    field = (field - field.mean()) / max(float(field.std()), 1e-6)
    height = lib.band(field, 0.07)
    print(f"height sd {height.std():.3f}")

    # Smoothness: a trowelled render is fairly even and a little glossier
    # on the high trowel strokes than in the shallow pits.
    variation = lib.fbm(SIZE, base_cells=26, octaves=3, seed=714, gain=0.55)
    smooth = 0.25 * (height - height.mean()) + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    # A render this flat is well under the stone tilt band on purpose, the
    # same call hardened_clay_family.py makes for a fired tile.
    normal_strength = 10.0
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
