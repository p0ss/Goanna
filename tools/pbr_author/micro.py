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
           Round 2 of the player's hair; the owner found it plastic tree
           bark (2026-10-02), so the player now takes bristle.
  bristle  hair as paintbrush bristles: each lock a bundle of about ten
           fine straight strands to a texel, each a thin cylinder (the
           normal tilts across it, flat along it) with its own width,
           place, tilt and smoothness, a few lying over the others; the
           strands end raggedly short of a tip that stands proud, thinning
           and rolling over, the tips keeping the art's colour.
           Too fine to differentiate, so it gives its normal as slopes,
           box filtered per pixel, and an occlusion (SLOPE_KINDS).
           Rounds 3 and 4 of the player's hair; the owner found it grooved
           decking on the GPU (2026-10-02), so the player now takes tress.
  tress    hair as clumped tresses: each lock split across into bundles of
           irregular width, each with its own strand count, a few degrees
           of its own direction, its own shine and a faint round; strands
           drawing together toward a proud tip, so bundles part there; an
           upper layer of strands starting part way down the lock; loose
           slanted fibres over the seams; per strand shine far larger than
           per strand tilt. A slope kind like bristle.
  straw    stiff fibres along the direction with the odd node across;
           "plait": true turns the direction a quarter per texel, like a
           plaited hat.
  leather  pebble grain (cells with creases between) and fine pores; the
           pebbles a little smoother than the creases.
  rope     twisted plies: ridges across the rope at a slant, with fibres.
  skin     nearly nothing: sparse faint pores and a soft variation.
  eye      flat, with one small soft rise high on each piece, so a glossy
           iris catches the sun in one spot (a catch light), with no rim.
           The owner rejected the rise on the player (2026-10-01): eyes
           now take "none", flat and glossy; this kind is kept for
           reference.

For animals and monsters, sized for a mob's 8 pixels to a texel (each
says its parameters in its docstring):

  fur      tufts in staggered rows lying along the direction, each rising
           from under the one before to a pointed tip; clumped, matte, a
           slight sheen near the tips. "length" 0.8 (a cow), 1.2 to 1.6
           (a wolf); "width", "clump", "strands", "fuzz".
  hide     a cow's or pig's skin: a net of fine creases, wrinkles across
           the direction in places, sparse pores, slightly waxy swells.
           "cell", "wrinkles".
  feather  overlapping rounded feathers in staggered rows along the
           direction, a shaft line down each, barbs, a step at each tip.
           "length", "width" (about a texel on a chicken), "barbs".
  scale    overlapping rounded scales with a faint keel; feather's
           cheaper relative. "length", "width".
  bone     smooth and satin with sparse pores and a few hairline cracks.
           "cracks".
  rotten   decaying skin: lumps, blotches that differ strongly in
           roughness, pits in the dry blotches, a few sores.
  mottle   soft rounded lumps of mixed size with hollows between, matte
           (a creeper: leafy, mossy). "cell".
  chitin   hard and glossy: fine wavy ridges across the direction, plates
           with a suture between. "ridges", "plates".

For riveted iron (the iron golem), each art texel one plate. Everything a
plate carries stays inside its texel, so nothing crosses a texel or a face
border:

  plate    the plate itself: a crisp shallow bevel at the texel's edge, a
           small tilt and offset per plate so neighbours meet with a small
           step, the shine varying per plate (uniform -1..1 in the
           smoothness, so a swing of 0.06 is plus or minus 0.06) and faint
           rust specks in the smoothness only. "bevel", "tilt", "step",
           "specks".
  scratches fine straight scratches, a few per plate at random angles.
           "count", "width", "length".
  dents    soft round hammer dents, sparse, at most one or two per plate.
           "density", "radius".
  rivets   a rivet head (a small dome in a shallow seat) in the outer
           corner of chosen plates. By rule, along the border rows and
           columns of each piece of the material, every "every" plates
           counted from the piece's nearest edge, so a symmetric piece
           gets symmetric rivets; or at the "at" list of [x, y] centres in
           art texels. "radius", "inset", "every", "ring", "min_size".
  rust     flaky, pitted rust: flakes at different heights with lifted
           edges, pits, very rough. "flake", "pits".
  leaf     small overlapping leaves at random angles, each domed with a
           midrib, a dark gap where none covers, the later leaf on top.
           "size".
  chain    mail, four rings through each: rings of round wire, "rings" to
           a texel across, in rows half a ring apart, each row's rings
           leaning the other way so each ring passes over two neighbours
           and under two; the gaps between low and rough, the wire
           smoother. Symmetric about the
           direction, so right on mirrored limbs. Sized for 16 map pixels
           to a texel (the player's armour layers).
  mix      several kinds summed: "layers", a list of {"kind", "strength",
           "swing", "params"}, each kind at its own amplitude and swing
           times strength and swing. A material takes one "micro", so a
           plate with scratches, dents and rivets is a mix.

The block kinds, for a piece of a skin made of what a block is made of (a
tool's handle, a lens, a buckle). Each samples extrude.micro_field, the
block's own field, so a change to the block kind changes these too:

  wood       planks' grain, running along the direction.
  bark       a log's fissures, running along the direction.
  glass      a pane's faint smudges and the odd hairline scratch.
  metal      a brushed plate, brushed along the direction.
  metal_worn tool iron: short scratches every way, dents, rubbed patches.

A block texel and a skin texel are both a sixteenth of a node, so the
field is laid on the skin at one block texel per art texel: it is built
cell * 16 pixels wide (16 texels, one block face) and read at the pixel's
u and v times cell, bilinear. The block field repeats over its 16 texels,
which is harmless here: every pixel reads it at its own face's u and v,
and atlas.py derives the normal per island, so nothing of one face reaches
another; a face more than 16 texels long would see the repeat, and no
villager face is. Amplitude and swing are the block's (extrude.MICRO_KINDS)
and the amplitude is scaled by the block class's normal strength over the
skin's ("strength" in the context, which atlas.py passes), so a skin's
grain rises as far per texel as the planks' does whatever the skin's own
strength.

  paper    very fine fibre, almost flat, matte: short fibres lying mostly
           along the direction with a few across, and a faint cockle.
           For book pages and maps. Not a block kind (no block is paper).

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


def _bristle_at(a, e, lt, lid, proud, sd, p):
    """One sample of bristle at a (across the lock from its middle) and e
    (along it, to its tip), both in texels, proud 0..1 how far the tip
    stands over what follows it: (slope along, slope across, smoothness,
    occlusion)."""
    n0 = p.get("strands", 10.0)
    layers = int(p.get("layers", 3))
    top_share = p.get("top", 0.35)
    jitter = p.get("jitter", 0.35)
    w0, w1 = p.get("width", (0.9, 1.4))
    rag, taper = p.get("rag", 0.2), p.get("taper", 0.25)
    rnd = p.get("round", 0.55)
    roll = p.get("roll", 2.0)
    tilt = p.get("tilt", 0.12)
    shape = np.shape(a)
    best = np.full(shape, -np.inf)
    su = np.zeros(shape)
    sv = np.zeros(shape)
    sm = np.zeros(shape)
    cyl_top = np.zeros(shape)
    t_top = np.ones(shape)
    for L in range(layers):
        # Upper layers a little sparser, finer and each at its own offset,
        # so a strand of one lies across the meeting of two below it.
        n = n0 * (1.0 if L == 0 else 0.85)
        per = 1.0 / n
        q = (a + 7.0 * _hash(lid, 10 + L, sd)) * n
        i0 = np.floor(q).astype(np.int64)
        key = lid * 7 + L
        for di in (-1, 0, 1):
            i = i0 + di

            def h(k):
                return _hash(i, key, sd + k)
            keep = (h(21) < top_share) if L > 0 else np.ones(shape, bool)
            cen = i + 0.5 + jitter * (h(22) - 0.5)
            w = 0.5 * (w0 + (w1 - w0) * h(23)) * (1.0 if L == 0 else 0.8)
            # Where the strand ends, in texels short of the lock's tip:
            # most a little short, a few right to it, the bottom layer
            # nearer the tip than the ones over it.
            end = rag * np.where(h(24) < 0.2, 0.05 * h(25), 0.25 + 0.75 * h(25))
            if L == 0:
                end = 0.7 * end
            end = end * proud
            t = np.clip((e - end) / taper, 0.0, 1.0)
            wt = w * (0.35 + 0.65 * np.sqrt(t))
            r = (q - cen) / wt
            inside = keep & (e > end) & (np.abs(r) < 1.0)
            rc = np.clip(r, -0.95, 0.95)
            cyl = np.sqrt(1.0 - rc * rc)
            fall = 1.0 - (1.0 - t) ** 2
            # Stacking: an upper layer lies over a lower one, and inside a
            # layer the strand standing higher where two overlap wins.
            z = 0.3 * L + 0.15 * h(26) + 0.5 * wt * per * cyl * fall
            hit = inside & (z > best)
            # Rise over run: across a cylinder, flattened by "round", and
            # down over its end where it tapers; and the strand's own tilt.
            g_v = -rnd * rc / cyl + tilt * (2.0 * h(27) - 1.0)
            dfall = np.where((t > 0.0) & (t < 1.0), 2.0 * (1.0 - t) / taper, 0.0)
            g_u = -roll * rnd * wt * per * cyl * dfall + 0.5 * tilt * (2.0 * h(28) - 1.0)
            # A strand's end keeps the strand's own smoothness, nearly: a
            # rough tip read grey (GPU review, 2026-10-02).
            s_ = 0.6 * (h(29) - 0.5) + 0.5 * (cyl - 0.7) - 0.1 * (1.0 - t)
            best = np.where(hit, z, best)
            su = np.where(hit, g_u, su)
            sv = np.where(hit, g_v, sv)
            sm = np.where(hit, s_, sm)
            cyl_top = np.where(hit, cyl, cyl_top)
            t_top = np.where(hit, t, t_top)
    covered = np.isfinite(best)
    crease = p.get("crease", 0.3)
    # Nothing on top: deeper hair inside the lock, a gap at its ragged tip.
    # The tip keeps the art's colour: the crease fades out along a strand's
    # taper and the gap between ends is barely occluded, since a dark or
    # rough tip read as grubby grey on the GPU.
    tip = (e < rag + taper) & (proud > 0.5)
    occ = np.where(covered, 1.0 - crease * t_top * (1.0 - cyl_top) ** 2,
                   np.where(tip, 1.0 - p.get("gap", 0.08), 1.0 - crease))
    sm = np.where(covered, sm, np.where(tip, -0.1, -0.3))
    sm = sm + p.get("crown", 0.25) * (0.5 - lt)
    return su, sv, sm, occ


def _bristle(c, p):
    """Hair as paintbrush bristles: every lock (a run of texels at one
    height, atlas.py passes its frame) is a bundle of fine straight
    strands lying along the direction, "strands" to a texel across (about
    1.6 map pixels each at 16 pixels to a texel). Each strand is a thin
    cylinder: its normal tilts across its width, left half one way, right
    half the other, flattened by "round", and is flat along it; strands
    meet with no groove carved between them. Spacing ("jitter") and width
    ("width", the range of a strand's width in strand spacings) vary per
    strand, so no ruled pattern beats with the map's pixels, and "layers"
    of strands lie one over another, the upper ones sparser ("top", the
    share of their places taken). Each strand has its own small tilt
    ("tilt", rise over run) and its own smoothness, so the light breaks
    into streaks along the hair. Strands end short of the lock's tip by up
    to "rag" texels, a few reaching it, thinning over the last "taper"
    texels and rolling over the end ("roll"); where every layer has ended
    the tip is ragged and the gap between ends faintly occluded ("gap"),
    as is the crease where two strands meet ("crease"), fading out along
    a strand's taper so its end keeps the art's colour. The lock is a touch
    smoother at its root than at its tip ("crown"). There is no sheen band
    and no round across the lock.

    The strands are finer than a central difference can resolve (a two
    pixel ridge has none), so this kind gives its normal as slopes, rise
    over run along u and across v, instead of a height to differentiate,
    averaged over "samples" squared points inside each map pixel: the box
    filtered normal of the strands, not an alias of them. Only atlas.py's
    material surface reads the slopes and the occlusion (SLOPE_KINDS), so
    it is not for "mix". Returns (detail, smooth, slope u, slope v,
    occlusion), the detail zero: the lock's stored height stays the
    relief, one level per texel, as for every kind."""
    n_px = np.shape(c["x"])
    la = c.get("la", np.zeros(n_px))
    lt = c.get("lt", np.full(n_px, 0.5))
    lw = c.get("lw", np.full(n_px, 0.5))
    ll = c.get("ll", np.ones(n_px))
    lid = c.get("lid", np.zeros(n_px, np.int64))
    ux = c.get("dx", np.zeros(n_px))
    uy = c.get("dy", np.ones(n_px))
    cell = float(c.get("cell", 16.0))
    sd = c["seed"]
    a0 = la * lw
    e0 = (1.0 - lt) * ll
    # A tip tucked under a higher lock, or at a box edge, is not ragged:
    # its strands run to the end. "proud" is the drop, in height units,
    # at which a tip is fully ragged.
    proud = np.clip(c.get("drop", np.full(n_px, 1.0)) / p.get("proud", 0.08), 0.0, 1.0)
    k = max(1, int(p.get("samples", 4)))
    out = [np.zeros(n_px) for _ in range(4)]
    for i in range(k):
        for j in range(k):
            ox = ((i + 0.5) / k - 0.5) / cell
            oy = ((j + 0.5) / k - 0.5) / cell
            du = ox * ux + oy * uy
            dv = -ox * uy + oy * ux
            for acc, val in zip(out, _bristle_at(a0 + dv, e0 - du, lt, lid, proud, sd, p)):
                acc += val
    su, sv, sm, occ = (o / (k * k) for o in out)
    return np.zeros(n_px), sm, su, sv, occ


def _tress_at(a, e, ll, lt, lid, proud, sd, p):
    """One sample of tress at a (across the lock from its middle) and e
    (along it, to its tip), texels: (slope along, slope across,
    smoothness, occlusion)."""
    shape = np.shape(a)
    bw = p.get("bundle", 0.34)
    clump = p.get("clump", 0.35)
    veer = p.get("veer", 0.05)
    n0 = p.get("strands", 11.0)
    rnd = p.get("round", 0.35)
    tilt = p.get("tilt", 0.04)
    shine = p.get("shine", 0.8)
    bshine = p.get("bundle_shine", 0.6)
    bround = p.get("bundle_round", 0.12)
    rag, taper = p.get("rag", 0.2), p.get("taper", 0.25)
    roll = p.get("roll", 2.0)
    s0 = ll - e  # along the lock from its root
    # Bundles: a one dimensional Voronoi across the lock, centres jittered
    # by most of a bundle so widths range about threefold.
    off = 5.0 * _hash(lid, 40, sd)
    kb = np.floor((a + off) / bw).astype(np.int64)
    ks = [kb + j for j in range(-3, 4)]
    cs = [(k + 0.5 + 0.9 * (_hash(k, lid, sd + 41) - 0.5)) * bw - off for k in ks]
    dist = np.stack([np.abs(a - cc) for cc in cs[1:6]])
    pick = np.argmin(dist, 0) + 1
    cstack = np.stack(cs)
    kstack = np.stack(ks)
    sel = lambda arr, d: np.take_along_axis(arr, (pick + d)[None], 0)[0]  # noqa: E731
    ck, kk = sel(cstack, 0), sel(kstack, 0)
    left = 0.5 * (ck - sel(cstack, -1))
    right = 0.5 * (sel(cstack, 1) - ck)
    hb = lambda k: _hash(kk, lid * 13 + 1, sd + k)  # noqa: E731
    # Toward the tip the strands of a bundle draw together, so bundles
    # part with a narrow gap between them where the tips stand proud;
    # each bundle runs a few degrees off the lock's direction.
    tipness = np.clip(1.0 - e / 0.6, 0.0, 1.0) * proud
    squeeze = 1.0 - clump * tipness * (0.5 + 0.5 * hb(2))
    b = (a - ck - veer * (2.0 * hb(3) - 1.0) * e) / squeeze
    half = np.where(b < 0, left, right)
    in_bundle = np.abs(b) < half
    nb = n0 * (0.75 + 0.55 * hb(4))
    best = np.full(shape, -np.inf)
    su = np.zeros(shape)
    sv = np.zeros(shape)
    sm = np.zeros(shape)
    cyl_top = np.zeros(shape)
    t_top = np.ones(shape)

    def lay(q, key, keep, w, end, start, z0, extra_v, s_off):
        nonlocal best, su, sv, sm, cyl_top, t_top
        i0 = np.floor(q).astype(np.int64)
        for di in (-1, 0, 1):
            i = i0 + di

            def h(k):
                return _hash(i, key, sd + k)
            kp = keep(h)
            cen = i + 0.5 + 0.35 * (h(22) - 0.5)
            ww = w(h)
            en = end(h)
            st = start(h)
            t = np.clip((e - en) / taper, 0.0, 1.0)
            wt = ww * (0.35 + 0.65 * np.sqrt(t))
            r = (q - cen) / wt
            inside = kp & (e > en) & (s0 > st) & (np.abs(r) < 1.0)
            rc = np.clip(r, -0.95, 0.95)
            cyl = np.sqrt(1.0 - rc * rc)
            # A strand that starts inside the lock rises out from under
            # the others over a tenth of a texel.
            rise = np.clip((s0 - st) / 0.1, 0.0, 1.0)
            z = z0 + 0.15 * h(26) + 0.1 * cyl * (1.0 - (1.0 - t) ** 2) * rise
            hit = inside & (z > best)
            g_v = -rnd * rc / cyl + tilt * (2.0 * h(27) - 1.0) + extra_v(h)
            dfall = np.where((t > 0.0) & (t < 1.0), 2.0 * (1.0 - t) / taper, 0.0)
            g_u = (-roll * rnd * 0.05 * cyl * dfall + 0.5 * tilt * (2.0 * h(28) - 1.0)
                   + np.where((rise > 0) & (rise < 1), 0.3, 0.0))
            s_ = shine * (h(29) - 0.5) + 0.3 * (cyl - 0.7) - 0.1 * (1.0 - t) + s_off
            best = np.where(hit, z, best)
            su = np.where(hit, g_u, su)
            sv = np.where(hit, g_v, sv)
            sm = np.where(hit, s_, sm)
            cyl_top = np.where(hit, cyl, cyl_top)
            t_top = np.where(hit, t, t_top)

    bkey = kk * 31 + lid * 977
    bundle_v = bround * np.clip(b / np.maximum(half, 1e-3), -1.0, 1.0)
    bundle_s = bshine * (hb(5) - 0.5)
    q_b = (b + 3.0 * hb(6)) * nb
    for L in range(2):
        # The bundle's strands: a full bottom layer, and a sparser one over
        # it whose strands start part way down the lock, so not every
        # strand runs the lock's full length.
        top = p.get("top", 0.3)
        rag_l = rag * (0.7 if L == 0 else 1.0)
        lay(q_b + 0.37 * L, bkey * 3 + L,
            (lambda h: np.ones(shape, bool) & in_bundle) if L == 0
            else (lambda h: (h(21) < top) & in_bundle),
            lambda h, L=L: 0.5 * (0.9 + 0.5 * h(23)) * (1.0 if L == 0 else 0.8),
            lambda h, r=rag_l: proud * r * np.where(h(24) < 0.2, 0.05 * h(25), 0.25 + 0.75 * h(25)),
            (lambda h: np.full(shape, -1.0)) if L == 0 else (lambda h: ll * 0.7 * h(30)),
            0.3 * L, lambda h: bundle_v, bundle_s)
    # Loose fibres over everything, across bundles: fine, sparse, short,
    # each at its own slant of several degrees.
    nf = p.get("fibres", 16.0)
    slant = p.get("slant", 0.12)
    fkey = lid * 7 + 5
    for F in range(2):
        sl = slant * (2.0 * _hash(F, lid, sd + 50) - 1.0)
        qf = (a + sl * e + 2.0 * _hash(lid, 51 + F, sd)) * nf
        flen = p.get("fibre_len", 0.6)
        lay(qf, fkey * 2 + F,
            lambda h: h(21) < p.get("fibre_share", 0.1),
            lambda h: 0.5 * (0.5 + 0.4 * h(23)),
            lambda h: ll * h(31) * 0.8,
            lambda h: np.maximum(ll - ll * h(31) * 0.8 - flen * (0.5 + h(32)), -1.0),
            0.7, lambda h: np.zeros(shape), 0.0)
    covered = np.isfinite(best)
    crease = p.get("crease", 0.2)
    tip = (e < rag + taper) & (proud > 0.5)
    seam = ~in_bundle
    occ = np.where(covered, 1.0 - crease * t_top * (1.0 - cyl_top) ** 2,
                   np.where(tip, 1.0 - p.get("gap", 0.08),
                            1.0 - np.where(seam, p.get("seam", 0.15), crease)))
    sm = np.where(covered, sm, np.where(tip, -0.1, -0.3))
    sm = sm + p.get("crown", 0.25) * (0.5 - lt)
    return su, sv, sm, occ


def _tress(c, p):
    """Hair as clumped tresses, the bristles' successor after the owner
    found them grooved decking (2026-10-02): parallel strands of near equal
    width and spacing are a repeating ridge. Each lock (atlas.py's frame)
    is split across into bundles of irregular width ("bundle", the mean
    in texels; a one dimensional Voronoi, so widths range about threefold),
    each with its own strand count ("strands" per texel, 0.75 to 1.3 times
    it), its own few degrees off the lock's direction ("veer", rise over
    run), its own shine ("bundle_shine") and a faint round across it
    ("bundle_round"). Toward a proud tip a bundle's strands draw together
    ("clump"), so bundles part at their ends. Inside a bundle the strands
    are thin cylinders as in bristle, flatter ("round"), the per strand
    shine ("shine") far larger than the per strand tilt ("tilt"), and an
    upper layer of them ("top", the share present) starts part way down
    the lock, so not every strand runs its full length. Loose fibres
    ("fibres" per texel, "fibre_share" of them present, "fibre_len",
    "slant") lie over everything at a slant, crossing the seams between
    bundles. The tips are bristle's cleaned ones ("rag", "taper", "gap");
    a seam between bundles is a little occluded ("seam"). Like bristle a
    slope kind: (detail, smooth, slope u, slope v, occlusion), averaged
    over "samples" squared points per pixel."""
    n_px = np.shape(c["x"])
    la = c.get("la", np.zeros(n_px))
    lt = c.get("lt", np.full(n_px, 0.5))
    lw = c.get("lw", np.full(n_px, 0.5))
    ll = c.get("ll", np.ones(n_px))
    lid = c.get("lid", np.zeros(n_px, np.int64))
    ux = c.get("dx", np.zeros(n_px))
    uy = c.get("dy", np.ones(n_px))
    cell = float(c.get("cell", 16.0))
    sd = c["seed"]
    a0 = la * lw
    e0 = (1.0 - lt) * ll
    proud = np.clip(c.get("drop", np.full(n_px, 1.0)) / p.get("proud", 0.08), 0.0, 1.0)
    k = max(1, int(p.get("samples", 4)))
    out = [np.zeros(n_px) for _ in range(4)]
    for i in range(k):
        for j in range(k):
            ox = ((i + 0.5) / k - 0.5) / cell
            oy = ((j + 0.5) / k - 0.5) / cell
            du = ox * ux + oy * uy
            dv = -ox * uy + oy * ux
            for acc, val in zip(out, _tress_at(a0 + dv, e0 - du, ll, lt, lid, proud, sd, p)):
                acc += val
    su, sv, sm, occ = (o / (k * k) for o in out)
    return np.zeros(n_px), sm, su, sv, occ


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


# --- animal and monster kinds -------------------------------------------------
# For mob skins. Like the kinds above they run along the face's direction
# (u along, v across, in art texels), so on a side face "down" lays fur and
# feathers down the body and on a top face it runs front to back, head to
# tail. Their defaults are sized for a mob's map, 8 pixels to an art texel
# (atlas.TEXEL_PX): nothing repeats in under about 2 map pixels, which
# would only alias. On a 16 pixel map (the player's parts) the finer
# parameters (fur "strands", feather "barbs") have room to rise.

def _shingle(c, p, length, width, overlap, point=False):
    """Overlapping shingles in rows along u, like feathers or scales: row r
    starts at u = r * length and its shingles reach overlap * length beyond
    it, each row staggered across by half a width and jittered. The
    shingle nearer the start of u lies on top, as feathers lie from head
    to tail. point narrows each to a point instead of a rounded tip. Per
    pixel: along its shingle (t, 0 at its root, 1 at its tip), across it
    (s, -1..1 of its half width there), and its id."""
    sd = c["seed"]
    # A slow warp so the rows are not ruled lines.
    u = c["u"] + 0.12 * length * vnoise(c["u"] * 0.7, c["v"] * 0.7, sd + 21)
    v = c["v"] + 0.15 * width * vnoise(c["u"] * 0.6, c["v"] * 0.6, sd + 22)
    span = length * (1.0 + overlap)
    r0 = np.floor(u / length).astype(np.int64)
    t_out = np.zeros(np.shape(u))
    s_out = np.zeros(np.shape(u))
    id_out = np.zeros(np.shape(u), np.int64)
    done = np.zeros(np.shape(u), bool)
    # Rows that can reach this pixel, nearest the start first (on top).
    back = int(np.ceil(overlap)) + 1
    for k in range(back, -1, -1):
        r = r0 - k
        off = 0.5 * (r % 2) + 0.3 * (_hash(r, 5, sd) - 0.5)
        a = v / width - off
        ci = np.round(a).astype(np.int64)
        ln = span * (0.85 + 0.3 * _hash(r, ci, sd + 1))
        t = (u - r * length) / ln
        if point:
            # Full width at the root, narrowing to a point (a tuft).
            hw = 0.54 * np.clip(1.0 - np.clip((t - 0.25) / 0.75, 0.0, 1.0) ** 1.3, 0.0, 1.0)
        else:
            # Full width at the root, a rounded tip.
            hw = 0.54 * np.sqrt(np.clip(1.0 - np.clip((t - 0.45) / 0.55, 0.0, 1.0) ** 2, 0.0, 1.0))
        s = (a - ci) / np.maximum(hw, 1e-3)
        hit = ~done & (t >= 0.0) & (t <= 1.0) & (np.abs(s) <= 1.0)
        t_out = np.where(hit, t, t_out)
        s_out = np.where(hit, s, s_out)
        id_out = np.where(hit, r * 7919 + ci, id_out)
        done |= hit
    return np.clip(t_out, 0.0, 1.0), np.clip(s_out, -1.0, 1.0), id_out


def _fur(c, p):
    """Short soft fur lying along the direction: tufts (clumps of hairs)
    in loose staggered rows, each rising from its root, where the tuft
    before it covers it, toward its tip, narrowing to a point. Tufts
    differ in height (clumping). Matte, with a slight sheen near the
    tips. "length" is a tuft's length in texels (0.8 a cow's short coat,
    1.2 to 1.6 a wolf's), "width" its width, "clump" how much tufts
    differ, "strands" grooves along each tuft (0, none, at 8 pixels to a
    texel; 2 or 3 on a 16 pixel map), "fuzz" a soft noise over all."""
    length = p.get("length", 0.8)
    width = p.get("width", 0.36)
    t, s, tid = _shingle(c, p, length, width, p.get("overlap", 0.7), point=True)
    sd = c["seed"]
    clump = 1.0 + p.get("clump", 0.35) * (_hash(tid, 3, sd + 4) - 0.5) * 2.0
    body = np.sqrt(np.clip(1.0 - s * s, 0.0, 1.0))
    rise = np.sin(0.5 * np.pi * np.clip(t * 1.25, 0.0, 1.0))
    n = p.get("strands", 0.0)
    if n > 0:
        sa = (s * 0.5 + 0.5) * n + 0.3 * _hash(tid, 6, sd)
        strand = np.sin(np.pi * _frac(sa)) ** 0.6 - 0.7
    else:
        strand = np.zeros(np.shape(t))
    fuzz = vnoise(c["x"] * 6.0, c["y"] * 6.0, sd + 7)
    d = (0.8 * rise * body * clump - 0.4 + 0.3 * strand * (0.4 + 0.6 * body)
         + p.get("fuzz", 0.08) * fuzz)
    tip = np.exp(-((t - 0.7) / 0.18) ** 2) * body
    s_ = 0.7 * tip - 0.3 * (1.0 - body) - 0.2 + 0.2 * strand
    return d, s_


def _hide(c, p):
    """A cow's or pig's skin: fine creases (a net of thin grooves, and
    longer wrinkles across the direction, in places), sparse pores, a soft
    swell between creases, and a slightly waxy surface, smoother on the
    swells than in the creases. "cell" is the crease net's size in
    texels, "wrinkles" wrinkles per texel along the direction."""
    sd = c["seed"]
    cell = p.get("cell", 0.55)
    f1, f2, idv = worley(c["x"] / cell, c["y"] / cell, sd)
    crease = np.clip(1.0 - (f2 - f1) / 0.16, 0.0, 1.0) ** 1.5
    wr = c["u"] * p.get("wrinkles", 1.8) + 0.6 * fbm(c["u"] * 0.8, c["v"] * 1.6, sd + 3, 2)
    gate = np.clip(vnoise(c["v"] * 1.2, c["u"] * 0.4, sd + 4) * 1.5 + 0.2, 0.0, 1.0)
    wrinkle = np.exp(-((_frac(wr) - 0.5) / 0.12) ** 2) * gate
    pf1, _, pid = worley(c["x"] / 0.25, c["y"] / 0.25, sd + 5)
    pore = np.clip(1.0 - pf1 / 0.3, 0.0, 1.0) * (pid > 0.75)
    swell = 0.5 * np.clip(f2 - f1, 0.0, 0.6) + 0.15 * fbm(c["x"] * 2.0, c["y"] * 2.0, sd + 6, 2)
    d = swell - 0.6 * crease - 0.45 * wrinkle - 0.4 * pore + 0.05 * (idv - 0.5)
    s = 0.6 * swell - 0.5 * crease - 0.3 * wrinkle - 0.2 * pore
    return d, s


def _feather(c, p):
    """Overlapping feathers in staggered rows along the direction, each
    with a rounded tip, a central shaft (a slight ridge, a little
    glossier), barbs slanting off it, and a step down at its tip onto the
    feather behind. "length" and "width" are a feather's size in texels
    (about one texel on a chicken); "barbs" per texel along the shaft (3
    at 8 pixels to a texel)."""
    length = p.get("length", 1.0)
    width = p.get("width", 0.8)
    t, s, fid = _shingle(c, p, length, width, p.get("overlap", 0.7))
    sd = c["seed"]
    body = np.sqrt(np.clip(1.0 - s * s, 0.0, 1.0))
    shaft = np.exp(-(s / 0.14) ** 2) * (1.0 - 0.6 * t)
    nb = p.get("barbs", 3.0)
    barb = np.sin(2 * np.pi * (t * length * nb - np.abs(s) * width * nb * 0.6))
    tone = _hash(fid, 2, sd) - 0.5
    d = (0.8 * (0.25 + 0.75 * t) * body - 0.4 + 0.3 * shaft + 0.06 * barb * body
         + 0.08 * tone)
    s_ = 0.5 * shaft + 0.2 * (body - 0.6) + 0.1 * barb * body
    return d, s_


def _scale(c, p):
    """Overlapping rounded scales in staggered rows along the direction,
    each a shallow dome with a faint keel, steeper at its free edge. A
    cheap relative of feather. "length" and "width" in texels."""
    length = p.get("length", 0.7)
    width = p.get("width", 0.7)
    t, s, sid = _shingle(c, p, length, width, p.get("overlap", 0.5))
    body = np.sqrt(np.clip(1.0 - s * s, 0.0, 1.0))
    keel = np.exp(-(s / 0.25) ** 2) * t
    tone = _hash(sid, 2, c["seed"]) - 0.5
    d = 0.7 * np.sqrt(t) * body - 0.35 + 0.15 * keel + 0.06 * tone
    s_ = 0.4 * body * t + 0.2 * keel - 0.3
    return d, s_


def _bone(c, p):
    """Bone: smooth, a little satin, with sparse small pores and a few
    hairline cracks (thin grooves along cell borders, only in places).
    "cracks" scales how much of the surface has them."""
    sd = c["seed"]
    f1, f2, _ = worley(c["x"] / 0.8, c["y"] / 0.8, sd)
    line = np.exp(-((f2 - f1) / 0.07) ** 2)
    gate = np.clip(vnoise(c["x"] * 0.9, c["y"] * 0.9, sd + 2) * 2.0 - 0.6 + p.get("cracks", 0.5),
                   0.0, 1.0)
    crack = line * gate
    pf1, _, pid = worley(c["x"] / 0.3, c["y"] / 0.3, sd + 3)
    pore = np.clip(1.0 - pf1 / 0.3, 0.0, 1.0) * (pid > 0.65)
    soft = fbm(c["x"] * 1.5, c["y"] * 1.5, sd + 4, 2)
    d = 0.25 * soft - 0.6 * pore - 0.8 * crack
    s = 0.2 * soft - 0.5 * pore - 0.6 * crack
    return d, s


def _rotten(c, p):
    """Decaying skin: lumpy, with blotches that differ strongly in
    roughness (wet and dry), small pits clustered in the dry blotches,
    and a few shallow sores. "pits" (default 1) scales the pits, the
    kind's pores, in the relief and the smoothness alike; 0 leaves the
    lumps, blotches and sores (the undead faces since 2026-10-03)."""
    sd = c["seed"]
    pits = float(p.get("pits", 1.0))
    blotch = fbm(c["x"] * 1.1, c["y"] * 1.1, sd, 3)
    lump = fbm(c["x"] * 2.5, c["y"] * 2.5, sd + 1, 2)
    pf1, _, pid = worley(c["x"] / 0.28, c["y"] / 0.28, sd + 2)
    dense = np.clip(0.5 - blotch, 0.0, 1.0)
    pit = np.clip(1.0 - pf1 / 0.35, 0.0, 1.0) ** 1.5 * (pid < 0.25 + 0.6 * dense)
    sf1, _, sid = worley(c["x"] / 1.0, c["y"] / 1.0, sd + 3)
    sore = np.clip(1.0 - sf1 / 0.3, 0.0, 1.0) * (sid > 0.8)
    if pits != 1.0:
        pit = pit * pits
    d = 0.35 * lump + 0.15 * blotch - 0.6 * pit - 0.5 * sore
    s = 1.1 * blotch - 0.3 * pit + 0.4 * sore
    return d, s


def _mottle(c, p):
    """Soft lumpy blotches, like a creeper's skin: overlapping rounded
    lumps of mixed size (leafy, mossy) with soft hollows between. Matte.
    "cell" is the lumps' size in texels."""
    sd = c["seed"]
    cell = p.get("cell", 0.6)
    f1, f2, idv = worley(c["x"] / cell, c["y"] / cell, sd)
    lump = np.clip(1.0 - f1 * 1.1, 0.0, 1.0) ** 0.8 * (0.7 + 0.6 * idv)
    g1, _, _ = worley(c["x"] / (cell * 0.5), c["y"] / (cell * 0.5), sd + 1)
    small = np.clip(1.0 - g1 * 1.2, 0.0, 1.0)
    hollow = np.clip(1.0 - (f2 - f1) / 0.25, 0.0, 1.0)
    grain = vnoise(c["x"] * 6.0, c["y"] * 6.0, sd + 2)
    d = 0.55 * lump + 0.25 * small - 0.3 * hollow - 0.4 + 0.05 * grain
    s = 0.2 * lump - 0.4 * hollow + 0.1 * grain - 0.1
    return d, s


def _chitin(c, p):
    """Hard glossy shell: fine parallel ridges across the direction (the
    growth lines of a plate), each slightly wavy, with a deeper suture
    between plates and each plate a little domed. Glossy on the ridges.
    "ridges" per texel, "plates" a plate's length in texels."""
    sd = c["seed"]
    n = p.get("ridges", 2.5)
    w = c["u"] + 0.05 * fbm(c["v"] * 1.5, c["u"] * 0.5, sd, 2)
    ridge = np.sin(np.pi * _frac(w * n)) ** 1.5
    plates = p.get("plates", 1.5)
    pa = w / plates + 0.2 * vnoise(c["v"] * 0.8, np.zeros(np.shape(c["v"])), sd + 1)
    suture = np.exp(-((_frac(pa) - 0.03) / 0.05) ** 2)
    dome = 0.3 * np.sin(np.pi * _frac(pa))
    d = 0.45 * ridge + dome - 0.4 - 0.8 * suture
    s = 0.4 * ridge - 0.7 * suture - 0.1
    return d, s


# --- riveted iron ------------------------------------------------------------
# One plate per art texel. Each kind works in the pixel's own texel (its
# integer cell and the position inside it), so a feature never leaves its
# plate and never reaches another face.

def _cell(c):
    tx, ty = np.floor(c["x"]), np.floor(c["y"])
    return tx.astype(np.int64), ty.astype(np.int64), c["x"] - tx, c["y"] - ty


def _plate(c, p):
    """A plate per texel: a crisp shallow bevel at its edge ("bevel", its
    width in texels), a small tilt ("tilt") and offset ("step") per plate,
    so neighbours at one height still meet with a small step and catch the
    light a little differently; in the smoothness the shine per plate,
    uniform -1..1, and faint rust specks ("specks", their share of plates,
    each pulling the smoothness down by up to 3)."""
    sd = c["seed"]
    tx, ty, fx, fy = _cell(c)
    bw = p.get("bevel", 0.09)
    e = np.minimum(np.minimum(fx, 1.0 - fx), np.minimum(fy, 1.0 - fy))
    bevel = np.clip(1.0 - e / bw, 0.0, 1.0)
    tilt = p.get("tilt", 0.25)
    ax = 2.0 * _hash(tx, ty, sd + 31) - 1.0
    ay = 2.0 * _hash(tx, ty, sd + 32) - 1.0
    off = p.get("step", 0.15) * (2.0 * _hash(tx, ty, sd + 33) - 1.0)
    d = -bevel + tilt * (ax * (fx - 0.5) + ay * (fy - 0.5)) + off
    shine = 2.0 * _hash(tx, ty, sd + 34) - 1.0
    f1, _, sid = worley(c["x"] / 0.13, c["y"] / 0.13, sd + 35)
    speck = np.clip(1.0 - f1 / 0.35, 0.0, 1.0) * (sid < p.get("specks", 0.06))
    speck = speck * (_hash(tx, ty, sd + 36) < 0.5)
    return d, shine - 3.0 * speck


def _scratches(c, p):
    """Fine straight scratches, about "count" per plate (0 to 2 times it),
    each a groove "width" texels wide and up to "length" texels long at a
    random angle, centred inside the plate and cut at its edge. A little
    rougher in the groove."""
    sd = c["seed"]
    tx, ty, fx, fy = _cell(c)
    count = p.get("count", 1.5)
    w = p.get("width", 0.045)
    ln = p.get("length", 0.7)
    out = np.zeros(np.shape(c["x"]))
    for k in range(int(np.ceil(2 * count))):
        on = _hash(tx, ty, sd + 40 + 7 * k) < count / np.ceil(2 * count)
        cx = 0.2 + 0.6 * _hash(tx, ty, sd + 41 + 7 * k)
        cy = 0.2 + 0.6 * _hash(tx, ty, sd + 42 + 7 * k)
        a = np.pi * _hash(tx, ty, sd + 43 + 7 * k)
        hl = 0.5 * ln * (0.4 + 0.6 * _hash(tx, ty, sd + 44 + 7 * k))
        dx, dy = np.cos(a), np.sin(a)
        rx, ry = fx - cx, fy - cy
        t = np.clip(rx * dx + ry * dy, -hl, hl)
        dist = np.hypot(rx - t * dx, ry - t * dy)
        g = np.exp(-(dist / w) ** 2) * (0.5 + 0.5 * _hash(tx, ty, sd + 45 + 7 * k))
        out = np.maximum(out, g * on)
    return -out, -out


def _dents(c, p):
    """Soft round hammer dents: a plate has one with probability
    "density" and a second, smaller one with "second" times that (0.5;
    0 for at most one), each a shallow dish of "radius" texels (0.6 to 1
    times it), kept inside the plate."""
    sd = c["seed"]
    tx, ty, fx, fy = _cell(c)
    dens = p.get("density", 0.45)
    r0 = p.get("radius", 0.3)
    out = np.zeros(np.shape(c["x"]))
    second = p.get("second", 0.5)
    for k, (share, size) in enumerate(((1.0, 1.0), (second, 0.6))):
        on = _hash(tx, ty, sd + 50 + 5 * k) < dens * share
        r = r0 * size * (0.6 + 0.4 * _hash(tx, ty, sd + 51 + 5 * k))
        m = np.minimum(r + 0.08, 0.5)
        cx = m + (1.0 - 2.0 * m) * _hash(tx, ty, sd + 52 + 5 * k)
        cy = m + (1.0 - 2.0 * m) * _hash(tx, ty, sd + 53 + 5 * k)
        q = ((fx - cx) ** 2 + (fy - cy) ** 2) / (r * r)
        dish = np.clip(1.0 - q, 0.0, 1.0) ** 2 * (0.6 + 0.4 * _hash(tx, ty, sd + 54 + 5 * k))
        out = np.maximum(out, dish * on)
    return -out, -0.3 * out


def _rivets(c, p):
    """Rivet heads: a dome of "radius" texels in a shallow seat, centred
    "inset" texels in from the outer corner of a plate. Which plates: those
    in the outer "ring" rows and columns of each piece of the material
    (atlas.py's piece frame), every "every" plates counted from the piece's
    nearest edge, on pieces at least "min_size" texels both ways; the
    outer corner is the one toward the piece's nearest edges, so a
    symmetric piece is riveted symmetrically. "at" adds rivets at listed
    [x, y] centres in art texels. "seat" is the seat ring's width as a
    share of the radius. A little smoother on the head."""
    radius = p.get("radius", 0.15)
    inset = p.get("inset", 0.27)
    every = max(1, int(p.get("every", 3)))
    ring = int(p.get("ring", 1))
    x, y = c["x"], c["y"]
    tx, ty, fx, fy = _cell(c)
    best = np.full(np.shape(x), np.inf)
    px, py = c.get("px"), c.get("py")
    if px is not None and ring > 0:
        hx = c.get("hx", np.ones(np.shape(x)))
        hy = c.get("hy", np.ones(np.shape(x)))
        cx, cy = x - px * hx, y - py * hy
        x0, x1 = np.round(cx - hx), np.round(cx + hx)
        y0, y1 = np.round(cy - hy), np.round(cy + hy)
        ex = np.minimum(tx - x0, x1 - 1 - tx)
        ey = np.minimum(ty - y0, y1 - 1 - ty)
        big = (2 * hx >= p.get("min_size", 3)) & (2 * hy >= p.get("min_size", 3))
        row = (ey < ring) & (ex % every == 0)
        col = (ex < ring) & (ey % every == 0)
        pick = big & (row | col)
        mx = tx + 0.5 - cx
        my = ty + 0.5 - cy
        rx = np.where(mx < -0.25, inset, np.where(mx > 0.25, 1.0 - inset, 0.5))
        ry = np.where(my < -0.25, inset, np.where(my > 0.25, 1.0 - inset, 0.5))
        dist = np.hypot(fx - rx, fy - ry)
        best = np.where(pick, dist, best)
    for at in p.get("at", []):
        best = np.minimum(best, np.hypot(x - at[0], y - at[1]))
    q = best / radius
    head = np.sqrt(np.clip(1.0 - q * q, 0.0, 1.0))
    sw = p.get("seat", 0.25)
    seat = np.clip(1.0 - np.abs(q - 1.0 - sw * 0.6) / sw, 0.0, 1.0)
    d = head - 0.25 * seat
    s = 0.6 * head - 0.4 * seat
    return d, s


def _rust(c, p):
    """Flaky, pitted rust: flakes ("flake" texels across) each at its own
    height with its edge lifted a little, small pits ("pits" their share),
    and a fine grit, all very rough."""
    sd = c["seed"]
    fl = p.get("flake", 0.3)
    f1, f2, idv = worley(c["x"] / fl, c["y"] / fl, sd + 60)
    edge = np.clip(1.0 - (f2 - f1) / 0.12, 0.0, 1.0)
    lift = np.clip(1.0 - (f2 - f1) / 0.3, 0.0, 1.0) * (idv > 0.5)
    pf1, _, pid = worley(c["x"] / 0.12, c["y"] / 0.12, sd + 61)
    pit = np.clip(1.0 - pf1 / 0.3, 0.0, 1.0) ** 1.5 * (pid < p.get("pits", 0.35))
    grit = vnoise(c["x"] * 14.0, c["y"] * 14.0, sd + 62)
    d = 0.6 * (idv - 0.5) + 0.3 * lift - 0.5 * edge - 0.6 * pit + 0.1 * grit
    s = -0.6 - 0.4 * pit - 0.3 * edge + 0.15 * grit
    return d, s


def _leaf(c, p):
    """Small overlapping leaves, two to a cell of "size" texels, each at a
    random angle, pointed at both ends, domed across with a midrib groove
    and its tip lifted. Where several cover a pixel the one with the
    higher order lies on top and stands a step higher; a pixel no leaf
    covers is a gap between them, low and rough."""
    sd = c["seed"]
    size = p.get("size", 0.45)
    x, y = c["x"] / size, c["y"] / size
    ix, iy = np.floor(x).astype(np.int64), np.floor(y).astype(np.int64)
    top = np.full(np.shape(x), -1.0)
    d = np.full(np.shape(x), -0.6)
    s = np.full(np.shape(x), -0.3)
    for k in range(2):
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                gx, gy = ix + dx, iy + dy
                h = sd + 70 + 11 * k
                lx = gx + _hash(gx, gy, h)
                ly = gy + _hash(gx, gy, h + 1)
                a = 2 * np.pi * _hash(gx, gy, h + 2)
                L = 0.62 + 0.25 * _hash(gx, gy, h + 3)
                W = 0.42 * L
                order = _hash(gx, gy, h + 4)
                rx, ry = x - lx, y - ly
                al = (rx * np.cos(a) + ry * np.sin(a)) / L
                ac = (-rx * np.sin(a) + ry * np.cos(a)) / W
                half = np.clip(1.0 - al * al, 0.0, 1.0) ** 0.8
                inside = (np.abs(al) <= 1.0) & (np.abs(ac) <= half)
                b = np.where(inside, ac / np.maximum(half, 1e-3), 1.0)
                body = np.sqrt(np.clip(1.0 - b * b, 0.0, 1.0))
                rib = np.exp(-(b / 0.18) ** 2) * (1.0 - al * al)
                lift = 0.25 * np.clip(al, 0.0, 1.0)
                hit = inside & (order > top)
                d = np.where(hit, 0.5 * body - 0.35 * rib + lift + 0.4 * order - 0.2, d)
                s = np.where(hit, 0.4 * body - 0.4 * rib - 0.1, s)
                top = np.where(hit, order, top)
    return d, s


def _chain(c, p):
    """Mail, four rings through each: rings of round wire, "rings" to a
    texel across, in rows half a ring apart along the direction, each row
    shifted half a ring, so every ring overlaps the four rings diagonal to
    it. Each ring is a torus of radius "radius" and wire half width "wire"
    (both in ring spacings); a row's rings lean along the direction one
    way and the next row's the other way ("lean"), so where two rings cross
    the leaning one is on top and each ring passes over two neighbours and
    under two. A pixel no wire covers is a gap, low and rough. The wire's
    top is smoother than its sides."""
    n = float(p.get("rings", 1.0))
    rad = float(p.get("radius", 0.4))
    wire = float(p.get("wire", 0.13))
    lean = float(p.get("lean", 0.12))
    a, b = c["u"] * n, c["v"] * n
    row0 = np.floor(a * 2.0)
    d = np.full(np.shape(a), -float(p.get("gap", 0.15)))
    s = np.full(np.shape(a), -0.5)
    top = np.full(np.shape(a), -np.inf)
    for dr in (-2, -1, 0, 1, 2):
        r = row0 + dr
        odd = np.mod(r, 2.0)
        off = 0.5 * odd
        for dc in (-1, 0, 1):
            col = np.floor(b - off) + dc
            cu, cv = 0.5 * r + 0.25, col + 0.5 + off
            du, dv = a - cu, b - cv
            q = (np.hypot(du, dv) - rad) / wire
            on = np.abs(q) < 1.0
            prof = np.sqrt(np.clip(1.0 - q * q, 0.0, 1.0))
            sign = np.where(odd < 0.5, 1.0, -1.0)
            jit = 0.1 * (_hash(r.astype(np.int64), col.astype(np.int64), c["seed"] + 80) - 0.5)
            h = 0.6 * prof + lean * sign * du + jit
            hit = on & (h > top)
            d = np.where(hit, h, d)
            s = np.where(hit, 0.6 * prof - 0.2, s)
            top = np.where(hit, h, top)
    return d, s


# --- block kinds --------------------------------------------------------------

# Per block kind: the block class whose normal strength the block kind is
# seen at, and whether the field's features run along its x (wood's grain,
# the brushing) or its y (bark's fissures, which follow the log).
BLOCK_KINDS = {
    "wood": ("planks", "x"),
    "bark": ("wood", "y"),
    "glass": ("glass", "x"),
    "metal": ("metal", "x"),
    "metal_worn": ("metal", "x"),
}
_block_fields = {}


def _block_field(kind, seed, size):
    key = (kind, seed, size)
    if key not in _block_fields:
        import extrude
        _block_fields[key] = extrude.micro_field(kind, seed, size=size)
    return _block_fields[key]


def _block(kind):
    def fn(c, p):
        import extrude
        cls, axis = BLOCK_KINDS[kind]
        cell = float(c.get("cell", 16.0))
        size = int(round(cell * 16))
        d, s = _block_field(kind, int(c["seed"]) & 0xffff, size)
        # Field pixel centres sit at whole coordinates; a pixel's u and v
        # are at texel centres, (i + 0.5) / cell.
        along = np.asarray(c["u"], np.float64) * cell - 0.5
        across = np.asarray(c["v"], np.float64) * cell - 0.5
        ys, xs = (across, along) if axis == "x" else (along, across)
        block_strength = extrude.CLASS_STYLE[cls][2]
        k = block_strength / float(c.get("strength", block_strength))
        return (k * extrude._sample(d, ys, xs).astype(np.float64),
                extrude._sample(s, ys, xs).astype(np.float64))
    fn.__doc__ = "extrude's %s field, read per pixel along the direction." % kind
    return fn


def _paper(c, p):
    """Paper: fine fibres, a few texel fractions long, lying mostly along
    the direction ("along", their count per texel along it, "across" per
    texel across) with a sparser set crossing them, and a faint cockle (a
    soft swell over several texels). Almost flat and matte: the smoothness
    barely moves."""
    sd = c["seed"]
    u, v = c["u"], c["v"]
    fa, fc = p.get("along", 1.5), p.get("across", 6.0)
    fibre = vnoise(u * fa, v * fc, sd)
    # A second set at about 60 degrees, so the fibres are a felt, not ruled.
    ru = 0.5 * u + 0.866 * v
    rv = -0.866 * u + 0.5 * v
    cross = vnoise(ru * fa, rv * fc, sd + 1)
    cockle = fbm(u * 0.35, v * 0.35, sd + 2, 2)
    d = 0.5 * fibre + 0.3 * cross + p.get("cockle", 0.3) * cockle
    s = 0.3 * fibre + 0.2 * cross
    return d, s


def _mix(c, p):
    """Several kinds summed (see the module docstring)."""
    d = np.zeros(np.shape(c["x"]))
    s = np.zeros(np.shape(c["x"]))
    for layer in p.get("layers", []):
        dk, sk, amp, swing = evaluate(layer["kind"], c, layer.get("params"))
        d = d + amp * float(layer.get("strength", 1.0)) * dk
        s = s + swing * float(layer.get("swing", 1.0)) * sk
    return d, s


# Kinds that want each lock's frame (atlas.py: la across -1..1, lt along
# 0..1, lw half width in texels, lid an id).
LOCK_KINDS = {"hair", "bristle", "tress"}

# Kinds that give their normal as slopes and an occlusion factor besides
# (detail, smooth); see _bristle. atlas.py passes them the direction in the
# image ("dx", "dy", the way u runs) and each lock's length ("ll", texels),
# and evaluate_slope returns the extra fields.
SLOPE_KINDS = {"bristle", "tress"}

# (function, default amplitude in height units, default smoothness swing)
KINDS = {
    "knit": (_knit, 0.050, 0.06),
    "wool": (_wool, 0.040, 0.04),
    "weave": (_weave, 0.050, 0.06),
    "twill": (_twill, 0.035, 0.06),
    "hair": (_hair, 0.060, 0.22),
    "bristle": (_bristle, 1.0, 0.28),
    "tress": (_tress, 1.0, 0.30),
    "straw": (_straw, 0.050, 0.15),
    "leather": (_leather, 0.030, 0.14),
    "rope": (_rope, 0.050, 0.08),
    "skin": (_skin, 0.006, 0.03),
    "eye": (_eye, 0.400, 0.0),
    "fur": (_fur, 0.100, 0.16),
    "hide": (_hide, 0.035, 0.12),
    "feather": (_feather, 0.120, 0.14),
    "scale": (_scale, 0.070, 0.14),
    "bone": (_bone, 0.030, 0.12),
    "rotten": (_rotten, 0.045, 0.25),
    "mottle": (_mottle, 0.065, 0.08),
    "chitin": (_chitin, 0.050, 0.14),
    "plate": (_plate, 0.030, 0.06),
    "scratches": (_scratches, 0.020, 0.10),
    "dents": (_dents, 0.035, 0.06),
    "rivets": (_rivets, 0.060, 0.15),
    "rust": (_rust, 0.050, 0.20),
    "leaf": (_leaf, 0.070, 0.12),
    "chain": (_chain, 0.060, 0.20),
    "mix": (_mix, 1.0, 1.0),
    "paper": (_paper, 0.008, 0.04),
}


def _add_block_kinds():
    import extrude
    for k in BLOCK_KINDS:
        amp, swing = extrude.MICRO_KINDS[k]
        KINDS[k] = (_block(k), amp, swing)


_add_block_kinds()


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
    d, s = fn(ctx, params)[:2]
    return d.astype(np.float32), s.astype(np.float32), amp, swing


def evaluate_slope(kind, ctx, params=None):
    """For a kind in SLOPE_KINDS: (detail, smooth, slope u, slope v,
    occlusion, amp, swing). The slopes are rise over run along u and
    across v, to be scaled by amp like the detail; the occlusion a factor
    0..1 on the map's."""
    fn, amp, swing = KINDS[kind]
    d, s, su, sv, occ = fn(ctx, dict(params or {}))
    f = np.float32
    return d.astype(f), s.astype(f), su.astype(f), sv.astype(f), occ.astype(f), amp, swing


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
    the wear smudges and a texel edge, each labelled, for a person to judge
    a kind by. Kinds run along image down. The light's x is image right, y
    image up. cell is map pixels per art texel: 16 for the player's parts,
    8 for a mob's (atlas.TEXEL_PX), where a finer map is drawn enlarged to
    the same size so the two compare."""
    from PIL import Image, ImageDraw
    size = cell * texels
    yy, xx = np.mgrid[0:size, 0:size]
    x = (xx + 0.5) / cell
    y = (yy + 0.5) / cell
    L = np.asarray(light, np.float64)
    L /= np.linalg.norm(L)

    def lit(d, s, gx=0.0, gy=0.0, occ=1.0):
        # The same rise per texel whatever the map's density. gx and gy
        # are a slope kind's rise over run, image right and down.
        h = d * 12.0 * cell / 16.0
        n = np.stack([-(np.gradient(h, axis=1) + gx), np.gradient(h, axis=0) + gy,
                      np.ones_like(h)], -1)
        n /= np.linalg.norm(n, axis=-1, keepdims=True)
        return np.clip((0.55 * np.clip((n * L).sum(-1), 0, 1) + 0.25) * occ + 0.15 * s, 0, 1)

    # The eye kind wants piece offsets: a dome per two texels.
    # The block kinds see a skin of strength 12, the rise lit() draws at.
    ctx = {"x": x.ravel(), "y": y.ravel(), "u": y.ravel(), "v": x.ravel(), "seed": 11,
           "px": (x.ravel() % 2) - 1.0, "py": (y.ravel() % 2) - 1.0,
           "cell": cell, "strength": 12.0}
    import extrude
    tiles = []
    labels = []
    for k in kind_names():
        if k in SLOPE_KINDS:
            # One lock over the whole square, its tip at the bottom edge,
            # running image down, standing proud.
            half = texels / 2.0
            lctx = dict(ctx, la=(x.ravel() - half) / half, lw=np.full(size * size, half),
                        lt=y.ravel() / texels, ll=np.full(size * size, float(texels)),
                        lid=np.zeros(size * size, np.int64), dx=np.zeros(size * size),
                        dy=np.ones(size * size))
            d, s, su, sv, occ, amp, swing = evaluate_slope(k, lctx)
            r = lambda a: a.reshape(size, size)  # noqa: E731
            tiles.append(lit(r(amp * d), r(swing * s), r(amp * sv), r(amp * su), r(occ)))
            labels.append(k)
            continue
        d, s, amp, swing = evaluate(k, ctx)
        tiles.append(lit((amp * d).reshape(size, size), (swing * s).reshape(size, size)))
        labels.append(k)
        if k in BLOCK_KINDS:
            # The block's own field as a block face shows it (grain across
            # a plank, fissures down a log), at the block's rise per texel.
            bd, bs = extrude.micro_field(k, 11, size=cell * 16)
            bamp, bswing = extrude.MICRO_KINDS[k]
            rise = extrude.CLASS_STYLE[BLOCK_KINDS[k][0]][2] / 12.0
            tiles.append(lit(bamp * rise * bd[:size, :size], bswing * bs[:size, :size]))
            labels.append(k + " block")
    names = labels
    mask = np.zeros((size, size), bool)
    mask[cell:size - cell, cell:size - cell] = True
    dist = edge_distance(mask, np.zeros((size, size), int))
    for seam in (False, True):
        d, s = stitch(dist, mask, cell, x, y, {}, seam=seam)
        tiles.append(lit(np.where(mask, 0.05 * d, 0.0), np.where(mask, 0.25 * s, 0.0)))
    tiles.append(np.clip(0.5 + 0.4 * wear(x, y, 3), 0, 1))
    tiles.append(lit(-0.02 * texel_edge(cell, (size, size)), np.zeros((size, size))))
    names = names + ["stitch", "seam", "wear", "texel_edge"]
    zoom = max(1, 16 // cell)
    tiles = [np.kron(t, np.ones((zoom, zoom))) for t in tiles]
    size *= zoom
    cols, gap, top = 5, 6, 14
    rows = -(-len(tiles) // cols)
    sheet = np.full((rows * (size + gap + top) + gap, cols * (size + gap) + gap), 0.1)
    for i, t in enumerate(tiles):
        r, c = divmod(i, cols)
        y0, x0 = gap + top + r * (size + gap + top), gap + c * (size + gap)
        sheet[y0:y0 + size, x0:x0 + size] = t
    im = Image.fromarray((sheet * 255 + 0.5).astype(np.uint8), "L")
    draw = ImageDraw.Draw(im)
    for i, n in enumerate(names):
        r, c = divmod(i, cols)
        draw.text((gap + c * (size + gap), gap + r * (size + gap + top) - 2), n, fill=220)
    im.save(path)
    return names


if __name__ == "__main__":
    import sys
    if len(sys.argv) not in (2, 3):
        raise SystemExit("usage: micro.py <swatch sheet.png> [map pixels per texel, 16 or 8]")
    print(" ".join(swatches(sys.argv[1], cell=int(sys.argv[2]) if len(sys.argv) == 3 else 16)))
