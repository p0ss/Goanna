"""Hand authored LabPBR height and smoothness for default_brick.

The 16 px art carries seven grey shades in two clusters: a dark cluster,
0.256 to 0.367, and a light cluster, 0.451 to 0.573, separated by a gap
(0.084) wider than any step inside either cluster. The light cluster is
the mortar here, not the dark one: it sits in four full width rows (3, 7,
11, 15, each a joint between a 3 texel course of brick and the next,
wrapping cleanly) and in two or three light columns per course, offset
course to course, the running bond stagger of a real brick wall. The dark
cluster is the fired clay, its own shade varying brick to brick and streak
to streak the way a kiln never fires two bricks quite the same.
"""
import sys

import numpy as np

import lib

STEM = "default_brick"
CLS = "stone"


def label_body(mortar_mask):
    """Connected components of the texels that are not mortar, 4 connected
    and wrapped, so each brick (however the mortar cuts its silhouette)
    gets its own id. Mortar texels stay unlabelled (-1), one shared group."""
    h, w = mortar_mask.shape
    labels = np.full((h, w), -1, dtype=int)
    next_id = 0
    for y in range(h):
        for x in range(w):
            if mortar_mask[y, x] or labels[y, x] >= 0:
                continue
            stack = [(y, x)]
            labels[y, x] = next_id
            while stack:
                cy, cx = stack.pop()
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = (cy + dy) % h, (cx + dx) % w
                    if mortar_mask[ny, nx] or labels[ny, nx] >= 0:
                        continue
                    labels[ny, nx] = next_id
                    stack.append((ny, nx))
            next_id += 1
    return labels, next_id


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    mortar_mask = lum > 0.40
    print(f"mortar texels: {int(mortar_mask.sum())} of 256")
    print("mortar mask:")
    for r in range(16):
        print(r, "".join("#" if mortar_mask[r, c] else "." for c in range(16)))

    labels, n_bricks = label_body(mortar_mask)
    sizes = [int((labels == i).sum()) for i in range(n_bricks)]
    print(f"bricks found: {n_bricks}, sizes {sizes}")

    # Target height per brick: its own mean brightness sets how far it
    # rises above the joint floor, a lighter fired brick catching more
    # light than a darker one. Mortar sits near the groove floor.
    brick_lum = np.array([lum[labels == i].mean() for i in range(n_bricks)])
    lo, hi = brick_lum.min(), brick_lum.max()
    brick_target = 0.55 + 0.35 * (brick_lum - lo) / max(hi - lo, 1e-6)
    target_dict = {-1: 0.08}
    for i in range(n_bricks):
        target_dict[i] = float(brick_target[i])

    labels_hi = lib.warp_labels(labels, amp=2.5, cells=10, seed=31)
    edges = lib.region_edges(labels_hi)
    max_dist = 4  # groove half width in 256 map texels, courses only 3 texels tall
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: flat brick tops, sharp fall to the joint

    target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for lbl, val in target_dict.items():
        target_map[labels_hi == lbl] = val
    layout = target_map * t

    # Each brick a very slightly convex face: a low, brick sized bulge
    # rounds off the flat crown the taper alone leaves in the middle.
    crown = lib.fbm(lib.SIZE, base_cells=6, octaves=2, seed=32) * 0.05
    layout = layout + crown * t

    # Fine tooling marks from the mould and the kiln: short scratches, plus
    # sparser pores where the clay pitted as it fired.
    tooling = lib.fbm(lib.SIZE, base_cells=52, octaves=3, seed=33, gain=0.55) * 0.06
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=34), 1) * 0.05
    height = lib.normalise01(layout + tooling + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the joint gathers dust and stays rough,
    # the fired face is what wears smooth. The brick's own patchy variation
    # rides on top; pack() moves the mean, the spread is ours.
    rough_noise = lib.fbm(lib.SIZE, base_cells=18, octaves=3, seed=35)
    smooth = 0.55 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the brick and joint edges the height field was
    # built to line up with.
    albedo = lib.upscale(src[..., :3])

    normal_strength = 40
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
