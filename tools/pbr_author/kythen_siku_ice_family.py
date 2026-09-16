"""Shared build for the four ice stems, one run() called by a one line
script per stem: kythen_siku_clear_ice.py, kythen_siku_glacier_ice.py,
kythen_siku_pressure_ice.py, kythen_siku_sea_ice.py.

All four read lib.class_of == "ice" from the bake, which gives every one
of them the same packed smoothness level, 0.88. But the game's own
material recipes (cultures/siku/materials.json) each state their own
surface.smooth: clear 0.90, glacier 0.85, sea 0.72, pressure 0.65, a real
spread from window pane to broken rubble that one packed level would
erase. keep_mean=False on every stem, so the authored field survives
packing as built; "ice" is already one of the three classes lib.pack
exempts from its usual smoothness ceiling, so this is the same lever the
class was given, just used precisely instead of by the class default.

clear_ice's 32 px art is the "flat" recipe with no accent painted: a
single shade, min equals max, nothing to segment. Its only structure is a
scatter of our own hairline cracks, a window pane's own checking; nothing
in the art says where they run, so they are a genuinely authored field.

glacier_ice segments cleanly at tolerance 0.03 into two dominant colour
cells (538 and 392 texels of 1024, checked by hand) plus a scatter of
small fragments: the "mottle" recipe's own base and accent, ice_blue
against the deeper ice_deep. That is real art structure, not an invented
partition, so the cell boundary is read as a shallow crack the way
default_stone.py reads a fleck boundary, not built from lib.segments'
np.kron square edges but straight from the label map (see build_glacier):
an internal colour band in clear ice has no reason to meander, so it is
not run through lib.warp_labels either.

sea_ice never separates at any tolerance, checked from 0.02 to 0.12 (n
stays near 40 to 70, the sizes never settling into a few dominant
regions): a per texel dither, the same kind of art default_dirt.py and
kythen_gravel.py read as grain rather than drawn regions. Built as
continuous noise, standing for an uneven scour of last winter's snow
still lying on this season's ice, paler and smoother where it is bare
(the recipe's own note).

pressure_ice is masonry, course 16 and stone_width 8 in the 32 px art:
two courses of four slabs, eight to the node exactly as the recipe's own
note says. Built from that exact grid arithmetic rather than
lib.segments, because the grid is the recipe's own numbers, not a
partition the script found or invented, and never warped: a slab cut and
driven up on edge has a straight edge, blocktex.py's own "hard angular
facet" note about why the masonry recipe was kept for it. Each slab gets
its own tilt, a linear gradient across the slab rather than a symmetric
dome, and its own small rise or dip against its neighbours, a rubble
field of individually cocked floes rather than a dressed pavement.
"""

import numpy as np

import lib

GAME = "kythen"
SIZE = lib.SIZE
CLS = "ice"


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def finish_smooth(shape, target_mean, spread=0.11, lo=0.02, hi=0.95):
    """keep_mean=False leaves pack() out of the smoothness mean, so the
    script owes it directly: target_mean is the recipe's own surface.smooth,
    spread is the sd the shape's own z-score is scaled to before the mean
    is set, so every stem lands on its own recipe number with real spread
    for the smoothness sd check regardless of what target_mean is."""
    return np.clip(target_mean + spread * zscore(shape), lo, hi)


def crack_field(size, seed, cells, sharpness=55.0):
    """Thin, wandering hairline lines from the zero level set of a smooth
    noise field: no region is found or invented here, only the ridge
    where the field crosses zero is kept as a line, which is why this
    works on clear_ice's own perfectly flat art with nothing to segment."""
    f = lib.fbm(size, cells, 3, seed, gain=0.55)
    ridge = 1.0 - np.abs(f) / (np.abs(f).max() + 1e-6)
    return np.clip(ridge * sharpness - (sharpness - 1.0), 0.0, 1.0)


# --- per stem builds ---------------------------------------------------------

def build_clear(src):
    lum = lib.luminance(src[..., :3])
    print(f"clear_ice: art lum min {lum.min():.3f} max {lum.max():.3f}, flat recipe, nothing to segment")
    cracks = np.maximum(crack_field(SIZE, 811, 6), 0.55 * crack_field(SIZE, 812, 10))
    print(f"crack coverage (>0.3): {(cracks > 0.3).mean():.4f} of the tile")
    grain = lib.blur(lib.white_noise(SIZE, 813), 1)
    shape = -0.85 * cracks + 0.10 * grain
    height = lib.band(shape, 0.045)
    rough_shape = -cracks + 0.35 * grain
    smooth = finish_smooth(rough_shape, target_mean=0.90, spread=0.10)
    return height, smooth, 5.0


def build_glacier(src):
    rgb = src[..., :3]
    h, w = rgb.shape[:2]
    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    lum = lib.luminance(rgb)
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"glacier_ice: segments n={n} tol={tolerance} top sizes {sorted(sizes.tolist(), reverse=True)[:6]}")

    scale = SIZE // h
    labels_hi = np.kron(labels, np.ones((scale, scale), dtype=int))
    edges = lib.region_edges(labels_hi)
    dist = lib.distance_to_edge(edges, max_dist=4)
    t = np.clip(dist / 4, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    lo, hi = float(region_lum.min()), float(region_lum.max())
    target = -1.0 + 2.0 * (region_lum - lo) / max(hi - lo, 1e-6)  # deep cell low, shallow cell high
    step = target[labels_hi]
    layout = lib.blur(step, 3)  # one shared ramp either side of the boundary, the planks reasoning
    grain = lib.blur(lib.white_noise(SIZE, 821), 1)
    shape = layout + 0.12 * grain
    height = lib.band(shape, 0.075)

    rough_shape = -(1.0 - t) + 0.4 * grain
    smooth = finish_smooth(rough_shape, target_mean=0.85, spread=0.10)
    return height, smooth, 7.0


def build_sea(src):
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"sea_ice: lum min {lum.min():.3f} max {lum.max():.3f} sd {lum.std():.3f}, never segments (checked 0.02 to 0.12)")
    art_lum = lib.upscale(lum)
    guide = lib.normalise01(lib.blur(art_lum, 3)) - 0.5  # -0.5..0.5, the art's own broad shading
    grain = lib.blur(lib.white_noise(SIZE, 831), 1)
    fine = lib.fbm(SIZE, base_cells=24, octaves=3, seed=832, gain=0.55)
    shape = 0.55 * guide + 0.30 * fine + 0.15 * grain
    height = lib.band(shape, 0.06)

    # Paler (higher guide) reads harder and barer per the recipe's own
    # note, so smoother there; darker patches are where the snow dusting
    # still sits, rougher.
    rough_shape = guide + 0.3 * zscore(fine)
    smooth = finish_smooth(rough_shape, target_mean=0.72, spread=0.12)
    return height, smooth, 6.0


def build_pressure(src):
    h, w = src.shape[:2]  # 32, 32
    course, stone_width = 16, 8  # cultures/siku/materials.json's own numbers
    rows = h // course      # 2
    cols = w // stone_width  # 4
    print(f"pressure_ice: masonry grid {rows} courses x {cols} slabs = {rows * cols} slabs, "
          f"from the recipe's own course={course} stone_width={stone_width}")

    ys = np.arange(SIZE)
    xs = np.arange(SIZE)
    row_px = SIZE // rows   # 128
    col_px = SIZE // cols   # 64
    block_row = (ys[:, None] // row_px)
    block_col = (xs[None, :] // col_px)
    block_id = (block_row * cols + block_col).astype(int) + np.zeros((SIZE, SIZE), dtype=int)
    ly = (ys[:, None] % row_px) - row_px / 2.0
    lx = (xs[None, :] % col_px) - col_px / 2.0
    ny = ly / (row_px / 2.0)
    nx = np.broadcast_to(lx / (col_px / 2.0), (SIZE, SIZE))
    ny = np.broadcast_to(ny, (SIZE, SIZE))

    n_blocks = rows * cols
    rng = np.random.default_rng(841)
    angle = rng.uniform(0.0, 2 * np.pi, n_blocks)
    mag = rng.uniform(0.45, 0.75, n_blocks)
    lift = rng.uniform(-0.2, 0.2, n_blocks)

    tilt = mag[block_id] * (nx * np.cos(angle[block_id]) + ny * np.sin(angle[block_id]))
    offset = lift[block_id]

    # The known grid gives the joint exactly, not a masonry edge found by
    # lib.segments: the recipe's own arithmetic, not a partition invented
    # here. No warp, no lib.warp_labels: a driven floe's own cut edge is
    # straight, the note the masonry recipe was kept for.
    edges = lib.region_edges(block_id)
    max_dist = 16  # wide taper: only two courses means half of every row join IS the wrap
    # join, so seam_n reads whichever pair of adjacent slabs happens to differ most, however
    # wide the taper; widening from 5 to 10 to 16 and adding a blur brought it from 6.9 to
    # 3.9 to the number reported below, and is reported rather than chased further, since a
    # narrower joint is the only way left to shrink it and that is the slab structure itself.
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    joint = -(1.0 - t) * 1.3  # a real crushed seam between floes, deeper than the tilt alone

    grain = lib.blur(lib.white_noise(SIZE, 842), 1)
    shape = tilt + offset + joint + 0.05 * grain
    shape = lib.blur(shape, 4)  # one shared ramp everywhere a block edge falls, wrap included
    height = lib.band(shape, 0.36)

    rough_shape = -(1.0 - t) + 0.3 * grain
    smooth = finish_smooth(rough_shape, target_mean=0.65, spread=0.13)
    return height, smooth, 26.0


BUILDERS = {
    "kythen_siku_clear_ice": build_clear,
    "kythen_siku_glacier_ice": build_glacier,
    "kythen_siku_sea_ice": build_sea,
    "kythen_siku_pressure_ice": build_pressure,
}


def run(stem, out_dir):
    src = lib.load_source(stem, GAME)
    print(f"{stem}: source shape {src.shape}")
    cls = lib.class_of(stem, GAME)
    print(f"lib.class_of reads: {cls} (kept; the four ices share one relief"
          " idea and their own recipe smooth values, set with keep_mean=False)")

    height, smooth, normal_strength = BUILDERS[stem](src)
    print(f"height sd {height.std():.4f}")
    print(f"smooth mean {smooth.mean():.4f} sd {smooth.std():.4f}")

    albedo = lib.upscale(src[..., :3])
    m = lib.pack(stem, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, keep_mean=False, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}, keep_mean=False")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    # Ice is glassy by nature: the default tilt band ("ice" falls through
    # check()'s tilt dict to the generic 15 to 30 degree fallback) asks for
    # more relief than a flat or lightly cracked pane should ever have.
    # clear_ice, glacier_ice and sea_ice are expected to read low here;
    # only pressure_ice, built from real cocked slabs, is expected to sit
    # inside or near the band.
    lib.preview(out_dir, stem, str(out_dir) + "/" + stem + "_preview.png")
    return lines
