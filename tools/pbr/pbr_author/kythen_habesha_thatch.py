"""Hand authored LabPBR height and smoothness for kythen_habesha_thatch,
bundled stalks laid in overlapping courses, a thatched roof face.

The 32 px art's row and column means are all close together (0.51 to 0.56
either way), which first looks like no directional structure at all, but
that is only because the real structure runs on neither axis: it is
diagonal. Grouping texels by the two diagonal coordinates instead shows
the difference plainly. Along x + y (the "/" diagonal, running from lower
left to upper right) the texels in one group vary by only 0.042 luminance
on average; along x - y ("\\") they vary by 0.076, and along a plain row or
column by 0.094 to the same rounding. The "/" direction is the one the art
holds most constant, which is the direction the stalks themselves run.

Reading a cross section across the grain (varying x - y, averaged over
x + y) turns up a clean period 2 comb: alternating low and high luminance
every single texel, argmin and argmax one apart. That is bundled stalks
drawn about one texel wide each, tight enough that at 32 px they read as a
fine diagonal hatch rather than individually countable stalks. The row
profile carries only a weak single wave across the whole 32 rows (min at
row 22, max at row 3, amplitude 0.038), nothing like timber_laced's sharp
banding, so the overlapping courses the brief describes are not something
this art draws in colour; they are added here as a gentle proud step every
eight rows, physically motivated (a thatched course overlaps and shadows
the one below it) but honestly not something the art's own numbers force,
kept subordinate to the diagonal stalk structure that the art does show.

Six colours in total: four in the ordinary comb range, a bright one that is
actually the light phase of the comb itself (636 of 1024 texels, not a rare
highlight), and a warm reddish one on only two texels, which is treated as
a scattered tie mark, the one piece of colour signal in this art that is
genuinely rare rather than structural.

The stalks are genuinely straight and directional the way default_tree.py's
bark furrows are, so they are built the same way: a straight, unwarped
profile across the grain (here a diagonal coordinate, x - y, rather than a
plain column), not lib.warp_labels, with the organic width and bundling
variation added afterward as noise blurred along the grain direction only,
the diagonal equivalent of default_tree.py's blur_axis.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_thatch"


def smoothstep(t):
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3 - 2 * t)


def blur_diag(field, radius, dy, dx):
    """Wrapped blur along one diagonal only: default_tree.py's blur_axis
    stretches a feature along a row or column axis; a diagonal grain needs
    the same idea along (dy, dx) instead, moving both axes together."""
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for s in range(-radius, radius + 1):
        acc += np.roll(field, (s * dy, s * dx), axis=(0, 1))
    return acc / k


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    uniq = sorted(set(np.round(lum.ravel(), 3).tolist()))
    print("unique shades:", uniq)
    cls = lib.class_of(STEM, GAME)
    print(f"lib.class_of reads: {cls}")

    for tol in (0.03, 0.06, 0.1):
        seg_labels, n = lib.segments(rgb, tolerance=tol)
        sizes = sorted([int((seg_labels == i).sum()) for i in range(n)], reverse=True)
        print(f"lib.segments tolerance {tol}: {n} regions, sizes {sizes[:10]}"
              f"{' ...' if len(sizes) > 10 else ''}")

    h, w = lum.shape
    yy, xx = np.mgrid[0:h, 0:w]
    d_slash = (xx + yy) % w   # constant along the "/" diagonal
    d_back = (xx - yy) % w    # constant along the "\" diagonal
    slash_std = np.array([lum[d_slash == i].std() for i in range(w)]).mean()
    back_std = np.array([lum[d_back == i].std() for i in range(w)]).mean()
    print(f"mean within group std: row {lum.std(axis=1).mean():.3f}, "
          f"col {lum.std(axis=0).mean():.3f}, '/' diagonal {slash_std:.3f}, "
          f"'\\' diagonal {back_std:.3f} (lowest wins: the grain direction)")

    cross = np.array([lum[d_back == i].mean() for i in range(w)])
    print("cross grain profile (by x - y):", np.round(cross, 3))
    print(f"argmin {cross.argmin()} argmax {cross.argmax()}: one apart, a period 2 comb")

    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    knot_mask = (np.abs(r - 0.690) < 0.02) & (np.abs(g - 0.408) < 0.02) & (np.abs(b - 0.282) < 0.02)
    print(f"knot (rare reddish) texels: {int(knot_mask.sum())} of {knot_mask.size}")

    row_mean = lum.mean(axis=1)
    print("row means:", np.round(row_mean, 3))

    SIZE = lib.SIZE
    yy_hi, xx_hi = np.mgrid[0:SIZE, 0:SIZE]

    # The stalks: a straight (unwarped) period across the grain, the same
    # reasoning default_tree.py gives for a genuinely straight, directional
    # bark furrow, here diagonal instead of a plain column. Two 32 px art
    # texels wide, matching the comb's own period, scaled by the 8x upscale.
    period = 2 * (SIZE // src.shape[0])
    phase = ((xx_hi - yy_hi) % period) / period
    tri = 1.0 - np.abs(2 * phase - 1.0)
    ridge = smoothstep(tri)

    # Organic width and bundling: low frequency noise, coherent along the
    # grain (blurred along the "/" direction) so one stalk keeps a
    # consistent width along its own run rather than pinching at random.
    width_src = lib.fbm(SIZE, base_cells=10, octaves=2, seed=71)
    width_jitter = blur_diag(width_src, radius=10, dy=1, dx=-1) * 0.18

    stalks = ridge * 0.55 + width_jitter

    # Courses: a gentle proud step every eight rows, the lower part of each
    # course sitting a little higher than the one above it settles into,
    # since a thatched course overlaps the course below it. Kept modest:
    # the art's own row signal is a weak single wave, not a strong band.
    course_h = 8
    course_phase = (yy_hi % course_h) / course_h
    course_step = smoothstep(course_phase) * 0.10

    # The rare knot texels: a small proud tie mark, nearest upscaled so it
    # sits where the art actually draws it, softened a touch.
    scale = SIZE // src.shape[0]
    knot_hi = np.repeat(np.repeat(knot_mask.astype(np.float32), scale, axis=0), scale, axis=1)
    knot_bump = lib.blur(knot_hi, 2) * 0.10

    # Fibre grain along the stalks themselves, the diagonal equivalent of
    # default_tree.py's along-grain blur.
    grain_src = lib.blur(lib.white_noise(SIZE, seed=72), 1)
    grain = blur_diag(grain_src, radius=6, dy=1, dx=-1) * 0.05

    layout = stalks + course_step + knot_bump + grain
    height = lib.normalise01(layout, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: stalk crests are what the weather and the
    # sun reach, worn smoother; the grooves between them and the knots stay
    # rougher, with the material's own patchy variation on top.
    rough_noise = lib.fbm(SIZE, base_cells=18, octaves=3, seed=73)
    smooth = 0.55 * height + 0.4 * rough_noise
    smooth = np.where(knot_hi > 0.5, smooth - 0.10, smooth)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 4
    m = lib.pack(STEM, out_dir, albedo, height, smooth, "leaves",
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, "leaves")
    for line in lines:
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
