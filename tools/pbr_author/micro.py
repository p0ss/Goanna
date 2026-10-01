"""Per material micro surface for model atlases (atlas.py).

extrude.py's micro surface is one kind per stem, a field that repeats over
a tile. A skin is several materials on many small faces, and its detail
has to follow each material and each face: a shirt is knitted, a boot is
leather with a stitched edge, hair runs down the head. Here a material in
a spec names its own kind:

  "hair": {"mode": "shade", ..., "micro": "hair", "micro_strength": 1.2,
           "micro_dir": "down"}

and the kind is evaluated per map pixel at that pixel's position, in art
texel units, along and across a direction chosen per face. Nothing here
repeats on a period, so on an atlas nothing wraps: a feature is continuous
inside a face, and a face border is where it stops, because atlas.py
derives the normal per island and never reads across one.

Like extrude's micro surface, all of this reaches the normal and the
smoothness only, never the stored height, so the texel grid of the relief
stays one flat height per texel (or per piece).

Directions ("micro_dir" on a material):

  down     model down on every side face, read from the model's own UVs
           and positions (atlas.face_frames); on a top or bottom face,
           where down has no direction, from front to back. The default.
  along    the long axis of each piece of the material inside a face (a
           diagonal strap), from the piece's pixel covariance.
  h, v     image right or image down, for every face.
  a number an angle in degrees in the image, 0 right, 90 down.

Mirrored limbs share one UV rectangle and so one field, mirrored on the
other limb. Kinds meant for limbs are symmetric (knit, plain weave) or run
along a face's down, which mirroring keeps.

The kinds, each (detail, smoothness) per pixel, roughly -0.5 to 0.5
before the material's strength:

  knit     stockinette: columns of V shaped loops pointing down, several
           to a texel, a little fibre fuzz. Matte.
  wool     knit, looser and fuzzier (a scarf).
  weave    plain weave, over and under, with slubs (thicker stretches of
           thread). "threads" per texel sets the count: linen, canvas and
           coarse are presets of it.
  linen    fine plain weave, 7 threads, slubby.
  canvas   plain weave, 4.5 threads, even.
  coarse   plain weave, 3 threads (trousers).
  twill    diagonal ribs. Leans one way, so not for mirrored limbs.
  hair     locks: each run of texels at one height a rounded bundle with
           a few soft strand grooves of varied width, a slight wave,
           drawn together toward the tip, and a sheen band across it.
  straw    stiff fibres along the direction with the odd node across;
           "plait": true turns the direction a quarter per texel, like a
           plaited hat.
  leather  pebble grain (cells with creases between) and fine pores; the
           pebbles a little smoother than the creases.
  rope     twisted plies: ridges across the rope at a slant, with fibres.
  skin     nearly nothing: sparse faint pores and a soft variation.
  eye      flat, with one small soft rise high on each piece, so a glossy
           iris catches the sun in one spot (a catch light), with no rim.

Edge features, which need the piece's shape, are separate material keys:

  "stitch": {...}   a dashed line of thread a fixed inset inside the edge
           of every piece of the material, a groove either side and a
           hole at each end of a stitch. The edge is where the material
           meets another material or a hole; a face border is not an
           edge, so a belt running round the body is stitched along its
           top and bottom only. Keys: inset, length, gap (texels), width
           (the thread's half width, texels), groove (texels beyond it),
           smooth (texels of boundary smoothing), follow ("edge", the
           default, or "axis": straight along the long axis of a piece
           drawn as a staircase of texels, a diagonal strap; see
           axis_distance), depth.
  "seam": {...}     a continuous groove a fixed inset inside the edge, for
           a sewn panel. Keys: inset, width, depth, smooth.
  "wear": x         sparse soft smudges in the smoothness, polish (up) and
           grime (down), x the swing. Cloth and leather are not uniformly
           rough.
  "texel_edge": x   a very shallow groove at each texel's border, x deep
           in height units, to the normal only. Default 0.
"""
import numpy as np

# --- noise at arbitrary coordinates ------------------------------------------


def _hash(ix, iy, seed):
    """A float in [0, 1) per pair of integer lattice coordinates."""
    h = (np.asarray(ix, np.int64) * 73856093) ^ (np.asarray(iy, np.int64) * 19349663) \
        ^ np.int64((seed * 83492791) & 0x7fffffff)
    h = h & 0xffffffff
    h = ((h ^ (h >> 16)) * 0x45d9f3b) & 0xffffffff
    h = ((h ^ (h >> 16)) * 0x45d9f3b) & 0xffffffff
    h = h ^ (h >> 16)
    return (h & 0xffffff).astype(np.float64) / float(1 << 24)


def vnoise(x, y, seed):
    """Smooth value noise, -1..1, one lattice cell per unit."""
    ix, iy = np.floor(x), np.floor(y)
    fx, fy = x - ix, y - iy
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    ix, iy = ix.astype(np.int64), iy.astype(np.int64)
    a = _hash(ix, iy, seed)
    b = _hash(ix + 1, iy, seed)
    c = _hash(ix, iy + 1, seed)
    d = _hash(ix + 1, iy + 1, seed)
    v = (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    return 2.0 * v - 1.0


def fbm(x, y, seed, octaves=3):
    out = np.zeros(np.shape(x))
    amp, norm = 1.0, 0.0
    for o in range(octaves):
        out += amp * vnoise(x * 2 ** o, y * 2 ** o, seed + 101 * o)
        norm += amp
        amp *= 0.5
    return out / norm


def worley(x, y, seed):
    """Distances to the nearest and second nearest feature point (one per
    unit cell) and the nearest one's cell hash."""
    ix, iy = np.floor(x).astype(np.int64), np.floor(y).astype(np.int64)
    f1 = np.full(np.shape(x), 9.0)
    f2 = np.full(np.shape(x), 9.0)
    idv = np.zeros(np.shape(x))
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            cx, cy = ix + dx, iy + dy
            px = cx + _hash(cx, cy, seed)
            py = cy + _hash(cx, cy, seed + 7)
            d = np.sqrt((x - px) ** 2 + (y - py) ** 2)
            closer = d < f1
            f2 = np.where(closer, f1, np.minimum(f2, d))
            idv = np.where(closer, _hash(cx, cy, seed + 13), idv)
            f1 = np.where(closer, d, f1)
    return f1, f2, idv


def _frac(a):
    return a - np.floor(a)


def _smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


# --- kinds ------------------------------------------------------------------
# Each takes a context (u along, v across, x and y in the image, all in art
# texels; seed; optional piece offsets) and the kind's parameters, and
# returns (detail, smooth).

def _knit(c, p):
    cols, rows = p.get("cols", 4.0), p.get("rows", 5.0)
    a = c["v"] * cols
    fx = _frac(a) - 0.5
    ci = np.floor(a)
    # The V: each leg's rows rise towards the column's edges, so the loops
    # point down (u runs down the face).
    ph = c["u"] * rows + p.get("slant", 0.9) * np.abs(fx)
    leg = np.sin(np.pi * _frac(ph))
    across = np.sin(np.pi * np.clip(np.abs(fx) * 2.0, 0.0, 1.0)) ** 0.7
    yarn = _hash(ci.astype(np.int64), np.floor(ph).astype(np.int64), c["seed"]) - 0.5
    fuzz = vnoise(c["x"] * 28.0, c["y"] * 28.0, c["seed"] + 5)
    d = across * (0.55 + 0.45 * leg) - 0.5 + 0.12 * yarn + p.get("fuzz", 0.12) * fuzz
    s = 0.5 * (across * leg - 0.5) + 0.3 * fuzz * p.get("fuzz", 0.12)
    return d, s


def _wool(c, p):
    q = {"cols": 2.5, "rows": 3.0, "fuzz": 0.35, "slant": 0.8}
    q.update(p)
    d, s = _knit(c, q)
    soft = fbm(c["x"] * 9.0, c["y"] * 9.0, c["seed"] + 9)
    return 0.8 * d + 0.15 * soft, 0.3 * s


def _weave(c, p):
    n = p.get("threads", 4.0)
    slub = p.get("slub", 0.2)
    a, b = c["u"] * n, c["v"] * n
    ia, ib = np.floor(a).astype(np.int64), np.floor(b).astype(np.int64)
    fa, fb = _frac(a), _frac(b)
    warp = np.sin(np.pi * fb)
    weft = np.sin(np.pi * fa)
    # Slubs: a thread is thicker for a stretch and then thinner.
    tw = 1.0 + slub * vnoise(c["u"] * 1.3, ib * 7.31, c["seed"] + 1)
    tf = 1.0 + slub * vnoise(c["v"] * 1.3, ia * 7.31, c["seed"] + 2)
    over = (ia + ib) % 2 == 0
    d = np.where(over, warp * (0.65 + 0.35 * weft) * tw, weft * (0.65 + 0.35 * warp) * tf)
    d = d - 0.5 + 0.06 * vnoise(c["x"] * 30.0, c["y"] * 30.0, c["seed"] + 3)
    return d, 0.4 * d


PRESETS = {
    "linen": ("weave", {"threads": 7.0, "slub": 0.35}),
    "canvas": ("weave", {"threads": 4.5, "slub": 0.12}),
    "coarse": ("weave", {"threads": 3.0, "slub": 0.2}),
}


def _twill(c, p):
    n = p.get("threads", 3.0)
    ph = (c["u"] + c["v"]) * n
    rib = np.sin(np.pi * _frac(ph))
    cross = np.sin(np.pi * _frac(c["v"] * n * 2.0))
    d = rib * (0.75 + 0.25 * cross) - 0.5 + 0.05 * vnoise(c["x"] * 30, c["y"] * 30, c["seed"])
    return d, 0.4 * d


def _strands(c, p, seed_off=0):
    n = p.get("strands", 10.0)
    wander = p.get("wander", 0.06)
    breaks = p.get("breaks", 0.3)
    sd = c["seed"] + seed_off
    # A slow drift across, so strands are not ruled lines, but slow enough
    # that they stay straight over a texel (a fast one reads as wood grain).
    vv = c["v"] + wander * fbm(c["u"] * 0.35, c["v"] * 0.5, sd + 1, 2)
    ids = np.floor(vv * n).astype(np.int64)
    f = _frac(vv * n)
    prof = np.sin(np.pi * f) ** p.get("round", 0.6)
    tone = _hash(ids, 0, sd + 2)
    gate = vnoise(c["u"] * 0.9 + tone * 13.0, ids * 1.7, sd + 3)
    keep = np.clip((gate + 1.0 - breaks) * 3.0, 0.35, 1.0)
    return prof * (0.7 + 0.3 * tone) * keep, tone


def _hair(c, p):
    """Hair in locks: each lock (a run of texels at one height, atlas.py
    passes its frame) is a rounded bundle, not a board. A few soft strand
    grooves of varied width and spacing, a slight wave, drawn together
    toward the lock's tip; and a sheen band across the lock, as hair's
    anisotropic highlight runs across the strands, in the smoothness with
    a slight swell in the normal. Without a lock frame it is one lock."""
    n_px = np.shape(c["x"])
    la = c.get("la", np.zeros(n_px))
    lt = c.get("lt", np.full(n_px, 0.5))
    lw = c.get("lw", np.full(n_px, 0.5))
    lid = c.get("lid", np.zeros(n_px, np.int64))
    sd = c["seed"]
    rnd = np.sqrt(np.clip(1.0 - la * la, 0.0, 1.0))
    # Across the lock in texels, drawn in toward the tip.
    v = la * lw * (1.0 - p.get("converge", 0.35) * lt) + _hash(lid, 1, sd)
    u = c["u"]
    v = v + p.get("wave", 0.025) * np.sin(2 * np.pi * (u * 0.8 + _hash(lid, 2, sd)))
    v = v + p.get("spacing", 0.12) * vnoise(v * 2.0, u * 0.3, sd + 3)
    n = p.get("strands", 2.5)
    ids = np.floor(v * n).astype(np.int64)
    f = _frac(v * n)
    w = 0.10 + 0.10 * _hash(ids, lid, sd + 4)
    edge = np.minimum(f, 1.0 - f)
    groove = np.exp(-(edge / w) ** 2) * (0.5 + 0.5 * _hash(ids, lid, sd + 5))
    centre = 0.3 + 0.2 * _hash(lid, 3, sd)
    band = np.exp(-((lt - centre + 0.04 * vnoise(v * 3.0, u, sd + 6)) / 0.13) ** 2)
    d = 0.8 * (rnd - 0.6) - 0.35 * groove + 0.3 * band
    s = 1.4 * (band - 0.3) + 0.3 * (rnd - 0.7) - 0.4 * groove
    return d, s


def _straw(c, p):
    q = {"strands": 5.0, "wander": 0.04, "breaks": 0.1, "round": 0.4}
    q.update(p)
    if q.get("plait", False):
        # Turn the fibres a quarter at every other texel, like plaited straw.
        par = (np.floor(c["x"]) + np.floor(c["y"])) % 2 == 1
        c = dict(c)
        c["u"], c["v"] = np.where(par, c["v"], c["u"]), np.where(par, -c["u"], c["v"])
    prof, tone = _strands(c, q)
    node = np.exp(-((_frac(c["u"] * 1.3 + tone * 3.0) - 0.5) / 0.04) ** 2)
    d = prof - 0.45 + 0.5 * node * prof
    s = 0.8 * (prof - 0.45) + 0.2 * (tone - 0.5)
    return d, s


def _leather(c, p):
    cell = p.get("cell", 0.16)
    f1, f2, idv = worley(c["x"] / cell, c["y"] / cell, c["seed"])
    crease = np.clip(1.0 - (f2 - f1) / 0.3, 0.0, 1.0) ** 2
    dome = np.clip(1.0 - f1 * 0.9, 0.0, 1.0)
    pores = vnoise(c["x"] * 45.0, c["y"] * 45.0, c["seed"] + 4)
    d = 0.45 * dome - 0.8 * crease + 0.08 * pores + 0.1 * (idv - 0.5)
    s = 0.6 * (dome - 0.5) - 0.6 * crease
    return d, s


def _rope(c, p):
    twist, plies = p.get("twist", 3.0), p.get("plies", 3.0)
    ph = c["u"] * twist + c["v"] * plies
    ply = np.sin(np.pi * _frac(ph)) ** 0.7
    fibre = np.sin(2 * np.pi * (c["u"] * twist * 5.0 + c["v"] * plies * 5.0 + 0.3
                                * vnoise(c["u"] * 4, c["v"] * 4, c["seed"])))
    d = ply - 0.5 + 0.12 * fibre * ply
    return d, 0.5 * (ply - 0.5)


def _skin(c, p):
    f1, _, idv = worley(c["x"] / 0.11, c["y"] / 0.11, c["seed"])
    pore = -np.clip(1.0 - f1 / 0.22, 0.0, 1.0) * (idv > 0.55)
    soft = fbm(c["x"] * 2.5, c["y"] * 2.5, c["seed"] + 3, 2)
    return 0.6 * pore + 0.25 * soft, 0.5 * soft


def _eye(c, p):
    """A flat eye with one small soft rise for a catch light: a gaussian
    spot, so it has no rim, at "spot" (x, y and radius in texels from the
    piece's centre, y down), high on the piece by default. A sun anywhere
    in front finds a point of it facing halfway to the viewer."""
    px, py = c.get("px"), c.get("py")
    if px is None:
        return np.zeros_like(c["x"]), np.zeros_like(c["x"])
    dx = px * c.get("hx", 1.0)
    dy = py * c.get("hy", 1.0)
    sx, sy, r = p.get("spot", (0.0, -0.4, 0.16))
    g = np.exp(-((dx - sx) ** 2 + (dy - sy) ** 2) / (r * r))
    return g, np.zeros_like(g)


# Kinds that want each lock's frame (atlas.py: la across -1..1, lt along
# 0..1, lw half width in texels, lid an id).
LOCK_KINDS = {"hair"}

# (function, default amplitude in height units, default smoothness swing)
KINDS = {
    "knit": (_knit, 0.050, 0.06),
    "wool": (_wool, 0.040, 0.04),
    "weave": (_weave, 0.050, 0.06),
    "twill": (_twill, 0.035, 0.06),
    "hair": (_hair, 0.060, 0.22),
    "straw": (_straw, 0.050, 0.15),
    "leather": (_leather, 0.030, 0.14),
    "rope": (_rope, 0.050, 0.08),
    "skin": (_skin, 0.006, 0.03),
    "eye": (_eye, 0.400, 0.0),
}


def kind_names():
    return sorted(set(KINDS) | set(PRESETS))


def evaluate(kind, ctx, params=None):
    """(detail, smooth, amp, swing) for a kind at the context's pixels."""
    params = dict(params or {})
    if kind in PRESETS:
        base, pre = PRESETS[kind]
        pre = dict(pre)
        pre.update(params)
        kind, params = base, pre
    fn, amp, swing = KINDS[kind]
    d, s = fn(ctx, params)
    return d.astype(np.float32), s.astype(np.float32), amp, swing


# --- pieces and edges --------------------------------------------------------

def edge_distance(mask, isl, smooth_px=0.0):
    """Map pixels from each pixel of mask to the nearest pixel of its own
    island that is not in mask. Pixels of other islands and outside the
    image count as inside, so a face border is never an edge: a piece that
    runs off one face onto the next is cut by the atlas, not by its
    maker. smooth_px blurs the piece first, so the edge of a diagonal
    piece drawn as a staircase of texels comes out as a straight line.
    Returns inf where mask is false."""
    from scipy import ndimage
    out = np.full(mask.shape, np.inf, np.float32)
    for i in np.unique(isl[mask]):
        if i < 0:
            continue
        ys, xs = np.nonzero(isl == i)
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
        own = isl[y0:y1, x0:x1] == i
        region = mask[y0:y1, x0:x1] | ~own
        pad = int(np.ceil(3 * smooth_px)) + 2
        region = np.pad(region, pad, constant_values=True)
        if smooth_px > 0:
            region = ndimage.gaussian_filter(region.astype(np.float32), smooth_px) > 0.5
        d = ndimage.distance_transform_edt(region)[pad:-pad, pad:-pad]
        sel = own & mask[y0:y1, x0:x1]
        sub = out[y0:y1, x0:x1]
        sub[sel] = d[sel]
    return out


def _tangent(dist, mask):
    """Unit tangent of the edge distance's contours, image x right and y
    down, smoothed so a dash line keeps one direction along an edge."""
    from scipy import ndimage
    dd = np.where(mask, dist, 0.0).astype(np.float32)
    dd = ndimage.gaussian_filter(dd, 1.5)
    gy, gx = np.gradient(dd)
    n = np.sqrt(gx * gx + gy * gy) + 1e-6
    return -gy / n, gx / n


def axis_distance(mask, isl, cell):
    """For a long piece drawn as a staircase of texels (a diagonal strap):
    distance in map pixels inward from the straight sides of the solid core
    the staircase encloses, measured across the piece's long axis, and that
    axis as a tangent. The teeth of the staircase lie outside the core and
    come out negative, so a stitch line inset from the core runs straight
    along the strap instead of following every step. Returns (dist, tx, ty)
    with dist -inf outside mask; a piece too short or too round to have an
    axis is left at -inf."""
    from scipy import ndimage
    dist = np.full(mask.shape, -np.inf, np.float32)
    tx = np.zeros(mask.shape, np.float32)
    ty = np.zeros(mask.shape, np.float32)
    for i in np.unique(isl[mask]):
        if i < 0:
            continue
        lab, n = ndimage.label(mask & (isl == i))
        for k in range(1, n + 1):
            ys, xs = np.nonzero(lab == k)
            if len(xs) < 2 * cell * cell:
                continue
            pts = np.stack([xs + 0.5, ys + 0.5]).astype(np.float64)
            c = pts.mean(1, keepdims=True)
            val, vec = np.linalg.eigh(np.cov(pts))
            if val[1] < 2.0 * max(val[0], 1e-6):
                continue
            d = vec[:, 1]
            nrm = np.array((-d[1], d[0]))
            along = d @ (pts - c)
            across = nrm @ (pts - c)
            # Occupancy per band across the axis, over the middle of the
            # piece's length (its ends are cut square or run off the face).
            a0, a1 = np.percentile(along, 15), np.percentile(along, 85)
            mid = (along >= a0) & (along <= a1)
            if mid.sum() < cell:
                continue
            step = 1.5
            wb = np.floor(across[mid] / step).astype(int)
            ab = np.floor(along[mid] / step).astype(int)
            n_a = len(np.unique(ab))
            occ = {}
            for w_, a_ in set(zip(wb.tolist(), ab.tolist())):
                occ[w_] = occ.get(w_, 0) + 1
            core = [w_ for w_, cnt in occ.items() if cnt >= 0.9 * n_a]
            if not core:
                continue
            lo, hi = min(core) * step, (max(core) + 1) * step
            dist[ys, xs] = np.minimum(across - lo, hi - across)
            tx[ys, xs], ty[ys, xs] = d[0], d[1]
    return dist, tx, ty


def stitch(dist, mask, cell, x, y, p, seam=False, tangent=None):
    """(detail, smooth) of a stitch line, or a seam groove when seam, inside
    the edge of every piece of mask. dist is edge_distance (or
    axis_distance) in map pixels, x and y the pixels' image position in
    texels, tangent the direction the stitches run along where it is known
    (axis_distance's), otherwise taken from dist."""
    inset = p.get("inset", 0.12 if seam else 0.22) * cell
    width = max(0.7, p.get("width", 0.05 if seam else 0.07) * cell)
    e = np.abs(dist - inset)
    if seam:
        g = np.clip(1.0 - e / width, 0.0, 1.0)
        return -g, -0.6 * g
    groove = max(0.6, p.get("groove", 0.05) * cell)
    tx, ty = _tangent(dist, mask) if tangent is None else tangent
    along = x * tx + y * ty
    length, gap = p.get("length", 0.36), p.get("gap", 0.18)
    period = length + gap
    f = _frac(along / period) * period
    soft = 0.05
    dash = _smooth(0.0, soft, f) * _smooth(length, length - soft, f)
    thread = np.sqrt(np.clip(1.0 - (e / width) ** 2, 0.0, 1.0)) * dash
    channel = np.clip(1.0 - np.abs(e - width) / groove, 0.0, 1.0)
    # The hole at each end of a stitch, where the thread goes through.
    hole = np.clip(1.0 - e / width, 0.0, 1.0) * (1.0 - dash) * _smooth(gap * 0.8, 0.0,
                                                                          np.minimum(f - length, period - f))
    d = 1.0 * thread - 0.55 * channel * (1.0 - thread) - 0.6 * hole
    s = 0.7 * thread - 0.4 * channel - 0.3 * hole
    return d, s


def wear(x, y, seed, scale=1.2):
    """Sparse soft smudges, -1 (grime) to 1 (polish), mostly 0."""
    n = fbm(x * scale, y * scale, seed + 77, 3)
    return (_smooth(0.3, 0.6, n) - _smooth(0.35, 0.65, -n)).astype(np.float32)


def texel_edge(cell, shape):
    """1 at the outermost pixel ring of every texel, falling to 0 a pixel
    in (more on a larger map), for a very shallow outline per texel."""
    w = max(1.0, cell / 16.0)
    i = np.arange(shape[1]) % cell
    j = np.arange(shape[0]) % cell
    di = np.minimum(i, cell - 1 - i)
    dj = np.minimum(j, cell - 1 - j)
    d = np.minimum(dj[:, None], di[None, :]).astype(np.float32)
    return np.clip(1.0 - d / w, 0.0, 1.0)


def swatches(path, cell=16, texels=6, light=(-0.5, 0.45, 0.75)):
    """A sheet of every kind on a flat square of texels x texels art
    texels, lit by one light, then stitching and a seam on an inset square,
    the wear smudges and a texel edge, for a person to judge a kind by.
    Kinds run along image down. The light's x is image right, y image up."""
    from PIL import Image
    size = cell * texels
    yy, xx = np.mgrid[0:size, 0:size]
    x = (xx + 0.5) / cell
    y = (yy + 0.5) / cell
    L = np.asarray(light, np.float64)
    L /= np.linalg.norm(L)

    def lit(d, s):
        h = d * 12.0
        n = np.stack([-np.gradient(h, axis=1), np.gradient(h, axis=0), np.ones_like(h)], -1)
        n /= np.linalg.norm(n, axis=-1, keepdims=True)
        return np.clip(0.55 * np.clip((n * L).sum(-1), 0, 1) + 0.25 + 0.15 * s, 0, 1)

    # The eye kind wants piece offsets: a dome per two texels.
    ctx = {"x": x.ravel(), "y": y.ravel(), "u": y.ravel(), "v": x.ravel(), "seed": 11,
           "px": (x.ravel() % 2) - 1.0, "py": (y.ravel() % 2) - 1.0}
    names = kind_names()
    tiles = []
    for k in names:
        d, s, amp, swing = evaluate(k, ctx)
        tiles.append(lit((amp * d).reshape(size, size), (swing * s).reshape(size, size)))
    mask = np.zeros((size, size), bool)
    mask[cell:size - cell, cell:size - cell] = True
    dist = edge_distance(mask, np.zeros((size, size), int))
    for seam in (False, True):
        d, s = stitch(dist, mask, cell, x, y, {}, seam=seam)
        tiles.append(lit(np.where(mask, 0.05 * d, 0.0), np.where(mask, 0.25 * s, 0.0)))
    tiles.append(np.clip(0.5 + 0.4 * wear(x, y, 3), 0, 1))
    tiles.append(lit(-0.02 * texel_edge(cell, (size, size)), np.zeros((size, size))))
    names = names + ["stitch", "seam", "wear", "texel_edge"]
    cols, gap = 5, 6
    rows = -(-len(tiles) // cols)
    sheet = np.full((rows * (size + gap) + gap, cols * (size + gap) + gap), 0.1)
    for i, t in enumerate(tiles):
        r, c = divmod(i, cols)
        y0, x0 = gap + r * (size + gap), gap + c * (size + gap)
        sheet[y0:y0 + size, x0:x0 + size] = t
    Image.fromarray((sheet * 255 + 0.5).astype(np.uint8), "L").save(path)
    return names


if __name__ == "__main__":
    import sys
    if len(sys.argv) != 2:
        raise SystemExit("usage: micro.py <swatch sheet.png>")
    print(" ".join(swatches(sys.argv[1])))
