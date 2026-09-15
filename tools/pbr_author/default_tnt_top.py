"""Hand authored LabPBR height and smoothness for default_tnt_top.

The same red wrapped paper as default_tnt_side (the lightest six of its
thirteen shades match the side's wrap family, 0.382 down to 0.254, in the
same broken period four column rhythm), scattered on top with darker
flecks of general wear. One cluster of them is not scattered: texels under
lum 0.19 (near black, 0.128 and 0.173, wrapped, 4 connected) fall into one
group of 12 touching texels at rows 7 to 10, columns 4 to 9, against
nineteen other dark texels under that same threshold that are all on their
own, no neighbour within lum 0.19 of them. That one cluster is the fuse
hole; the rest is the wrap's own weather, built the same way as the side,
straight from the art's own shading.
"""
import sys

import numpy as np

import lib

STEM = "default_tnt_top"
CLS = "wood"
SIZE = lib.SIZE
HOLE_LUM_MAX = 0.19


def find_hole(lum):
    """The one connected cluster of near black texels, wrapped 4 connected,
    picked out from the scattered single dark flecks the wrap's weathering
    also leaves under the same threshold."""
    dark = lum < HOLE_LUM_MAX
    h, w = dark.shape
    comp = -np.ones((h, w), dtype=int)
    nid = 0
    for y in range(h):
        for x in range(w):
            if not dark[y, x] or comp[y, x] >= 0:
                continue
            stack = [(y, x)]
            comp[y, x] = nid
            while stack:
                cy, cx = stack.pop()
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = (cy + dy) % h, (cx + dx) % w
                    if dark[ny, nx] and comp[ny, nx] < 0:
                        comp[ny, nx] = nid
                        stack.append((ny, nx))
            nid += 1
    sizes = np.bincount(comp[comp >= 0], minlength=nid)
    biggest = int(np.argmax(sizes))
    return comp == biggest, int(sizes[biggest]), nid


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")

    hole, hole_size, n_comps = find_hole(lum)
    print(f"dark clusters under lum {HOLE_LUM_MAX}: {n_comps}, biggest {hole_size} texels")
    ys, xs = np.where(hole)
    print("hole rows", sorted(set(ys.tolist())), "cols", sorted(set(xs.tolist())))

    # The wrap and its weather, read straight from the art as default_tnt_side
    # reads its own wrap, the same seeds so the two faces match.
    lum_hi = lib.upscale(lum, smooth=False)
    layout = 0.35 + 0.45 * lib.blur(lum_hi, 2)

    # The fuse hole: burned or drilled, not cut straight, so its edge gets
    # the organic warp a hand made opening gets rather than a machined one.
    hole_hi = lib.warp_labels(hole.astype(int), amp=2.0, seed=121)
    edge = lib.region_edges(hole_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edge, max_dist=max_dist)
    wall = np.where(hole_hi > 0, 0.0, dist)
    wall_t = np.clip(wall / max_dist, 0.0, 1.0)
    wall_t = wall_t * wall_t * (3 - 2 * wall_t)
    layout = layout * wall_t + 0.08 * (1 - wall_t)

    fibre = lib.fbm(SIZE, base_cells=30, octaves=3, seed=111, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=112), 1) * 0.03
    layout = layout + fibre * wall_t + pores * wall_t

    height = lib.normalise01(layout, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=113, gain=0.55)
    smooth = 0.4 * (1 - wall_t) + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 24.0
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
