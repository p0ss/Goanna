"""Hand authored LabPBR height and smoothness for kythen_habesha_threshing_floor.

The 32 px art is ten grey shades, luminance 0.213 to 0.465, spread 0.062,
the darkest and flattest spread of the four habesha soil stems. Segmenting
it (tolerance 0.06) gives one region that chains through 763 of the 1024
texels, everywhere in the tile, plus a scatter of thirty odd small patches
five to twenty three texels each. Checked for a deliberate worn path or
sweep stroke (an elongated region, or several aligned the same way): none
of the patches are elongated in a shared direction, and the three that do
span the tile's full height are themselves sparse within that span, nine
percent fill or less, so they are texels that happen to chain through the
wrap rather than a drawn streak. This reads as ordinary mottled colour
variation in packed earth, not distinct worn patches or sweep marks, so
the surface is built flat: subtle undulation and fine grain, no domed
regions, no crown.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_threshing_floor"
CLS = "soil"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    print(f"lib.class_of reads: {lib.class_of(STEM, GAME)}")

    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    tolerance = 0.06
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    reg_lum = np.array([lum[labels == i].mean() for i in range(n)])
    order = np.argsort(-sizes)
    print(f"segments tol={tolerance}: n={n}, largest {sizes[order[0]]} texels "
          f"({100.0 * sizes[order[0]] / sizes.sum():.0f} percent of the tile)")
    print("other regions, size and bounding box (checking for an elongated "
          "worn path or sweep stroke):")
    elongated = False
    for i in order[1:12]:
        ys, xs = np.where(labels == i)
        h_ext, w_ext = ys.max() - ys.min() + 1, xs.max() - xs.min() + 1
        fill = sizes[i] / (h_ext * w_ext)
        print(f"  size {sizes[i]}, lum {reg_lum[i]:.3f}, bbox {h_ext}x{w_ext}, fill {fill:.2f}")
        if max(h_ext, w_ext) >= 20 and fill > 0.3:
            elongated = True
    print("elongated streak found:" , elongated, "(none of these are a solid "
          "long streak; the ones that span the full height are under 10 "
          "percent filled, wrap chained noise rather than a stroke)")
    print("reading: no distinct worn patches or sweep marks, just mottled "
          "colour variation; built flat")

    # Flat, subtly undulating: fine packed dirt texture at grain scale, no
    # region doming and no crown. This is the flattest of the four habesha
    # soil stems by the art's own spread.
    grain = lib.fbm(lib.SIZE, base_cells=34, octaves=3, seed=71, gain=0.55)
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=72), 1)
    texture = 0.5 * grain + 0.5 * pores
    height = lib.band(texture, half_width=0.45, centre=0.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height with its own worn-earth variation: threshing
    # traffic polishes the high points, the low pores hold dust and stay
    # rough.
    rough_noise = lib.fbm(lib.SIZE, base_cells=22, octaves=3, seed=73, gain=0.6)
    smooth = 0.5 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 6
    # The only relief on this flat face is the fine pore texture, one or two
    # texels across, which pack()'s default fine_detail (0.35) is built to
    # damp. At the default it damped away the self shadow entirely (ao min
    # 0.70); fine_detail=1.0 keeps it, the documented exception for a
    # surface where texel scale detail is the point.
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0], fine_detail=1.0)
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
