"""Hand authored height and smoothness for the twelve Firecountry bark
sides, tools/pbr_author/kythen_firecountry_<species>_bark.py, one run()
shared by six constructions chosen per species from what its own 32 px art
draws. Every one of the twelve arts has a column mean spread several times
its row mean spread (checked by hand: beefwood 0.035 against 0.013, right
through to river box 0.168 against 0.027), so the family rule holds
everywhere: a bark's furrows run along the log, not across it. What
differs is how much of that column signal is a clean furrow against how
much is scattered mottling, and that difference picks the mode:

  furrow        a handful of dark, nearly flat columns cut the ring into
                bark ridges, the same read as default_tree.py's oak.
                beefwood, ironbark, kurrajong, osier, quandong.
  furrow_plates the same column furrows, with a second, shallower set of
                horizontal joints added on top so the ridges break into
                boxy plates. The art's own row mean is almost flat for
                both (coolabah 0.038, river box 0.027 against column
                spreads of 0.116 and 0.168), so the plate joints are a
                structural decision, not a row read: real box and coolabah
                bark plates the way the furrowed ridges do, this just
                gives them a second grain.
  lenticel      no columns at all, a scatter of small marks on an even
                field, the mcl_core_log_birch.py read. manna gum's art is
                three shades with the marks lighter than the field (shed
                ribbons, stood proud); wattle's is the marks darker than
                the field (lenticel pores, sunk).
  papery        one big, irregular, warped blob rather than many small
                marks: paperbark's darker two shades sit together in a
                loose patch covering roughly a third of the tile, which
                is what a hanging sheet of shed paper bark reads as, not
                a furrow and not a scatter of pores.
  fibrous       cypress pine's art has the family's weakest column signal
                relative to its overall contrast and no clean flat
                columns at all, just a fine, busy mix of shades with no
                dominant structure: stringy fibre and flaking, not a
                furrow.
  scaly         nut pine's dark texels fall in short diagonal runs rather
                than columns or scatter, climbing the tile the way
                overlapping bark scales climb a trunk.

Straight, unwarped column edges throughout: default_tree.py's reasoning
still holds, a bark furrow is a straight channel down the log, and
lib.warp_labels on it would turn that channel into a scribble. The plate
joints, lenticel marks and papery sheet are warped, because those
boundaries are organic, not a groove cut along the grain.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
SIZE = lib.SIZE


def blur_axis(field, radius, axis):
    """Wrapped box blur along one axis only, to stretch a feature along the
    other axis. lib.blur does both axes."""
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


# --- column furrow read, generalised from default_tree.py -------------------

def column_furrows(lum, margin_frac):
    """Furrow columns and ridge runs from the art's own column means, wrap
    aware, the same read default_tree.py gives the oak. margin_frac is a
    share of the column mean's own spread rather than a fixed shade, so it
    means the same thing on a low contrast bark (beefwood, spread 0.035) as
    on a high contrast one (river box, spread 0.168)."""
    n = lum.shape[1]
    col_mean = lum.mean(axis=0)
    spread = float(col_mean.max() - col_mean.min())
    margin = margin_frac * max(spread, 1e-6)
    is_furrow = col_mean < (col_mean.min() + margin)
    furrow_cols = np.where(is_furrow)[0]
    col_id = np.zeros(n, dtype=int)
    next_id = 0
    cur_id = None
    for x in range(n):
        if is_furrow[x]:
            col_id[x] = -(1 + list(furrow_cols).index(x))
            cur_id = None
        else:
            if cur_id is None:
                cur_id = next_id
                next_id += 1
            col_id[x] = cur_id
    if not is_furrow[0] and not is_furrow[-1] and col_id[0] != col_id[-1]:
        col_id[col_id == col_id[-1]] = col_id[0]
    ridge_lum = {}
    for c in set(col_id.tolist()):
        cols = np.where(col_id == c)[0]
        ridge_lum[c] = float(col_mean[cols].mean())
    return col_id, furrow_cols, ridge_lum


def stepped_dish(col_id, ridge_lum, n, furrow_target, ridge_range, edge_dist):
    """The stepped plateau, blurred by edge_dist texels so a species with
    few furrow groups (ironbark, osier) does not read one single-texel
    wide jump against hundreds of flat interior columns as a false seam:
    seam_energy compares the wrap edge to the mean of every interior row
    and column step, and an unblurred jump this rare makes that mean, and
    so the ratio, blow out (checked by hand: ironbark's own raw step read
    seam_n 1.89). A blurred step also under reports ao_from_height (a
    probe of the same shape read ao_min 0.50 blurred against 0.14 raw), so
    ao here comes from hard_cracks instead, not from this step. Returns
    the layout (roughly 0..1) and the ridge closeness t (1 on a ridge
    crown, 0 in a furrow floor), for the crown bulge and a smoothness term
    to key off."""
    ids = sorted(ridge_lum.keys())
    furrow_ids = [c for c in ids if c < 0]
    ridge_ids = [c for c in ids if c >= 0]
    ridge_vals = np.array([ridge_lum[c] for c in ridge_ids]) if ridge_ids else np.array([0.0])
    lo, hi = float(ridge_vals.min()), float(ridge_vals.max())
    target = {}
    for c in furrow_ids:
        target[c] = furrow_target
    for c in ridge_ids:
        m = ridge_lum[c]
        target[c] = ridge_range[0] + (ridge_range[1] - ridge_range[0]) * (m - lo) / max(hi - lo, 1e-6)
    remap = {c: i for i, c in enumerate(sorted(target.keys()))}
    col_id_shifted = np.vectorize(remap.get)(col_id)
    target_arr = np.array([target[c] for c in sorted(target.keys())])

    scale = SIZE // n
    labels16 = np.broadcast_to(col_id_shifted[None, :], (n, n)).copy()
    labels_hi = np.kron(labels16, np.ones((scale, scale), dtype=int))
    edges = lib.region_edges(labels_hi)
    dist = lib.distance_to_edge(edges, max_dist=edge_dist)
    t = np.clip(dist / edge_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target_arr[labels_hi]
    layout = lib.blur(step, max(1, edge_dist))
    return layout, t


def band_groove(size, n_bands, seed, edge_dist, jitter=0.4):
    """A set of roughly evenly spaced, jittered horizontal joints, for the
    plate mode's second grain. Not read from the art (the row mean is
    almost flat on both plate species), a structural decision that the
    ridges break into boxy plates rather than run the tile's full height.
    Returns t, 1 right at a joint and 0 a joint's edge_dist away."""
    rng = np.random.default_rng(seed)
    spacing = size / n_bands
    ys = np.array([int((i + 0.5) * spacing + rng.uniform(-jitter, jitter) * spacing)
            % size for i in range(n_bands)])
    edge = np.zeros((size, size), dtype=np.float32)
    edge[ys, :] = 1.0
    dist = lib.distance_to_edge(edge, max_dist=edge_dist)
    t = np.clip(dist / edge_dist, 0.0, 1.0)
    return t * t * (3 - 2 * t)


def hard_cracks(size, n, seed, length_range, depth, axis_bias=0.7, width=3):
    """A scatter of short, unblurred straight slots cut depth out of the
    height field. lib.pack's own fine_detail damping (fine_detail=0.35 by
    default) measures a texel against a one texel blur of itself, so a
    slot only one texel wide is mostly "fine" detail and lib.pack fills
    most of it back in (checked by hand: a wandering one texel wide crack
    on kurrajong's own smooth bark still read ao_min 0.40, barely moved by
    raising its count or depth). width texels wide, a slot's own centre
    column sits inside three texels of itself under lib.pack's one texel
    blur and survives undamaged, the same reason an 8 texel wide probe
    notch read ao_min 0.15 where a 2 texel one read 0.0 but softened
    further once damped. Left raw the way stepped_dish's own step is
    kept clean, for the same reason. axis_bias favours a mostly vertical
    slot (0 fully horizontal, 1 fully vertical), since a crack in bark
    splits along the grain."""
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    half = width // 2
    for _ in range(n):
        cy = rng.integers(0, size)
        cx = rng.integers(0, size)
        length = rng.integers(length_range[0], length_range[1] + 1)
        vertical = rng.uniform() < axis_bias
        for i in range(length):
            for w in range(-half, width - half):
                if vertical:
                    y = (cy + i) % size
                    x = (cx + w) % size
                else:
                    y = (cy + w) % size
                    x = (cx + i) % size
                field[y, x] = 1.0
    return field * depth


def mark_dish(mask16, size, warp_amp, edge_dist, seed):
    """A birch style scatter of marks turned into a shallow dish, mcl_core_
    log_birch.py's own recipe. Returns dish, 1 near a mark and fading to 0
    within edge_dist texels of it."""
    labels_hi = lib.warp_labels(mask16, size=size, amp=warp_amp, seed=seed, cells=12)
    edges = lib.region_edges(labels_hi)
    dist = lib.distance_to_edge(edges, max_dist=edge_dist)
    t = np.clip(dist / edge_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    return (1 - t) * labels_hi


# --- the six modes ------------------------------------------------------

def furrow_height(lum, n, margin_frac, furrow_target, ridge_range, edge_dist,
        crown_amp, grain_amp, grain_radius, crack_amp, pore_amp, seed,
        crack_count, crack_len, crack_depth):
    col_id, furrow_cols, ridge_lum = column_furrows(lum, margin_frac)
    print("  furrow columns:", furrow_cols.tolist(), "of", n)
    layout, t = stepped_dish(col_id, ridge_lum, n, furrow_target, ridge_range, edge_dist)
    crown = lib.fbm(SIZE, base_cells=4, octaves=2, seed=seed + 1) * crown_amp
    layout = layout + crown * t
    grain_src = lib.fbm(SIZE, base_cells=20, octaves=3, seed=seed + 2, gain=0.55)
    grain = blur_axis(grain_src, radius=grain_radius, axis=0) * grain_amp
    crack_src = lib.blur(lib.white_noise(SIZE, seed=seed + 3), 1)
    crack = blur_axis(crack_src, radius=3, axis=1) * crack_amp * t
    pores_src = lib.blur(lib.white_noise(SIZE, seed=seed + 4), 1)
    pores = blur_axis(pores_src, radius=8, axis=0) * pore_amp
    # The blurred step above is kept gentle enough to avoid a seam ratio
    # blow out on a species with few furrow groups, which also means it
    # under reports to ao_from_height; a few unblurred splits along the
    # furrow floor (see hard_cracks) give it a real wall to occlude at.
    cracks = hard_cracks(SIZE, crack_count, seed + 6, crack_len, crack_depth)
    height = lib.normalise01(layout + grain + crack + pores - cracks, 0.5, 99.5)
    return height, t


def furrow_plates_height(lum, n, margin_frac, furrow_target, ridge_range, edge_dist,
        crown_amp, grain_amp, grain_radius, crack_amp, pore_amp, seed,
        n_bands, plate_depth, plate_edge_dist, crack_count, crack_len, crack_depth):
    height, t = furrow_height(lum, n, margin_frac, furrow_target, ridge_range, edge_dist,
            crown_amp, grain_amp, grain_radius, crack_amp, pore_amp, seed,
            crack_count, crack_len, crack_depth)
    band_t = band_groove(SIZE, n_bands, seed + 11, plate_edge_dist)
    height = np.clip(height - plate_depth * band_t, 0.0, 1.0)
    print("  plate bands:", n_bands, "depth", plate_depth)
    return height, np.maximum(t, band_t)


def lenticel_height(lum, n, dark_thresh, mask_brighter, sign, warp_amp, edge_dist, base,
        mark_amp, grain_amp, grain_radius, pore_amp, seed):
    # mask_brighter picks which side of the threshold is the mark: manna
    # gum's shed ribbons are the lighter shade on a darker field, wattle's
    # lenticel pores are the darker shade on a lighter field. sign then
    # says whether the mark sits proud (a ribbon, standing off the trunk)
    # or sunk (a pore).
    mask16 = (lum > dark_thresh).astype(int) if mask_brighter else (lum < dark_thresh).astype(int)
    print("  marked texels: %d / %d (%.1f%%)" % (mask16.sum(), n * n, 100.0 * mask16.mean()))
    scar = mark_dish(mask16, SIZE, warp_amp, edge_dist, seed)
    grain_src = lib.fbm(SIZE, base_cells=10, octaves=3, seed=seed + 2, gain=0.55)
    grain = blur_axis(grain_src, radius=grain_radius, axis=0) * grain_amp
    pores_src = lib.blur(lib.white_noise(SIZE, seed=seed + 3), 1)
    pores = pores_src * pore_amp
    layout = base + sign * mark_amp * scar
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    return height, scar


def papery_height(lum, n, dark_thresh, warp_amp, sheet_amp, sheet_blur, seed,
        crease_amp, crease_radius, grain_amp, pore_amp, crack_count, crack_len,
        crack_depth):
    mask16 = (lum < dark_thresh).astype(int)
    print("  sheet texels: %d / %d (%.1f%%)" % (mask16.sum(), n * n, 100.0 * mask16.mean()))
    mask_hi = lib.warp_labels(mask16, size=SIZE, amp=warp_amp, seed=seed, cells=10).astype(np.float32)
    plateau = lib.blur(mask_hi, sheet_blur)
    creases = blur_axis(lib.fbm(SIZE, base_cells=16, octaves=3, seed=seed + 2, gain=0.55),
            radius=crease_radius, axis=1) * crease_amp
    grain = blur_axis(lib.fbm(SIZE, base_cells=24, octaves=2, seed=seed + 3, gain=0.5),
            radius=6, axis=0) * grain_amp
    pores = lib.blur(lib.white_noise(SIZE, seed=seed + 4), 1) * pore_amp
    # A handful of unblurred splits where a sheet has actually come away
    # from the trunk: see hard_cracks, the soft plateau above has no real
    # occluding wall of its own for lib.pack's ao_from_height to find.
    cracks = hard_cracks(SIZE, crack_count, seed + 5, crack_len, crack_depth)
    layout = 0.35 + sheet_amp * plateau
    height = lib.normalise01(layout + creases + grain + pores - cracks, 0.5, 99.5)
    return height, plateau


def fibrous_height(n, seed, fine_amp, fine_radius, coarse_amp, coarse_radius,
        fleck_amp, crack_count, crack_len, crack_depth):
    fine = blur_axis(lib.fbm(SIZE, base_cells=30, octaves=3, seed=seed, gain=0.55),
            radius=fine_radius, axis=0) * fine_amp
    coarse = blur_axis(lib.fbm(SIZE, base_cells=14, octaves=2, seed=seed + 1, gain=0.5),
            radius=coarse_radius, axis=0) * coarse_amp
    flecks = blur_axis(lib.blur(lib.white_noise(SIZE, seed=seed + 2), 1), radius=3, axis=0) * fleck_amp
    # Cypress pine's own art has no column or region structure to build a
    # real occluding wall from (the family's weakest column signal), so a
    # few unblurred splits along the fibre give lib.pack's ao_from_height
    # somewhere genuinely deep to find, the way a stringy bark always has a
    # fissure somewhere even when the general texture does not show one.
    cracks = hard_cracks(SIZE, crack_count, seed + 3, crack_len, crack_depth)
    height = lib.normalise01(fine + coarse + flecks - cracks, 0.5, 99.5)
    return height, fine + coarse


def scale_stamp(length, width, amp, shadow_depth):
    """A small elongated dome pointed at both ends of its long axis (y, up
    the trunk) with a shadow crescent along its lower rim, where the scale
    above overlaps the one below the way shingles do."""
    ry = int(np.ceil(length))
    rx = int(np.ceil(width))
    dy = np.arange(-ry, ry + 1, dtype=np.float32)
    dx = np.arange(-rx, rx + 1, dtype=np.float32)
    gy, gx = np.meshgrid(dy, dx, indexing="ij")
    r = np.sqrt((gy / length) ** 2 + (gx / width) ** 2)
    dome = np.where(r <= 1.0, 0.5 * (1.0 + np.cos(np.pi * np.clip(r, 0, 1))), 0.0)
    shadow = np.where((gy > 0.35 * length) & (r <= 1.0), -shadow_depth * (gy / length), 0.0)
    return (amp * dome + shadow * amp).astype(np.float32), ry, rx


def scatter_scales(size, guide, n, seed, length_range, width_range, amp_range):
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    length = rng.uniform(*length_range, n)
    width = rng.uniform(*width_range, n)
    jitter = rng.uniform(*amp_range, n)
    for i in range(n):
        local_guide = guide[cy[i], cx[i]]
        amp = jitter[i] * (0.4 + 0.8 * local_guide)
        stamp, ry, rx = scale_stamp(length[i], width[i], amp, shadow_depth=0.18)
        ys = (np.arange(-ry, ry + 1) + cy[i]) % size
        xs = (np.arange(-rx, rx + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
    return field


def scaly_height(lum, n, seed, count, length_range, width_range, grain_amp,
        crack_count, crack_len, crack_depth):
    guide = lib.normalise01(lib.blur(lib.upscale(1.0 - lum), 2))
    scales = scatter_scales(SIZE, guide, count, seed, length_range, width_range, (0.7, 1.15))
    scales = lib.normalise01(scales)
    grain = blur_axis(lib.fbm(SIZE, base_cells=22, octaves=2, seed=seed + 5, gain=0.5),
            radius=6, axis=0) * grain_amp
    # The scale domes are smooth shouldered, no wall for ao_from_height on
    # their own; a few unblurred splits between scale clusters give it
    # something to occlude at.
    cracks = hard_cracks(SIZE, crack_count, seed + 6, crack_len, crack_depth)
    height = lib.normalise01(0.85 * scales + 0.15 * guide + grain - cracks, 0.5, 99.5)
    return height, scales


# --- driver --------------------------------------------------------------

def run(stem, out_dir, *, mode, seed, normal_strength,
        margin_frac=0.25, furrow_target=0.10, ridge_range=(0.55, 0.85),
        edge_dist=3, crown_amp=0.14, grain_amp=0.20, grain_radius=10,
        crack_amp=0.05, pore_amp=0.03,
        n_bands=5, plate_depth=0.18, plate_edge_dist=3,
        dark_thresh=0.5, mask_brighter=False, sign=1.0, warp_amp=3.0, mark_amp=0.35, base=0.65,
        sheet_amp=0.30, sheet_blur=3, crease_amp=0.05, crease_radius=6,
        fine_amp=0.20, fine_radius=16, coarse_amp=0.12, coarse_radius=9,
        fleck_amp=0.05, scale_count=90, scale_length=(3.0, 6.0),
        scale_width=(1.4, 2.6),
        crack_count=5, crack_len=(6, 16), crack_depth=0.9,
        smooth_t_w=0.5, smooth_var_w=0.45, smooth_var_cells=16, cls_override=None):
    src = lib.load_source(stem, GAME)
    n = src.shape[0]
    print(f"{stem}: art {src.shape}, mode {mode}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print("  lum min %.3f max %.3f mean %.3f" % (lum.min(), lum.max(), lum.mean()))
    col_mean = lum.mean(axis=0)
    row_mean = lum.mean(axis=1)
    print("  col spread %.3f  row spread %.3f" %
            (col_mean.max() - col_mean.min(), row_mean.max() - row_mean.min()))

    key_field = None
    if mode == "furrow":
        height, key_field = furrow_height(lum, n, margin_frac, furrow_target, ridge_range,
                edge_dist, crown_amp, grain_amp, grain_radius, crack_amp, pore_amp, seed,
                crack_count, crack_len, crack_depth)
    elif mode == "furrow_plates":
        height, key_field = furrow_plates_height(lum, n, margin_frac, furrow_target, ridge_range,
                edge_dist, crown_amp, grain_amp, grain_radius, crack_amp, pore_amp, seed,
                n_bands, plate_depth, plate_edge_dist, crack_count, crack_len, crack_depth)
    elif mode == "lenticel":
        height, key_field = lenticel_height(lum, n, dark_thresh, mask_brighter, sign, warp_amp,
                edge_dist, base, mark_amp, grain_amp, grain_radius, pore_amp, seed)
    elif mode == "papery":
        height, key_field = papery_height(lum, n, dark_thresh, warp_amp, sheet_amp, sheet_blur,
                seed, crease_amp, crease_radius, grain_amp, pore_amp,
                crack_count, crack_len, crack_depth)
    elif mode == "fibrous":
        height, key_field = fibrous_height(n, seed, fine_amp, fine_radius, coarse_amp,
                coarse_radius, fleck_amp, crack_count, crack_len, crack_depth)
    elif mode == "scaly":
        height, key_field = scaly_height(lum, n, seed, scale_count, scale_length,
                scale_width, grain_amp, crack_count, crack_len, crack_depth)
    else:
        raise ValueError("unknown mode " + mode)
    print("  height sd %.3f" % height.std())

    variation = lib.fbm(SIZE, base_cells=smooth_var_cells, octaves=3, seed=seed + 20, gain=0.55)
    key_z = zscore(key_field) if key_field is not None else np.zeros((SIZE, SIZE), dtype=np.float32)
    smooth = 0.5 + smooth_t_w * 0.12 * key_z + smooth_var_w * 0.20 * zscore(variation)
    print("  pre pack smooth sd %.3f" % smooth.std())

    albedo = lib.upscale(rgb)
    cls = lib.class_of(stem, GAME)
    if cls_override is not None and cls_override != cls:
        print(f"  class_of says {cls}, overridden to {cls_override}: the art is plainly bark, "
                "not stone; NAME_HINTS has no bark entry so class_of fell back to the bake's "
                "own smoothness level, a name-matching gap rather than a real material read")
        cls = cls_override
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
    print("kythen_bark_family.py is a library; run one of the per stem scripts.")
