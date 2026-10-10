"""Hand authored LabPBR height and smoothness for kythen_norse_hearth_kerb,
the stones edging a hearth, proud of the ash bed they contain.

The 32 px art carries the exact same coursed joint grid as
kythen_norse_dry_stone.py: four courses of eight rows, joints in the
brightest shade (0.582) at rows 0, 8, 16, 24 and at columns 0, 8, 16, 24 in
courses one and three, staggered to 4, 12, 20, 28 in courses two and four.
Flood filling the non-joint texels gives the same sixteen 7x7 stones. The
difference from dry_stone is the middle shade (0.384): scattered inside
the stone bodies rather than confined to the joint, it reads as ash dust
settled on the kerb tops, not as more coursing, so it becomes a speckled
darkening in the smoothness field rather than more height structure. The
kerb sits proud of the ash it borders, so the stones get a firmer, higher
crown than dry_stone's flat faces.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_hearth_kerb"
CLS = "stone"


def label_blocks(mask):
    """Flood fill of the non-joint texels, wrapped, 4 connected: the same
    reasoning as kythen_norse_dry_stone.py, at least three joint columns
    cross every course so no seam cut is needed."""
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

    joint_mask = lum >= 0.582 - 1e-4
    print(f"joint texels: {int(joint_mask.sum())} of {joint_mask.size} "
          f"({joint_mask.mean()*100:.1f}%)")
    dust_mask = np.isclose(lum, 0.384, atol=1e-3)
    print(f"dust texels: {int(dust_mask.sum())} ({dust_mask.mean()*100:.1f}%)")

    h = src.shape[0]
    labels, n_stones = label_blocks(joint_mask)
    sizes = [int((labels == i).sum()) for i in range(n_stones)]
    stone_lum = np.array([lum[labels == i].mean() for i in range(n_stones)])
    print(f"coursed stones found: {n_stones}, sizes {sizes}")
    print("stone lums:", [round(float(v), 3) for v in stone_lum])

    lo, hi = stone_lum.min(), stone_lum.max()
    brightness_share = (stone_lum - lo) / max(hi - lo, 1e-6)
    jitter = np.random.default_rng(61).uniform(-1.0, 1.0, n_stones)
    stone_target = 0.65 + 0.10 * brightness_share + 0.16 * jitter
    print("stone target range:", round(float(stone_target.min()), 3),
          "to", round(float(stone_target.max()), 3))

    scale = 256 // h
    joint_hi = np.repeat(np.repeat(joint_mask, scale, axis=0), scale, axis=1)
    labels_hi = np.repeat(np.repeat(labels, scale, axis=0), scale, axis=1)
    dust_hi = np.repeat(np.repeat(dust_mask, scale, axis=0), scale, axis=1)

    max_dist = 3  # narrow: a small max_dist gives the packer's ao pass a
                  # sharp enough edge to read as a real gap (see
                  # kythen_norse_dry_stone.py's own tuning notes)
    dist = lib.distance_to_edge(joint_hi.astype(np.float32), max_dist=max_dist)
    wobble = lib.fbm(lib.SIZE, base_cells=40, octaves=2, seed=62) * 1.4
    dist = np.where(joint_hi, 0.0, np.clip(dist + wobble, 0.0, max_dist))
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    target_map = stone_target[labels_hi]
    layout = target_map * t

    # A firmer crown than dry_stone's: this kerb is dressed to sit proud
    # of the ash bed, not a flat flagstone.
    crown = lib.fbm(lib.SIZE, base_cells=5, octaves=2, seed=63) * 0.08
    layout = layout + crown * t

    tooling = lib.fbm(lib.SIZE, base_cells=42, octaves=3, seed=64, gain=0.55) * 0.04
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=65), 1) * 0.04
    height = lib.normalise01(layout + tooling + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height as usual, with the art's own dust texels
    # pulled further down: ash settled in the low corners of the kerb
    # tops stays matte and rough, not part of the height structure.
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=66)
    smooth = 0.5 * height + 0.5 * rough_noise
    dust_soft = lib.blur(dust_hi.astype(np.float32), 1)
    smooth = smooth - 0.35 * dust_soft
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 41
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
