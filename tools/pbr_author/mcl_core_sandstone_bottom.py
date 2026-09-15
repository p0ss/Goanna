"""Hand authored height and smoothness for mcl_core_sandstone_bottom.

The underside: mean luminance 0.640, standard deviation 0.061, between the
side's 0.088 and the top's 0.027. That sits it between the two: rougher
than the dressed cut face above, still nowhere near the strong bedding the
side carries. It is the same cut stone, left exposed underneath rather than
dressed flat, so weather has worked it a little further than the top face.

An earlier version of this script ran lib.segments over the art and domed
every patch it found as its own region, which read as tiling or cracked
pavement rather than a weathered stone face. This face stays flat cut stone
with grain and pits on top: more pits than the top face and a broad, shallow
weathering sweep across the whole face, both continuous fields rather than
domes copied from the art's own colour regions.

Shares its fine grain and pore noise with mcl_core_sandstone_normal and
_top (seeds 61, 62) so the three faces read as one stone.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_sandstone_bottom"
CLS = "sand"
SIZE = lib.SIZE

GRAIN_SEED = 61
PORES_SEED = 62


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")

    # A flat baseline, the same starting point as the top face, but with
    # more pit coverage and deeper pits: this underside has weathered
    # further than the dressed cut above it.
    baseline = 0.5
    pit_field = lib.fbm(SIZE, base_cells=9, octaves=2, seed=76, gain=0.5)
    pit_floor = np.percentile(pit_field, 14.0)
    pit_depth = np.clip(pit_floor - pit_field, 0.0, None)
    pit_depth = pit_depth / max(pit_depth.max(), 1e-6)
    print(f"pit coverage {(pit_depth > 0.05).mean() * 100:.1f}% of the face")

    # A broad, shallow weathering sweep across the whole face, a continuous
    # undulation rather than a region: real weather does not respect the
    # art's colour boundaries.
    weathering = lib.fbm(SIZE, base_cells=10, octaves=3, seed=77, gain=0.55)

    # Same fine grain and pores as the other two sandstone faces.
    grain = lib.fbm(SIZE, base_cells=44, octaves=3, seed=GRAIN_SEED, gain=0.55) * 0.03
    pores = lib.blur(lib.white_noise(SIZE, seed=PORES_SEED), 1) * 0.03
    height = lib.normalise01(
            baseline + grain + pores + weathering * 0.09 - pit_depth * 0.32,
            0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the pits and weathering hollows hold dust
    # and stay rough, the proud spots are what wears smooth. A wider
    # variation than the top face's own, matching a face weather has
    # worked on rather than a tool has cut.
    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=78, gain=0.55)
    smooth = 0.5 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 9.0
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
