"""Hand authored height and smoothness for mcl_core_log_big_oak_top.

The same edge-ring, sawn-face split as default_tree_top.py, built the same
way: see that script's docstring for the reasoning behind lib.segments
refining, but never overriding, the true one texel edge, and for the
concentric ring plus radial crack construction. This texture's own numbers:
the ring runs 0.135 to 0.242, the face 0.188 to 0.434, so the two overlap a
little more than default_tree_top's do (both textures carry a 0.188 shade)
but the ring is still clearly the darker of the two on average.

Oak's own furrows on the side (mcl_core_log_big_oak.py) are deeper and more
numerous than default_tree's, and this top matches that: the ring to face
step is deeper (0.90 to 0.25 against default_tree_top's 0.80 to 0.40) and
the groove narrower (distance_to_edge capped at 2 texels rather than 5), so
the transition reads as a sharper cut rather than a soft gradient. Without
that extra depth the ring to face step alone left ao_min just over the 0.35
jointed-surface target; oak's own bark being rougher than default_tree's is
the reason to push it, not an arbitrary fix.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_log_big_oak_top"
CLS = lib.class_of(STEM)
SIZE = lib.SIZE
SEED = 201  # shared with mcl_core_log_big_oak.py, the side of the same log


def blur_axis(field, radius, axis):
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def smoothstep(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3 - 2 * x)


def find_bark_ring(rgb, tolerance):
    labels, n = lib.segments(rgb, tolerance=tolerance)
    h, w = labels.shape
    edge_mask = np.zeros((h, w), dtype=bool)
    edge_mask[0, :] = True
    edge_mask[-1, :] = True
    edge_mask[:, 0] = True
    edge_mask[:, -1] = True
    yy, xx = np.indices((h, w))
    edge_dist = np.minimum(np.minimum(yy, h - 1 - yy), np.minimum(xx, w - 1 - xx))
    is_ring_seg = np.zeros((h, w), dtype=bool)
    for lab in range(n):
        member = labels == lab
        if not member[edge_mask].any():
            continue
        frac_edge = member[edge_mask].sum() / member.sum()
        if frac_edge >= 0.5:
            is_ring_seg[member] = True
    is_ring = (edge_dist == 0) | (is_ring_seg & (edge_dist <= 2))
    return is_ring.astype(int)


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")

    is_ring = find_bark_ring(rgb, tolerance=0.07)
    print(f"bark ring texels: {is_ring.sum()} / 256")

    ring_warp_amp = 6.0
    labels_hi = lib.warp_labels(is_ring, size=SIZE, amp=ring_warp_amp, seed=SEED, cells=10)
    ring_mask = labels_hi == 1
    interior_mask = ~ring_mask
    edges = lib.region_edges(labels_hi)
    ring_max_dist = 2  # narrow: oak's cut is sharper than default_tree's
    dist = lib.distance_to_edge(edges, max_dist=ring_max_dist)
    t = smoothstep(dist / ring_max_dist)
    interior_fade = t * interior_mask
    ring_fade = t * ring_mask

    target_ring, target_face = 0.90, 0.25  # deeper step; see module docstring
    step = np.where(labels_hi == 1, target_ring, target_face).astype(np.float32)
    narrow = lib.blur(step, 2)
    wide = lib.blur(step, 4)
    layout = narrow + 0.9 * (narrow - wide)

    yy, xx = np.indices((SIZE, SIZE)).astype(np.float32)
    cy = cx = (SIZE - 1) / 2.0
    r = np.sqrt((yy - cy) ** 2 + (xx - cx) ** 2)
    wobble = lib.fbm(SIZE, base_cells=6, octaves=2, seed=SEED + 11) * 4.0
    rings = np.sin((r + wobble) * 0.10) * 0.025
    layout = layout + rings * interior_fade

    theta = np.arctan2(yy - cy, xx - cx)
    crack_n = 6
    rng = np.random.default_rng(SEED + 21)
    crack_angles = rng.uniform(0, 2 * np.pi, crack_n)
    crack_len = rng.uniform(0.6, 0.9, crack_n)
    crack_width = np.radians(6.0)
    r_max = SIZE / 2 - ring_max_dist * 2
    cracks = np.zeros((SIZE, SIZE), dtype=np.float32)
    for a, cl in zip(crack_angles, crack_len):
        d = np.angle(np.exp(1j * (theta - a)))
        radial_mask = smoothstep((r - 0.35 * r_max) / (0.15 * r_max)) * (1 - smoothstep((r - cl * r_max) / (0.15 * r_max)))
        cracks += np.exp(-(d / crack_width) ** 2) * radial_mask
    crack_amp = 0.15
    layout = layout - crack_amp * cracks * interior_fade

    ring_grain_src = lib.fbm(SIZE, base_cells=16, octaves=3, seed=SEED + 2, gain=0.55)
    ring_grain = blur_axis(ring_grain_src, radius=10, axis=0) * 0.16
    ring_crack_src = lib.blur(lib.white_noise(SIZE, seed=SEED + 3), 1)
    ring_crack = blur_axis(ring_crack_src, radius=3, axis=1) * 0.06
    layout = layout + (ring_grain + ring_crack) * ring_fade

    pores = lib.blur(lib.white_noise(SIZE, seed=SEED + 4), 1) * 0.02

    height = lib.normalise01(layout + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = lib.fbm(SIZE, base_cells=18, octaves=3, seed=SEED + 5, gain=0.55)
    centre_bonus = np.exp(-(r / (SIZE * 0.12)) ** 2)
    smooth = (0.75 - 0.35 * ring_fade + 0.15 * directional_rough
            + 0.18 * centre_bonus - 0.15 * crack_amp * cracks * interior_fade)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 32.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS, normal_strength=normal_strength)
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
