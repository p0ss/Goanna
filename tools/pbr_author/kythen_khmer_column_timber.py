"""Hand authored height and smoothness for kythen_khmer_column_timber.

The 32 px art has only two shades, and the darker one is the whole of
columns 0, 8, 16 and 24, nowhere else: four timber staves, eight texels
wide, running the column's full height, the join between them a narrow
groove rather than a masonry mortar bed. Inside each stave the two shades
scatter with no row or column pattern lib.segments could turn into a
region (checked by column fraction: 28 to 75 percent dark, no rhythm to
it), which is an adze's own texture, short overlapping hewn facets, not a
drawn layout.

The relief is built the same way as kythen_khmer_plank_timber.py's board
joints, a groove at each stave boundary, with the stave face carrying
short, irregular adze facets (a directional noise field, coarser and less
regular than a saw's grain) rather than the plank's smooth long grain.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_column_timber"
CLS = "wood"
SIZE = lib.SIZE
ART = 32
REP = SIZE // ART


def main(out_dir):
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.4f} max {lum.max():.4f} mean {lum.mean():.3f}")
    print(f"class_of reads: {lib.class_of(STEM, GAME)} (kept)")

    joint_col = np.array([c % 8 == 0 for c in range(ART)])
    print("joint columns:", np.where(joint_col)[0].tolist())
    joint_hi = np.tile(np.repeat(joint_col, REP)[None, :], (SIZE, 1))

    dist = lib.distance_to_edge(joint_hi.astype(np.float32), max_dist=3)
    t = np.clip(dist / 3.0, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    # Adze facets: short, overlapping strokes at a shallow angle, coarser
    # and less regular than a saw's long grain. Built from two noise
    # fields at different angles and blended, so no single direction
    # dominates the way a plank's grain does.
    a = lib.fbm(SIZE, base_cells=26, octaves=3, seed=841, gain=0.55)
    b = lib.fbm(SIZE, base_cells=22, octaves=3, seed=842, gain=0.55)
    facets = 0.5 * a + 0.5 * b

    # A whisper of long grain up the stave, underneath the facets.
    grain_src = lib.fbm(SIZE, base_cells=10, octaves=2, seed=843)
    grain = np.zeros_like(grain_src)
    for d in range(-8, 9):
        grain += np.roll(grain_src, d, axis=0)
    grain /= 17.0

    layout = -0.85 * (1.0 - t) + 0.55 * facets * t + 0.15 * grain
    height = lib.normalise01(layout, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=24, octaves=3, seed=844, gain=0.55)
    smooth = 0.45 * t + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 18.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=ART)
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
