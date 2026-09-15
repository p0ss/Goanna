"""Hand authored LabPBR height and smoothness for default_furnace_front.

The same flat, grain-only dressed stone face as default_furnace_side (see
that module for the joint network and why it is built flat rather than
domed), but with a mouth cut into it: rows 8 to 13, columns 5 to 10 are far
darker than any stone shade elsewhere on the face (0.092 to 0.360 against
0.263 to 0.681), a clean rectangle. Inside it, rows 8 to 10 are flat black
(0.092 throughout, the firebox interior) and rows 11 to 13 mix five
different shades in a scatter (0.092, 0.173, 0.239, 0.313, 0.360), a grate
over an ash floor. Row 14 returns straight to ordinary stone brightness, so
the mouth is exactly those six rows deep and six columns wide, not a
gradient fading into the stone. The mouth stays a real, deep recess against
the now much flatter body around it.
"""
import sys

import numpy as np

import lib

import default_furnace_side as body

STEM = "default_furnace_front"
CLS = "stone"
SIZE = lib.SIZE

MOUTH_ROWS = slice(8, 14)
MOUTH_COLS = slice(5, 11)
CORE_LUM_MAX = 0.16
GRATE_LUM_MAX = 0.40


def mouth_masks(lum):
    box = np.zeros((16, 16), dtype=bool)
    box[MOUTH_ROWS, MOUTH_COLS] = True
    core = box & (lum < CORE_LUM_MAX)
    grate = box & ~core & (lum < GRATE_LUM_MAX)
    return box, core, grate


def carve_mouth(height, box, core, grate, floor=0.06, grate_level=0.22):
    """Cut the firebox into an already built cobble height field. The
    opening is a machined rectangle, straight edged (no warp_labels: this
    is a cut hole, not an organic stone silhouette), so the mask goes
    straight to map resolution by nearest repeat."""
    box_hi = np.repeat(np.repeat(box, 16, axis=0), 16, axis=1).astype(np.float32)
    core_hi = np.repeat(np.repeat(core, 16, axis=0), 16, axis=1)
    grate_hi = np.repeat(np.repeat(grate, 16, axis=0), 16, axis=1)

    edge = lib.region_edges(box_hi > 0.5)
    max_dist = 4
    dist = lib.distance_to_edge(edge, max_dist=max_dist)
    wall = np.where(box_hi > 0.5, 0.0, dist)
    wall_t = np.clip(wall / max_dist, 0.0, 1.0)
    wall_t = wall_t * wall_t * (3 - 2 * wall_t)  # 0 at the mouth, 1 on the untouched face

    depth = np.where(core_hi, floor, np.where(grate_hi, grate_level, height))
    # Sub texel scatter on the grate and ash floor: it is not a flat cut
    # like the firebox back wall, it is loose ash and iron bars.
    scatter = lib.fbm(SIZE, base_cells=24, octaves=3, seed=71) * 0.03
    depth = np.where(grate_hi, depth + scatter, depth)
    return height * wall_t + depth * (1 - wall_t)


def build(stem, active_emission_stem=None):
    out_dir = sys.argv[1]
    src = lib.load_source(stem)
    # Same flat, grain-only masonry body as the side, at the side's own
    # joint threshold: outside the mouth this is the same stone face, so it
    # should read as the same material rather than getting its own layout.
    height, smooth = body.build_body(stem, src, body.SIDE_MORTAR_THRESH)

    lum = lib.luminance(src[..., :3])
    box, core, grate = mouth_masks(lum)
    print(f"mouth: box {int(box.sum())} texels, core {int(core.sum())}, grate {int(grate.sum())}")
    height = carve_mouth(height, box, core, grate)

    # Smoothness follows the same cut: the firebox interior is sooty and
    # rough, the grate a little less so (worn iron bars), the untouched
    # cobble keeps its own build.
    box_hi = np.repeat(np.repeat(box, 16, axis=0), 16, axis=1)
    core_hi = np.repeat(np.repeat(core, 16, axis=0), 16, axis=1)
    smooth = np.where(core_hi, 0.05, np.where(box_hi, 0.18, smooth))
    print(f"height sd {height.std():.3f}")
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    emission = None
    if active_emission_stem:
        emission = fire_emission(active_emission_stem)

    normal_strength = 14
    m = lib.pack(stem, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, emission=emission)
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    lib.preview(out_dir, stem, str(out_dir) + "/" + stem + "_preview.png")
    return lines


def fire_emission(active_stem):
    """How much each texel of the active art glows, from its own colour,
    read only inside the mouth: the cobble body carries a warm grey tint of
    its own (every stone shade has R a little above B, up to 0.09 of full
    scale even on the brightest chip), so measuring warmth over the whole
    face would leave a faint glow on stone that never wanted one. Inside
    the mouth a fire texel is warm on another scale entirely, R well above
    B (0.77 of full scale at the hottest, still 0.33 at the coolest visible
    ember), so restricting the read to the mouth's own rows and columns is
    what makes the stone genuinely zero rather than merely faint, and the
    grate bars fall out the same way: their near black paint (31, 21, 24)
    is no warmer than the stone is, so they read as unlit iron between the
    coals rather than glowing themselves."""
    active_src = lib.load_source(active_stem)
    r = active_src[..., 0]
    b = active_src[..., 2]
    warmth = np.clip((r - b) / 0.55, 0.0, 1.0)
    box = np.zeros((16, 16), dtype=bool)
    box[MOUTH_ROWS, MOUTH_COLS] = True
    warmth = np.where(box, warmth, 0.0)
    warmth_hi = lib.upscale(warmth, smooth=False)
    warmth_hi = lib.blur(warmth_hi, 2)
    box_hi = lib.upscale(box.astype(np.float32), smooth=False)
    box_hi = lib.blur(box_hi, 4)  # let the glow bleed a little onto the rim, no further
    return np.clip(warmth_hi * np.clip(box_hi * 2.0, 0.0, 1.0), 0.0, 1.0)


def main():
    return build(STEM)


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
