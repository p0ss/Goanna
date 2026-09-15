"""Hand authored height and smoothness for mcl_core_log_birch_top.

Birch inverts the other three species' pattern: its bark is pale, not dark,
so the ring here is the brighter part of the art (0.633 to 0.855) and the
sawn face the darker, more varied part (0.218 to 0.631), the opposite
relationship to default_tree_top, mcl_core_log_big_oak_top and
mcl_core_log_spruce_top. lib.segments does not need to know this; it finds
the connected colour regions either way, and the target heights below are
assigned by role (ring stands proud, face is flat) rather than by which one
happens to be lighter, so the inversion falls out for free. On this
texture segments and the true one texel edge agree exactly: the ring found
is the full 60 texel perimeter with nothing added and nothing missing,
matching mcl_core_log_birch.py's own finding that birch's art is the
cleanest, most regular of the four on this family of measurements.

The face gets the same growth ring, radial crack and heartwood-smoothest
treatment as the other three tops, but weaker: birch's own side texture
(mcl_core_log_birch.py) is a smooth, papery bark with shallow horizontal
lenticel scars rather than a furrowed one, and its top follows that lead
with a shallower ring to face step and fainter growth rings, so the two
faces read as the same, gentler species of bark.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_log_birch_top"
CLS = lib.class_of(STEM)
SIZE = lib.SIZE
SEED = 401  # shared with mcl_core_log_birch.py, the side of the same log


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

    is_ring = find_bark_ring(rgb, tolerance=0.09)
    print(f"bark ring texels: {is_ring.sum()} / 256")

    ring_warp_amp = 4.0  # gentler than the other three: birch's ring is regular
    labels_hi = lib.warp_labels(is_ring, size=SIZE, amp=ring_warp_amp, seed=SEED, cells=10)
    ring_mask = labels_hi == 1
    interior_mask = ~ring_mask
    edges = lib.region_edges(labels_hi)
    ring_max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=ring_max_dist)
    t = smoothstep(dist / ring_max_dist)
    interior_fade = t * interior_mask
    ring_fade = t * ring_mask

    # A shallower step than the other three species: birch's own bark reads
    # smooth and papery, not deeply cut, on the side too.
    target_ring, target_face = 0.85, 0.55
    step = np.where(labels_hi == 1, target_ring, target_face).astype(np.float32)
    narrow = lib.blur(step, 2)
    wide = lib.blur(step, 4)
    layout = narrow + 0.9 * (narrow - wide)

    yy, xx = np.indices((SIZE, SIZE)).astype(np.float32)
    cy = cx = (SIZE - 1) / 2.0
    r = np.sqrt((yy - cy) ** 2 + (xx - cx) ** 2)
    wobble = lib.fbm(SIZE, base_cells=6, octaves=2, seed=SEED + 11) * 4.0
    rings = np.sin((r + wobble) * 0.11) * 0.02
    layout = layout + rings * interior_fade

    theta = np.arctan2(yy - cy, xx - cx)
    crack_n = 4  # fewer cracks: birch's face is calmer than the other three
    rng = np.random.default_rng(SEED + 21)
    crack_angles = rng.uniform(0, 2 * np.pi, crack_n)
    crack_len = rng.uniform(0.55, 0.95, crack_n)
    crack_width = np.radians(4.0)
    r_max = SIZE / 2 - ring_max_dist * 2
    cracks = np.zeros((SIZE, SIZE), dtype=np.float32)
    for a, cl in zip(crack_angles, crack_len):
        d = np.angle(np.exp(1j * (theta - a)))
        radial_mask = smoothstep(r / (0.12 * r_max)) * (1 - smoothstep((r - cl * r_max) / (0.15 * r_max)))
        cracks += np.exp(-(d / crack_width) ** 2) * radial_mask
    crack_amp = 0.10
    layout = layout - crack_amp * cracks * interior_fade

    # The ring band's own texture, much fainter than the other three
    # species: birch bark is smooth, not furrowed.
    ring_grain_src = lib.fbm(SIZE, base_cells=16, octaves=3, seed=SEED + 2, gain=0.55)
    ring_grain = blur_axis(ring_grain_src, radius=10, axis=0) * 0.10
    ring_crack_src = lib.blur(lib.white_noise(SIZE, seed=SEED + 3), 1)
    ring_crack = blur_axis(ring_crack_src, radius=3, axis=1) * 0.03
    layout = layout + (ring_grain + ring_crack) * ring_fade

    pores = lib.blur(lib.white_noise(SIZE, seed=SEED + 4), 1) * 0.015

    height = lib.normalise01(layout + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = lib.fbm(SIZE, base_cells=18, octaves=3, seed=SEED + 5, gain=0.55)
    centre_bonus = np.exp(-(r / (SIZE * 0.12)) ** 2)
    smooth = (0.75 - 0.35 * ring_fade + 0.15 * directional_rough
            + 0.18 * centre_bonus - 0.15 * crack_amp * cracks * interior_fade)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 30.0
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
