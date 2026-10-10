"""Hand authored LabPBR height and smoothness for kythen_siku_frozen_subsoil.

The 32 px art (cultures/siku/materials.json: "mottle", base silt_grey,
accent ice_pale, cells 12) is permafrost, "gravel and ice, and it does not
thaw". Read the same way kythen_siku_tundra_ground.py reads its own
mottled dither, lib.segments (tolerance 0.02) finding 260 real clods, most
a handful of texels, a hundred lone. The brief calls for the ice in the
cracks smoother than the clods around it: the accent is literally
ice_pale, so the lightest texels (region luminance in the top third of
the tile's own range) are read as the ice rather than a lit clod face,
and get their own, higher smoothness band, soil class's own ceiling
(0.05 + 0.25) rather than a true glassy number, since this is still one
soil texture and not an inlay of a different material.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_siku_frozen_subsoil"
CLS = "soil"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("lib.class_of reads:", lib.class_of(STEM, GAME))

    tolerance = 0.02
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:15])

    lo, hi = region_lum.min(), region_lum.max()
    ice_cut = lo + 0.66 * (hi - lo)
    is_ice = region_lum > ice_cut
    print(f"ice regions (top third of the tile's own luminance range): "
          f"{int(is_ice.sum())} of {n}, {int(sizes[is_ice].sum())} texels")
    target = 0.15 + 0.65 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, size=SIZE, seed=101)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    ice_hi = is_ice[labels_hi]

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 1.1 * (narrow - wide)

    lumps = lib.fbm(SIZE, base_cells=12, octaves=3, seed=102, gain=0.55) * 0.26
    grit = lib.blur(lib.white_noise(SIZE, seed=103), 1) * 0.05
    pits = lib.blur(lib.white_noise(SIZE, seed=104), 2) * 0.04
    # Ice fills the crack rather than piling above it, so it is not given
    # its own extra lift, only a slightly harder, less pitted surface.
    height = lib.normalise01(layout + lumps + grit + pits * (1.0 - 0.6 * ice_hi), 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=105, gain=0.55)
    smooth = 0.35 * t + 0.45 * variation + 0.45 * ice_hi.astype(np.float32)
    print(f"pre pack smooth sd {smooth.std():.4f}")
    print(f"smooth mean on ice texels vs clod texels (pre pack): "
          f"{smooth[ice_hi].mean():.3f} vs {smooth[~ice_hi].mean():.3f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 13.5
    height = lib.band(height, 0.5)
    fine_detail = 1.0  # kythen_siku_dry_stone.py's own finding: a clod pit only three or
    # four texels wide is exactly the scale pack()'s default 0.35 damping exists to flatten.
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, fine_detail=fine_detail, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}, fine_detail={fine_detail}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    s_back = np.asarray(lib.Image.open(str(out_dir) + "/" + STEM + "_s.png").convert("RGBA")).astype(np.float32) / 255.0
    print(f"packed smoothness: ice texels {s_back[..., 0][ice_hi].mean():.3f}, "
          f"clod texels {s_back[..., 0][~ice_hi].mean():.3f} (ice should read smoother)")
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
