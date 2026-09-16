"""Hand authored height and smoothness for the twelve Firecountry leaf
cut-outs, tools/pbr_author/kythen_firecountry_<species>_leaf.py, one run()
shared by three stamp shapes. Every one of the twelve arts is the same
kind of drawing as mcl_core_leaves_big_oak.py and mcl_core_leaves_spruce.py:
a per texel dither of a handful of grey levels with 8 to 12 percent of the
tile punched to alpha zero, a canopy or a sprig seen face on with small
gaps of sky between overlapping leaves, not a single leaf silhouette to
segment. So the relief is built the same way those two scripts build it,
scattered stamps taller where the art is lighter, the alpha holes carved
to the deepest point regardless of what stamp would otherwise sit there,
with the stamp shape read from what each species actually is:

  blade     a long lanceolate eucalypt style leaf with a midrib, oak's own
            lobe_stamp crossed with spruce's elongated needle_stamp: an
            anisotropic dome tapered to a point at both ends of its long
            axis, with a raised midrib running that axis. Most of the
            twelve read this way: beefwood, coolabah, ironbark, kurrajong,
            manna gum, osier, paperbark, quandong, river box, each
            differing only in the blade's own length, width and midrib
            strength (coarse and broad for beefwood and kurrajong, fine
            and slender for quandong and osier, small for paperbark).
  needle    spruce's own needle_stamp, no midrib, a thin leaf is too
            narrow to carry one: cypress pine's scale foliage (very short,
            dense, appressed to the stem) and nut pine's true needles
            (longer, sparser, spruce's own proportions).
  feathery  the same needle_stamp again at a smaller size and a much
            higher count, wattle's fine bipinnate foliage: many short,
            slender leaflets rather than one or two broad blades.

leaves is not a jointed class (lib.check only asks ao_min of stone,
gravel, wood and soil), so there is no ambient occlusion target to meet
here, unlike the bark family.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
SIZE = lib.SIZE


def zscore(field):
    """Zero mean, unit spread, so components combine by a chosen weight
    instead of by whatever scale a noise function happened to come out at.
    Kept local because pack() clips smoothness to 0..1 before it re-centres
    the mean, the same reason the two worked leaf scripts keep it local."""
    return (field - field.mean()) / (field.std() + 1e-6)


def blade_stamp(length, width, angle, amp, midrib_amp=0.18, midrib_sigma_frac=0.22,
        rim_frac=0.80, rim_depth=0.08):
    """A lanceolate blade: an anisotropic dome tapered to a point at both
    ends of its long axis (mcl_core_leaves_spruce.py's needle_stamp shape),
    with a raised midrib along that axis (mcl_core_leaves_big_oak.py's own
    midrib term) and a shallow rim groove where the next leaf overlaps."""
    r_extent = int(np.ceil(max(length, width)))
    d = np.arange(-r_extent, r_extent + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    r = np.sqrt((u / length) ** 2 + (v / width) ** 2)
    dome = np.where(r <= 1.0, 0.5 * (1.0 + np.cos(np.pi * np.clip(r, 0, 1))), 0.0)
    in_rim = (r > rim_frac) & (r <= 1.0)
    rim = np.zeros_like(dome)
    rim[in_rim] = -rim_depth * np.sin(np.pi * (r[in_rim] - rim_frac) / (1.0 - rim_frac))
    sigma = midrib_sigma_frac * width
    midrib = midrib_amp * np.exp(-(v ** 2) / (2.0 * sigma ** 2)) * dome
    return (amp * (dome + rim + midrib)).astype(np.float32), r_extent


def needle_stamp(length, width, angle, amp, rim_frac=0.78, rim_depth=0.06):
    """mcl_core_leaves_spruce.py's own needle: an elongated dome, no
    midrib, a needle or a wattle leaflet is too thin to carry one."""
    r_extent = int(np.ceil(max(length, width)))
    d = np.arange(-r_extent, r_extent + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    r = np.sqrt((u / length) ** 2 + (v / width) ** 2)
    dome = np.where(r <= 1.0, 0.5 * (1.0 + np.cos(np.pi * np.clip(r, 0, 1))), 0.0)
    in_rim = (r > rim_frac) & (r <= 1.0)
    rim = np.zeros_like(dome)
    rim[in_rim] = -rim_depth * np.sin(np.pi * (r[in_rim] - rim_frac) / (1.0 - rim_frac))
    return (amp * (dome + rim)).astype(np.float32), r_extent


def scatter_stamps(size, guide, n, seed, stamp_fn, length_range, width_range,
        amp_lo=0.4, amp_hi=0.9):
    """Places n stamps at random positions and angles, taller where guide
    (the art's own brightness) is higher, combined by maximum so a proud
    leaf is not averaged away by whatever else overlaps it. Shared by all
    three shapes, mcl_core_leaves_big_oak.py's scatter_lobes and
    mcl_core_leaves_spruce.py's scatter_needles generalised over the stamp
    function."""
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    angle = rng.uniform(0.0, np.pi, n)
    length = rng.uniform(length_range[0], length_range[1], n)
    width = rng.uniform(width_range[0], width_range[1], n)
    jitter = rng.uniform(0.85, 1.15, n)
    for i in range(n):
        local_guide = guide[cy[i], cx[i]]
        amp = jitter[i] * (amp_lo + (amp_hi - amp_lo) * local_guide)
        stamp, r = stamp_fn(length[i], width[i], angle[i], amp)
        ys = (np.arange(-r, r + 1) + cy[i]) % size
        xs = (np.arange(-r, r + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
    return field


def run(stem, out_dir, *, shape, seed, normal_strength,
        fine_n, fine_length, fine_width, coarse_n, coarse_length, coarse_width,
        coarse_weight=0.8, midrib_amp=0.18, grain_cells=40, grain_weight=0.08,
        guide_weight=0.15, hole_floor=0.03, alpha_blur=2,
        smooth_base=0.5, smooth_height_w=0.12, smooth_var_w=0.09,
        smooth_var_cells=18, smooth_var_sign=1.0):
    src = lib.load_source(stem, GAME)
    n = src.shape[0]
    print(f"{stem}: art {src.shape}, shape {shape}")
    lum16 = lib.luminance(src[..., :3])
    alpha16 = src[..., 3]
    print("  source luminance min %.3f mean %.3f max %.3f sd %.3f" %
            (lum16.min(), lum16.mean(), lum16.max(), lum16.std()))
    print("  alpha: %d of %d texels transparent (%.1f%%)" %
            ((alpha16 < 0.5).sum(), n * n, 100.0 * (alpha16 < 0.5).mean()))

    art_rgb = lib.upscale(src[..., :3])
    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 2))
    alpha256 = lib.upscale(src[..., 3])
    alpha_soft = lib.blur(alpha256, alpha_blur)

    if shape == "blade":
        stamp_fn = lambda l, w, a, amp: blade_stamp(l, w, a, amp, midrib_amp=midrib_amp)
    else:
        stamp_fn = needle_stamp

    fine = scatter_stamps(SIZE, guide, fine_n, seed, stamp_fn, fine_length, fine_width)
    coarse = scatter_stamps(SIZE, guide, coarse_n, seed + 1, stamp_fn, coarse_length, coarse_width)
    foliage = np.maximum(fine, coarse_weight * coarse)
    foliage = lib.normalise01(foliage)

    grain = lib.fbm(SIZE, base_cells=grain_cells, octaves=2, seed=seed + 3, gain=0.5)
    body_weight = 1.0 - grain_weight - guide_weight
    canopy = lib.normalise01(body_weight * foliage + guide_weight * guide +
            grain_weight * (grain * 0.5 + 0.5))

    # The holes go all the way down regardless of what stamp would
    # otherwise be there: a hole is a gap through the whole leaf, not a
    # dim stamp, the same reasoning the two worked leaf scripts give.
    height = canopy * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)
    print("  height sd %.3f" % height.std())

    variation = lib.fbm(SIZE, base_cells=smooth_var_cells, octaves=3, seed=seed + 4, gain=0.55)
    smooth = (smooth_base + smooth_height_w * zscore(height) +
            smooth_var_sign * smooth_var_w * zscore(variation))
    print("  pre pack smooth sd %.3f" % smooth.std())

    albedo = lib.upscale(src)
    cls = lib.class_of(stem, GAME)
    m = lib.pack(stem, out_dir, albedo, height, smooth, cls,
            normal_strength=normal_strength, art_texels=n)
    print(f"  normal_strength={normal_strength}  class={cls}")
    for k, v in m.items():
        print(f"    {k} = {v:.4f}")
    lines = lib.check(m, cls)
    for line in lines:
        print("  " + line)
    lib.preview(out_dir, stem, str(out_dir) + "/" + stem + "_preview.png")
    return lines


if __name__ == "__main__":
    print("kythen_leaf_family.py is a library; run one of the per stem scripts.")
