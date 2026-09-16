"""Hand authored height and smoothness for kythen_moana_coconut_trunk, a
ringed palm trunk side.

Column mean lum is a smooth, continuous ramp with period sixteen, twice
across the 32 px tile: a furrow at columns 0 and 15 to 16 to 31 (about
0.283, low and matching each other across both the internal join and the
tile's own wrap, so it is a real read of the art, not an artefact), rising
through a shoulder to a ridge plateau around columns 4 to 11 (0.34 to
0.355). This is a real gradient drawn in the art, not a manufactured flat
face with a single step joint the way kythen_moana_hardwood.py's planks
are, so it is read straight off the art's own column brightness (a
circular linear interpolation of the 32 samples, which tiles exactly since
sixteen divides the map size's own repeat) rather than built from labels.
Row mean and row std are both flat (0.33, no variation down y), so as with
kythen_khmer_sugar_palm_trunk.py the art draws no horizontal ring
banding; the brief wants frond base scars encircling the trunk regardless,
so those are built as a periodic profile down y, and fine vertical fibre
runs the whole face so the tilt reaches the wood target without pushing
the furrow to an implausible depth.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_coconut_trunk"
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
    w = lum.shape[1]
    col_mean = lum.mean(axis=0)
    row_mean = lum.mean(axis=1)
    row_std = lum.std(axis=1)
    print("column mean lum:", np.round(col_mean, 3).tolist())
    print(f"row mean lum range {row_mean.min():.3f} to {row_mean.max():.3f}, "
          f"row std range {row_std.min():.3f} to {row_std.max():.3f} (no ring banding drawn)")
    print(f"class read back from the bake: {CLS_READ}; used here: {CLS} (fibrous palm trunk)")

    profile = lib.normalise01(col_mean)
    layout1d = upsample_wrap(profile, SIZE)
    layout = np.broadcast_to(layout1d[None, :], (SIZE, SIZE)).astype(np.float32)
    # A gentle unsharp lift so the furrow wall and the ridge crest read as
    # real edges rather than the plain smooth ramp the interpolation gives.
    wide = lib.blur(layout, 3)
    layout = layout + 1.0 * (layout - wide)

    # Rings: frond base scars encircling the trunk, periodic down y, built
    # the same way as kythen_khmer_sugar_palm_trunk.py's own rings: a
    # sharp edged dip with a soft fade above.
    ring_count, ring_sharp, ring_amp = 7, 0.12, 0.62
    y = np.arange(SIZE)[:, None] / SIZE
    phase = (y * ring_count) % 1.0
    ring_profile = np.where(phase < ring_sharp, np.cos(np.pi * phase / ring_sharp), 1.0) * 0.5 + 0.5

    # Fine vertical fibre across the whole trunk, furrow floor included,
    # so the area averaged tilt reaches the wood target without forcing
    # the furrow itself to an implausible depth.
    fibre = blur_axis(lib.fbm(SIZE, base_cells=46, octaves=3, seed=2101, gain=0.55), 3, 0) * 0.28
    grain = blur_axis(lib.fbm(SIZE, base_cells=16, octaves=3, seed=2102, gain=0.55), 12, 0) * 0.18
    pores = blur_axis(lib.blur(lib.white_noise(SIZE, seed=2103), 1), 5, 0) * 0.05

    # The furrow and ridge walls (the layout's own steepest columns): a
    # straight groove with no y variation reads as barely occluded by
    # ao_from_height, which tests eight compass directions and finds
    # nothing along the two vertical ones, and pack()'s own fine_detail
    # damping (grit belongs in smoothness, not height) took most of a
    # texel scale white noise crack straight back out again. Coupling the
    # ring dip's own depth to the wall strength survives that damping,
    # since a ring is a broad, not texel scale, feature: real scar tearing
    # is heavier where a frond base met the furrow than where it crossed
    # the smooth ridge crest, so this is a plausible reading as well as a
    # fix.
    wall = lib.normalise01(np.abs(np.roll(layout1d, -1) - np.roll(layout1d, 1)))
    wall2d = np.broadcast_to(wall[None, :], (SIZE, SIZE))
    rings = (1.0 - ring_profile) * ring_amp * (0.20 + 1.30 * wall2d)

    height = lib.normalise01(layout - rings + fibre + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=14, octaves=3, seed=2104, gain=0.55), radius=6, axis=0)
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
