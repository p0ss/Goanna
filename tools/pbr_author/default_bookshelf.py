"""Hand authored LabPBR height and smoothness for default_bookshelf.

The art carries 43 shades, mostly saturated book cover colours, but rows
0, 7, 8 and 15 and columns 0 and 15 stand apart: they use only the same
dozen brown, plank coloured shades wherever they occur (lum 0.104 to
0.561), never a book colour, and row means confirm it (rows 7 and 15 sit at
0.439, every other row 0.16 to 0.30). That is the shelf's own frame, two
horizontal boards and two end posts, in the shape of a capital H: it splits
the face into two six row compartments, rows 1 to 6 and rows 9 to 14, each
its own row of books between the posts.

The very darkest shade band inside the compartments, 0.092 to 0.150,
appears only as thin, scattered marks: not one material, the crease where
two spines meet and the shadow line down the near side of a spine. The
first pass segmented the whole face by colour and gave each little
highlight or shadow patch inside a spine its own region, warped and domed
the way a cobble chip is, which is why the spines read as chunks rather
than books: a spine's own internal shading is not a second material.

This rebuild finds only the crease, by shade the same way
default_stone_brick.py finds mortar, and holds everything else, frame
included, flat. A spine gets a hairline recess at the crease and, across
the width between two creases, at most a faint convex crown; nothing else
raises or domes it. The frame sits proud of the spines by a couple of
texels, an ordinary plank board, and covers take a little more sheen than
the frame does.
"""
import sys

import numpy as np

import lib

STEM = "default_bookshelf"
CLS = "wood"
SIZE = lib.SIZE
CREASE_LUM_MAX = 0.16

SPINE_HALF_WIDTH = 0.04   # the spine faces: flat, fine cover grain only
CROWN_DIST = 20           # map texels over which a spine's faint crown rises
CROWN_AMP = 0.035         # at most a faint convexity, never a dome
RECESS_DIST = 2           # the hairline crease itself: one texel wide, soft
CREASE_FLOOR = 0.30       # recessed a little below the spine band

FRAME_LEVEL = 0.72        # proud of the spine band by a couple of texels
FRAME_GRAIN_AMP = 0.05

GRAIN_SEED = 83
PORE_SEED = 84
FRAME_GRAIN_SEED = 51     # shared with mcl_books_bookshelf_top's own plank
ROUGH_SEED = 53


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

    frame = frame_mask_lowres()
    crease = (~frame) & (lum < CREASE_LUM_MAX)
    print(f"frame texels: {int(frame.sum())} of 256, crease texels: {int(crease.sum())}")

    frame_hi = lib.upscale(frame.astype(np.float32), smooth=False)
    crease_hi = lib.upscale(crease.astype(np.float32), smooth=False)

    # A faint crown, peaking midway between one crease and the next: this
    # is the only curvature a spine gets, capped well short of a dome.
    dist_crown = lib.distance_to_edge(crease_hi, max_dist=CROWN_DIST)
    dist_crown = np.where(crease_hi > 0.5, 0.0, dist_crown)
    crown_t = np.clip(dist_crown / CROWN_DIST, 0.0, 1.0)
    crown_t = crown_t * crown_t * (3 - 2 * crown_t)

    # The crease itself: much narrower than the crown, a scored hairline.
    dist_recess = lib.distance_to_edge(crease_hi, max_dist=RECESS_DIST)
    dist_recess = np.where(crease_hi > 0.5, 0.0, dist_recess)
    recess_t = np.clip(dist_recess / RECESS_DIST, 0.0, 1.0)
    recess_t = recess_t * recess_t * (3 - 2 * recess_t)

    cover_grain = (lib.fbm(SIZE, base_cells=40, octaves=3, seed=GRAIN_SEED, gain=0.55) * 0.7
            + lib.blur(lib.white_noise(SIZE, seed=PORE_SEED), 1) * 0.3)
    spine_band = lib.band(cover_grain, half_width=SPINE_HALF_WIDTH)
    spine_height = spine_band + CROWN_AMP * crown_t
    spine_height = spine_height * recess_t + CREASE_FLOOR * (1 - recess_t)

    frame_grain = lib.fbm(SIZE, base_cells=20, octaves=3, seed=FRAME_GRAIN_SEED, gain=0.55)
    frame_height = FRAME_LEVEL + frame_grain * FRAME_GRAIN_AMP

    frame_t = lib.blur(frame_hi, 2)
    height = spine_height * (1 - frame_t) + frame_height * frame_t
    print(f"height sd {height.std():.3f}")

    # Smoothness: covers take a little more sheen than the frame, the
    # crease collecting dust and staying roughest of all.
    rough_noise = lib.fbm(SIZE, base_cells=18, octaves=3, seed=ROUGH_SEED)
    smooth = 0.5 + 0.3 * rough_noise + 0.12 * (1 - frame_t) - 0.15 * (1 - recess_t)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 16.0
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
