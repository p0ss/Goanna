"""Hand authored height and smoothness for kythen_mitteleuropa_alluvium.

The 32 px art has seven shades in a gentle mottle, no drawn stones or
clods (lib.segments finds only fragments, half of them a single texel, at
every tolerance tried). This is fine river silt, and the only structure
worth keeping is directional: a shift by one texel keeps 0.79 of the
field's own variance along a column against 0.70 along a row, so the
mottle is a touch longer up and down than it is side to side, a faint
hint of the current's own ripples. That is built here as low amplitude
sine bands running across the tile (a fixed number of cycles, so it tiles
exactly), broken up by a slow phase wobble so the bands are not perfectly
straight, held to a small share of the height alongside the art's own
sweep and fine silt grain.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_alluvium"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def ripple_field(size, cycles, amp, seed):
    """A tileable ripple: cycles is an integer count so the sine closes
    exactly at the wrap, and its phase is bent by a slow noise field so
    the bands wander rather than ruling the tile with straight lines."""
    wobble = lib.fbm(size, base_cells=4, octaves=2, seed=seed) * 1.6
    y = np.arange(size)[:, None] * np.ones((1, size))
    return amp * np.sin(2 * np.pi * cycles * y / size + wobble)


def pit_mask(size, native, frac, amp, seed):
    """A scatter of small silt hollows: a sparse binary mask at the art's
    own resolution, warped up for an organic edge but never blurred, so
    the wall still rises within a texel or two. A blurred edge was tried
    first (a graded pit from a blurred white noise threshold) and left the
    ambient occlusion at 0.5 to 0.8 regardless of depth, the same trap
    kythen_khmer_floodplain_clay.py records for its crack mask: the
    horizon based occlusion needs a real wall, not a gradual slope."""
    rng = np.random.default_rng(seed)
    m = (rng.uniform(0.0, 1.0, (native, native)) < frac).astype(int)
    return lib.warp_labels(m, amp=amp, seed=seed).astype(np.float32)


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("class:", CLS)

    for tolerance in (0.03, 0.05, 0.08):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        sizes = np.bincount(labels.ravel())
        singles = int((sizes == 1).sum())
        print(f"segments at tolerance {tolerance}: n={n} singles={singles} "
              f"(no real drawn regions, a fine mottle)")

    def ac(a, shift, axis):
        b = np.roll(a, shift, axis=axis)
        return float((a * b).mean() / (a * a).mean())
    l0 = lum - lum.mean()
    print(f"shift 1 autocorrelation: rows(axis=1) {ac(l0, 1, 1):.3f} "
          f"cols(axis=0) {ac(l0, 1, 0):.3f} (slightly longer down columns, faint ripple)")

    sweep32 = lib.blur(lum, 2)
    sweep = lib.upscale(sweep32, smooth=True)
    sweep = lib.normalise01(sweep)

    ripple = ripple_field(SIZE, cycles=7, amp=1.0, seed=841)
    ripple = lib.normalise01(ripple)

    grain = lib.fbm(SIZE, base_cells=70, octaves=2, seed=842, gain=0.5)
    dust = lib.blur(lib.white_noise(SIZE, seed=843), 1)

    # The flat plate: sweep, ripple and grain, held to a modest band since
    # this is silt, not a domed clod soil.
    flat = lib.normalise01(0.35 * sweep + 0.25 * ripple + 0.25 * grain + 0.15 * dust, 0.5, 99.5)
    flat = lib.band(flat, 0.30)

    # A scatter of small hollows where the current has scoured the silt,
    # the only real depth on the tile and the thing that gives the ao a
    # true low point.
    pits = pit_mask(SIZE, src.shape[0], frac=0.10, amp=2.0, seed=846)
    print(f"pit fraction {pits.mean():.3f}")

    height = np.clip(flat - pits * 0.5, 0.0, 1.0)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=26, octaves=3, seed=844, gain=0.55)
    # The scoured hollows are freshly wet, smoother than the dried plate.
    smooth = 0.30 * (height - height.mean()) + 0.6 * variation - 0.10 * pits
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 10.0
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
