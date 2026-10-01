"""Texel extrusion for model atlases: mob skins.

extrude.py was written for node tiles, which repeat. A mob skin is a UV
atlas of box faces (for each box its top and bottom, then its four sides
in a row), so three of the tile rule's assumptions are wrong for it:

  size     extrude.build makes every map lib.SIZE wide, which gives a
           64 px skin 4 map pixels per art texel and the 128 px iron golem
           2. A mob texel is about a sixteenth of a block, like a node
           texel. Here the map is TEXEL_PX map pixels per art texel at the
           256 pack (16 at the 512 one, via lib.PX) whatever the art's
           size, and the albedo is written at the same size because the
           client sizes by the albedo.
  wrap     the chamfer, the normal and the occlusion wrapped at the
           image's edge. An atlas does not tile.
  islands  two faces side by side in the image are not neighbours on the
           model. The island map says which face each texel belongs to,
           read from the model's own UVs (the .b3d the game draws the skin
           on), so nothing is bevelled, sloped or occluded across a face
           border. Drawn texels no face uses become islands of their own,
           by 4 connected component, never wrapped.

What a face edge does is the spec's "face_edge":

  flat     (default) the relief runs flat to the edge of every face.
  bevel    every face border slopes down by "bevel_depth" (a share of the
           full height range) over "bevel_px" map pixels at the 256 pack.
           Every edge of a box is convex, so this is right on any box
           without knowing which faces meet: the box reads as slightly
           rounded. It goes to the normal only, like the micro surface,
           so the stored height stays one value per texel and the
           occlusion never darkens a convex edge.

Mirrored limbs share one UV rectangle, so one texel is drawn on both
limbs, once mirrored. A tangent space normal map is right on both only
when the client builds the tangent frame per fragment from the mirrored
UVs (entity_common.gdshaderinc reconstructs it from the surface); a
relief that leans one way (a slope from left to right inside a face)
then leans the mirrored way on the other limb, which is what mirroring
means, so author nothing that has to point one way in model space.

A crack or damage overlay (a "^" texture drawn over the skin) is built
with "overlay": true in its spec: its drawn texels sink as joints into a
surface standing at "surface" height (default 1), so the walls of the
groove slope inward, and every texel it does not draw is the neutral fill
(flat normal, full occlusion, default _s). The client composites the
overlay's maps over the skin's where the overlay is drawn.

Skins are listed in stems/<game>.mobs.txt, one per line:

    <stem> <model.b3d> [brush]

brush is which of the model's materials the skin is drawn on (0 for the
first). A spec in specs/<game>/<stem>.json works as for extrude.py, plus
the keys above, "micro_materials" (the materials the micro surface is
drawn on, default all) and "texel_px" to override the map density.
"strength" is in node units as in extrude.py (the full height range's
rise in texels of a 256 px node map, sixteen to an art texel), so a skin
and a block with the same strength have the same rise per art texel.
"""
import struct
import sys
import zlib
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import extrude  # noqa: E402
import lib  # noqa: E402

HERE = Path(__file__).resolve().parent
# Map pixels per art texel at the 256 pack. A node texel gets 16; a skin
# gets half that, because a 64 px skin at 16 would be 1024 square and the
# iron golem's 128 px atlas 2048 square, four times the texture memory of a
# node array layer per map for something seen mostly at a distance. Eight
# still leaves each texel a flat top inside its one pixel chamfer.
TEXEL_PX = 8
BEVEL_PX = 2
BEVEL_DEPTH = 0.12


def mobs_list(game):
    """(stem, model, brush) for every skin in stems/<game>.mobs.txt."""
    p = HERE / "stems" / (game + ".mobs.txt")
    if not p.exists():
        return []
    out = []
    for line in p.read_text().splitlines():
        line = line.split("#", 1)[0].split()
        if line:
            out.append((line[0], line[1], int(line[2]) if len(line) > 2 else 0))
    return out


def model_of(stem, game):
    for s, model, brush in mobs_list(game):
        if s == stem:
            return model, brush
    raise KeyError("%s is not in stems/%s.mobs.txt" % (stem, game))


# --- the model's faces --------------------------------------------------------

def _chunks(b, off, end):
    while off < end:
        tag = b[off:off + 4].decode("latin1")
        ln = struct.unpack("<i", b[off + 4:off + 8])[0]
        yield tag, off + 8, off + 8 + ln
        off += 8 + ln


def read_b3d(path):
    """Every mesh in a Blitz3D file as (positions, uvs, [(brush, tris)]).
    Only what the face layout needs: the first texture coordinate set."""
    b = Path(path).read_bytes()
    out = []

    def walk(off, end):
        for tag, s, e in _chunks(b, off, end):
            if tag == "BB3D":
                walk(s + 4, e)
            elif tag == "NODE":
                # Name, then position, scale and rotation (10 floats).
                walk(b.index(b"\0", s) + 1 + 40, e)
            elif tag == "MESH":
                verts, tris = None, []
                for t2, s2, e2 in _chunks(b, s + 4, e):
                    if t2 == "VRTS":
                        flags, sets, size = struct.unpack("<iii", b[s2:s2 + 12])
                        per = 3 + (3 if flags & 1 else 0) + (4 if flags & 2 else 0) + sets * size
                        arr = np.frombuffer(b[s2 + 12:e2], "<f4").reshape(-1, per)
                        uv0 = per - sets * size
                        verts = (arr[:, :3], arr[:, uv0:uv0 + 2])
                    elif t2 == "TRIS":
                        brush = struct.unpack("<i", b[s2:s2 + 4])[0]
                        tris.append((brush, np.frombuffer(b[s2 + 4:e2], "<i4").reshape(-1, 3)))
                out.append((verts[0], verts[1], tris))
    walk(0, len(b))
    return out


def model_path(model, game):
    root = lib.GAMES[game]["art"]
    hits = sorted(root.rglob(model))
    if not hits:
        raise FileNotFoundError("%s under %s" % (model, root))
    return hits[0]


def faces(model, brush, w, h, game=lib.DEFAULT_GAME):
    """Each face the model draws from this brush as (x0, y0, x1, y1) in art
    texels, end exclusive, with the number of triangles using it (two per
    box face; four when two mirrored limbs share it)."""
    rects = {}
    for pos, uv, tris in read_b3d(model_path(model, game)):
        for b, idx in tris:
            if b != brush:
                continue
            for t in idx:
                u, v = uv[t, 0] * w, uv[t, 1] * h
                r = (int(round(u.min())), int(round(v.min())),
                     int(round(u.max())), int(round(v.max())))
                if r[2] > r[0] and r[3] > r[1]:
                    rects[r] = rects.get(r, 0) + 1
    return sorted(rects.items(), key=lambda kv: (kv[0][1], kv[0][0]))


def _components(mask):
    """4 connected components of a boolean mask, not wrapped."""
    h, w = mask.shape
    lab = -np.ones(mask.shape, dtype=int)
    n = 0
    for y in range(h):
        for x in range(w):
            if not mask[y, x] or lab[y, x] >= 0:
                continue
            stack = [(y, x)]
            lab[y, x] = n
            while stack:
                cy, cx = stack.pop()
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = cy + dy, cx + dx
                    if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and lab[ny, nx] < 0:
                        lab[ny, nx] = n
                        stack.append((ny, nx))
            n += 1
    return lab, n


def face_map(src, model=None, brush=0, game=lib.DEFAULT_GAME, spec=None):
    """One island id per art texel, -1 where there is none. Faces come from
    the model, or from the spec's "faces" list of [x0, y0, x1, y1] when the
    skin has no model; where faces overlap (a one texel side face inside a
    larger one) the larger face keeps the texel, since it shows more of it.
    Drawn texels outside every face are grouped by component."""
    h, w = src.shape[:2]
    spec = spec or {}
    rects = [tuple(r) for r in spec.get("faces", [])]
    if model and not rects:
        rects = [r for r, _ in faces(model, brush, w, h, game)]
    isl = -np.ones((h, w), dtype=int)
    area = np.zeros((h, w), dtype=int)
    for i, (x0, y0, x1, y1) in enumerate(rects):
        a = (x1 - x0) * (y1 - y0)
        sl = (slice(max(y0, 0), min(y1, h)), slice(max(x0, 0), min(x1, w)))
        take = area[sl] < a
        isl[sl] = np.where(take, i, isl[sl])
        area[sl] = np.where(take, a, area[sl])
    alpha = src[..., 3] if src.shape[-1] == 4 else np.ones((h, w), np.float32)
    loose = (alpha >= 0.5) & (isl < 0)
    if loose.any():
        lab, _ = _components(loose)
        isl = np.where(loose, len(rects) + lab, isl)
    return isl


# --- building ----------------------------------------------------------------

def texel_px(spec):
    """Map pixels per art texel for this build."""
    return max(1, int(round(float(spec.get("texel_px", TEXEL_PX)) * lib.PX)))


def chamfer_islands(h, isl, px=1):
    """extrude.chamfer's box blur, reading only the pixel's own island and
    never wrapping, so a face runs flat to its edge."""
    out = h.copy()
    for _ in range(px):
        acc = np.zeros_like(out)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                acc += lib._island_shift(out, isl, dy, dx)
        out = acc / 9.0
    return out


def border_distance(isl):
    """Map pixels from each pixel to the nearest pixel of another island
    (or the image edge), Chebyshev, counted from 0 at the border pixel."""
    d = np.full(isl.shape, -1, dtype=np.int32)
    inside = isl >= 0
    edge = np.zeros(isl.shape, bool)
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
        pad = np.pad(isl, 1, constant_values=-2)[1 + dy:1 + dy + isl.shape[0],
                                                1 + dx:1 + dx + isl.shape[1]]
        edge |= inside & (pad != isl)
    d[edge] = 0
    front = edge
    k = 0
    while True:
        k += 1
        grow = np.zeros(isl.shape, bool)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                pad = np.pad(front, 1)[1 + dy:1 + dy + isl.shape[0], 1 + dx:1 + dx + isl.shape[1]]
                grow |= pad
        grow &= inside & (d < 0)
        if not grow.any():
            break
        d[grow] = k
        front = grow
    return d


def overlay_heights(src, spec, cls):
    """An overlay's height at the art's size: the surface it is drawn on
    stands at "surface", its own texels sink by material as usual."""
    hgt, pos, joints, mat = extrude.heights(src, spec, cls)
    alpha = src[..., 3]
    drawn = alpha >= 0.5
    hgt = np.where(drawn, hgt, float(spec.get("surface", 1.0))).astype(np.float32)
    return hgt, pos, joints, mat


def build(stem, out_dir, game=lib.DEFAULT_GAME, spec=None, model=None, brush=None):
    """Write the skin's three maps to out_dir and return lib's metrics."""
    spec = extrude.load_spec(stem, game) if spec is None else spec
    if model is None:
        model, b = model_of(stem, game)
        brush = b if brush is None else brush
    brush = brush or 0
    cls = spec.get("class") or extrude.stem_class(stem, game)
    _, _, strength, _ = extrude.CLASS_STYLE.get(cls, extrude.DEFAULT_STYLE)
    src = lib.load_source(stem, game)
    cell = texel_px(spec)
    # Strength is in 256 px node map pixels, where a texel is 16 of them;
    # here a texel is cell pixels, so the same rise per texel is this many.
    strength = float(spec.get("strength", strength)) * cell / 16.0
    if spec.get("overlay"):
        hgt, pos, joints, mat = overlay_heights(src, spec, cls)
    else:
        hgt, pos, joints, mat = extrude.heights(src, spec, cls)
    isl = face_map(src, model, brush, game, spec)
    up = lambda a: np.kron(a, np.ones((cell, cell), dtype=a.dtype))  # noqa: E731
    isl_hi = up(isl)
    hi = chamfer_islands(up(hgt), isl_hi, extrude.chamfer_px(spec, cell))

    sm, f0, metal, glow = extrude.surface(spec, cls, mat, pos, joints)
    emission = up(glow) if glow.max() > 0 else None
    smooth_hi = np.clip(up(sm), 0.0, lib.SMOOTH_CEILING)
    detail = np.zeros(hi.shape, np.float32)
    kind = extrude.micro_kind(stem, spec, cls)
    if kind in extrude.MICRO_KINDS:
        amp, swing = extrude.MICRO_KINDS[kind]
        amp *= float(spec.get("micro_strength", 1.0))
        # Micro features are sized in 256 px node map pixels, a texel being
        # 16 of them; a field cell * 16 wide puts the same features on the
        # same share of a skin texel. It tiles over the atlas; nothing
        # needs it to, but it does no harm either.
        size = cell * 16
        d, dsm = extrude.micro_field(kind, zlib.crc32(stem.encode()) & 0xffff, size=size,
                                     direction=spec.get("micro_dir", "h"))
        # A skin is several materials and one micro kind fits only some:
        # scratches belong on the golem's iron, not on its vines.
        only = spec.get("micro_materials")
        mask = up(np.isin(mat, only).astype(np.float32)) if only else 1.0
        detail += amp * extrude._fit(d, hi.shape) * mask
        smooth_hi = np.clip(smooth_hi + swing * extrude._fit(dsm, hi.shape) * mask, 0.0,
                            lib.SMOOTH_CEILING)
    if spec.get("face_edge", "flat") == "bevel":
        w = max(1.0, float(spec.get("bevel_px", BEVEL_PX)) * lib.PX)
        ramp = np.clip(1.0 - (border_distance(isl_hi) + 0.5) / w, 0.0, 1.0)
        detail -= float(spec.get("bevel_depth", BEVEL_DEPTH)) * ramp * (isl_hi >= 0)
    albedo = np.kron(src, np.ones((cell, cell, 1), dtype=src.dtype))
    return lib.pack(stem, out_dir, albedo, hi, smooth_hi, cls,
                    normal_strength=strength, metal_mask=up(metal), keep_mean=False,
                    emission=emission, f0=up(f0), fine_detail=1.0,
                    art_texels=src.shape[1], normal_detail=detail if detail.any() else None,
                    islands=isl_hi)


# --- judging -----------------------------------------------------------------

def _load(out_dir, stem, suffix, mode="RGBA"):
    from PIL import Image
    return np.asarray(Image.open(Path(out_dir) / (stem + suffix)).convert(mode)).astype(np.float32) / 255.0


def check(stem, out_dir, game=lib.DEFAULT_GAME, spec=None, model=None, brush=None):
    """Pass or fail lines for a built skin. Unlike extrude.check nothing
    is measured across the image's wrap or across an island border."""
    spec = extrude.load_spec(stem, game) if spec is None else spec
    if model is None:
        model, b = model_of(stem, game)
        brush = b if brush is None else brush
    cls = spec.get("class") or extrude.stem_class(stem, game)
    src = lib.load_source(stem, game)
    rows, cols = src.shape[:2]
    cell = texel_px(spec)
    n = _load(out_dir, stem, "_n.png")
    s = _load(out_dir, stem, "_s.png")
    alpha = src[..., 3]
    drawn = alpha >= 0.5
    isl = face_map(src, model, brush or 0, game, spec)
    lines = []

    def line(ok, text):
        lines.append(("ok   " if ok else "FAIL ") + text)

    line(n.shape[:2] == (rows * cell, cols * cell),
         "map %dx%d, %d px per art texel" % (n.shape[1], n.shape[0], cell))
    a = _load(out_dir, stem, ".png")
    line(a.shape[:2] == n.shape[:2] == s.shape[:2], "albedo, _n and _s the same size")

    # One height per texel away from its chamfer.
    edge = min(extrude.chamfer_px(spec, cell) + 1, (cell - 1) // 2)
    hmap = n[..., 3].reshape(rows, cell, cols, cell)[:, edge:cell - edge, :, edge:cell - edge]
    spread = hmap.max(axis=(1, 3)) - hmap.min(axis=(1, 3))
    share = float((spread[drawn] <= 2.5 / 255).mean()) if drawn.any() else 1.0
    line(share >= 0.98, "on the texel grid %.0f%% of drawn texels (want >= 98)" % (100 * share))

    tex_h = np.round(hmap.mean(axis=(1, 3)) * 255)[drawn]
    levels = len(np.unique(tex_h))
    modes = [m.get("mode", "shade") for m in (spec.get("materials") or {"b": {}}).values()]
    want = 1 if spec.get("overlay") else 3
    line("shade" not in modes or levels >= want, "%d distinct texel heights (want >= %d)" % (levels, want))

    # Depth: the tile measure, but differences only inside an island. The
    # entity shader marches no parallax, so this is the normal's slope per
    # height step, compared with the node pack's range.
    xy = n[..., :2] * 2 - 1
    nz = np.sqrt(np.clip(1 - (xy ** 2).sum(-1), 1e-4, 1))
    hh = n[..., 3]
    isl_hi = np.kron(isl, np.ones((cell, cell), dtype=int))
    gx = lib.island_gradient(hh, isl_hi, 1)
    gy = lib.island_gradient(hh, isl_hi, 0)
    g = np.abs(gx) + np.abs(gy)
    r = ((np.abs(xy[..., 0]) + np.abs(xy[..., 1])) / nz / np.maximum(g, 1e-6))[g > 0.01]
    # In node units: the rise of the full range per texel, times 16 texels.
    depth = float(np.median(r)) / cell / 16.0 if r.size >= 100 else 0.0
    line(spec.get("overlay") or 0.02 <= depth <= 0.105,
         "relief %.3f node equivalent (want 0.02 to 0.10)" % depth)

    # No step at an island border: the height on either side of a border
    # differs only as the art says, so the normal at a border pixel must
    # not carry a slope towards the other island. Measured as the normal's
    # tilt in the outermost pixel ring of every face against the ring
    # inside it, without a bevel; with one the ring is the bevel and must
    # tilt outward the same everywhere.
    bd = border_distance(isl_hi)
    up_drawn = np.kron(drawn, np.ones((cell, cell), bool))
    ring = (bd == 0) & up_drawn
    # Just inside means past the bevel, where there is one.
    bevel = spec.get("face_edge", "flat") == "bevel"
    reach = int(np.ceil(max(1.0, float(spec.get("bevel_px", BEVEL_PX)) * lib.PX))) if bevel else 1
    inner = (bd == reach + 1) & up_drawn
    tilt = np.sqrt((xy ** 2).sum(-1))
    if bevel and ring.any():
        # Outward is down the border distance's gradient; in the normal's
        # frame x is image x and y is image up.
        bdf = bd.astype(np.float32)
        gxb = lib.island_gradient(bdf, isl_hi, 1)
        gyb = lib.island_gradient(bdf, isl_hi, 0)
        out = (xy[..., 0] * -gxb + xy[..., 1] * gyb) > 0.02
        share = float(out[ring].mean())
        line(share >= 0.95 and tilt[ring].mean() >= tilt[inner].mean() + 0.05,
             "bevel leans outward at %.0f%% of face border pixels, tilt %.2f against %.2f"
             " inside (want >= 95%%, steeper)" % (100 * share, tilt[ring].mean(), tilt[inner].mean()))
    else:
        rmean = float(tilt[ring].mean()) if ring.any() else 0.0
        imean = float(tilt[inner].mean()) if inner.any() else 0.0
        line(rmean <= imean + 0.03, "face border tilt %.3f against %.3f just inside (want no step)"
             % (rmean, imean))

    # Occlusion is not darker at a face border than inside it.
    ao = n[..., 2]
    if ring.any() and inner.any():
        line(ao[ring].mean() >= ao[inner].mean() - 0.02,
             "occlusion at face borders %.2f, inside %.2f" % (ao[ring].mean(), ao[inner].mean()))

    sm = s[..., 0][up_drawn] if up_drawn.any() else s[..., 0].ravel()
    line(sm.max() <= 0.951, "smoothness %.2f to %.2f, mean %.2f" % (sm.min(), sm.max(), sm.mean()))
    metal = (s[..., 1] >= 0.898) & up_drawn
    if metal.any():
        # Metal albedo is reflectance: a near black metal texel renders as a
        # black mirror (the hopper). Report the darkest metal texel.
        lum = lib.luminance(a[..., :3])[metal]
        line(float(np.percentile(lum, 1)) >= 0.2,
             "metal on %.0f%% of drawn, darkest 1%% lum %.2f (want >= 0.20)"
             % (100 * metal.sum() / up_drawn.sum(), float(np.percentile(lum, 1))))

    holes = ~up_drawn
    if holes.any():
        nn = np.array(lib.pbr_bake.NEUTRAL_N, np.float32) / 255.0
        ns = np.array(lib.pbr_bake.NEUTRAL_S, np.float32) / 255.0
        line(bool(np.all(np.abs(n[holes] - nn) < 1.5 / 255)), "transparent texels flat normal")
        line(bool(np.all(np.abs(s[holes] - ns) < 1.5 / 255)), "transparent texels default _s")
    # The release gate, on the same files. Its wrap seam warning measures a
    # tile's repeat, which an atlas never does.
    g = extrude._gate()
    rep = g.inspect(stem, Path(out_dir) / (stem + "_n.png"), Path(out_dir) / (stem + "_s.png"),
                    cls, lib.source_path(stem, game), Path(out_dir) / (stem + ".png"), None)
    for f in rep["failures"]:
        line(False, "gate: " + f)
    for w in rep["warnings"]:
        lines.append("note gate: " + w + (" (an atlas does not tile)" if "wrap" in w else ""))
    nfaces = len(spec.get("faces") or faces(model, brush or 0, cols, rows, game))
    lines.append("note %d faces, %d drawn texels outside every face (their own islands)"
                 % (nfaces, int((drawn & (isl >= nfaces)).sum())))
    return lines


# --- previews ------------------------------------------------------------------

def previews(stem, out_dir, dest, scale=1):
    """Flat atlas previews (no tiling): height, normal, smoothness, a lit
    view, and a contact sheet of all of them beside the albedo."""
    from PIL import Image
    dest = Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    n = _load(out_dir, stem, "_n.png")
    s = _load(out_dir, stem, "_s.png")
    a = _load(out_dir, stem, ".png")
    xy = n[..., :2] * 2.0 - 1.0
    z = np.sqrt(np.clip(1.0 - (xy ** 2).sum(-1), 0.0, 1.0))
    nrm = np.stack([xy[..., 0], xy[..., 1], z], -1)
    l = np.array((0.5, -0.4, 0.75), np.float32)
    l /= np.linalg.norm(l)
    ndl = np.clip((nrm * l).sum(-1), 0.0, 1.0)
    hv = l + np.array([0.0, 0.0, 1.0])
    hv /= np.linalg.norm(hv)
    ndh = np.clip((nrm * hv).sum(-1), 0.0, 1.0)
    shin = 2.0 + 200.0 * s[..., 0] ** 2
    metal = s[..., 1:2] >= 0.898
    # Metal reflects in its albedo's colour, a dielectric at 4%.
    f = np.where(metal, a[..., :3], 0.04)
    spec = (ndh ** shin)[..., None] * f * (shin + 8)[..., None] / 8 * 0.25
    diffuse = np.where(metal, 0.15, 1.0) * a[..., :3]
    lit = diffuse * (0.25 * n[..., 2:3] + 0.9 * ndl[..., None]) + spec
    lit = np.clip(lit, 0, 1) ** (1 / 2.2)
    grey = lambda v: np.repeat(v[..., None], 3, -1)  # noqa: E731
    panels = {
        "albedo": np.where(a[..., 3:4] < 0.5, 0.18, a[..., :3]),
        "height": grey(n[..., 3]),
        "normal": np.concatenate([n[..., :2], np.ones(n.shape[:2] + (1,), np.float32)], -1),
        "ao": grey(n[..., 2]),
        "smooth": grey(s[..., 0]),
        "metal": np.where(metal, np.array([0.9, 0.75, 0.3]), grey(s[..., 1] * 4).clip(0, 1)),
        "lit": np.where(a[..., 3:4] < 0.5, 0.18, lit),
    }
    paths = []
    for k, v in panels.items():
        im = Image.fromarray((np.clip(v, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
        if scale != 1:
            im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
        p = dest / ("%s.%s.png" % (stem, k))
        im.save(p)
        paths.append(p)
    # Contact sheet: two rows of four, the last cell the lit view again at
    # the albedo's side for a direct comparison.
    order = ["albedo", "lit", "height", "normal", "ao", "smooth", "metal"]
    h, w = n.shape[:2]
    gap = 8
    sheet = np.full((2 * h + 3 * gap, 4 * w + 5 * gap, 3), 0.1, np.float32)
    for i, k in enumerate(order):
        r, c = divmod(i, 4)
        y, x = gap + r * (h + gap), gap + c * (w + gap)
        sheet[y:y + h, x:x + w] = np.clip(panels[k], 0, 1)
    p = dest / ("%s.sheet.png" % stem)
    Image.fromarray((sheet * 255 + 0.5).astype(np.uint8), "RGB").save(p)
    paths.append(p)
    return paths


def print_faces(stem, game=lib.DEFAULT_GAME):
    """The skin's faces and, per face, its palette as a character map, for
    an author writing a spec."""
    model, brush = model_of(stem, game)
    src = lib.load_source(stem, game)
    h, w = src.shape[:2]
    rgb = np.clip(np.round(src[..., :3] * 255.0), 0, 255).astype(int)
    drawn = src[..., 3] >= 0.5
    cols, inv = np.unique(rgb[drawn], axis=0, return_inverse=True)
    idx = -np.ones((h, w), dtype=int)
    idx[drawn] = inv.ravel()
    sym = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    for i, c in enumerate(cols):
        print("%s #%02x%02x%02x lum %.2f n %d" % (sym[i % len(sym)], *c,
              lib.luminance(c / 255.0), int((idx == i).sum())))
    for r, cnt in faces(model, brush, w, h, game):
        x0, y0, x1, y1 = r
        print("face %s, %d triangles" % (list(r), cnt))
        for y in range(y0, y1):
            print("  " + "".join(sym[idx[y, x] % len(sym)] if idx[y, x] >= 0 else "."
                                 for x in range(x0, x1)))


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("out_dir")
    ap.add_argument("stems", nargs="+")
    ap.add_argument("--game", default=lib.DEFAULT_GAME)
    ap.add_argument("--faces", action="store_true", help="print faces and palettes and stop")
    ap.add_argument("--preview", default=None, help="write previews into this directory")
    a = ap.parse_args()
    for s in a.stems:
        if a.faces:
            print("==", s)
            print_faces(s, a.game)
            continue
        build(s, a.out_dir, a.game)
        lines = check(s, a.out_dir, a.game)
        if a.preview:
            previews(s, a.out_dir, a.preview)
        bad = [l for l in lines if l.startswith("FAIL")]
        print("%-44s %s" % (s, "pass" if not bad else "; ".join(l[5:] for l in bad)))
        for l in lines:
            print("    " + l)
