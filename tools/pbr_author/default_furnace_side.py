"""Hand authored LabPBR height and smoothness for default_furnace_side.

The art is a rough grey dressed stone face, nine shades running 0.263 to
0.681. The first pass read it with default_cobble's segment and dome
recipe and gave the ramp lumps: rounded chips where the art draws flat
dressed blocks with thin dark joints between them. This rebuild finds the
joints the way default_stone_brick.py finds mortar, by shade, and holds
everything else flat.

The darkest shade alone is a scatter of single texels, not a joint; the two
darkest together (up to lum 0.351) still do not close a line. Only at the
three darkest shades (up to lum 0.407, a wide cut but this art draws no
clean gap between mortar and stone the way default_cobble does) does row 2
come back as a full width line, wrapping cleanly into row 15 the way a
dressed course really would. That is the joint network used here: whatever
that threshold marks, thin and chamfered a couple of texels deep, and
nothing else. The blocks it encloses are not domed or individually
targeted by their own brightness; they are one flat face in a narrow
lib.band, carrying only fine stone grain, because that is what the art
actually draws between the joints.

default_furnace_top (and default_furnace_bottom, the same file) is a
single stone slab, not dressed courses: no threshold here closes a line
short of swallowing most of the face, so its own darkest shade is kept as
sparse weathered flecks rather than forced into a joint that is not there.

default_furnace_front cuts its mouth into this same body (see
default_furnace_front.py), and default_furnace_front_active is the lit
version of the front. All five faces use the same GRAIN_SEED, PORE_SEED
and VARIATION_SEED, so the stone reads as one material regardless of which
side is in view.
"""
import sys

import numpy as np

import lib

STEM = "default_furnace_side"
CLS = "stone"
SIZE = lib.SIZE

BAND_HALF_WIDTH = 0.15   # the block faces: flat, per README's "flat where
                          # the art is flat" rule, not stretched to the
                          # class's full mortar-joint depth
JOINT_CHAMFER = 3        # map texels of soft edge on the joint recess
JOINT_FLOOR = 0.16       # the joint sits this far below the block band,
                          # a couple of texels once normal_strength scales it

SIDE_MORTAR_THRESH = 0.407   # three darkest shades: see module docstring

GRAIN_SEED = 80
PORE_SEED = 81
VARIATION_SEED = 82


def stone_grain():
    """Fine stone grain, fixed seeds shared by every furnace face so the
    material reads as one thing regardless of which side is in view."""
    grain = lib.fbm(SIZE, base_cells=40, octaves=3, seed=GRAIN_SEED, gain=0.55)
    pores = lib.blur(lib.white_noise(SIZE, seed=PORE_SEED), 1)
    return grain * 0.7 + pores * 0.3


def joint_recess(mask, block):
    """Carve a thin, chamfered recess into an already flat block field
    wherever mask (16 px, bool) marks the art's darkest line. mask decides
    where the joint sits; JOINT_CHAMFER decides how wide its soft edge is,
    so a wide dark patch in the art still reads as a groove, not a trench."""
    mask_hi = np.repeat(np.repeat(mask, 16, axis=0), 16, axis=1).astype(np.float32)
    dist = lib.distance_to_edge(mask_hi, max_dist=JOINT_CHAMFER)
    dist = np.where(mask_hi > 0.5, 0.0, dist)
    t = np.clip(dist / JOINT_CHAMFER, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: flat block, sharp fall to the joint
    return block * t + JOINT_FLOOR * (1 - t)


def build_body(stem, src, mortar_thresh):
    """The dressed stone body: a flat face in a narrow band, its only
    relief fine stone grain, with the art's darkest shade carved in as a
    thin chamfered joint. mortar_thresh is picked per face from where the
    art's own darkest line actually forms; see the callers."""
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{stem}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")

    mask = lum <= mortar_thresh
    print(f"joint texels: {int(mask.sum())} of 256 at thresh {mortar_thresh:.3f}")

    block = lib.band(stone_grain(), half_width=BAND_HALF_WIDTH)
    height = joint_recess(mask, block)

    # Roughness follows height: the joint gathers dust and stays rough, the
    # dressed face is what wears smooth. The stone's own patchy variation
    # rides on top; pack() moves the mean, the spread is ours.
    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=VARIATION_SEED, gain=0.55)
    smooth = 0.6 * height + 0.5 * variation
    return height, smooth


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    height, smooth = build_body(STEM, src, SIDE_MORTAR_THRESH)
    print(f"height sd {height.std():.3f}")
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 16
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
