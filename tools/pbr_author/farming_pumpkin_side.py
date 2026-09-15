"""Hand authored height and smoothness for farming_pumpkin_side.

The plain rib pattern, no carved features: column means of the 16 px art
step between four dark valleys (columns 0, 4, 8, 12, each 0.32 to 0.41) and
four bright crests (columns 2 to 3, 6 to 7, 10, 13 to 14, each 0.45 to
0.52), four ribs across the tile with a groove between each, wrapping
cleanly (column 15 at 0.348 sits with column 0 at 0.324, both valley
shades). That is a profile along x, the same kind of reading
mcl_core_sandstone_normal.py takes off its own art's row means for strata,
just turned ninety degrees because a gourd's ribs run the other way to
sandstone's beds.

farming_pumpkin_face.py, farming_pumpkin_face_light.py and this script
share the same column profile (read from this texture, since the carved
faces' own column means are skewed by the eyes and mouth cut into them)
and the same fine grain and pore seeds, so the four faces of one pumpkin
read as one gourd.
"""

import sys

import numpy as np

import lib

STEM = "farming_pumpkin_side"
CLS = "wood"
SIZE = lib.SIZE

GRAIN_SEED = 101
PORES_SEED = 102


def rib_taper(max_dist=10):
    """0 at the groove between two ribs, 1 on a rib's own rounded crest, at
    map size. The groove sits at this texture's own column minima: local
    minima of the column means fall at columns 0, 4, 8 and 12, an even
    four rib spacing, so a real, narrow groove (distance_to_edge, the same
    technique a masonry joint uses) sits there rather than the wide, flat
    trough a plain per column profile gives, which read with almost no
    occlusion at all. A little wobble on the groove's own edge (the same
    idea default_stone_brick.py uses on its joint) breaks the groove from
    being one straight canyon running the whole height of the tile, which
    left ambient occlusion reading as if there were no groove there at
    all: a canyon occludes along its own length but not along its walls
    only, and the same want of row to row variation made the tile's own
    wrap seam read worse than it is. Read from farming_pumpkin_side
    regardless of which pumpkin face calls it, so the ribs line up across
    all four faces."""
    side_src = lib.load_source("farming_pumpkin_side")
    col = lib.luminance(side_src[..., :3]).mean(axis=0)
    valley = [c for c in range(16) if col[c] < col[(c - 1) % 16] and col[c] < col[(c + 1) % 16]]
    groove = np.zeros(16, dtype=bool)
    groove[valley] = True
    groove_hi = np.tile(np.repeat(groove, SIZE // 16)[None, :], (SIZE, 1))
    dist = lib.distance_to_edge(groove_hi.astype(np.float32), max_dist=max_dist)
    wobble = lib.fbm(SIZE, base_cells=48, octaves=2, seed=104) * (max_dist * 0.5)
    dist = np.where(groove_hi, 0.0, np.clip(dist + wobble, 0.0, max_dist))
    t = np.clip(dist / max_dist, 0.0, 1.0)
    return t * t * (3 - 2 * t), valley


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("column means:", np.round(lum.mean(axis=0), 3).tolist())

    t, valley = rib_taper()
    print("valley columns:", valley)
    ribs = 0.10 * (1.0 - t) + 0.85 * t

    grain = lib.fbm(SIZE, base_cells=30, octaves=3, seed=GRAIN_SEED, gain=0.55) * 0.06
    pores = lib.blur(lib.white_noise(SIZE, seed=PORES_SEED), 1) * 0.03
    height = lib.normalise01(ribs + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the groove between ribs stays dustier and
    # rougher, the rounded crest is what wears smooth.
    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=103, gain=0.55)
    smooth = 0.55 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 17.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength)
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
