"""Hand authored LabPBR height and smoothness for kythen_norse_dry_stone,
a stacked dry stone wall face, no mortar.

The 32 px art draws real coursing: four courses of eight rows each, rows 0,
8, 16 and 24 are a full width band of the brightest shade (0.453), the
horizontal joint between courses, and within each course the same shade
marks four vertical joints, at columns 0, 8, 16, 24 in courses one and
three and staggered half a stone to columns 4, 12, 20, 28 in courses two
and four, a genuine running bond. This is the joint mask the masonry rule
asks for, found directly by threshold rather than reasoned by hand the way
kythen_habesha_terrace_face.py had to when its own art carried no such
signal. Flood filling the non-joint texels, wrapped, gives sixteen 7x7
stones, each with its own faint internal shade variation (mean lum 0.229
to 0.258) from the art's remaining three darker shades. Stones are flat
topped ("flat stones") with deep gaps and no mortar bed between them.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_dry_stone"
CLS = "stone"


def label_blocks(mask):
    """Flood fill of the non-joint texels, wrapped, 4 connected. The grid
    has at least three joint columns crossing every course, so unlike
    default_stone_brick.py's single joint column case, no seam cut is
    needed: every stone separates cleanly."""
    h, w = mask.shape
    labels = np.full((h, w), -1, dtype=int)
    next_id = 0
    for y in range(h):
        for x in range(w):
            if mask[y, x] or labels[y, x] >= 0:
                continue
            stack = [(y, x)]
            labels[y, x] = next_id
            while stack:
                cy, cx = stack.pop()
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = (cy + dy) % h, (cx + dx) % w
                    if mask[ny, nx] or labels[ny, nx] >= 0:
                        continue
                    labels[ny, nx] = next_id
                    stack.append((ny, nx))
            next_id += 1
    return labels, next_id


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    cls_read = lib.class_of(STEM, GAME)
    print(f"lib.class_of reads: {cls_read}, using {CLS}")

    joint_mask = lum >= 0.453 - 1e-4
    print(f"joint texels: {int(joint_mask.sum())} of {joint_mask.size} "
          f"({joint_mask.mean()*100:.1f}%)")

    h = src.shape[0]
    labels, n_stones = label_blocks(joint_mask)
    sizes = [int((labels == i).sum()) for i in range(n_stones)]
    stone_lum = np.array([lum[labels == i].mean() for i in range(n_stones)])
    print(f"coursed stones found: {n_stones}, sizes {sizes}")
    print("stone lums:", [round(float(v), 3) for v in stone_lum])

    lo, hi = stone_lum.min(), stone_lum.max()
    brightness_share = (stone_lum - lo) / max(hi - lo, 1e-6)
    jitter = np.random.default_rng(51).uniform(-1.0, 1.0, n_stones)
    stone_target = 0.60 + 0.10 * brightness_share + 0.18 * jitter
    print("stone target range:", round(float(stone_target.min()), 3),
          "to", round(float(stone_target.max()), 3))

    joint_hi = np.repeat(np.repeat(joint_mask, 256 // h, axis=0), 256 // h, axis=1)
    labels_hi = np.repeat(np.repeat(labels, 256 // h, axis=0), 256 // h, axis=1)

    max_dist = 3  # deep, wide gaps: real dry stone has no mortar bed to fill them
    dist = lib.distance_to_edge(joint_hi.astype(np.float32), max_dist=max_dist)
    wobble = lib.fbm(lib.SIZE, base_cells=40, octaves=2, seed=52) * 1.4
    dist = np.where(joint_hi, 0.0, np.clip(dist + wobble, 0.0, max_dist))
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: broad flat stone tops, sharp fall into the gap

    target_map = stone_target[labels_hi]
    layout = target_map * t

    # Flat stones: only a very low, broad bulge, well short of a cobble's
    # dome, since the art calls these flat stones stacked in courses.
    crown = lib.fbm(lib.SIZE, base_cells=5, octaves=2, seed=53) * 0.04
    layout = layout + crown * t

    tooling = lib.fbm(lib.SIZE, base_cells=42, octaves=3, seed=54, gain=0.55) * 0.04
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=55), 1) * 0.04
    height = lib.normalise01(layout + tooling + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=56)
    smooth = 0.5 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 44
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
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
