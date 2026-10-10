"""Hand authored height and smoothness for kythen_moana_pandanus_trunk, a
ringed palm trunk side.

Column mean lum has three furrow like dips instead of kythen_moana_coconut
_trunk.py's clean two, roughly every ten to eleven columns (0 to 1, 9 to
12, 18 to 23, and the run 30 to 31 meeting column 0 at the wrap): pandanus
trunks carry many stilt roots and leaf scar columns rather than one wide
smooth gap, so a less regular spacing is expected. Column std is
revealing: the plateau columns (2 to 8, 13 to 17, 24 to 29) are dead flat,
std 0.000, while the dipping columns carry real texture, std up to 0.08,
the opposite of the sugar palm's own read where the furrow was the flat
one. Read straight off the art's own column brightness the same way as
the coconut trunk (a circular linear interpolation of the 32 samples,
tiling exactly), with the furrow columns' own drawn texture folded in
rather than smoothed away. Row mean is flat (0.47 to 0.52, no systematic
shift with y), so as with the other trunk scripts the art draws no
horizontal ring banding and frond base scars are built rather than read.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_pandanus_trunk"
CLS_READ = lib.class_of(STEM, GAME)
CLS = "wood"
SIZE = lib.SIZE


def blur_axis(field, radius, axis):
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def upsample_wrap(profile, out_size):
    """Circular linear interpolation of a 1D profile to out_size, tiling
    exactly (unlike a plain image resize, which clamps at its edges)."""
    n = len(profile)
    scale = out_size / n
    xs = (np.arange(out_size) + 0.5) / scale - 0.5
    i0 = np.floor(xs).astype(int) % n
    i1 = (i0 + 1) % n
    f = (xs - np.floor(xs)).astype(np.float32)
    return profile[i0] * (1 - f) + profile[i1] * f


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    col_mean = lum.mean(axis=0)
    col_std = lum.std(axis=0)
    row_mean = lum.mean(axis=1)
    row_std = lum.std(axis=1)
    print("column mean lum:", np.round(col_mean, 3).tolist())
    print("column std lum:", np.round(col_std, 3).tolist())
    print(f"row mean lum range {row_mean.min():.3f} to {row_mean.max():.3f}, "
          f"row std range {row_std.min():.3f} to {row_std.max():.3f} (no ring banding drawn)")
    print(f"class read back from the bake: {CLS_READ}; used here: {CLS} (fibrous palm trunk)")

    profile = lib.normalise01(col_mean)
    layout1d = upsample_wrap(profile, SIZE)
    layout = np.broadcast_to(layout1d[None, :], (SIZE, SIZE)).astype(np.float32)
    wide = lib.blur(layout, 3)
    layout = layout + 1.0 * (layout - wide)

    # Rings: frond base scars encircling the trunk, periodic down y, built
    # the same device as kythen_moana_coconut_trunk.py, coupled to the
    # furrow wall's own strength so ao_from_height (which tests eight
    # compass directions and finds nothing along a groove with no y
    # variation) has real structure to see, and because a scar tears
    # harder where it meets a furrow than where it crosses the smooth
    # ridge. ring_count 8 divides the map size exactly, so the dip's own
    # fast reset from flat back to flat (see the cosine below) recurs as
    # eight byte for byte identical kinks; at the first ring_sharp tried
    # (0.12, the sugar palm and coconut scripts' own value) the dip fell
    # in about four texels, and the seam measure's inner join average,
    # mostly the flat run between rings, diluted the seven interior kinks
    # against the one that lands on the tile edge and read it as a
    # failure even though every ring is the same shape (see docs/pbr-
    # authoring-playbook.md's note on this). Widening the dip to a
    # quarter of the ring's own period gave the inner average enough
    # texels of real gradient to match.
    ring_count, ring_sharp, ring_amp = 8, 0.30, 0.60
    y = np.arange(SIZE)[:, None] / SIZE
    phase = (y * ring_count) % 1.0
    ring_profile = np.where(phase < ring_sharp, np.cos(np.pi * phase / ring_sharp), 1.0) * 0.5 + 0.5
    wall = lib.normalise01(np.abs(np.roll(layout1d, -1) - np.roll(layout1d, 1)))
    wall2d = np.broadcast_to(wall[None, :], (SIZE, SIZE))
    rings = (1.0 - ring_profile) * ring_amp * (0.20 + 1.30 * wall2d)

    # The furrow columns carry their own drawn texture (col_std up to
    # 0.08), read here as a coarser, patchier fibre than the smooth
    # ridge's own fine grain, folded in everywhere at a lower level so the
    # ridge is not left perfectly bare.
    furrow_guide = 1.0 - layout
    coarse_fibre = blur_axis(lib.fbm(SIZE, base_cells=22, octaves=3, seed=2201, gain=0.55), 4, 0)
    fibre = (0.14 + 0.22 * furrow_guide) * coarse_fibre
    grain = blur_axis(lib.fbm(SIZE, base_cells=16, octaves=3, seed=2202, gain=0.55), 12, 0) * 0.16
    pores = blur_axis(lib.blur(lib.white_noise(SIZE, seed=2203), 1), 5, 0) * 0.05

    height = lib.normalise01(layout - rings + fibre + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=14, octaves=3, seed=2204, gain=0.55), radius=6, axis=0)
    smooth = 0.50 * layout + 0.35 * directional_rough + 0.15 * (1.0 - ring_profile)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 19.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength} ring_count={ring_count}")
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
