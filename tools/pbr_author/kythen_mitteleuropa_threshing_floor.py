"""Hand authored LabPBR height and smoothness for kythen_mitteleuropa_threshing_floor.

The 32 px art is seven grey shades, luminance 0.409 to 0.655, no drawn
joint, block or worn path: mottled colour variation in packed earth, the
same reading kythen_habesha_threshing_floor.py's own art gets (checked the
same way, lib.segments finds one region chaining through most of the tile
plus a scatter of small patches, none elongated in a shared direction), so
this is built flat: subtle undulation and fine grain, no domed regions.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_threshing_floor"
CLS = "soil"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    print(f"lib.class_of reads: {lib.class_of(STEM, GAME)}")

    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    tolerance = 0.06
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    order = np.argsort(-sizes)
    print(f"segments tol={tolerance}: n={n}, largest {sizes[order[0]]} texels "
          f"({100.0 * sizes[order[0]] / sizes.sum():.0f} percent of the tile)")
    elongated = False
    for i in order[1:12]:
        ys, xs = np.where(labels == i)
        h_ext, w_ext = ys.max() - ys.min() + 1, xs.max() - xs.min() + 1
        fill = sizes[i] / (h_ext * w_ext)
        if max(h_ext, w_ext) >= 20 and fill > 0.3:
            elongated = True
    print("elongated worn path or sweep stroke found:", elongated,
          "(none here either, the same reading kythen_habesha_threshing_floor.py's "
          "art gets); built flat")

    # Flat, subtly undulating: fine packed dirt texture at grain scale, no
    # region doming and no crown, the same construction
    # kythen_habesha_threshing_floor.py uses for its own flat soil face.
    grain = lib.fbm(lib.SIZE, base_cells=34, octaves=3, seed=921, gain=0.55)
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=922), 1)
    texture = 0.5 * grain + 0.5 * pores
    height = lib.band(texture, half_width=0.45, centre=0.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(lib.SIZE, base_cells=22, octaves=3, seed=923, gain=0.6)
    smooth = 0.5 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 6
    # The only relief on this flat face is the fine pore texture, one or
    # two texels across, which pack()'s default fine_detail (0.35) is built
    # to damp; fine_detail=1.0 keeps it, the same call
    # kythen_habesha_threshing_floor.py makes for the same reason.
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
