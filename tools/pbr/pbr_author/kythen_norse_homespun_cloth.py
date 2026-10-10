"""Norse homespun cloth: a woven weave, matte, with a visible warp and weft.

32 px art, nine shades, and a clean period-4 repeat in both directions
(checked by hand: averaging every 4x4 block across the tile gives one
canonical cell, and every one of the 64 blocks matches it to within
rounding). That canonical cell is a smooth gradient from 0.330 at one
corner to 0.704 at the opposite corner, with the other two corners close
to each other and intermediate (0.414, 0.409): the signature of two
perpendicular ramps multiplied together, brightest where a horizontal and
a vertical highlight coincide, darkest where both fall away, exactly what
a small square of two threads crossing looks like lit from one direction.
Four map texels per art texel puts the thread repeat at 32 map texels,
dividing the 256 map exactly eight times, so a periodic construction at
that period tiles by construction with no wrap seam to manage.

Unlike wool_family.py's isotropic bundle noise (right for felted wool,
which has no visible thread direction), this is woven cloth, so the height
field is built from two real perpendicular thread systems, a vertical warp
and a horizontal weft, each a rounded ridge running the length of its own
axis, combined through a plain-weave over-under checkerboard so the warp
rides on top of the weft in one sub-cell and tucks under it in the next,
the same alternation a real over-one-under-one weave makes. A fine twist
texture runs along each thread's own axis on top, and the whole tile stays
matte, the same low, mostly rough smoothness wool_family.py builds.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_homespun_cloth"
SIZE = lib.SIZE
SEED = 9701


def blur_axis(field, radius, axis):
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def thread_ridge(t, width=0.62):
    """A rounded ridge along one axis of a periodic thread: t is the local
    position within one thread period, 0 to 1. Raised across width of the
    period, centred at 0.5, flat (the gap between threads) elsewhere."""
    d = np.abs(t - 0.5)
    half = width / 2.0
    ridge = np.where(d < half, 0.5 * (1.0 + np.cos(np.pi * d / half)), 0.0)
    return ridge


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    n = src.shape[0]
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print("lum min %.3f max %.3f mean %.3f sd %.3f" % (lum.min(), lum.max(), lum.mean(), lum.std()))

    period_art = 4
    tile = np.zeros((period_art, period_art), dtype=np.float32)
    reps = n // period_art
    for oy in range(reps):
        for ox in range(reps):
            tile += lum[oy * period_art:oy * period_art + period_art,
                    ox * period_art:ox * period_art + period_art]
    tile /= reps * reps
    print("canonical 4x4 cell (averaged over every repeat):")
    print(np.round(tile, 3))

    cls_needle = lib.class_of(STEM, GAME)
    print(f"class_of reads: {cls_needle} (overridden to cloth: this is a weave, not foliage, "
          f"a name-matching gap with no wool or cloth entry in NAME_HINTS)")
    cls = "cloth"

    scale = SIZE // n
    period = period_art * scale
    print(f"thread period: {period_art} art texels = {period} map texels, "
          f"dividing {SIZE} exactly {SIZE // period} times")

    yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    u = (xx % period) / period
    v = (yy % period) / period

    warp = thread_ridge(u)   # vertical threads, ridge runs along y
    weft = thread_ridge(v)   # horizontal threads, ridge runs along x

    # Plain weave: over one, under one. Each thread period is split into
    # two halves along its own axis (the odd and even thread), and the
    # over/under sense alternates in a checkerboard of those halves, the
    # same over-under alternation a real plain weave has.
    ix = (xx // (period / 2)).astype(int) % 2
    iy = (yy // (period / 2)).astype(int) % 2
    warp_over = (ix + iy) % 2 == 0

    tuck = 0.28  # how far the tucked-under thread recedes
    warp_h = np.where(warp_over, warp, warp * (1.0 - tuck))
    weft_h = np.where(warp_over, weft * (1.0 - tuck), weft)
    weave = np.maximum(warp_h, weft_h)

    # Twist texture along each thread's own axis: warp threads get grain
    # running along y, weft threads along x, the same directional blur
    # this game's timber scripts use for grain running the length of a
    # board.
    warp_twist = blur_axis(lib.fbm(SIZE, base_cells=48, octaves=2, seed=SEED + 1, gain=0.5),
            radius=1, axis=0) * 0.10
    weft_twist = blur_axis(lib.fbm(SIZE, base_cells=48, octaves=2, seed=SEED + 2, gain=0.5),
            radius=1, axis=1) * 0.10
    twist = np.where(warp >= weft, warp_twist, weft_twist)

    fuzz = lib.blur(lib.white_noise(SIZE, seed=SEED + 3), 1) * 0.05

    height = lib.normalise01(weave + twist + fuzz, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: matte throughout, the same wool_family.py reasoning,
    # with only a faint whisper following the weave so a proud thread top
    # reads a shade less rough than the gap beside it.
    variation = lib.fbm(SIZE, base_cells=40, octaves=2, seed=SEED + 4, gain=0.5)
    smooth = 0.15 * (height - height.mean()) + 0.5 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 2.5
    m = lib.pack(STEM, out_dir, albedo, height, smooth, cls,
            normal_strength=normal_strength, art_texels=n)
    print(f"normal_strength={normal_strength}  class={cls}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, cls)
    for line in lines:
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
