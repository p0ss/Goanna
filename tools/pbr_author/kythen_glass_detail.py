"""Hand authored height and smoothness for kythen_glass_detail.

The 16 px art is a window frame: a fully transparent 12 by 12 pane in the
middle (alpha 0), a bright inner sash (alpha 0.431, luminance 0.786) and a
brighter outer sash (alpha 0.745, luminance 0.931) at the tile's border.
Nowhere is it fully opaque. This is glass, flat by nature: the frame gets
a shallow bevel where the sash steps down toward the pane, everything else
stays close to flat, and the class keeps the smoothness high the way
glass should read, a clean surface rather than a bumpy one.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_glass_detail"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    alpha = src[..., 3]
    lum = lib.luminance(rgb)
    print(f"alpha levels: {sorted(set(np.round(alpha.ravel(), 3).tolist()))}")
    print(f"lum levels: {sorted(set(np.round(lum.ravel(), 3).tolist()))}")

    # Three flat bands by alpha: pane (0), inner sash (0.431), outer sash
    # (0.745). No lib.segments needed, the alpha channel already gives the
    # exact bands.
    band_id = np.zeros((16, 16), dtype=int)
    band_id[np.isclose(alpha, 0.431, atol=0.05)] = 1
    band_id[np.isclose(alpha, 0.745, atol=0.05)] = 2
    print("band texel counts:", [int((band_id == i).sum()) for i in range(3)])

    # Straight edges: a window sash is milled, not an organic silhouette.
    labels_hi = np.kron(band_id, np.ones((16, 16), dtype=int))
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    target = np.array([0.40, 0.55, 0.65])  # pane low, inner sash mid, outer sash proud
    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 0.7 * (narrow - wide)

    # A little texel scale variation on the sash only, glass itself stays
    # clean; the pane carries no structure since it draws as an empty hole.
    grain = lib.blur(lib.white_noise(SIZE, seed=91), 1) * 0.02

    height = lib.normalise01(layout + grain, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: kept high and even, glass and its frame both read as
    # clean and hard, the class level does the real work here.
    # Wide spread even though the surface itself is clean: a pane picks up
    # dust and faint frosting unevenly, so the smoothness carries more
    # variation than the height does, glass's own clean flatness untouched.
    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=92, gain=0.55)
    smooth = 0.75 + 0.5 * variation

    albedo = lib.upscale(src)  # RGBA, keeps the pane's transparency

    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 4.0
    # Flat by nature: a fired pane and a milled sash both stay in a narrow
    # band, not the full class depth a stone joint would use.
    height = lib.band(height, 0.12)
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
