"""Hand authored height and smoothness for the concrete family, one module
shared by all sixteen mcl_colorblocks_concrete_<colour> stems.

The white block's art (mcl_colorblocks_concrete_white.png) is a near flat
16 px tile: four luminance shades within 0.004 of each other, standard
deviation 0.0017, one connected region at every lib.segments tolerance from
0.01 to 0.08. Checking the other fifteen colours finds the same thing, a
near uniform fill, and a couple (black, red) barely dither at all. That is
a smooth cast surface, not a drawing with regions to lift, so the relief
here is authored rather than read off the art: a moulded concrete slab,
almost flat, with the fine grain a cast surface takes off its formwork and
a scatter of the shallow air bubble pits every real pour traps against the
mould face.

The surface is the same physical thing under every colour, so height and
smoothness use one set of noise seeds for all sixteen stems; only the
albedo, upscaled from each colour's own art, changes.

lib.class_of reads "stone" for every one of the sixteen stems (Mineclonia
gives concrete a hard footstep, the same as any masonry). That pulls in the
masonry tilt target, 28 to 40 degrees, built for cobbles and bricks with
real joints between separate stones. A poured, sanded concrete face has
nothing like that: the fields below come out around 5 degrees, and that is
reported as a failure against the stone target rather than padded out with
noise the surface would not physically have. ao_min and smoothness sd meet
their targets on the strength of the bubble pits and the grain alone.
"""

import sys

import numpy as np

import lib

SIZE = lib.SIZE
COLOURS = ["black", "blue", "brown", "cyan", "green", "grey", "light_blue",
        "lime", "magenta", "orange", "pink", "purple", "red", "silver",
        "white", "yellow"]

# One cast surface, sixteen tints: every colour shares these seeds.
PIT_SEED = 41
GRAIN_SEED = 42
VARIATION_SEED = 43
PIT_COUNT = 15
PIT_RADIUS = 3.0
PIT_DEPTH = 0.25
NORMAL_STRENGTH = 6


def bubble_pits(size, count, radius, depth, seed, radius_jitter=0.4):
    """A handful of round, wrapped depressions at random centres: the air
    bubbles a real pour traps against the mould face. Each is a smoothstep
    bowl of its own radius (jittered so they are not all one size), stamped
    by maximum rather than summed, so two that land close together do not
    dig an unrealistically deep double pit."""
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    ys = rng.integers(0, size, count)
    xs = rng.integers(0, size, count)
    rs = radius * (1.0 + rng.uniform(-radius_jitter, radius_jitter, count))
    yy, xx = np.mgrid[0:size, 0:size]
    for cy, cx, r in zip(ys, xs, rs):
        dy = np.abs(yy - cy)
        dy = np.minimum(dy, size - dy)
        dx = np.abs(xx - cx)
        dx = np.minimum(dx, size - dx)
        d = np.sqrt(dy.astype(np.float32) ** 2 + dx.astype(np.float32) ** 2)
        t = np.clip(1.0 - d / r, 0.0, 1.0)
        t = t * t * (3 - 2 * t)  # smoothstep: a rounded bowl, not a cone
        field = np.maximum(field, t)
    return field * depth


def run(stem, out_dir):
    cls = lib.class_of(stem)
    src = lib.load_source(stem)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{stem}: lum mean {lum.mean():.3f} sd {lum.std():.4f} class {cls}")

    # The bowls sit at the same sixteen spots in every colour, since the
    # seed is shared and it is one mould surface under sixteen tints.
    pit = bubble_pits(SIZE, PIT_COUNT, PIT_RADIUS, PIT_DEPTH, seed=PIT_SEED)

    # Fine cast grain: the formwork's own texture, well under the pits in
    # scale, a texel or two of the 256 map wide.
    grain = lib.fbm(SIZE, base_cells=140, octaves=2, seed=GRAIN_SEED, gain=0.5) * 0.05

    height = np.clip(0.5 - pit + grain, 0.0, 1.0)
    print(f"height sd {height.std():.4f}")

    # Smoothness follows height (README rule): the bubble pits, the deepest
    # recesses here, come out roughest; the flat cast face reads even and
    # fairly matte, with the class level (pack() moves the mean there)
    # doing most of that work and only the surface's own patchy variation,
    # from a second noise field, riding on top for spread.
    variation = lib.fbm(SIZE, base_cells=60, octaves=3, seed=VARIATION_SEED, gain=0.5)
    smooth = 0.6 * (height - height.mean()) + 0.6 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    # Nearest upscale keeps the art's own texel plateaus.
    albedo = lib.upscale(rgb)

    m = lib.pack(stem, out_dir, albedo, height, smooth, cls,
            normal_strength=NORMAL_STRENGTH)
    print(f"normal_strength={NORMAL_STRENGTH}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, cls)
    for line in lines:
        print(line)
    if cls == "stone" and m["tilt_mean_deg"] < 28:
        print("note tilt target above is stone's masonry joint figure (28 "
                "to 40 deg); this is a smooth cast slab, not jointed "
                "masonry, so the low tilt is the surface as built, not a "
                "shortfall to noise away")
    lib.preview(out_dir, stem, str(out_dir) + "/" + stem + "_preview.png")
    return lines


if __name__ == "__main__":
    sys.exit("run a per stem script, e.g. mcl_colorblocks_concrete_white.py, "
            "not this module directly")
