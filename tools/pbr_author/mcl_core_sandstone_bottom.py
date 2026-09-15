"""Hand authored height and smoothness for mcl_core_sandstone_bottom.

The underside: mean luminance 0.640, standard deviation 0.061, between the
side's 0.088 and the top's 0.027. lib.segments at tolerance 0.03 finds one
79 texel matrix at 0.653, the same shade the top face's matrix sits at.
Alongside the same kind of one to four texel specks the top face has, this
art also carries eleven patches of 5 to 13 texels, running from 0.505 (real
pits, weathered right back) up to 0.743 (proud lumps); the top face has
only four regions that size and none bigger than six. That is a rougher,
weathered face: the same cut stone, left exposed underneath rather than
dressed flat.

Shares its fine grain and pore noise with mcl_core_sandstone_normal and
_top (seeds 61, 62) so the three faces read as one stone, with a coarser
weathering sweep added on top that the other two faces do not carry.

seam_albedo reads unusually high here, 3.95 against the other two faces'
1.1 and 0.7, and it is not a height or smoothness matter: the source art
itself has a diagonal light to dark gradient baked in, mostly brightest
near row 0 and column 0 (0.70 to 0.74) and mostly darkest near row 15 and
column 15 (0.50 to 0.57), so row 0 to row 15 and column 0 to column 15 both
carry a mean jump of about 0.14, wider than the typical texel to texel step
inside the art. lib.load_baked_albedo's already baked, smoothly upscaled
copy of the same art has the same fault (seam_albedo 3.0 against this
script's own 3.95), so it is the art, not the choice of upscale, and the
rule against repainting the albedo means it stays as the game ships it.
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

    tolerance = 0.03
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:12], "...")
    matrix = region_lum[np.argmax(sizes)]
    print(f"matrix shade {matrix:.3f} ({int(sizes.max())} texels)")

    # Target height per patch, straight off its own brightness: the
    # darkest patches are weathered pits, the brightest are proud lumps
    # the wind has not cut back yet.
    lo, hi = region_lum.min(), region_lum.max()
    target = 0.20 + 0.60 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=5.0, seed=76)
    edges = lib.region_edges(labels_hi)
    max_dist = 4  # patches run 5 to 13 texels, a wider taper than the top's flecks for a rougher, lumpier read
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = 0.5 + (target[labels_hi] - 0.5) * t

    # Same fine grain and pores as the other two sandstone faces, plus a
    # coarser weathering sweep neither of them carries: broad shallow
    # scallops a weathered underside has that a dressed face does not.
    grain = lib.fbm(SIZE, base_cells=44, octaves=3, seed=GRAIN_SEED, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=PORES_SEED), 1) * 0.05
    weathering = lib.fbm(SIZE, base_cells=14, octaves=3, seed=77, gain=0.55) * 0.10
    height = lib.normalise01(layout + grain + pores + weathering, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the pits hold dust and stay rough, the
    # proud lumps are what wears smooth. A wider variation than the top
    # face's own, matching a face weather has worked on rather than a
    # tool has cut.
    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=78, gain=0.55)
    smooth = 0.5 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 8.5
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
