"""Hand authored LabPBR height and smoothness for kythen_mitteleuropa_forest_glass.

The 32 px art is fully opaque (alpha 1.0 throughout, not a windowed cut
out) and carries only two close olive and teal greens in a fine, roughly
even dither, no drawn frame, sash or pane boundary: a solid block face of
hand blown "forest glass", the early, wood-ash-fluxed glass that comes out
faintly green and never perfectly clear. The two tone dither is the small
trapped bubbles and colour striations that kind of glass always carries,
not a pattern to segment into regions: checked with lib.segments, the two
colours interleave too finely (every second or third texel) for any region
bigger than a handful of texels to form. The relief is a scatter of tiny
domes standing for those trapped bubbles on an otherwise flat, glassy
face, built from tileable noise (lib.white_noise, lib.fbm) rather than a
nearest upscale of the art's own dither: a per texel dither like this one
tiles exactly but is not uniformly smooth texel to texel, and stretching
it directly gave a false seam at the wrap in earlier stems (rye thatch)
built that way, purely from which one noisy texel pair happened to land on
the tile's own edge.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_forest_glass"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    alpha = src[..., 3]
    lum = lib.luminance(rgb)
    print(f"alpha unique: {sorted(set(np.round(alpha.ravel(), 3).tolist()))} (opaque, not a cut out)")
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")

    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    print(f"segments tol={tolerance}: n={n}, largest region {sizes.max()} texels "
          f"of {sizes.sum()}; no coherent frame or pane, a fine dither only")

    # A scatter of tiny domes for the trapped bubbles, sparse and small,
    # the same construction kythen_habesha_aksumite_ashlar.py uses for its
    # own rare deep pit but inverted (a bump, not a pit) and denser, since
    # bubbles in hand blown glass are common rather than rare.
    bump_field = lib.blur(lib.white_noise(SIZE, seed=951), 1)
    bump_cut = float(np.percentile(bump_field, 92))
    bubbles = np.where(bump_field > bump_cut, (bump_field - bump_cut) * 6.0, 0.0)

    # A slower, broader waviness, the pane's own hand blown unevenness.
    waviness = lib.fbm(SIZE, base_cells=6, octaves=2, seed=952, gain=0.5)

    field = 0.6 * bubbles + 0.4 * waviness
    height = lib.normalise01(field, 0.5, 99.5)
    # Flat by nature: a blown pane stays in a narrow band, not the full
    # class depth a stone joint would use, the same call
    # kythen_glass_detail.py makes for its own frame and pane.
    height = lib.band(height, 0.12)
    print(f"height sd {height.std():.3f}")

    # Smoothness: kept high and even, glass reads as a clean, hard surface;
    # a little more spread than the height alone carries, since dust and
    # faint frosting sit unevenly on a real pane even when it is clean.
    variation = lib.fbm(SIZE, base_cells=22, octaves=3, seed=953, gain=0.55)
    smooth = 0.78 + 0.5 * variation - 0.3 * bubbles

    albedo = lib.upscale(rgb)
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 5.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, cls,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, cls)
    for line in lines:
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
