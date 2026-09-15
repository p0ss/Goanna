"""Hand authored height and smoothness for default_snow.

The art is almost flat: four grey levels a few percent apart, no regions,
no pattern larger than a single texel. That is snow settled on the ground,
not carved into it: a soft crust with a gentle roll to it from drifting,
and a scatter of individual crystal facets a texel across catching the
light. There are no joints, no lobes, nothing with a hard edge anywhere:
the whole point of snow is that it buries edges.
"""

import sys

import numpy as np

import lib

SIZE = lib.SIZE


def zscore(field):
    """Zero mean, unit spread, so components combine by a chosen weight
    instead of by whatever scale a noise function happened to come out at.
    Kept local because pack() clips smoothness to 0..1 before it re-centres
    the mean, so an unscaled, off-centre smooth field can lose its spread
    to that first clip rather than to the class level shift."""
    return (field - field.mean()) / (field.std() + 1e-6)


def build(out_dir):
    stem = "default_snow"
    src = lib.load_source(stem)
    print("source", stem, src.shape)
    lum16 = lib.luminance(src[..., :3])
    print("source luminance min %.3f mean %.3f max %.3f sd %.3f" %
          (lum16.min(), lum16.mean(), lum16.max(), lum16.std()))
    print("nearly flat, low contrast: no structure to read off, just a crust")

    art_rgb = lib.upscale(src[..., :3])
    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 3))

    # A broad, low frequency drift: two octaves of large cell noise, blurred
    # again so nothing in it ever reads as an edge.
    drift = lib.fbm(SIZE, base_cells=5, octaves=3, seed=601, gain=0.5)
    drift = lib.blur(drift * 0.5 + 0.5, 3)

    # Sparkle: a sparse set of texel sized bumps, individual crystal facets
    # catching the light. Thresholding white noise at a high percentile
    # keeps it sparse; a one texel blur keeps its own edges soft.
    grains = lib.white_noise(SIZE, seed=602)
    threshold = np.percentile(grains, 96.0)
    sparkle = np.clip((grains - threshold) / (grains.max() - threshold), 0.0, 1.0)
    sparkle = lib.blur(sparkle, 1)

    height = 0.62 * drift + 0.28 * guide + 0.22 * sparkle
    height = lib.normalise01(height)

    # Smoothness: matte crust everywhere, with the same sparse crystals
    # standing out as the smoother, glinting texels, plus a little of its
    # own broad variation so the drift itself is not perfectly uniform.
    variation = lib.fbm(SIZE, base_cells=6, octaves=2, seed=603, gain=0.5)
    smooth = 0.5 + 0.11 * zscore(variation) + 0.35 * sparkle

    albedo = lib.upscale(src[..., :3])
    normal_strength = 6.0
    metrics = lib.pack(stem, out_dir, albedo, height, smooth, "snow",
                        normal_strength=normal_strength)
    lines = lib.check(metrics, "snow")
    print("normal_strength", normal_strength)
    for k, v in metrics.items():
        print("  %s %.4f" % (k, v))
    print("\n".join(lines))
    preview_path = out_dir.rstrip("/") + "/" + stem + "_preview.png"
    lib.preview(out_dir, stem, preview_path)
    print("preview", preview_path)
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = build(out_dir)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
