"""Hand authored LabPBR height and smoothness for default_tnt_side.

Row means split the face cleanly: rows 5 to 11 sit at 0.59 to 0.79, every
other row at 0.30 to 0.33. The bright band is the paper label, glued to
the stick; the rest is the wrapping paper itself, and there each row
repeats its own four column shades every four texels (row 0 goes 8, 4, 5,
9; row 4 goes 8, 5, 6, A; and so on, all nine wrap rows the same period,
different shades), a stack of vertical creases running the paper wraps a
cylinder in. The label's own lum values are almost binary: four close
cream shades, 0.677 to 0.852, for its background, and two much darker
ones, 0.217 and 0.314, for the TNT mark printed on it, nothing between.

The wrap's crease shading is read straight from the art as height, since
the art already draws the fold by shading it; the label sits a hair below
that as its own flat plane, with the printed mark recessed a touch further
into it.
"""
import sys

import numpy as np

import lib

STEM = "default_tnt_side"
CLS = "wood"
SIZE = lib.SIZE
LABEL_ROWS = list(range(5, 12))


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("row means:", np.round(lum.mean(axis=1), 3).tolist())

    label_row = np.zeros((16, 16), dtype=bool)
    label_row[LABEL_ROWS, :] = True
    label_hi = lib.upscale(label_row.astype(np.float32), smooth=False)
    label_t = lib.blur(label_hi, 3)
    print(f"label rows: {int(label_row[:, 0].sum())} of 16")

    # The wrap: its own shading is the fold, upscaled and smoothed a touch
    # so the pixel grid does not show through as a second, false crease.
    lum_hi = lib.upscale(lum, smooth=False)
    wrap_layout = 0.35 + 0.45 * lib.blur(lum_hi, 2)

    # The label: a flat plane a hair below the wrap's own mean level, the
    # printed mark recessed further still. text_hi comes from the art's own
    # two darkest label shades, not a separate mask, since nothing else on
    # the label is that dark.
    text_mask = lum < 0.40
    text_hi = lib.upscale((text_mask & label_row).astype(np.float32), smooth=False)
    text_hi = lib.blur(text_hi, 1)
    label_layout = 0.42 - 0.30 * text_hi

    layout = wrap_layout * (1 - label_t) + label_layout * label_t

    # A scored line where the label's own edge overlaps the wrap: real
    # occlusion for a real seam, not just the shading either side of it.
    label_edge = lib.region_edges(label_hi > 0.5)
    edge_dist = lib.distance_to_edge(label_edge, max_dist=3)
    edge_groove = np.clip(1.0 - edge_dist / 3, 0.0, 1.0)
    layout = layout - 0.12 * edge_groove

    # Paper fibre: fine, mostly isotropic noise, a slight lengthwise streak
    # since paper this thin still shows a grain from how it was cut.
    fibre = lib.fbm(SIZE, base_cells=30, octaves=3, seed=111, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=112), 1) * 0.03
    layout = layout + fibre + pores

    height = lib.normalise01(layout, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: the label paper is a touch smoother than the coarser
    # wrapping paper, the printed mark rougher still where the ink sits.
    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=113, gain=0.55)
    smooth = 0.3 * label_t - 0.15 * text_hi + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 20.0
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
