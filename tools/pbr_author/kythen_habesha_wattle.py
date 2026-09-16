"""Hand authored LabPBR height and smoothness for kythen_habesha_wattle,
woven withies.

The 32 px art has a clean period four pattern in both row means and column
means: [0.19, 0.28, 0.30, 0.31] repeating eight times across both axes,
identically. A withy runs as a rounded strand about three texels wide with
a one texel dark gap where the weave dips under its neighbour, in both the
horizontal and the vertical direction at once, which is exactly what a
plain basket weave looks like seen face on.

Because the row and column statistics are identical, there is no signal in
the art that says which strand goes over and which goes under at a given
crossing (an actual over-under alternation would show up as different
brightness on alternating crossings, and it does not here). Rather than
invent an alternation the art does not draw, the two directions are built
as two ridge fields, one varying only with y and one only with x, each
tiling exactly on its own period, and combined with max() so both strands
read continuously along their own length and a crossing reads as a
slightly higher knot where two withies meet, which is what this art
actually shows.

IMPORTANT for the next person tempted to add a real over-under checkerboard
here: it has been tried three times in this file's history and has failed
the tile every time, for the same structural reason each time, whether the
swap is a hard coefficient flip, a np.where on the strand fields themselves
followed by a continuous blend, or a discrete trough mask on top of that
blend. A checkerboard mask (cell_y + cell_x) % 2 changes value at a cell
boundary that sits in the middle of the map, not only at the tile's own
wrap edge, and whichever quantity is switched by that mask (a coefficient,
which field plays "over", or which trough gets subtracted) generally holds
a different value on the two sides of that swap, so the swap itself plants
a discontinuity at every cell boundary. seam_n and seam_s measure exactly
that kind of discontinuity, comparing the tile's wrap edge to its ordinary
internal joins; they fail whether or not the wrap edge itself lands on a
swap, because the metric is now dominated by the many non-wrap swaps
scattered through the interior. The failures recorded while testing this
file: a hard coefficient flip (seam_n 3.3 to 4.1), a np.where flip feeding
a continuous blend (tilt overshot to 45 degrees, seam_n 2.9, seam_s 9.3),
and a np.where flip plus a separate discrete trough subtraction (seam_n
2.8, seam_s 2.8). max() of two independently periodic fields, used below,
has no such swap anywhere and tiles cleanly on every attempt.

max() alone left ao_min at 0.78 (want 0.35 or under): the "gap" phase, 0
in both ridge fields, is already their shared floor, and normalise01 never
pushed that floor low enough to read as a real hole. stamp_grid below adds
one identical pit per weave cell, at the same phase (0, 0) every time, no
checkerboard, no alternation, so it tiles for the same reason ridge()
does: every cell gets the same treatment as every other, with nothing
that differs on the two sides of any boundary, wrap included.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_wattle"
CLS = lib.class_of(STEM, GAME)


def ridge(phase):
    """A single smooth lobe per period, 0 at the gap (phase 0) rising to 1
    at the strand's rounded crown (phase 0.5) and back to 0 at the next
    gap: one minus cosine is exactly periodic, so this tiles on its own."""
    return 0.5 * (1.0 - np.cos(phase * 2 * np.pi))


def dome_stamp(radius, amp):
    """A round bump (amp > 0) or pit (amp < 0), zero slope at its own rim,
    the same stamp cast_bronze.py and fig_bark.py use for their own
    localised relief."""
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    r = np.sqrt(dx ** 2 + dy ** 2)
    dome = np.where(r <= radius, 0.5 * (1.0 + np.cos(np.pi * np.clip(r, 0, radius) / radius)), 0.0)
    return (amp * dome).astype(np.float32)


def stamp_grid(size, period, radius, amp):
    """One negative stamp per weave cell, at a fixed position within every
    cell (no alternation, no checkerboard): every cell gets an identical
    pit at phase (0, 0), where both ridge fields already sit at their own
    floor, standing in for the real hole a weave has where a withy tucks
    fully out of sight under its neighbour. Same location every period, so
    this tiles exactly, the same reasoning the module docstring gives for
    ridge() itself, with none of the mid-tile discontinuity a checkerboard
    swap plants."""
    field = np.zeros((size, size), dtype=np.float32)
    stamp = dome_stamp(radius, amp)
    for cy in range(0, size, period):
        for cx in range(0, size, period):
            ys_ = (np.arange(-radius, radius + 1) + cy) % size
            xs_ = (np.arange(-radius, radius + 1) + cx) % size
            idx = np.ix_(ys_, xs_)
            field[idx] = np.minimum(field[idx], stamp)
    return field


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}, class_of reads {CLS}")

    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print("row means:", np.round(lum.mean(axis=1), 3))
    print("col means:", np.round(lum.mean(axis=0), 3))
    print("row and column stats match: a period four weave, symmetric in "
          "both directions, with no over-under signal in the brightness")

    SIZE = lib.SIZE
    scale = SIZE // src.shape[0]
    period_map = 4 * scale  # the art's own period four weave, at map scale

    ys = np.arange(SIZE)[:, None]
    xs = np.arange(SIZE)[None, :]
    phase_y = (ys % period_map) / period_map
    phase_x = (xs % period_map) / period_map

    h_strand = np.broadcast_to(ridge(phase_y), (SIZE, SIZE))
    v_strand = np.broadcast_to(ridge(phase_x), (SIZE, SIZE))
    weave = np.maximum(h_strand, v_strand * 0.92) * 0.5 + 0.3

    # A real hole at each crossing, not just a lower ridge: max() alone
    # left ao_min at 0.78, because the "gap" phase 0 point is already the
    # ridge fields' own floor and normalise01 never pushed it deep enough
    # to self shadow. One identical pit per weave cell (stamp_grid, no
    # checkerboard, see the module docstring for why that matters for the
    # seam) gives every crossing a genuine dip down to where the withy
    # actually disappears from view.
    pit = stamp_grid(SIZE, period_map, radius=5, amp=-2.0)
    weave = lib.normalise01(weave + pit, 0.5, 99.5)

    grain = lib.fbm(SIZE, base_cells=40, octaves=3, seed=601, gain=0.55) * 0.04
    height = lib.normalise01(weave + grain, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=602)
    smooth = 0.5 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 24
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
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
