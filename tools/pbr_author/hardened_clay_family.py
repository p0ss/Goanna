"""Shared build for hardened_clay and its sixteen stained colours, one
script per stem calling run(stem, out_dir).

hardened_clay's art is a narrow band of grey buff shades with the mottling
of a fired tile, not the blocky lump and crack network default_clay.py
finds in the raw, unfired art (checked with lib.segments the same way:
here it fragments into a hundred slivers before a real lump shape appears,
because a kiln tile has none to find). Checked by hand across all
seventeen textures, each stem's own normalised luminance correlates above
0.97 with plain hardened_clay's, so the mottling pattern is one drawing
recoloured, and building the layout from each stem's own art already
keeps the same relief in every dye; the undulation, the pits and the
grain on top all use fixed seeds regardless of stem, so nothing about the
surface drifts with the colour.

lib.class_of("hardened_clay") reads "stone": a fired tile is a ceramic,
hard like stone rather than soft like dug clay, so it takes stone's tilt
band (28 to 40 degrees) and its jointed ao_min rule, met here by the
pits rather than by a crack network.
"""

import numpy as np

import lib

CLS = "stone"
SIZE = lib.SIZE


def run(stem, out_dir):
    src = lib.load_source(stem)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    lo, hi = float(lum.min()), float(lum.max())
    norm_lum = (lum - lo) / max(hi - lo, 1e-6)
    print(f"{stem}: lum min {lo:.3f} max {hi:.3f} mean {lum.mean():.3f}")

    # Mottling: the art's own light and dark, smoothly upscaled and
    # rounded, a gentle undulation that follows the fired tile's own
    # blotches rather than a shape invented here.
    mottle = lib.upscale(norm_lum, smooth=True)
    mottle = lib.blur(mottle, 3)

    # A few-texel-scale ripple on top of the mottling, the tile's own
    # gentle undulation, fixed seed so it is identical across dyes.
    ripple = lib.fbm(SIZE, base_cells=48, octaves=2, seed=601, gain=0.5)

    # Sparse small pits: a kiln flaw here and there, not a crack network.
    # White noise, blurred just enough to round a pit's edge, then only
    # its deepest few percent kept so the pits stay sparse and small.
    pit_field = lib.blur(lib.white_noise(SIZE, seed=602), 1)
    pit_cut = float(np.percentile(pit_field, 6))
    pits = np.where(pit_field < pit_cut, pit_field - pit_cut, 0.0)

    # Fine grain: the ceramic's own texture, finer again and shallow.
    grain = lib.blur(lib.white_noise(SIZE, seed=603), 2)

    # Kept in a narrow band around the middle rather than stretched to the
    # full byte: the shader gives the full range the depth of the class
    # (a mortar joint for stone), so a stretched map turns a fired tile's
    # faint undulation into pumice. Ten percent of the range is a tile.
    field = 0.15 * mottle + 0.65 * ripple + 0.08 * pits + 0.12 * grain
    field = (field - field.mean()) / max(float(field.std()), 1e-6)
    height = np.clip(0.5 + 0.05 * field, 0.0, 1.0)
    print(f"height sd {height.std():.3f}")

    # Smoothness: fairly even, a little glossier on the raised parts than
    # in the pits, plus the ceramic's own light variation.
    variation = lib.fbm(SIZE, base_cells=30, octaves=3, seed=604, gain=0.55)
    smooth = 0.20 * (height - height.mean()) + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    # Fired clay is nearly smooth: the first pass chased the stone class's
    # tilt band and came out as pitted rock on the ramp. The tilt is
    # reported under that band on purpose.
    normal_strength = 12.0
    m = lib.pack(stem, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength)
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    lib.preview(out_dir, stem, str(out_dir) + "/" + stem + "_preview.png")
    return lines
