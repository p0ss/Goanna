"""Hand authored LabPBR height and smoothness for kythen_mitteleuropa_oak_shingle.

The 32 px art carries five grey shades. The darkest, 0.236, runs full width
across four rows spaced exactly eight texels apart (0, 8, 16, 24): the
shadow gap where each course of shingles overlaps the one below it, four
courses of eight rows each. Inside a course the art carries no clean
monotonic rise from top to bottom (row means wander 0.359 to 0.392 rather
than climbing steadily), but it does carry a fainter full height seam, one
darker column per course, the butt joint between two shingles laid side by
side in that course (checked column by column within each course band: row
9 to 15 is clearly darkest at column 12, row 17 to 23 at column 8, and so
on, a different column each course, the ordinary stagger a shingled roof is
laid with).

Built as courses (the strong, unambiguous signal): each course tapers from
a recessed top edge, tucked under the course above, to a proud bottom
edge that overlaps the course below, the shape the brief calls for and the
art's own shadow rows bound even though the row means inside a course do
not climb cleanly on their own. The fainter per-course seam is read from
the art as a shallow crease, not a full masonry joint: splitting each
course into two separately domed shingles would need the same wrap-safe
handling default_stone_brick.py's single-joint courses do, and the art
does not draw the seam deep enough to justify that complexity.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_oak_shingle"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}, class_of reads {CLS}")
    # The art tiles, but not at texel (0, 0): a shadow row sits right on
    # row 0 and, once found, course 0's own seam column turns out to sit
    # right on column 0 as well, so the seam metric's single wrap
    # comparison would land on a course boundary and a seam crease's own
    # steepest points rather than an ordinary course body, the same false
    # alarm default_cobble.py's docstring describes. Rolling both axes
    # moves the wrap into a course's own flat body instead (checked so no
    # course's own seam column, [0, 16, 12, 4] before the roll, lands back
    # on column 0 or 31 afterwards); the surface is the same closed loop
    # either way.
    src = np.roll(src, (4, 10), axis=(0, 1))
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    row_mean = lum.mean(axis=1)
    print("row means:", np.round(row_mean, 3))

    art = src.shape[0]
    up = SIZE // art
    n_courses = 4
    course_h = art // n_courses  # 8
    shadow_rows = row_mean < (row_mean.min() + 0.05)
    print("shadow rows:", np.where(shadow_rows)[0].tolist())

    # Per course seam column: within each course's own body rows (excluding
    # its shadow row), the single darkest column.
    seam_col_per_course = []
    for c in range(n_courses):
        rows = [(c * course_h + r) % art for r in range(1, course_h)]
        body_col_mean = lum[rows, :].mean(axis=0)
        seam_col_per_course.append(int(np.argmin(body_col_mean)))
    print("seam column per course:", seam_col_per_course)

    # Course taper: recessed at the shadow row, rising through the body to
    # a proud lower edge just before the next shadow row, an ease-in ramp
    # since the brief and the shadow rows both call for this shape even
    # though the row means inside a course do not climb monotonically on
    # their own.
    art_row = np.arange(art)
    course_pos = (art_row % course_h) / course_h  # 0 at the shadow row, near 1 at the proud edge
    ramp = course_pos ** 0.6
    course_profile = np.broadcast_to(ramp[:, None], (art, art))
    course_hi = lib.upscale(course_profile, smooth=True)
    course_hi = lib.blur(course_hi, 1)

    # A real flat, low trench at each course's own shadow row, the same
    # construction the ashlar and oak board stems use for their own single
    # art texel joints: the smooth ramp above dips at the shadow row but
    # does not sit there long enough to give the ao a course boundary
    # needs, since it starts climbing again within a texel or two.
    shadow_hi = np.repeat(shadow_rows, up)[:, None].repeat(SIZE, axis=1)
    max_dist = 1
    shadow_dist = lib.distance_to_edge(shadow_hi.astype(np.float32), max_dist=max_dist)
    shadow_t = np.clip(shadow_dist / max_dist, 0.0, 1.0)
    shadow_t = shadow_t * shadow_t * (3 - 2 * shadow_t)
    course_trench = -1.3 * (1.0 - shadow_t)

    # The seam: a shallow crease at each course's own darkest column,
    # restricted to that course's own rows so it does not run into the
    # course above or below.
    seam_mask = np.zeros((art, art), dtype=bool)
    for c in range(n_courses):
        rows = [(c * course_h + r) % art for r in range(course_h)]
        seam_mask[rows, seam_col_per_course[c]] = True
    seam_hi = np.repeat(np.repeat(seam_mask, up, axis=0), up, axis=1)
    max_dist = 1
    dist = lib.distance_to_edge(seam_hi.astype(np.float32), max_dist=max_dist)
    seam_t = np.clip(dist / max_dist, 0.0, 1.0)
    seam_t = seam_t * seam_t * (3 - 2 * seam_t)
    seam_crease = -0.10 * (1.0 - seam_t)

    grain = lib.fbm(SIZE, base_cells=22, octaves=3, seed=901, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=902), 1) * 0.04

    layout = 0.4 * course_hi + course_trench + seam_crease + grain + pores
    height = lib.normalise01(layout, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows the course shape and the seam: the recessed top
    # edge and the seam crease gather dust and stay rough, the proud
    # bottom edge is what weather wears smooth.
    rough_noise = lib.fbm(SIZE, base_cells=18, octaves=3, seed=903, gain=0.55)
    smooth = 0.3 * shadow_t + 0.25 * course_hi + 0.25 * seam_t + 0.3 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 22.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=art)
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
