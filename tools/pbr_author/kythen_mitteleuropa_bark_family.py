"""Hand authored height and smoothness for the thirteen Mitteleuropa bark
sides, tools/pbr_author/kythen_mitteleuropa_<species>_bark.py, one run()
shared by seven constructions chosen per species from its brief character
and what its own 32 px art draws (checked by hand, column mean spread
against row mean spread and the furrow columns a threshold on the column
mean finds):

  furrow        a handful of dark, nearly flat columns cut the ring into
                bark ridges, the kythen_bark_family.py read. oak (col
                spread 0.071, a clean run of furrow columns) and lime
                (spread 0.118, the family's clearest column signal) both
                give a good column read; elm's is weaker (spread 0.043,
                barely two columns clear the threshold) so elm leans more
                on grain and cracks than on the stepped dish itself. Deep
                for oak and elm, shallow for lime (brief: "lime shallow"),
                held to a narrower ridge_range and a smaller furrow_target
                gap so the dish itself is gentler even though the wood
                class target still asks for the same 18 to 28 degree tilt
                as everything else, made up here by grain instead of by
                the groove.
  flute         the same column read, but blurred until the step becomes a
                continuous wave instead of a plateau with a wall: beech
                (5 to 6 columns at a shallow margin) and hornbeam (weaker,
                3 to 4) both show a faint vertical striping in their art,
                not a real groove, which is what the brief's "smooth with
                faint fluting" describes. A handful of hard, unblurred
                cracks still give ao_from_height something to occlude at,
                since the wood class is judged jointed regardless of how
                gentle the fluting reads.
  diamond       two families of straight furrows crossing at a shallow
                angle, forming a lattice of diamond facets: ash's own
                column read is real (spread 0.170, the family's strongest)
                but is not a single clean furrow set top to bottom, the
                per row band check found the dark columns shift under a
                straight column read (columns 1, 20, 27 darkest in rows 0
                to 7; 0, 11, 20 in rows 8 to 15; 0, 31 in rows 16 to 23),
                which is exactly what a net of crossing fissures looks
                like read one row band at a time rather than what a
                straight furrow does. True ash bark grows this way, so the
                lattice is a structural decision built for the character,
                not a per pixel read, the same standing kythen_bark_family
                gives its plate joints.
  fissured_plates the furrow read with band_groove's horizontal joints
                added on top, breaking the ridges into boxy plates: alder
                and poplar (brief: "fissured plates"), whose own column
                signal is present but not strong (alder 0.041, poplar
                0.101, both well under oak's or lime's), so, as
                kythen_bark_family's own plate species found, the plate
                joints are a structural decision that gives real alder and
                poplar bark its plating rather than a row by row read.
  lenticel      birch's own weak column signal (spread 0.105 but only 2 to
                3 columns clear even a loose margin) and its genuinely
                mottled art (lum 0.708 to 0.907, patches rather than
                stripes) match mcl_core_log_birch.py's read exactly: scars
                from a mark mask, not a furrow.
  scaly         silver fir's column signal is the family's weakest bar
                juniper's (spread 0.049, at most 1 to 4 columns even at a
                loose margin) and its art is a fine, busy, almost uniform
                mottle: the kythen_firecountry_nut_pine_bark.py read,
                overlapping scale domes climbing the tile, guided by the
                art's own darker texels. "Resinous" lifts the smoothness
                mean and adds a few brighter resin beads at the scale
                edges, where sap collects.
  fibrous       juniper (brief: "stringy") has 10 to 13 of 32 columns
                clearing even a strict margin, which is not a clean furrow
                set, it is the whole tile carrying weak, broken vertical
                structure with no dominant columns at all, the
                kythen_firecountry_cypress_pine_bark.py read. Willow
                (brief: "deep and stringy") gets the same construction
                with more amplitude and deeper, more frequent cracks, so
                it reads as the same family of bark pulled further along
                the same axis rather than a different material.

Straight, unwarped column and lattice edges throughout, the same reasoning
default_tree.py and kythen_bark_family.py give: a furrow is a channel cut
along the grain and lib.warp_labels on it turns the channel into a
scribble. Only the organic marks (lenticel scars, scale outlines) are
warped, because those boundaries are not a straight cut.
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


# --- column furrow read ------------------------------------------------

def column_furrows(lum, margin_frac):
    """Furrow columns and ridge runs from the art's own column means, wrap
    aware. margin_frac is a share of the column mean's own spread, so it
    means the same thing on a low contrast bark as on a high contrast
    one."""
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
    """The stepped plateau from the column read, blurred by edge_dist
    texels. Returns the layout and t, the ridge closeness (1 on a ridge
    crown, 0 in a furrow floor)."""
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
    """Roughly evenly spaced, jittered horizontal joints, for the plate
    mode's second grain: not read from the art, a structural decision that
    the ridges break into boxy plates."""
    rng = np.random.default_rng(seed)
    spacing = size / n_bands
    ys = np.array([int((i + 0.5) * spacing + rng.uniform(-jitter, jitter) * spacing)
            % size for i in range(n_bands)])
    edge = np.zeros((size, size), dtype=np.float32)
    edge[ys, :] = 1.0
    dist = lib.distance_to_edge(edge, max_dist=edge_dist)
    t = np.clip(dist / edge_dist, 0.0, 1.0)
    return t * t * (3 - 2 * t)


def diamond_lattice(size, spacing, width, warp_amp, warp_cells, seed):
    """Two families of straight furrows crossing at 45 degrees, forming a
    lattice of diamond facets. u and v are computed from a position warped
    by a tileable fbm field rather than the raw grid, so the lattice lines
    wander gently the way real fissures do while staying an exact function
    of position mod size, which keeps the whole field tileable without a
    single np.roll. spacing must divide size so the modulo wrap lines up
    with the texture's own wrap. Returns t, 1 on a lattice line and fading
    to 0 a groove's width away, for the depth term and the smoothness
    term to key off."""
    assert size % spacing == 0, "diamond spacing must divide the map size"
    gy, gx = np.meshgrid(np.arange(size, dtype=np.float32), np.arange(size, dtype=np.float32), indexing="ij")
    wx = lib.fbm(size, warp_cells, 2, seed) * warp_amp
    wy = lib.fbm(size, warp_cells, 2, seed + 17) * warp_amp
    x = gx + wx
    y = gy + wy
    u = np.mod(x + y, spacing)
    v = np.mod(x - y, spacing)
    du = np.minimum(u, spacing - u)
    dv = np.minimum(v, spacing - v)
    d = np.minimum(du, dv)
    t = np.clip(1.0 - d / width, 0.0, 1.0)
    return t * t * (3 - 2 * t)


def hard_cracks(size, n, seed, length_range, depth, axis_bias=0.7, width=3):
    """A scatter of short, unblurred straight slots cut depth out of the
    height field, kept raw (not blurred) so lib.pack's fine_detail damping
    does not fill them back in, giving ao_from_height a real wall to find
    even when the surrounding structure is gentle. axis_bias favours a
    mostly vertical slot, since a crack in bark splits along the grain."""
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
    """A birch style scatter of marks turned into a shallow dish."""
    labels_hi = lib.warp_labels(mask16, size=size, amp=warp_amp, seed=seed, cells=12)
    edges = lib.region_edges(labels_hi)
    dist = lib.distance_to_edge(edges, max_dist=edge_dist)
    t = np.clip(dist / edge_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    return (1 - t) * labels_hi


def scale_stamp(length, width, amp, shadow_depth):
    """A small elongated dome, pointed at both ends of its long axis (y, up
    the trunk), with a shadow crescent along its lower rim, where the scale
    above overlaps the one below."""
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


# --- the seven modes -----------------------------------------------------

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
    cracks = hard_cracks(SIZE, crack_count, seed + 6, crack_len, crack_depth)
    height = lib.normalise01(layout + grain + crack + pores - cracks, 0.5, 99.5)
    return height, t


def flute_height(lum, n, margin_frac, furrow_target, ridge_range, wave_edge_dist,
        grain_amp, grain_radius, pore_amp, seed, crack_count, crack_len, crack_depth):
    col_id, furrow_cols, ridge_lum = column_furrows(lum, margin_frac)
    print("  flute columns:", furrow_cols.tolist(), "of", n)
    # A much wider edge_dist than furrow_height's turns the stepped dish
    # into a continuous wave: no flat plateau, no sharp wall, a wave
    # crossing every column boundary at a shallow angle instead.
    layout, t = stepped_dish(col_id, ridge_lum, n, furrow_target, ridge_range, wave_edge_dist)
    grain_src = lib.fbm(SIZE, base_cells=18, octaves=3, seed=seed + 2, gain=0.55)
    grain = blur_axis(grain_src, radius=grain_radius, axis=0) * grain_amp
    pores_src = lib.blur(lib.white_noise(SIZE, seed=seed + 3), 1)
    pores = blur_axis(pores_src, radius=6, axis=0) * pore_amp
    # A handful of real cracks even on an otherwise gentle wave: the wood
    # class is judged jointed regardless of how faint the fluting reads,
    # and a smooth continuous wave has no wall of its own for
    # ao_from_height to occlude at.
    cracks = hard_cracks(SIZE, crack_count, seed + 6, crack_len, crack_depth)
    height = lib.normalise01(layout + grain + pores - cracks, 0.5, 99.5)
    return height, t


def diamond_height(lum, n, spacing, width, depth, warp_amp, warp_cells,
        grain_amp, grain_radius, pore_amp, crown_amp, seed,
        crack_count, crack_len, crack_depth):
    t = diamond_lattice(SIZE, spacing, width, warp_amp, warp_cells, seed)
    # A slow bulge per facet from the art's own colour, so a lighter patch
    # of bark reads as a slightly prouder facet rather than every diamond
    # standing at the same height.
    crown = lib.fbm(SIZE, base_cells=8, octaves=2, seed=seed + 1) * crown_amp
    layout = 0.65 - depth * t + crown * (1.0 - t)
    grain_src = lib.fbm(SIZE, base_cells=20, octaves=3, seed=seed + 2, gain=0.55)
    grain = blur_axis(grain_src, radius=grain_radius, axis=0) * grain_amp
    pores_src = lib.blur(lib.white_noise(SIZE, seed=seed + 4), 1)
    pores = pores_src * pore_amp
    cracks = hard_cracks(SIZE, crack_count, seed + 6, crack_len, crack_depth, axis_bias=0.5)
    height = lib.normalise01(layout + grain + pores - cracks, 0.5, 99.5)
    return height, t


def fissured_plates_height(lum, n, margin_frac, furrow_target, ridge_range, edge_dist,
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
        mark_amp, grain_amp, grain_radius, pore_amp, seed, crack_count, crack_len, crack_depth):
    mask16 = (lum > dark_thresh).astype(int) if mask_brighter else (lum < dark_thresh).astype(int)
    print("  marked texels: %d / %d (%.1f%%)" % (mask16.sum(), n * n, 100.0 * mask16.mean()))
    scar = mark_dish(mask16, SIZE, warp_amp, edge_dist, seed)
    grain_src = lib.fbm(SIZE, base_cells=10, octaves=3, seed=seed + 2, gain=0.55)
    grain = blur_axis(grain_src, radius=grain_radius, axis=0) * grain_amp
    pores_src = lib.blur(lib.white_noise(SIZE, seed=seed + 3), 1)
    pores = pores_src * pore_amp
    layout = base + sign * mark_amp * scar
    cracks = hard_cracks(SIZE, crack_count, seed + 6, crack_len, crack_depth, axis_bias=0.3)
    height = lib.normalise01(layout + grain + pores - cracks, 0.5, 99.5)
    return height, scar


def scaly_height(lum, n, seed, count, length_range, width_range, grain_amp,
        resin_amp, crack_count, crack_len, crack_depth):
    guide = lib.normalise01(lib.blur(lib.upscale(1.0 - lum), 2))
    scales = scatter_scales(SIZE, guide, count, seed, length_range, width_range, (0.7, 1.15))
    scales = lib.normalise01(scales)
    grain = blur_axis(lib.fbm(SIZE, base_cells=22, octaves=2, seed=seed + 5, gain=0.5),
            radius=6, axis=0) * grain_amp
    cracks = hard_cracks(SIZE, crack_count, seed + 6, crack_len, crack_depth)
    height = lib.normalise01(0.85 * scales + 0.15 * guide + grain - cracks, 0.5, 99.5)
    # Resin: a few bright beads sitting right at the scale edges, where sap
    # collects and hardens. Returned as its own field so run() can key the
    # smoothness off it directly rather than off the general scale shape.
    resin_src = lib.blur(lib.white_noise(SIZE, seed=seed + 7), 1)
    resin = np.clip(resin_src, 0.0, None) * scales * resin_amp
    return height, scales, resin


def fibrous_height(n, seed, fine_amp, fine_radius, coarse_amp, coarse_radius,
        fleck_amp, crack_count, crack_len, crack_depth):
    fine = blur_axis(lib.fbm(SIZE, base_cells=30, octaves=3, seed=seed, gain=0.55),
            radius=fine_radius, axis=0) * fine_amp
    coarse = blur_axis(lib.fbm(SIZE, base_cells=14, octaves=2, seed=seed + 1, gain=0.5),
            radius=coarse_radius, axis=0) * coarse_amp
    flecks = blur_axis(lib.blur(lib.white_noise(SIZE, seed=seed + 2), 1), radius=3, axis=0) * fleck_amp
    cracks = hard_cracks(SIZE, crack_count, seed + 3, crack_len, crack_depth)
    height = lib.normalise01(fine + coarse + flecks - cracks, 0.5, 99.5)
    return height, fine + coarse


def smooth_grain_height(n, seed, fine_amp, fine_radius, coarse_amp, coarse_radius,
        crack_count, crack_len, crack_depth):
    """Hazel: no furrow, no plates, an even bark held smooth by fine, near
    isotropic undulation rather than by any drawn structure (the art's own
    bright vertical streaks are a fibre sheen, not a groove: thresholding
    them the way column_furrows does flags most of the tile, the opposite
    of what a furrow read should pick out). A couple of shallow cracks
    still give the wood class's jointed check somewhere to occlude at,
    since even a smooth bark carries the odd hairline split."""
    fine = lib.fbm(SIZE, base_cells=26, octaves=3, seed=seed, gain=0.55) * fine_amp
    coarse = blur_axis(lib.fbm(SIZE, base_cells=12, octaves=2, seed=seed + 1, gain=0.5),
            radius=coarse_radius, axis=0) * coarse_amp
    cracks = hard_cracks(SIZE, crack_count, seed + 3, crack_len, crack_depth, axis_bias=0.5)
    height = lib.normalise01(fine + coarse - cracks, 0.5, 99.5)
    return height, fine + coarse


# --- driver ----------------------------------------------------------------

def run(stem, out_dir, *, mode, seed, normal_strength,
        margin_frac=0.25, furrow_target=0.10, ridge_range=(0.55, 0.85),
        edge_dist=3, crown_amp=0.14, grain_amp=0.20, grain_radius=10,
        crack_amp=0.05, pore_amp=0.03,
        wave_edge_dist=9,
        spacing=32, width=5, warp_amp=2.0, warp_cells=10, depth=0.30,
        n_bands=5, plate_depth=0.18, plate_edge_dist=3,
        dark_thresh=0.5, mask_brighter=False, sign=1.0, mark_amp=0.35, base=0.65,
        scale_count=90, scale_length=(3.0, 6.0), scale_width=(1.4, 2.6), resin_amp=0.25,
        fine_amp=0.20, fine_radius=16, coarse_amp=0.12, coarse_radius=9, fleck_amp=0.05,
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

    resin = None
    if mode == "furrow":
        height, key_field = furrow_height(lum, n, margin_frac, furrow_target, ridge_range,
                edge_dist, crown_amp, grain_amp, grain_radius, crack_amp, pore_amp, seed,
                crack_count, crack_len, crack_depth)
    elif mode == "flute":
        height, key_field = flute_height(lum, n, margin_frac, furrow_target, ridge_range,
                wave_edge_dist, grain_amp, grain_radius, pore_amp, seed,
                crack_count, crack_len, crack_depth)
    elif mode == "diamond":
        height, key_field = diamond_height(lum, n, spacing, width, depth, warp_amp, warp_cells,
                grain_amp, grain_radius, pore_amp, crown_amp, seed,
                crack_count, crack_len, crack_depth)
    elif mode == "fissured_plates":
        height, key_field = fissured_plates_height(lum, n, margin_frac, furrow_target, ridge_range,
                edge_dist, crown_amp, grain_amp, grain_radius, crack_amp, pore_amp, seed,
                n_bands, plate_depth, plate_edge_dist, crack_count, crack_len, crack_depth)
    elif mode == "lenticel":
        height, key_field = lenticel_height(lum, n, dark_thresh, mask_brighter, sign, warp_amp,
                edge_dist, base, mark_amp, grain_amp, grain_radius, pore_amp, seed,
                crack_count, crack_len, crack_depth)
    elif mode == "scaly":
        height, key_field, resin = scaly_height(lum, n, seed, scale_count, scale_length,
                scale_width, grain_amp, resin_amp, crack_count, crack_len, crack_depth)
    elif mode == "fibrous":
        height, key_field = fibrous_height(n, seed, fine_amp, fine_radius, coarse_amp,
                coarse_radius, fleck_amp, crack_count, crack_len, crack_depth)
    elif mode == "smooth_grain":
        height, key_field = smooth_grain_height(n, seed, fine_amp, fine_radius, coarse_amp,
                coarse_radius, crack_count, crack_len, crack_depth)
    else:
        raise ValueError("unknown mode " + mode)
    print("  height sd %.3f" % height.std())

    variation = lib.fbm(SIZE, base_cells=smooth_var_cells, octaves=3, seed=seed + 20, gain=0.55)
    key_z = zscore(key_field) if key_field is not None else np.zeros((SIZE, SIZE), dtype=np.float32)
    smooth = 0.5 + smooth_t_w * 0.12 * key_z + smooth_var_w * 0.20 * zscore(variation)
    if resin is not None:
        # Resinous: the general level sits a touch higher, and the beads
        # right at a scale edge sit higher again, a waxy bead among an
        # otherwise ordinary bark roughness.
        smooth = smooth + 0.06 + 0.20 * resin
    print("  pre pack smooth sd %.3f" % smooth.std())

    albedo = lib.upscale(rgb)
    cls = lib.class_of(stem, GAME)
    if cls_override is not None and cls_override != cls:
        print(f"  class_of says {cls}, overridden to {cls_override}: the art is plainly bark, "
                "which class_of usually reads as wood, this stem's name must be catching an "
                "unrelated bake entry instead")
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
    print("kythen_mitteleuropa_bark_family.py is a library; run one of the per stem scripts.")
