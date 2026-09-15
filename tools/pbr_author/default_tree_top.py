"""Hand authored height and smoothness for default_tree_top, the cut end.

The outer ring of every one of this stem family's four top textures is the
16 px art's edge: row 0, row 15, column 0 and column 15. Here those texels
sit at 0.225 to 0.285, while the interior (rows and columns 1 to 14) runs
0.33 to 0.626, well above the ring on average, though a few interior texels
dip as low as 0.225 too, an interior sawn face patch that happens to be
dark rather than a gap in the bark. That gap between "the edge, mostly one
narrow band" and "brighter, with some dark outliers" is what a real cut
log looks like: an outer ring of bark around a lighter, mottled sawn face.

lib.segments finds the connected regions in the colour data directly, which
generally agrees with the edge but is not identical to it: on this texture
it also picks up a few edge-adjacent interior texels that read as the same
tone as the ring. Those are kept as extra bark within two texels of the true
edge (the ring cannot spread further inward than that, so it stays a ring
and does not swallow the sawn face); the true one texel edge is always
included regardless of what segments finds, so the ring is never broken by
a segmentation gap. lib.warp_labels then rounds that ring's boundary into
an irregular, log-like silhouette rather than the square the art draws (no
np.kron, following the README's own reasoning about domes carrying the
pixel grid). lib.region_edges and lib.distance_to_edge turn the ring to
face transition into a groove with real depth, the same unsharp technique
mcl_core_planks_big_oak.py uses for its joints, so the ring stands a little
proud of the flat face rather than merely differing in colour.

The face gets faint concentric growth rings (a sine of radius from the
block's centre, wobbled by a low frequency noise field so they are not
perfect circles) and a handful of radial cracks (thin troughs in angle,
starting a little way out from the pith and fading before they reach the
ring), with the heartwood centre left the smoothest part of the whole map.
The ring band itself carries the same vertical bark grain default_tree.py
uses on the side, at the same seed, so the two faces read as one log.
"""

import sys

import numpy as np

import lib

STEM = "default_tree_top"
CLS = lib.class_of(STEM)
SIZE = lib.SIZE
SEED = 101  # shared with default_tree.py, the side of the same log


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
    """The 16 px label map: 1 for the bark ring, 0 for the sawn face.
    Always includes the true one texel edge; lib.segments can extend that
    up to two texels inward where the art's own colour regions agree, but
    no further, so the ring cannot eat the whole face."""
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
    ring_max_dist = 5
    dist = lib.distance_to_edge(edges, max_dist=ring_max_dist)
    t = smoothstep(dist / ring_max_dist)
    interior_fade = t * interior_mask  # 0 at the ring, 1 deep in the face
    ring_fade = t * ring_mask  # 0 at the face, 1 deep in the ring

    # The ring to face step, unsharpened into a matched-slope groove the
    # same way mcl_core_planks_big_oak.py builds its joints.
    target_ring, target_face = 0.80, 0.40
    step = np.where(labels_hi == 1, target_ring, target_face).astype(np.float32)
    narrow = lib.blur(step, 2)
    wide = lib.blur(step, 4)
    layout = narrow + 0.9 * (narrow - wide)

    # Faint concentric growth rings, radius from the block's own centre,
    # wobbled so they are not perfect circles, present only on the face.
    yy, xx = np.indices((SIZE, SIZE)).astype(np.float32)
    cy = cx = (SIZE - 1) / 2.0
    r = np.sqrt((yy - cy) ** 2 + (xx - cx) ** 2)
    wobble = lib.fbm(SIZE, base_cells=6, octaves=2, seed=SEED + 11) * 4.0
    rings = np.sin((r + wobble) * 0.10) * 0.025
    layout = layout + rings * interior_fade

    # A few radial cracks: thin troughs in angle, starting a little way out
    # from the pith and fading out before they reach the ring, so neither
    # the heartwood nor the bark is broken by them.
    theta = np.arctan2(yy - cy, xx - cx)
    crack_n = 5
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
    crack_amp = 0.04
    layout = layout - crack_amp * cracks * interior_fade

    # Bark grain on the ring band, sharing default_tree.py's vertical fibre
    # construction and seed so the cut end reads as the same bark.
    ring_grain_src = lib.fbm(SIZE, base_cells=16, octaves=3, seed=SEED + 2, gain=0.55)
    ring_grain = blur_axis(ring_grain_src, radius=10, axis=0) * 0.18
    ring_crack_src = lib.blur(lib.white_noise(SIZE, seed=SEED + 3), 1)
    ring_crack = blur_axis(ring_crack_src, radius=3, axis=1) * 0.05
    layout = layout + (ring_grain + ring_crack) * ring_fade

    pores = lib.blur(lib.white_noise(SIZE, seed=SEED + 4), 1) * 0.02

    height = lib.normalise01(layout + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: the face smoother than the ring, a directional field for
    # spread, a bonus at the pith so the heartwood is the smoothest point on
    # the map, and a touch of extra roughness right on the radial cracks.
    directional_rough = lib.fbm(SIZE, base_cells=18, octaves=3, seed=SEED + 5, gain=0.55)
    centre_bonus = np.exp(-(r / (SIZE * 0.12)) ** 2)
    smooth = (0.75 - 0.35 * ring_fade + 0.15 * directional_rough
            + 0.18 * centre_bonus - 0.15 * crack_amp * cracks * interior_fade)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 34.0
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
