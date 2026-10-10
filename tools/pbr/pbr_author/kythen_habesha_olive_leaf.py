"""Hand authored height and smoothness for kythen_habesha_olive_leaf.

The alpha channel was checked before deciding a structure: the 32 px
art's holes are a scatter of small clusters spread right across the
tile, the same layout as the other habesha leaves, not one contiguous
transparent border shaped like a single leaf silhouette. So this is a
canopy tile, not a cut-out, and the relief is built the same way as the
other habesha leaves: many overlapping lobe stamps standing taller where
the art is lighter. Olive leaves are narrow and lanceolate rather than
broad, so the lobes here are elongated (an ellipse rather than a round
dome, in the spirit of the juniper script's needle_stamp but wider and
with a readable pale midrib) at a size between kosso's leaflets and
fig's broad lobes. The alpha holes are gaps through the whole canopy and
are carved to a low floor regardless of what lobe sits there.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
SIZE = lib.SIZE


def zscore(field):
    """Zero mean, unit spread, so components combine by a chosen weight
    instead of by whatever scale a noise function happened to come out
    at."""
    return (field - field.mean()) / (field.std() + 1e-6)


def leaflet_stamp(half_len, half_wid, angle, amp, rim_frac=0.82, rim_depth=0.09,
        midrib_amp=0.22, midrib_sigma_frac=0.20):
    """An elongated dome (a narrow lanceolate leaflet, not a round lobe)
    with a raised midrib along its own long axis, the pale rib an olive
    leaf shows, and a shallow rim groove where one leaflet gives way to
    the next."""
    r = half_len
    d = np.arange(-r, r + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    along = dx * ca + dy * sa
    across = -dx * sa + dy * ca
    q = np.sqrt((along / half_len) ** 2 + (across / half_wid) ** 2)
    dome = np.where(q <= 1.0, 0.5 * (1.0 + np.cos(np.pi * np.clip(q, 0, 1))), 0.0)
    in_rim = (q > rim_frac) & (q <= 1.0)
    rim = np.zeros_like(dome)
    rim[in_rim] = -rim_depth * np.sin(np.pi * (q[in_rim] - rim_frac) / (1.0 - rim_frac))
    sigma = midrib_sigma_frac * half_wid
    midrib = midrib_amp * np.exp(-(across ** 2) / (2.0 * sigma ** 2)) * dome
    return (amp * (dome + rim + midrib)).astype(np.float32)


def scatter_leaflets(size, guide, n, seed, len_range, wid_range):
    """Places n leaflets at random positions and random axes, taller
    where guide (the art's own brightness) is higher, combined by
    maximum so a proud leaflet is not averaged away by whatever else
    overlaps it."""
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    angle = rng.uniform(0.0, np.pi, n)
    half_len = rng.integers(len_range[0], len_range[1] + 1, n)
    half_wid = rng.uniform(wid_range[0], wid_range[1], n)
    jitter = rng.uniform(0.85, 1.15, n)
    for i in range(n):
        local_guide = guide[cy[i], cx[i]]
        amp = jitter[i] * (0.4 + 0.9 * local_guide)
        r = int(half_len[i])
        stamp = leaflet_stamp(r, float(half_wid[i]), angle[i], amp)
        ys = (np.arange(-r, r + 1) + cy[i]) % size
        xs = (np.arange(-r, r + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
    return field


def build(out_dir):
    stem = "kythen_habesha_olive_leaf"
    src = lib.load_source(stem, GAME)
    print("source", stem, src.shape)
    lum32 = lib.luminance(src[..., :3])
    alpha32 = src[..., 3]
    print("source luminance min %.3f mean %.3f max %.3f sd %.3f" %
          (lum32.min(), lum32.mean(), lum32.max(), lum32.std()))
    transparent = (alpha32 < 0.5).sum()
    print("alpha: %d of %d texels transparent (%.1f%%)" %
          (transparent, alpha32.size, 100.0 * transparent / alpha32.size))
    print("alpha holes are scattered clusters across the whole tile, not a "
          "single bordered silhouette: this is a canopy tile, not a cut-out.")

    cls = lib.class_of(stem, GAME)
    print("class_of ->", cls)

    art_rgb = lib.upscale(src[..., :3])
    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 2))

    alpha256 = lib.upscale(src[..., 3])
    alpha_soft = lib.blur(alpha256, 2)

    # Narrow, elongated leaflets between kosso's size and fig's, two
    # tiers so the canopy keeps some depth variation.
    leaflets_fine = scatter_leaflets(SIZE, guide, 480, seed=6501,
            len_range=(7, 10), wid_range=(2.0, 2.8))
    leaflets_coarse = scatter_leaflets(SIZE, guide, 190, seed=6502,
            len_range=(11, 15), wid_range=(2.6, 3.4))
    leaflets = np.maximum(leaflets_fine, 0.8 * leaflets_coarse)
    leaflets = lib.normalise01(leaflets)

    grain = lib.fbm(SIZE, base_cells=40, octaves=2, seed=6503, gain=0.5)

    canopy = lib.normalise01(0.82 * leaflets + 0.18 * guide + 0.07 * (grain * 0.5 + 0.5))

    hole_floor = 0.03
    height = canopy * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)

    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=6504, gain=0.55)
    smooth = 0.5 + 0.12 * zscore(height) + 0.09 * zscore(variation)

    albedo = lib.upscale(src)
    normal_strength = 7.8
    metrics = lib.pack(stem, out_dir, albedo, height, smooth, cls,
                        normal_strength=normal_strength, art_texels=src.shape[0])
    lines = lib.check(metrics, cls)
    print("normal_strength", normal_strength)
    for k, v in metrics.items():
        print("  %s %.4f" % (k, v))
    print("\n".join(lines))
    preview_path = out_dir.rstrip("/") + "/" + stem + "_preview.png"
    lib.preview(out_dir, stem, preview_path)
    print("preview", preview_path)
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = build(out_dir)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
