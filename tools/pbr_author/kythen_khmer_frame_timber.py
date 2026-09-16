"""Hand authored height and smoothness for kythen_khmer_frame_timber.

The 32 px art has five shades scattered with no region lib.segments could
usefully separate: 96 percent of the darkest shade sits away from any
column pattern, and the only rhythm at all is that the darkest shade never
occurs off columns 0, 4, 8, ... 28 (the same period as
kythen_khmer_plank_timber.py's boards), but only 3 to 41 percent of the
time there, far too sparse and uneven to be a drawn joint the way the
plank's own columns are. lib.class_of reads "soil" back from the bake, a
level readback artefact with no bearing here (frame_timber sits right
beside kythen_khmer_column_timber.py and kythen_khmer_plank_timber.py in
the brief, all three called out as timber), overridden to "wood".

Read as a surface rather than a masonry style layout, this is a length of
structural timber with its own grain and the odd tool mark, not a wall
built from boards: the relief comes mostly from directional grain along y
(a frame member stands, like the column) with only a faint groove at the
same period the other two timber stems draw a real joint at, since a
framed post does sit against its neighbours even where the art does not
draw a clean line there.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_frame_timber"
CLS = "wood"
SIZE = lib.SIZE
ART = 32
REP = SIZE // ART


def main(out_dir):
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.4f} max {lum.max():.4f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 4).tolist())))
    print(f"class_of reads: {lib.class_of(STEM, GAME)}, overridden to {CLS} "
            "(this stem sits with the brief's other timber stems)")

    faint_joint = np.array([c % 4 == 0 for c in range(ART)])
    joint_hi = np.tile(np.repeat(faint_joint, REP)[None, :], (SIZE, 1))
    dist = lib.distance_to_edge(joint_hi.astype(np.float32), max_dist=2)
    t = np.clip(dist / 2.0, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    # The art's own per texel brightness, upscaled with a wrapped blur (not
    # lib.upscale's smooth=True bilinear resize, which does not wrap: see
    # kythen_khmer_earthenware_tile.py's own note on that), as a faint
    # guide to where the timber happens to be lighter or darker.
    norm_lum = (lum - lum.mean()) / max(float(lum.std()), 1e-6)
    dash = lib.blur(lib.upscale(norm_lum), 1)

    # Long grain up the member, the dominant feature of a standing post.
    grain_src = lib.fbm(SIZE, base_cells=8, octaves=2, seed=851)
    grain = np.zeros_like(grain_src)
    for d in range(-10, 11):
        grain += np.roll(grain_src, d, axis=0)
    grain /= 21.0

    # A scatter of small tool marks and checks, sparser than the column's
    # adze facets: this is a dressed structural member, not a hewn post.
    marks = lib.blur(lib.white_noise(SIZE, seed=852), 1)
    mark_cut = float(np.percentile(marks, 12))
    marks = np.where(marks < mark_cut, marks - mark_cut, 0.0)

    layout = 0.30 * grain + 0.20 * dash + 0.25 * marks - 0.85 * (1.0 - t)
    height = lib.normalise01(layout, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # A blurred copy of height, not the raw field: pack()'s own fine_detail
    # pass quietly smooths the narrow joint's worst seam behaviour out of
    # the normal and occlusion maps, but the smoothness map is built here,
    # before that pass, so it needs the same easing by hand or the joint's
    # sharp edge reads as a bad tile in _s even though _n comes out clean.
    rough_noise = lib.fbm(SIZE, base_cells=22, octaves=3, seed=853, gain=0.55)
    smooth = 0.4 * lib.blur(height, 2) + 0.6 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 14.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=ART)
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
    lines = main(out_dir)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
