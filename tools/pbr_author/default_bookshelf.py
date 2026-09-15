"""Hand authored LabPBR height and smoothness for default_bookshelf.

The art carries 43 shades, mostly saturated book cover colours, but rows
0, 7, 8 and 15 and columns 0 and 15 stand apart: they use only the same
dozen brown, plank coloured shades wherever they occur (lum 0.104 to
0.561), never a book colour, and row means confirm it (rows 7 and 15 sit at
0.439, every other row 0.16 to 0.30). That is the shelf's own frame, two
horizontal boards and two end posts, in the shape of a capital H: it splits
the face into two six row compartments, rows 1 to 6 and rows 9 to 14, each
its own row of books between the posts.

Segmenting the whole face at tolerance 0.05 (138 regions) never merges a
frame texel into a book region or the reverse, since the two palettes never
come within 0.05 of each other; the frame rows and posts come back as their
own large, clean regions. Inside the compartments the regions are mostly
one or two texels, book covers a few texels wide with their own highlight
and shadow shade, and the very darkest shade band, 0.092 to 0.150, appears
only as thin, scattered marks between them: not one material, the crease
where two spines meet and the shadow line down the near side of a spine.
"""
import sys

import numpy as np

import lib

STEM = "default_bookshelf"
CLS = "wood"
SIZE = lib.SIZE
SEG_TOLERANCE = 0.05
CREASE_LUM_MAX = 0.16


def frame_mask_lowres():
    m = np.zeros((16, 16), dtype=bool)
    m[[0, 7, 8, 15], :] = True
    m[:, [0, 15]] = True
    return m


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("row means:", np.round(lum.mean(axis=1), 3).tolist())

    frame = frame_mask_lowres()
    print(f"frame texels: {int(frame.sum())} of 256")

    labels, n = lib.segments(rgb, tolerance=SEG_TOLERANCE)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    frame_share = np.array([frame[labels == i].mean() for i in range(n)])
    is_frame_region = frame_share > 0.5
    print(f"segments: n={n} tolerance={SEG_TOLERANCE}, "
          f"{int(is_frame_region.sum())} frame regions, {int((~is_frame_region).sum())} book regions")

    crease = (~is_frame_region) & (region_lum < CREASE_LUM_MAX)
    print(f"crease regions: {int(crease.sum())}, "
          f"{int(sizes[crease].sum())} texels of {int(sizes[~is_frame_region].sum())} book texels")

    book = ~is_frame_region & ~crease
    lo, hi = region_lum[book].min(), region_lum[book].max()
    book_target = 0.42 + 0.28 * (region_lum - lo) / max(hi - lo, 1e-6)

    # Book chips get a light, organic warp: a spine's own edge is not
    # machined straight the way a masonry joint is, it is a worn page edge.
    # The frame keeps its rectilinear shape, an ordinary plank board, by
    # going up at native resolution with no warp at all.
    frame_hi = np.repeat(np.repeat(is_frame_region[labels], 16, axis=0), 16, axis=1)

    labels_hi = lib.warp_labels(labels, amp=1.5, seed=81)
    crease_hi = crease[labels_hi]
    edges = lib.region_edges(labels_hi)
    max_dist = 3  # a crease between books, not a masonry groove
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    crease_level = 0.20
    target_hi = np.where(crease_hi, crease_level, book_target[labels_hi])
    book_layout = target_hi * t + crease_level * (1 - t)

    frame_level = 0.68
    frame_grain = lib.fbm(SIZE, base_cells=20, octaves=3, seed=51, gain=0.55) * 0.06
    frame_layout = frame_level + frame_grain

    frame_t = lib.blur(frame_hi.astype(np.float32), 2)
    layout = book_layout * (1 - frame_t) + frame_layout * frame_t

    # Paper texture on the book spines: a fine, slightly directional
    # scratch, the grain a page edge shows end on.
    paper = lib.blur(lib.white_noise(SIZE, seed=82), 1) * 0.03
    layout = layout + paper * (1 - frame_t)

    height = lib.normalise01(layout, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: the frame is a plank, worn smoother than paper; book
    # covers are matte, their own patchy variation on top, the creases
    # between them collect dust and stay roughest of all.
    rough_noise = lib.fbm(SIZE, base_cells=18, octaves=3, seed=53)
    smooth = 0.35 * frame_t + 0.35 * t * (1 - frame_t) + 0.4 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 12.0
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
