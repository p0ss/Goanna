"""Hand authored height and smoothness for the thirteen Mitteleuropa leaf
faces, tools/pbr_author/kythen_mitteleuropa_<species>_leaf.py, one run()
shared by two constructions.

Every one of the thirteen arts (checked by hand) is a canopy face in the
mcl_core_leaves_big_oak.py sense, not a single leaf silhouette: 87 to 94
percent opaque, with small, mostly single texel holes scattered through
the whole tile rather than one drawn outline, the light coming through the
gaps between many overlapping small leaves seen face on. So the relief is
built the way that art was, and the way kythen_leaves.py and
kythen_firecountry_saltbush_leaf.py both already build it here: many small
stamps scattered and combined by maximum, standing taller where the art's
own brightness is higher, with the alpha holes carved to the deepest point
on the map afterwards regardless of what stamp would otherwise sit there,
since a hole is a gap through the whole canopy rather than a dim leaf.

  broadleaf   a dome stretched into an ellipse of the species' own leaf
              shape (round for hazel and lime, elongated for willow's
              lanceolate blade and ash's pinnate leaflets) with a raised
              midrib along its long axis, mcl_core_leaves_big_oak.py's
              lobe_stamp generalised with a length and a width instead of
              one radius. Used for the eleven broadleaf species: alder,
              ash, beech, birch, elm, hazel, hornbeam, lime, oak, poplar,
              willow.
  needle      mcl_core_leaves_spruce.py's own construction, short thin
              domes at random angles with no midrib, for silver fir's
              flat needles.
  scale       small flat overlapping domes, shorter and rounder than a
              needle and angled every which way rather than climbing one
              axis the way kythen_mitteleuropa_bark_family.py's bark
              scales do, since juniper foliage is awl shaped scale leaves
              pressed close along the shoot, not bark plates. For juniper.

Character (leaf size and aspect, length to width) comes from the species'
real leaf shape, since the 32 px art carries no more than a canopy's worth
of per texel shading to read; scattering many small stamps is itself
already the structural decision the family rule allows for a surface with
no single shape to segment, the same standing default_leaves.py and the
oak and spruce scripts give their own canopies.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
SIZE = lib.SIZE


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def leaf_stamp(length, width, angle, amp, rim_frac=0.80, rim_depth=0.10,
        midrib_amp=0.20, midrib_sigma_frac=0.20):
    """An elongated dome (raised cosine along an ellipse, so it meets zero
    slope at its own rim), a raised midrib along the long axis, and a
    shallow groove just inside the rim where one leaf gives way to the
    next. length equal to width gives mcl_core_leaves_big_oak.py's own
    round lobe; length greater than width gives an elongated blade."""
    r_extent = int(np.ceil(max(length, width)))
    d = np.arange(-r_extent, r_extent + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    r = np.sqrt((u / length) ** 2 + (v / width) ** 2)
    dome = np.where(r <= 1.0, 0.5 * (1.0 + np.cos(np.pi * np.clip(r, 0, 1))), 0.0)
    rim_r0 = rim_frac
    in_rim = (r > rim_r0) & (r <= 1.0)
    rim = np.zeros_like(dome)
    rim[in_rim] = -rim_depth * np.sin(np.pi * (r[in_rim] - rim_r0) / (1.0 - rim_r0))
    sigma = midrib_sigma_frac * width * 2.0
    midrib = midrib_amp * np.exp(-(v ** 2) / (2.0 * sigma ** 2)) * dome
    return (amp * (dome + rim + midrib)).astype(np.float32), r_extent


def needle_stamp(length, width, angle, amp, rim_frac=0.78, rim_depth=0.06):
    """mcl_core_leaves_spruce.py's own needle: an elongated dome with no
    midrib, since a needle is too thin to carry one."""
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


def scatter_stamps(size, guide, n, seed, length_range, width_range, stamp_fn, **stamp_kwargs):
    """Places n stamps at random positions and angles, taller where guide
    (the art's own brightness) is higher, combined by maximum so a proud
    stamp is not averaged away by whatever else overlaps it."""
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
        amp = jitter[i] * (0.4 + 0.9 * local_guide)
        stamp, r = stamp_fn(length[i], width[i], angle[i], amp, **stamp_kwargs)
        ys = (np.arange(-r, r + 1) + cy[i]) % size
        xs = (np.arange(-r, r + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
    return field


def run(stem, out_dir, *, mode, seed, normal_strength,
        fine_len=(6.0, 9.0), fine_wid=(6.0, 9.0), fine_n=700,
        coarse_len=(10.0, 15.0), coarse_wid=(10.0, 15.0), coarse_n=260, coarse_weight=0.8,
        rim_depth=0.10, midrib_amp=0.20,
        grain_cells=40, grain_amp=0.08,
        canopy_lobe_w=0.82, canopy_guide_w=0.18,
        hole_floor=0.03, hole_blur=2,
        smooth_height_w=0.12, smooth_var_w=0.09, smooth_var_cells=18, smooth_var_sign=1.0):
    src = lib.load_source(stem, GAME)
    n = src.shape[0]
    print(f"{stem}: art {src.shape}, mode {mode}")
    lum16 = lib.luminance(src[..., :3])
    alpha16 = src[..., 3]
    print("  lum min %.3f max %.3f mean %.3f sd %.3f" %
            (lum16.min(), lum16.max(), lum16.mean(), lum16.std()))
    holes = int((alpha16 < 0.5).sum())
    print(f"  alpha: {holes} of {n * n} texels transparent ({100.0 * holes / (n * n):.1f}%)")

    art_rgb = lib.upscale(src[..., :3])
    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 2))

    alpha256 = lib.upscale(alpha16)
    alpha_soft = lib.blur(alpha256, hole_blur)

    if mode == "broadleaf":
        fine = scatter_stamps(SIZE, guide, fine_n, seed, fine_len, fine_wid, leaf_stamp,
                rim_depth=rim_depth, midrib_amp=midrib_amp)
        coarse = scatter_stamps(SIZE, guide, coarse_n, seed + 1, coarse_len, coarse_wid, leaf_stamp,
                rim_depth=rim_depth, midrib_amp=midrib_amp)
    elif mode == "needle":
        fine = scatter_stamps(SIZE, guide, fine_n, seed, fine_len, fine_wid, needle_stamp)
        coarse = scatter_stamps(SIZE, guide, coarse_n, seed + 1, coarse_len, coarse_wid, needle_stamp)
    elif mode == "scale":
        fine = scatter_stamps(SIZE, guide, fine_n, seed, fine_len, fine_wid, needle_stamp,
                rim_depth=0.16)
        coarse = scatter_stamps(SIZE, guide, coarse_n, seed + 1, coarse_len, coarse_wid, needle_stamp,
                rim_depth=0.16)
    else:
        raise ValueError("unknown mode " + mode)

    lobes = np.maximum(fine, coarse_weight * coarse)
    lobes = lib.normalise01(lobes)

    grain = lib.fbm(SIZE, base_cells=grain_cells, octaves=2, seed=seed + 3, gain=0.5)
    canopy = lib.normalise01(canopy_lobe_w * lobes + canopy_guide_w * guide + 0.08 * (grain * 0.5 + 0.5))

    # The holes go all the way down regardless of what stamp would
    # otherwise be there: a hole is a gap through the whole canopy.
    height = canopy * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)
    print(f"  height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=smooth_var_cells, octaves=3, seed=seed + 4, gain=0.55)
    smooth = 0.5 + smooth_height_w * zscore(height) + smooth_var_sign * smooth_var_w * zscore(variation)
    print(f"  pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src)  # RGBA, keeps the cut-out alpha
    cls = lib.class_of(stem, GAME)
    print("  class_of ->", cls)
    m = lib.pack(stem, out_dir, albedo, height, smooth, cls,
            normal_strength=normal_strength, art_texels=n)
    print(f"  normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"    {k} = {v:.4f}")
    lines = lib.check(m, cls)
    for line in lines:
        print("  " + line)
    lib.preview(out_dir, stem, str(out_dir) + "/" + stem + "_preview.png")
    return lines


if __name__ == "__main__":
    print("kythen_mitteleuropa_leaf_family.py is a library; run one of the per stem scripts.")
