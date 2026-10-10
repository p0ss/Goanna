"""Shared build for the three skin stems, one run() called by a one line
script per stem: kythen_siku_sealskin.py, kythen_siku_skin_cover.py,
kythen_siku_skin_lining.py.

lib.class_of reads "leaves" for sealskin and skin_cover (the SSS proxy
class_of falls back to when a stem's own packed scattering byte is high,
which a stretched, slightly translucent hide plausibly earns) but "soil"
for skin_lining, an inconsistency inside one material family that would
read as two different surfaces on one tent. All three are overridden to
"leaves" here so the family reads as one thing, the rule lib.py's own
"faces of one block match" gives for a single block's own faces, applied
to a family of three that dress the same shelter.

sealskin (cultures/siku/materials.json) is "mottle", cells 12, grain 3,
surface.smooth 0.42: a stretched hide's own natural blotching, nothing
drawn to segment (checked: no tolerance separates it into real regions,
the same dither reading kythen_dirt.py gives its own art).

skin_lining is "mottle" too, cells 12, grain 3, no surface.smooth given in
the recipe: the same mottled hide reading as sealskin, no seam, thinner
and paler (caribou belly fur).

skin_cover is "masonry", course 16, stone_width 32 in the 32 px art:
stone_width spans the whole tile, so there is no vertical joint, only two
courses stacked, one seam. Checked by hand off the row means: row 0 and
row 16 both dip to 0.3345, every other row sits between 0.38 and 0.42,
so the seam is real and lands at both those rows, not invented. Built
from that row split directly, the same known-grid reasoning
kythen_siku_ice_family.py's pressure_ice uses for its own masonry, not
lib.segments: the seam is caribou_brown mortar, a stitched joint of two
big hides, kept straight rather than run through lib.warp_labels (a
sewn tent seam is drawn straight in the art and is closer to dressed
than organic).
"""

import numpy as np

import lib

GAME = "kythen"
SIZE = lib.SIZE
CLS = "leaves"


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def hide_mottle(src, seed_base):
    """The shared mottled hide read: the art's own blotching, smoothly
    upscaled so the patches the artist drew stay put but round off rather
    than keep their texel corners, plus fine grain below the texel."""
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    lo, hi = float(lum.min()), float(lum.max())
    norm_lum = (lum - lo) / max(hi - lo, 1e-6)
    print(f"  lum min {lo:.3f} max {hi:.3f} mean {lum.mean():.3f}")

    guide = lib.upscale(norm_lum, smooth=True)
    guide = lib.blur(guide, 2)

    grain = lib.blur(lib.white_noise(SIZE, seed_base), 1)
    fine = lib.fbm(SIZE, base_cells=36, octaves=2, seed=seed_base + 1, gain=0.5)
    shape = 0.55 * (guide - 0.5) + 0.30 * fine + 0.15 * grain
    return shape, guide, grain


def build_sealskin(src):
    shape, guide, grain = hide_mottle(src, 851)
    height = lib.band(shape, 0.08)
    variation = lib.fbm(SIZE, base_cells=40, octaves=2, seed=853, gain=0.5)
    smooth = 0.15 * zscore(shape) + 0.30 * zscore(variation)
    return height, smooth, 3.5


def build_skin_lining(src):
    shape, guide, grain = hide_mottle(src, 861)
    height = lib.band(shape, 0.06)
    variation = lib.fbm(SIZE, base_cells=44, octaves=2, seed=863, gain=0.5)
    smooth = 0.15 * zscore(shape) + 0.30 * zscore(variation)
    return height, smooth, 3.0


def build_skin_cover(src):
    h, w = src.shape[:2]  # 32, 32
    course = 16
    rows = h // course  # 2
    print(f"  masonry rows: course={course} -> {rows} courses, no column joint (stone_width spans the tile)")

    shape, guide, grain = hide_mottle(src, 871)

    row_px = SIZE // rows  # 128
    ys = np.arange(SIZE)
    block_row = (ys // row_px)[:, None]
    block_row = np.broadcast_to(block_row, (SIZE, SIZE)).copy()
    edges = lib.region_edges(block_row)
    # Wide taper, as kythen_siku_ice_family.py's pressure_ice needed: two
    # courses means half of every row join is the wrap join, and a narrow
    # taper left that one join a sharper step than the diluted mean of the
    # 255 mostly flat inner joins (seam_n read 2.38 at max_dist 8).
    max_dist = 18
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    seam = -(1.0 - t) * 0.9

    combined = 0.7 * shape + seam
    combined = lib.blur(combined, 4)  # one shared ramp at every course edge, wrap included
    height = lib.band(combined, 0.16)

    variation = lib.fbm(SIZE, base_cells=40, octaves=2, seed=873, gain=0.5)
    smooth = 0.15 * (1.0 - t) * -1.0 + 0.10 * zscore(shape) + 0.3 * zscore(variation)
    return height, smooth, 6.0


BUILDERS = {
    "kythen_siku_sealskin": build_sealskin,
    "kythen_siku_skin_cover": build_skin_cover,
    "kythen_siku_skin_lining": build_skin_lining,
}


def run(stem, out_dir):
    src = lib.load_source(stem, GAME)
    print(f"{stem}: source shape {src.shape}")
    cls_read = lib.class_of(stem, GAME)
    print(f"lib.class_of reads: {cls_read}, overridden to {CLS} for all three so the family "
          "reads as one hide rather than two classes on one tent (see module docstring)")

    height, smooth, normal_strength = BUILDERS[stem](src)
    print(f"height sd {height.std():.4f}")
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(src[..., :3])
    m = lib.pack(stem, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    lib.preview(out_dir, stem, str(out_dir) + "/" + stem + "_preview.png")
    return lines
