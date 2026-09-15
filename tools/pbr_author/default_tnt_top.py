"""Hand authored LabPBR height and smoothness for default_tnt_top.

The same red wrapped paper as default_tnt_side (the lightest six of its
thirteen shades match the side's wrap family, 0.382 down to 0.254, in the
same broken period four column rhythm), scattered on top with darker
flecks of general wear. One cluster of them is not scattered: texels under
lum 0.19 (near black, 0.128 and 0.173, wrapped, 4 connected) fall into one
group of 12 touching texels at rows 7 to 10, columns 4 to 9, against
nineteen other dark texels under that same threshold that are all on their
own, no neighbour within lum 0.19 of them. That one cluster is the fuse
hole; the rest is the wrap's own paper, built the same cosine fold as
default_tnt_side rather than the fibre and pore grain the first pass gave
it, which read as concrete. See default_tnt_side.py for the fold and why.
"""
import sys

import numpy as np

import lib

import default_tnt_side as side

STEM = "default_tnt_top"
CLS = "wood"
SIZE = lib.SIZE
HOLE_LUM_MAX = 0.19
HOLE_FLOOR = 0.08
HOLE_CHAMFER = 2


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

    # The paper: the same cosine fold as the side, held in the same narrow
    # band, no grain noise.
    fold = lib.band(side.paper_fold(), half_width=side.FOLD_HALF_WIDTH)

    # The fuse hole: burned or drilled, not cut straight, so its edge gets
    # the organic warp a hand made opening gets rather than a machined one.
    hole_hi = lib.warp_labels(hole.astype(int), amp=2.0, seed=121)
    edge = lib.region_edges(hole_hi)
    dist = lib.distance_to_edge(edge, max_dist=HOLE_CHAMFER)
    wall = np.where(hole_hi > 0, 0.0, dist)
    wall_t = np.clip(wall / HOLE_CHAMFER, 0.0, 1.0)
    wall_t = wall_t * wall_t * (3 - 2 * wall_t)
    height = fold * wall_t + HOLE_FLOOR * (1 - wall_t)
    print(f"height sd {height.std():.3f}")

    # Smoothness: even and matte like the side, the fuse hole's burned rim
    # rougher.
    smooth_noise = lib.fbm(SIZE, base_cells=24, octaves=3, seed=side.SMOOTH_SEED, gain=0.55)
    smooth = 0.5 + 0.4 * smooth_noise - 0.25 * (1 - wall_t)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 14.0
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
