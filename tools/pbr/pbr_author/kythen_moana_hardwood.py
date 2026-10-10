"""Hand authored height and smoothness for kythen_moana_hardwood.

Column mean lum has a sharp, regular shape: columns 0, 8, 16 and 24 sit at
0.19, every other column sits on a flat plateau around 0.29 (std under
0.005 within a plateau run). Row mean is flat everywhere (0.27 to 0.29, no
horizontal structure). That is four sawn planks across the 32 px tile,
each eight texels wide, a dark join at the left edge of each board and an
otherwise flat face, no crown drawn. This is manufactured, dressed timber,
not a log's bark, so the join position and period are read straight from
the art's own column shape and built as a straight groove (never warped: a
warped label turns a straight sawn edge into a scribble), and the face
between joins is held flat, carrying only vertical grain running the
length of the board and the end grain arcs of a growth ring caught at a
shallow angle. See the join construction below for why a plain upscale of
the art's own column values was replaced with a built V and kerf: the
straight repeated step it gave first read as a seam failure at the tile
edge and, once fixed with a wide taper, had no ambient occlusion (see the
inline comments).
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_hardwood"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def blur_axis(field, radius, axis):
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    w = lum.shape[1]
    col_mean = lum.mean(axis=0)
    row_mean = lum.mean(axis=1)
    print("column mean lum:", np.round(col_mean, 3).tolist())
    print(f"row mean lum range {row_mean.min():.3f} to {row_mean.max():.3f} (no horizontal structure)")
    print("class read back from bake:", CLS, "(sawn timber planks)")

    scale = SIZE // w
    # Which art columns are the join: well below the plateau mean.
    threshold = col_mean.mean() - 1.5 * col_mean.std()
    is_join = col_mean < threshold
    join_cols = np.where(is_join)[0]
    print("join columns:", join_cols.tolist())

    # The join as a smooth, symmetric V, not a flat bottomed step: a
    # continuous circular distance in map texels to the centre of the
    # nearest join period, never warped (this is dressed timber, straight
    # edges only). A distance built from a repeated boolean block instead
    # gives the join a flat zero-distance floor the width of one art
    # texel, which steps abruptly off the plateau on one side; that abrupt
    # step recurs at every join including the one that lands on the tile
    # edge, and the seam measure's inner average, mostly flat plateau
    # texels, dilutes the three interior steps against the one wrap step
    # and reads it as a failure even though the material tiles (see
    # docs/pbr-authoring-playbook.md's note on this). A continuous V has
    # no flat floor to create that asymmetry and tiles exactly, since the
    # join period divides the map size.
    period = scale * (join_cols[1] - join_cols[0]) if len(join_cols) > 1 else scale * w
    centre = join_cols[0] * scale + scale / 2.0

    # A straight join, run through ao_from_height (8 compass directions,
    # a horizon test per direction), reads as barely occluded: it has no
    # variation along y, so the two vertical directions and a good share
    # of the diagonals see no rise at all, and the occlusion average is
    # diluted to almost nothing even though the horizontal slope is a real
    # groove. A hand sawn board is never perfectly true along its own
    # length either, so this adds a slight, slow wobble to where the join
    # sits and a slight, slow modulation of how deep it cuts, both single
    # column tileable noise (one edge of a 2D tileable field, so it wraps
    # in y on its own): enough to give the vertical directions something
    # real to test without reading as a wavy board.
    wobble = lib.fbm(SIZE, base_cells=6, octaves=2, seed=1905, gain=0.5)[:, 0] * 2.5
    depth_raw = lib.blur(lib.white_noise(SIZE, seed=1906), 2)[:, 0]
    depth_raw = (depth_raw - depth_raw.min()) / max(depth_raw.max() - depth_raw.min(), 1e-6)
    depth_mod = 0.02 + 0.98 * depth_raw
    x = np.arange(SIZE, dtype=np.float32)
    centre_y = centre + wobble
    phase = (x[None, :] - centre_y[:, None]) % period
    dist = np.minimum(phase, period - phase)
    # A true V, linear from the centre, not a smoothstep: smoothstep's zero
    # slope right at the centre left the groove too shallow within the
    # occlusion radius for a real self shadow, even at good overall depth.
    # A wide taper for the seam measure (see the docstring above): most of
    # the "inner join" average has to see some gradient too, or the one
    # wrap join reads as an outlier against a mostly dead flat plateau.
    half_width = 13.0
    t = np.clip(dist / half_width, 0.0, 1.0)
    # A narrow saw kerf right at the centre, on top of the wide taper: the
    # actual reveal between two boards, a texel or two of real depth, the
    # feature ao_from_height's short radius can actually see, without
    # narrowing the wide taper that keeps the seam measure honest.
    kerf_half_width = 2.5
    kerf = np.clip(1.0 - dist / kerf_half_width, 0.0, 1.0)
    col_hi = 1.0 - (1.0 - t) * depth_mod[:, None] - 0.5 * kerf * depth_mod[:, None]
    col_hi = np.clip(col_hi, 0.0, 1.0)

    # The smoothness field keeps the plain, unwobbled join shape: the
    # occlusion fix above is a height only device (self shadow reads from
    # height alone), and feeding its faster row to row modulation into
    # smoothness too only made that map noisier for no reason.
    x_flat = (x - centre) % period
    dist_flat = np.minimum(x_flat, period - x_flat)
    t_flat = np.clip(dist_flat / half_width, 0.0, 1.0)
    kerf_flat = np.clip(1.0 - dist_flat / kerf_half_width, 0.0, 1.0)
    col_hi_flat = np.broadcast_to(np.clip(t_flat - 0.5 * kerf_flat, 0.0, 1.0)[None, :], (SIZE, SIZE))

    # Vertical grain the length of each board, and a coarser wavering
    # streak for the timber's own figure.
    grain = blur_axis(lib.fbm(SIZE, base_cells=20, octaves=3, seed=1901, gain=0.55), 10, 0) * 0.35
    figure = blur_axis(lib.fbm(SIZE, base_cells=6, octaves=2, seed=1902, gain=0.5), 14, 0) * 0.25

    # End grain growth ring arcs, caught at a shallow angle where a board
    # was sawn close to the pith: a few gentle concentric waves down the
    # board's own length.
    y = np.arange(SIZE)[:, None] / SIZE
    rings = 0.08 * np.sin(2 * np.pi * (y * 5.0 + 0.15 * grain))
    rings = np.broadcast_to(rings, (SIZE, SIZE))

    pores = blur_axis(lib.blur(lib.white_noise(SIZE, seed=1903), 1), 5, 0) * 0.06

    raw = 0.62 * col_hi + 0.16 * grain + 0.10 * figure + 0.06 * rings + 0.06 * pores
    height = lib.normalise01(raw, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=16, octaves=3, seed=1904, gain=0.55), radius=8, axis=0)
    smooth = 0.55 * col_hi_flat + 0.30 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 20.0
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
