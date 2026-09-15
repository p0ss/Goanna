"""Hand authored LabPBR height and smoothness for default_tnt_side.

Row means split the face cleanly: rows 5 to 11 sit at 0.59 to 0.79, every
other row at 0.30 to 0.33. The bright band is the paper label, glued to
the stick; the rest is the wrapping paper itself, and there each row
repeats its own four column shades every four texels (row 0 goes 8, 4, 5,
9; row 4 goes 8, 5, 6, A; and so on, all nine wrap rows the same period,
different shades), a stack of vertical creases running the paper wraps a
cylinder in.

The first pass read that shading straight into height and added a fibre
and pore grain on top, which read as concrete rather than paper: paper
does not have aggregate texture, only the fold. This rebuild throws the
grain away and builds the fold itself, a gentle cosine ridge at the art's
own four texel period, held in a narrow lib.band so the relief stays a
texel or two, never a slab's worth. The label sits a hair below that as
its own flat plane, the printed mark (the art's two darkest label shades,
0.217 and 0.314, nothing between them and the cream background) recessed
a hair further still. Smoothness is independent noise, not derived from
the fold, since a paper crease does not collect any more dust than the
flat either side of it.
"""
import sys

import numpy as np

import lib

STEM = "default_tnt_side"
CLS = "wood"
SIZE = lib.SIZE
LABEL_ROWS = list(range(5, 12))

FOLD_PERIOD_TEXELS = 4     # the art's own column repeat
FOLD_HALF_WIDTH = 0.05     # a texel or two of relief, not a slab
LABEL_BELOW = 0.15         # the label sits this far below the wrap's centre
TEXT_RECESS = 0.12         # the printed mark, further again
TEXT_LUM_MAX = 0.40        # the two darkest label shades only
EDGE_GROOVE = 0.35         # a real, glued seam where the label meets the wrap
EDGE_CHAMFER = 1           # one texel: a scored line, not a bevel

SMOOTH_SEED = 115


def paper_fold(size=SIZE, period_texels=FOLD_PERIOD_TEXELS, phase_texels=1.0):
    """A gentle cosine ridge across the columns, one cycle per
    period_texels source texels, matching the art's own fold rhythm.
    Constant down each column, since the crease runs the height of the
    wrap. phase_texels shifts the peak to sit near the art's own brightest
    column rather than at texel 0."""
    period_map = period_texels * 16
    phase_map = phase_texels * 16
    x = np.arange(size, dtype=np.float32)
    wave = np.cos(2 * np.pi * (x - phase_map) / period_map)
    return np.broadcast_to(wave[None, :], (size, size)).copy()


def build(stem, label_rows=LABEL_ROWS):
    src = lib.load_source(stem)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{stem}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")

    label_row = np.zeros((16, 16), dtype=bool)
    label_row[label_rows, :] = True
    label_hi = lib.upscale(label_row.astype(np.float32), smooth=False)
    label_t = lib.blur(label_hi, 3)
    print(f"label rows: {int(label_row[:, 0].sum())} of 16")

    fold = lib.band(paper_fold(), half_width=FOLD_HALF_WIDTH)

    text_mask = (lum < TEXT_LUM_MAX) & label_row
    text_hi = lib.upscale(text_mask.astype(np.float32), smooth=False)
    text_hi = lib.blur(text_hi, 1)
    label_plane = (0.5 - LABEL_BELOW) - TEXT_RECESS * text_hi

    height = fold * (1 - label_t) + label_plane * label_t

    # A scored line right at the label's own edge, where it is glued down
    # over the wrap: real occlusion for a real seam, not just the shading
    # either side of it.
    label_edge = lib.region_edges(label_hi > 0.5)
    edge_dist = lib.distance_to_edge(label_edge, max_dist=EDGE_CHAMFER)
    edge_groove = np.clip(1.0 - edge_dist / EDGE_CHAMFER, 0.0, 1.0)
    height = height - EDGE_GROOVE * edge_groove
    print(f"height sd {height.std():.3f}")

    # Smoothness: even and fairly matte, not tied to the fold (a crease is
    # not dustier than the flat paper either side of it). The material's
    # own slight variation, plus a touch more sheen on the printed label.
    smooth_noise = lib.fbm(SIZE, base_cells=24, octaves=3, seed=SMOOTH_SEED, gain=0.55)
    smooth = 0.5 + 0.4 * smooth_noise + 0.05 * label_t
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])
    return height, smooth, albedo


def main():
    out_dir = sys.argv[1]
    height, smooth, albedo = build(STEM)

    normal_strength = 10.0
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
