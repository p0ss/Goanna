"""Hand authored height and smoothness for kythen_khmer_gold_leaf.

The 32 px art is one flat gold shade, no layout at all, so the whole map is
built from what gilding actually looks like rather than anything drawn.
The brief calls both this stem and kythen_khmer_bronze.py out as metal by
name, overriding lib.class_of's guess ("gravel" here, a level readback
artefact with no bearing on the material): metal_mask is set over the
whole face and the class passed to lib.pack is "metal".

Gold leaf is beaten to a few hundred atoms thick and laid down in small
overlapping squares, so the relief is not a texture at all but a faint grid
of the leaf's own laps, each edge a whisper of a ridge where the next leaf
overlaps the last, plus the fine, shallow dimpling of the beating itself.
lib.pack's mean shift is turned off (keep_mean=False) so this stem's own
high, even smoothness is not pulled down to share a level with
kythen_khmer_bronze.py's duller, patinated one; both are metal so the
packer would otherwise average them onto the same "metal" class figure.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_gold_leaf"
CLS = "metal"
SIZE = lib.SIZE


def main(out_dir):
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print(f"class_of reads: {lib.class_of(STEM, GAME)}, overridden to {CLS} per the brief")

    # Leaf laps: a grid of small overlapping squares, 32 texels on the 256
    # map so the grid divides the tile exactly and tiles cleanly (a leaf is
    # applied in sheets a few centimetres across), each edge a faint raised
    # overlap. Built the same way a masonry joint is, but inverted (the
    # join is a low ridge, not a groove) and much shallower.
    # Offset half a cell so the tile's own row 0 and column 0 fall in the
    # middle of a leaf, not exactly on a lap line: with the grid lines on
    # the wrap, an entire wrap row or column sits on a joint at once, a
    # coincidence the seam measure reads as a bad tile even though the
    # pattern repeats correctly (row 32 meets row 31 the same way row 0
    # meets row 255, it is just that the measure's join sampling dilutes
    # every join equally except the one it calls the wrap).
    cell = 32
    gy = ((np.arange(SIZE) + cell // 2) % cell).astype(np.float32)
    gx = ((np.arange(SIZE) + cell // 2) % cell).astype(np.float32)
    dy = np.minimum(gy, cell - gy)
    dx = np.minimum(gx, cell - gx)
    d = np.minimum(dy[:, None], dx[None, :])
    lap = np.clip(1.0 - d / 3.0, 0.0, 1.0)
    lap = lap * lap * (3 - 2 * lap)

    # The beating itself: very fine, shallow dimpling.
    dimple = lib.fbm(SIZE, base_cells=48, octaves=3, seed=731, gain=0.5)

    field = 0.5 * lap + 0.5 * dimple
    field = (field - field.mean()) / max(float(field.std()), 1e-6)
    # A leaf is close to flat; gold leaf reads as bright because it is
    # smooth, not because it has relief, so the height stays in a narrow
    # band. This sits under the generic 15 to 30 degree tilt band lib.check
    # falls back to for a class with no target of its own, the same way a
    # polished or manufactured face is allowed to: the whole point of leaf
    # gilding is a face with almost nothing on it.
    height = lib.band(field, 0.14)
    print(f"height sd {height.std():.3f}")

    metal_mask = np.full((SIZE, SIZE), True)

    # Smooth and bright, per the brief, with the leaf's own laps and
    # dimpling carried into the roughness too, so no single texel is a
    # pinpoint mirror: the lap lines themselves are duller (dust and wear
    # catch on the overlap) and there is broader patch to patch variation
    # from how evenly each leaf was burnished down.
    variation = lib.fbm(SIZE, base_cells=26, octaves=3, seed=732, gain=0.55)
    patch = lib.fbm(SIZE, base_cells=8, octaves=2, seed=735, gain=0.5)
    smooth = 0.78 - 0.22 * lap + 0.14 * variation + 0.10 * patch
    smooth = np.clip(smooth, 0.0, 0.95)
    print(f"pre pack smooth mean {smooth.mean():.3f} sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 9.0
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
