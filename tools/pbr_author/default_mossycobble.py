"""Hand authored LabPBR height and smoothness for default_mossycobble.

The 16 px art has 27 distinct shades, far more than default_cobble's own
six: this is not a recolour with a separate moss layer laid on top, it is
one continuous mottled surface, moss tint blended in per texel at varying
strength. Subtracting the green (greenness = G - avg(R, B)) finds the moss:
a soft patch of raised, positive greenness covering about 18 percent of the
tile, roughly rows 3 to 9 and columns 2 to 9, that also reads as darker
luminance than the bare stone under it (moss is a darker material than the
grey rock here, not a lighter one). Running lib.segments on the de-mossed
proxy (R + B) / 2 still will not find default_cobble's stones: even with
tolerance down at 0.03 it returns about a hundred regions, almost all one
to a few texels, because the shading is a smooth gradient with no colour
cliff between one stone and the next the way the mortar cliff in
default_stone_brick has. The stones this texture draws have to be built,
not found: a wrapped Voronoi cellular pattern gives the same rounded,
irregular, roughly cobble sized footprint lib.segments would have handed
over if the art still had one, and each cell's own height still comes from
the art, the mean of the de-mossed proxy under it.
"""
import sys

import numpy as np

import lib

STEM = "default_mossycobble"
CLS = "stone"


def voronoi_labels(size, n_seeds, seed):
    """A wrapped Voronoi partition of a size x size grid into n_seeds
    cells, rounded and irregular the way lib.segments would hand back
    cobble's own stones if this art still drew them with hard edges."""
    rng = np.random.default_rng(seed)
    sy = rng.uniform(0, size, n_seeds)
    sx = rng.uniform(0, size, n_seeds)
    yy, xx = np.mgrid[0:size, 0:size]
    labels = np.zeros((size, size), dtype=int)
    best = np.full((size, size), np.inf)
    for i in range(n_seeds):
        dy = np.abs(yy - sy[i])
        dy = np.minimum(dy, size - dy)
        dx = np.abs(xx - sx[i])
        dx = np.minimum(dx, size - dx)
        d = dy * dy + dx * dx
        closer = d < best
        best = np.where(closer, d, best)
        labels = np.where(closer, i, labels)
    return labels


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", len(set(np.round(lum.ravel(), 3).tolist())))

    greenness = rgb[..., 1] - (rgb[..., 0] + rgb[..., 2]) / 2.0
    print(f"greenness min {greenness.min():.3f} max {greenness.max():.3f}, "
          f"moss coverage (>0.02) {float((greenness > 0.02).mean()):.3f}")

    proxy_val = (rgb[..., 0] + rgb[..., 2]) / 2.0  # de-mossed brightness
    proxy_rgb = np.stack([proxy_val] * 3, axis=-1)
    labels_check, n_check = lib.segments(proxy_rgb, tolerance=0.03)
    sizes_check = sorted(np.bincount(labels_check.ravel()).tolist(), reverse=True)
    print(f"segments on de-mossed proxy, tolerance 0.03: n={n_check}, "
          f"largest sizes {sizes_check[:8]} of 256 (too fragmented to use as stones)")

    # A dozen middling stones, the size default_cobble's own docstring
    # describes for the art this texture is built from.
    n_stones = 13
    labels = voronoi_labels(16, n_stones, seed=51)
    stone_lum = np.array([proxy_val[labels == i].mean() for i in range(n_stones)])
    sizes = [int((labels == i).sum()) for i in range(n_stones)]
    print(f"stones: {n_stones}, sizes {sizes}")

    lo, hi = stone_lum.min(), stone_lum.max()
    target = 0.55 + 0.35 * (stone_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=3.0, cells=10, seed=52)
    edges = lib.region_edges(labels_hi)
    max_dist = 5  # groove half width in 256 map texels
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: domed stone tops, sharp fall to the joint

    target_map = target[labels_hi]
    layout = target_map * t

    # Each stone a slightly convex dome; the taper alone saturates flat in
    # the middle of a stone, a wide slow bulge rounds that off.
    crown = lib.fbm(lib.SIZE, base_cells=5, octaves=2, seed=53) * 0.06
    layout = layout + crown * t

    # Sub texel structure: stone grain a couple of texels across, sparse
    # pores about half a texel across, matching default_cobble's own.
    grain = lib.fbm(lib.SIZE, base_cells=32, octaves=3, seed=54, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=55), 1) * 0.05

    # The moss layer: a soft, organic patch, not a texel hard mask, so the
    # 16 px greenness is normalised, upscaled keeping its own edges, then
    # blurred into the rounded clump real moss grows in. It sits mostly in
    # the joints (a low absolute height there means the same bump reads as
    # filling the groove) and creeps a little way up over whichever stone
    # edges it happens to cover.
    moss01 = lib.normalise01(greenness, 2.0, 98.0)
    moss_hi = lib.upscale(np.stack([moss01] * 3, axis=-1))[..., 0]
    moss_amount = np.clip(lib.blur(moss_hi, 3), 0.0, 1.0)
    print(f"moss_amount hi-res mean {moss_amount.mean():.3f}")
    moss_bump = moss_amount * 0.12

    height = lib.normalise01(layout + grain + pores + moss_bump, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: joints stay rough, dome tops wear smooth.
    # Moss is soft and matte regardless of what it sits on, so it pulls
    # smoothness down wherever it grows, over a joint or over a stone top.
    rough_noise = lib.fbm(lib.SIZE, base_cells=16, octaves=3, seed=56)
    smooth = 0.55 * height + 0.55 * rough_noise - 0.3 * moss_amount
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 30
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
