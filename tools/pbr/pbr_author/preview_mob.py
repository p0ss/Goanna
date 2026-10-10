"""Offline three quarter view of any mob model with authored maps.

preview_figure.py draws the default player's front. This draws any .b3d
the game draws a skin on, from the front and one side, so an agent can
judge a mob's maps without a GPU:

  geometry every triangle of the model in its stored (bind) pose, read with
           atlas.py's model reading, from every brush given a texture,
           rasterised orthographically into a z buffer with back faces
           culled (Luanti culls them on mesh entities by default). Luanti's
           model space is left handed, so x is reflected for the view, as
           in preview_figure.py; the outward normal comes from the file's
           winding before the reflection. A pixel of a layer with albedo
           alpha under 0.5 lets the face behind show.
  view     from the model's front (model +Z, which is where an entity with
           yaw 0 and mcl_mobs "rotate" 0 looks) turned --yaw degrees
           (default 35) toward model +X and --pitch degrees (default 20)
           down, so the front and one side show. --turn rotates the model
           first, for a model whose front is not +Z.
  albedo   each brush's layer string, as Luanti evaluates the plain forms:
           a ^ stack of images and bracketed tinted masks
           (mask.png^[colorize:#rrggbb:alpha), colorize as apply_colorize
           with keep_alpha and every ^ as blit_pixel, integer for integer.
           "blank.png", or no string, leaves a brush undrawn.
  maps     composited as src/goanna_overlay_companions.h does (the same
           rule as preview_figure.py): each layer's companions are its own
           image's, or for a mask the part's; a layer with none is neutral
           (flat, rough); the first layer covers everything and each later
           one goes over by its albedo alpha; _n mixes in all four
           channels, of _s only the smoothness mixes, and F0, scattering
           and emission come from the topmost layer covering a pixel at
           0.5 or more. Every input is sampled nearest at the largest size.
  decode   red above 128 tilts the normal toward +U (image right), green
           above 128 toward the top of the image, no flip
           (docs/systems/materials.md, entities). The tangent frame is per
           triangle from its positions and UVs, so a mirrored limb's
           normal is mirrored as on the model.
  shading  in linear light: a sun (direct, the material occlusion at 0.4
           of its effect); a sky ambient by normal (zenith blue, horizon
           pale, ground dim), fully occluded by the material occlusion; a
           crude sky reflection, the same sky looked up by the reflected
           view direction and blurred toward its average with roughness,
           weighted by Schlick Fresnel (with roughness) on F0, so a smooth
           or metal surface shows the sky; a GGX specular from the sun,
           roughness (1 - smoothness) squared, Smith visibility. F0 is the
           _s green byte, or for a metal (230 and above) the albedo. A
           pixel whose _s blue byte says it scatters gets a wrapped
           diffuse term. Then clipped and encoded as sRGB.

What it does not model, so do not read these off it: shadows (no box
shadows another), any reflection other than the sky gradient (no ground,
no other boxes), animation (the bind pose only, which for some models is
not the pose the game shows at rest, and a mesh node's own transform is
not applied: the script stops on one that is not the identity),
transparency (alpha is clipped at 0.5, not blended), mipmapping and
filtering (nearest at the map's resolution, as close up), the client's
tone mapping, exposure, fog and post process, perspective, and the entity
shader itself. It judges what the maps contain, not how the game looks.

--parallax marches the stored height (the _n alpha) the way the entity
shader does (project/shaders/entity_common.gdshaderinc): the depth in
nodes measured from each brush's composited _n as the client measures it
(reliefDepth in src/goanna_textures.cpp, over the model's faces), the
march along the view clamped inside each face's UV rectangle, the chord
refinement, the pull back from a transparent hit, and the self shadow
toward the sun folded into the occlusion. It is crude: nearest sampling,
32 fixed steps, no fade with distance and no mipmaps, so it shows the
march at its closest. A height below the top of the range is seen sunk
below the box's face, and where the march reaches a face's edge the edge
texel is drawn stretched, as in the game; a material that should sit on
the surface belongs near 1.

--contrast prints, per visible face, the luminance's relative contrast
(std over mean, after a box blur one art texel wide, inside the face away
from its bevel) with maps on over maps off, for the high and the low sun.
The blur stands in for viewing distance only roughly: the client's mip
chain averages sub-texel detail further than this does, and the sky here
is a gradient, so glare off a smooth face is under-reported too. --crop
writes crop.png, one face three times enlarged.

--legibility, with --parallax, prints per visible face how much of the
art survives the march: the share of art texels that keep at least half
the pixels they cover on the flat face, and the distinct colours shown.
A raised texel sliding over a lower neighbour at an angle hides it; the
GPU review of 2026-10-02 saw the creeper's darker greens vanish that way.
Heights are marched lifted per face, as the client does since it lifts
each face's highest texel onto the face.

Writes into <out dir>:
  maps_on.png           sun high, from the front and the visible side
  maps_off.png          the same with every map neutral (flat, rough)
  low_sun.png           sun low from the hidden side, grazing the front,
                        to show weave, fur, scales and creases
  low_sun_maps_off.png
  compare.png           maps off, maps on, low sun on, low sun off, side
                        by side, the order preview_figure.py uses
  crop.png              with --crop: maps off, maps on, low sun on
  night.png             with --night: the lamp lit view, and
  night_maps_off.png    the same with maps neutral; crop_night.png with
                        --crop, maps off then on

    python3 tools/pbr/pbr_author/preview_mob.py <model.b3d> <maps dir> <out dir> \\
        <layers for brush 0> [<layers for brush 1> ...]

for example

    python3 tools/pbr/pbr_author/preview_mob.py mobs_mc_iron_golem.b3d maps out \\
        mobs_mc_iron_golem.png blank.png
"""
import argparse
import re
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import atlas  # noqa: E402
import lib  # noqa: E402

NEUTRAL_N = (128, 128, 255, 255)
NEUTRAL_S = (0, 10, 0, 255)

# Sky radiance in linear light by direction's height: below, at, above
# the horizon.
SKY_ZENITH = np.array((0.30, 0.45, 0.80))
SKY_HORIZON = np.array((0.75, 0.80, 0.85))
SKY_GROUND = np.array((0.22, 0.20, 0.18))


# --- the layer string and the maps ---------------------------------------------

def parse_layers(texture):
    """[(image stem, tint or None)] bottom first. Plain images and
    bracketed tinted masks only; anything else stops the script."""
    out = []
    for part in re.findall(r"\([^)]*\)|[^\^()]+", texture):
        part = part.strip("()")
        m = re.match(r"([\w.]+)\.png(?:\^\[colorize:#([0-9A-Fa-f]{6})[0-9A-Fa-f]{0,2}:alpha)?$", part)
        if not m:
            raise SystemExit("not a plain layer: %r" % part)
        out.append((m.group(1), "#" + m.group(2) if m.group(2) else None))
    return out


def load8(path):
    return np.asarray(Image.open(path).convert("RGBA")).astype(np.int64)


def companion(maps, image, suffix):
    """The client's lookup: the image's own name, then for a mask the part's."""
    names = [image]
    if image.endswith("_mask"):
        names.append(image[:-5])
    for n in names:
        p = Path(maps) / (n + suffix + ".png")
        if p.exists():
            return load8(p)
    return None


def nearest(img, h, w):
    ys = (np.arange(h) * img.shape[0]) // h
    xs = (np.arange(w) * img.shape[1]) // w
    return img[ys][:, xs]


def composite(texture, maps, game, maps_on=True):
    """(albedo RGBA 0..1 at the art's size, _n and _s bytes at the
    largest size)."""
    albedo = None
    alphas, comps = [], []
    for image, tint in parse_layers(texture):
        a = load8(lib.source_path(image, game))
        if tint:
            a = atlas._colorize_alpha(a, tint)
        if albedo is not None and a.shape[:2] != albedo.shape[:2]:
            a = nearest(a, *albedo.shape[:2])
        albedo = a if albedo is None else atlas._blit(a, albedo)
        alphas.append(a[..., 3] / 255.0)
        comps.append((companion(maps, image, "_n"), companion(maps, image, "_s"))
                     if maps_on else (None, None))
    sizes = [c.shape[:2] for pair in comps for c in pair if c is not None]
    sizes.append(albedo.shape[:2])
    H, W = max(s[0] for s in sizes), max(s[1] for s in sizes)
    N = np.zeros((H, W, 4))
    S = np.zeros((H, W, 4))
    for i, ((cn, cs), al) in enumerate(zip(comps, alphas)):
        n = nearest(cn, H, W).astype(np.float64) if cn is not None else np.broadcast_to(
            np.array(NEUTRAL_N, np.float64), (H, W, 4))
        s = nearest(cs, H, W).astype(np.float64) if cs is not None else np.broadcast_to(
            np.array(NEUTRAL_S, np.float64), (H, W, 4))
        if i == 0:
            N[:] = n
            S[:] = s
            continue
        m = nearest(al, H, W)[..., None]
        N = N * (1 - m) + n * m
        S[..., 0] = S[..., 0] * (1 - m[..., 0]) + s[..., 0] * m[..., 0]
        top = m[..., 0] >= 0.5
        S[..., 1:] = np.where(top[..., None], s[..., 1:], S[..., 1:])
    return albedo / 255.0, np.round(N), np.round(S)


# --- the model -------------------------------------------------------------------

def check_mesh_nodes(path):
    """Stop on a mesh whose node carries a transform: the vertices are
    used as stored, which is right only when it is the identity."""
    b = Path(path).read_bytes()
    ident = (0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0)

    def walk(off, end, chain):
        for tag, s, e in atlas._chunks(b, off, end):
            if tag == "BB3D":
                walk(s + 4, e, chain)
            elif tag == "NODE":
                z = b.index(b"\0", s)
                f = struct.unpack("<10f", b[z + 1:z + 41])
                here = chain + [f]
                if any(t == "MESH" for t, _, _ in atlas._chunks(b, z + 41, e)):
                    for g in here:
                        if not np.allclose(g, ident, atol=1e-5):
                            raise SystemExit("%s: a mesh node has a transform this preview "
                                             "does not apply" % path)
                walk(z + 41, e, here)
    walk(0, len(b), [])


def triangles(model, brushes, game):
    """Per brush with a texture: [(positions, uvs, outward normal)] in a
    right handed model space (x reflected)."""
    path = atlas.model_path(model, game)
    check_mesh_nodes(path)
    flip = np.array((-1.0, 1.0, 1.0))
    out = {b: [] for b in brushes}
    for pos, uv, tris in atlas.read_b3d(path):
        for b, idx in tris:
            b = max(b, 0)
            if b not in out:
                continue
            for t in idx:
                p = pos[t].astype(np.float64)
                n = np.cross(p[1] - p[0], p[2] - p[0])
                ln = np.linalg.norm(n)
                if ln < 1e-12:
                    continue
                out[b].append((p * flip, uv[t].astype(np.float64), (n / ln) * flip))
    return out


def view_basis(yaw, pitch, turn):
    """(rotation applied to the model, camera right, up, toward the
    viewer), in the right handed space. The view starts at the model's
    front, model +Z, and swings yaw degrees toward model +X, which after
    the reflection is view -x."""
    t = np.radians(turn)
    rot = np.array(((np.cos(t), 0, np.sin(t)), (0, 1, 0), (-np.sin(t), 0, np.cos(t))))
    y, p = np.radians(yaw), np.radians(pitch)
    toward = np.array((-np.sin(y) * np.cos(p), np.sin(p), np.cos(y) * np.cos(p)))
    fwd = -toward
    right = np.cross(fwd, (0.0, 1.0, 0.0))
    right /= np.linalg.norm(right)
    up = np.cross(right, fwd)
    return rot, right, up, toward


def units_per_texel(tris_by_brush, sizes):
    """Median model units per art texel, from each triangle's dP/du."""
    vals = []
    for b, tris in tris_by_brush.items():
        w = sizes[b][1]
        for p, uv, _ in tris:
            e = np.stack([p[1] - p[0], p[2] - p[0]], 1)
            duv = np.stack([uv[1] - uv[0], uv[2] - uv[0]], 1)
            if abs(np.linalg.det(duv)) < 1e-12:
                continue
            dpdu = (e @ np.linalg.inv(duv))[:, 0]
            vals.append(np.linalg.norm(dpdu) / w)
    return float(np.median(vals)) if vals else 1.0


def rasterise(tris_by_brush, layers, basis, ppu, margin):
    """Per screen pixel: albedo, _n, _s and the tangent frame in view
    space (x right, y up, z toward the viewer), or nothing."""
    rot, right, up, toward = basis
    M = np.stack([right, up, toward])  # model to view
    allp = np.concatenate([t[0] for tris in tris_by_brush.values() for t in tris]) @ rot.T @ M.T
    x0, x1 = allp[:, 0].min(), allp[:, 0].max()
    y0, y1 = allp[:, 1].min(), allp[:, 1].max()
    W = int(np.ceil((x1 - x0) * ppu)) + 2 * margin
    H = int(np.ceil((y1 - y0) * ppu)) + 2 * margin
    depth = np.full((H, W), -np.inf)
    out = {"a": np.zeros((H, W, 3)), "n": np.zeros((H, W, 4)), "s": np.zeros((H, W, 4)),
           "T": np.zeros((H, W, 3)), "B": np.zeros((H, W, 3)), "F": np.zeros((H, W, 3)),
           "hit": np.zeros((H, W), bool),
           # What march() and the contrast measure need: the UV, dP/du and
           # dP/dv in view space, the face's UV rectangle, its brush and
           # an id per face.
           "uv": np.zeros((H, W, 2)), "dpdu": np.zeros((H, W, 3)), "dpdv": np.zeros((H, W, 3)),
           "rect": np.zeros((H, W, 4)), "brush": np.full((H, W), -1), "face": np.full((H, W), -1)}
    face_ids = {}
    for b, tris in tris_by_brush.items():
        albedo, N, S = layers[b]
        ah, aw = albedo.shape[:2]
        mh, mw = N.shape[:2]
        for p0, uv, fn0 in tris:
            p = p0 @ rot.T @ M.T
            fn = M @ (rot @ fn0)
            if fn[2] <= 1e-6:
                continue
            sx = (p[:, 0] - x0) * ppu + margin
            sy = (y1 - p[:, 1]) * ppu + margin
            bx0, bx1 = max(int(np.floor(sx.min())), 0), min(int(np.ceil(sx.max())), W)
            by0, by1 = max(int(np.floor(sy.min())), 0), min(int(np.ceil(sy.max())), H)
            if bx1 <= bx0 or by1 <= by0:
                continue
            yy, xx = np.mgrid[by0:by1, bx0:bx1] + 0.5
            d = (sy[1] - sy[2]) * (sx[0] - sx[2]) + (sx[2] - sx[1]) * (sy[0] - sy[2])
            if abs(d) < 1e-9:
                continue
            l0 = ((sy[1] - sy[2]) * (xx - sx[2]) + (sx[2] - sx[1]) * (yy - sy[2])) / d
            l1 = ((sy[2] - sy[0]) * (xx - sx[2]) + (sx[0] - sx[2]) * (yy - sy[2])) / d
            l2 = 1 - l0 - l1
            inside = (l0 >= -1e-6) & (l1 >= -1e-6) & (l2 >= -1e-6)
            if not inside.any():
                continue
            u = l0 * uv[0, 0] + l1 * uv[1, 0] + l2 * uv[2, 0]
            v = l0 * uv[0, 1] + l1 * uv[1, 1] + l2 * uv[2, 1]
            z = l0 * p[0, 2] + l1 * p[1, 2] + l2 * p[2, 2]
            # UVs at exactly 1.0 sample the last texel, as clamp would.
            ai = (np.clip(np.floor(v * ah).astype(int), 0, ah - 1),
                  np.clip(np.floor(u * aw).astype(int), 0, aw - 1))
            mi = (np.clip(np.floor(v * mh).astype(int), 0, mh - 1),
                  np.clip(np.floor(u * mw).astype(int), 0, mw - 1))
            alpha = albedo[ai][..., 3]
            ys, xs = np.nonzero(inside & (alpha >= 0.5))
            if not len(ys):
                continue
            Y, X = ys + by0, xs + bx0
            nearer = z[ys, xs] > depth[Y, X]
            ys, xs, Y, X = ys[nearer], xs[nearer], Y[nearer], X[nearer]
            depth[Y, X] = z[ys, xs]
            out["a"][Y, X] = albedo[ai][ys, xs, :3]
            out["n"][Y, X] = N[mi][ys, xs]
            out["s"][Y, X] = S[mi][ys, xs]
            e = np.stack([p[1] - p[0], p[2] - p[0]], 1)
            duv = np.stack([uv[1] - uv[0], uv[2] - uv[0]], 1)
            if abs(np.linalg.det(duv)) < 1e-12:
                T = np.cross((0.0, 1.0, 0.0), fn)
                T = T / (np.linalg.norm(T) + 1e-9)
                Bv = np.cross(fn, T)
                dpdu = dpdv = np.zeros(3)
            else:
                dpdu, dpdv = (e @ np.linalg.inv(duv)).T
                T = dpdu / np.linalg.norm(dpdu)
                Bv = dpdv / np.linalg.norm(dpdv)
            rect = (uv[:, 0].min(), uv[:, 1].min(), uv[:, 0].max(), uv[:, 1].max())
            key = (b,) + tuple(np.round(rect, 6)) + tuple(np.round(fn, 3))
            out["uv"][Y, X, 0] = u[ys, xs]
            out["uv"][Y, X, 1] = v[ys, xs]
            out["dpdu"][Y, X] = dpdu
            out["dpdv"][Y, X] = dpdv
            out["rect"][Y, X] = rect
            out["brush"][Y, X] = b
            out["face"][Y, X] = face_ids.setdefault(key, len(face_ids))
            out["T"][Y, X] = T
            out["B"][Y, X] = Bv
            out["F"][Y, X] = fn
            out["hit"][Y, X] = True
    return out


# --- parallax ------------------------------------------------------------------

def relief_depth(N, tris, art_w):
    """The client's measure of a skin's depth in nodes (reliefDepth in
    src/goanna_textures.cpp): the median ratio of the normal's slope to the
    height's gradient inside each face, every second pixel, over the map
    pixels a node spans (sixteen art texels), capped at 0.10."""
    mh, mw = N.shape[:2]
    isl = -np.ones((mh, mw), int)
    for i, (_, uv, _) in enumerate(tris):
        x0 = max(0, int(np.ceil(uv[:, 0].min() * mw - 0.5)))
        x1 = min(mw, int(np.ceil(uv[:, 0].max() * mw - 0.5)))
        y0 = max(0, int(np.ceil(uv[:, 1].min() * mh - 0.5)))
        y1 = min(mh, int(np.ceil(uv[:, 1].max() * mh - 0.5)))
        isl[y0:y1, x0:x1] = i
    n = N / 255.0
    nx, ny = n[..., 0] * 2 - 1, n[..., 1] * 2 - 1
    nz = np.sqrt(np.clip(1 - nx * nx - ny * ny, 1e-4, 1))
    gx = lib.island_gradient(n[..., 3].astype(np.float32), isl, 1)
    gy = lib.island_gradient(n[..., 3].astype(np.float32), isl, 0)
    g = (np.abs(gx) + np.abs(gy))[::2, ::2]
    keep = (g > 0.01) & (isl[::2, ::2] >= 0)
    r = ((np.abs(nx) + np.abs(ny)) / nz)[::2, ::2][keep] / g[keep]
    if r.size < 100:
        return 0.0
    return float(min(0.10, np.median(r) / (16.0 * mw / art_w)))


def _lookup(img, uv):
    h, w = img.shape[:2]
    return img[np.clip(np.floor(uv[..., 1] * h).astype(int), 0, h - 1),
               np.clip(np.floor(uv[..., 0] * w).astype(int), 0, w - 1)]


def face_lift(N, albedo, rects):
    """Per pixel, 1 minus the highest stored height over the drawn texels
    of its face, which the client adds to every height it marches so a
    face's highest texel sits on the face (lift_tex in
    entity_common.gdshaderinc, built in src/goanna_entities.cpp)."""
    mh, mw = N.shape[:2]
    a = nearest(albedo[..., 3], mh, mw) >= 0.5
    keys, inv = np.unique(np.round(rects, 6), axis=0, return_inverse=True)
    out = np.zeros(len(keys))
    for i, (u0, v0, u1, v1) in enumerate(keys):
        x0, x1 = int(round(u0 * mw)), max(int(round(u1 * mw)), int(round(u0 * mw)) + 1)
        y0, y1 = int(round(v0 * mh)), max(int(round(v1 * mh)), int(round(v0 * mh)) + 1)
        hh = N[y0:y1, x0:x1, 3][a[y0:y1, x0:x1]]
        out[i] = 1.0 - hh.max() / 255.0 if hh.size else 0.0
    return out[inv.ravel()]


def march(r, layers, depths, steps=32):
    """A crude parallax occlusion march, the entity shader's
    (project/shaders/entity_common.gdshaderinc): from each pixel's UV,
    along the view's slope through the height (1 - the _n alpha) at
    depths[brush] nodes, clamped inside the face's own UV rectangle, with
    the same chord refinement and the same pull back from a transparent
    hit. Then albedo, _n and _s are read again at the marched UV. Nearest
    sampling, a fixed step count, no fade with distance. Heights are read
    lifted per face as the client lifts them (face_lift). Returns a copy of
    r with the march's state kept for shadow()."""
    r = {k: (v.copy() if isinstance(v, np.ndarray) else v) for k, v in r.items()}
    r["d_hit"] = np.zeros(r["hit"].shape)
    r["depth"] = np.zeros(r["hit"].shape)
    r["shadow_ok"] = r["hit"].copy()
    for b, (albedo, N, S) in layers.items():
        sel = r["hit"] & (r["brush"] == b) & (depths.get(b, 0.0) > 0)
        if not sel.any():
            continue
        ah, aw = albedo.shape[:2]
        F, du, dv = r["F"][sel], r["dpdu"][sel], r["dpdv"][sel]
        uv0 = r["uv"][sel]
        rect = r["rect"][sel]
        lu = np.maximum((du * du).sum(-1), 1e-12)
        lv = np.maximum((dv * dv).sum(-1), 1e-12)
        vn_raw = F[:, 2]
        vn = np.maximum(vn_raw, 0.08)
        vt = np.array((0.0, 0.0, 1.0)) - F * vn_raw[:, None]
        texel = 0.5 * (np.sqrt(lu) / aw + np.sqrt(lv) / ah)
        depth = depths[b] * 16.0 * texel
        slope = np.stack([(vt * du).sum(-1) / lu, (vt * dv).sum(-1) / lv], -1) * (depth / vn)[:, None]
        inset = 0.005 / np.array((aw, ah))
        lo = rect[:, :2] + inset
        hi = np.maximum(rect[:, 2:] - inset, lo)
        lift = face_lift(N, albedo, rect)
        height = lambda q: np.maximum(1.0 - lift - _lookup(N, q)[..., 3] / 255.0, 0.0)  # noqa: E731
        d = np.zeros(len(uv0))
        d_prev = d.copy()
        uv = np.clip(uv0, lo, hi)
        h = height(uv)
        h_prev = h.copy()
        dd = 1.0 / steps
        for _ in range(steps):
            go = d < h
            if not go.any():
                break
            d_prev = np.where(go, d, d_prev)
            h_prev = np.where(go, h, h_prev)
            d = np.where(go, d + dd, d)
            uv = np.where(go[:, None], np.clip(uv0 - slope * d[:, None], lo, hi), uv)
            h = np.where(go, height(uv), h)
        below = d - h
        above = h_prev - d_prev
        w = below / np.maximum(below + above, 1e-5)
        d_hit = d + (d_prev - d) * w
        puv = np.clip(uv0 - slope * d_hit[:, None], lo, hi)
        ok = np.ones(len(uv0), bool)
        holes = _lookup(albedo, puv)[..., 3] < 0.5
        if holes.any():
            t_in, t_out = np.zeros(holes.sum()), np.ones(holes.sum())
            a0, a1 = uv0[holes], puv[holes]
            for _ in range(4):
                t = 0.5 * (t_in + t_out)
                inside = _lookup(albedo, a0 + (a1 - a0) * t[:, None])[..., 3] >= 0.5
                t_in = np.where(inside, t, t_in)
                t_out = np.where(inside, t_out, t)
            puv[holes] = a0 + (a1 - a0) * t_in[:, None]
            ok[holes] = False
        r["uv"][sel] = puv
        r["a"][sel] = _lookup(albedo, puv)[..., :3]
        r["n"][sel] = _lookup(N, puv)
        r["s"][sel] = _lookup(S, puv)
        r["d_hit"][sel] = d_hit
        r["depth"][sel] = depth
        r["shadow_ok"][sel] = ok
        r.setdefault("lo", np.zeros(r["hit"].shape + (2,)))[sel] = lo
        r.setdefault("hi", np.zeros(r["hit"].shape + (2,)))[sel] = hi
        r.setdefault("_N", {})[b] = N
        r.setdefault("lift", np.zeros(r["hit"].shape))[sel] = lift
    return r


def shadow(r, sun_view, up_view, strength=0.85):
    """The march's self shadow toward the sun, as the shader climbs it:
    eight steps from the hit, clamped to the face, 1 lit to 0.15 shadowed."""
    out = np.ones(r["hit"].shape)
    if "_N" not in r:
        return out
    L = np.asarray(sun_view, np.float64)
    L = L / np.linalg.norm(L)
    if float(np.dot(L, up_view)) <= 0.02:
        return out
    for b, N in r["_N"].items():
        sel = r["hit"] & (r["brush"] == b) & r["shadow_ok"] & (r["depth"] > 0)
        F = r["F"][sel]
        sn = F @ L
        sel_idx = np.nonzero(sel)
        keep = sn > 0.05
        if not keep.any():
            continue
        Y, X = sel_idx[0][keep], sel_idx[1][keep]
        F, sn = F[keep], sn[keep]
        du, dv = r["dpdu"][Y, X], r["dpdv"][Y, X]
        lu = np.maximum((du * du).sum(-1), 1e-12)
        lv = np.maximum((dv * dv).sum(-1), 1e-12)
        st = L - F * sn[:, None]
        sslope = np.stack([(st * du).sum(-1) / lu, (st * dv).sum(-1) / lv], -1) * (r["depth"][Y, X] / sn)[:, None]
        d_hit = r["d_hit"][Y, X]
        puv, lo, hi = r["uv"][Y, X], r["lo"][Y, X], r["hi"][Y, X]
        blocked = np.zeros(len(Y))
        k = np.zeros(len(Y))
        dk = d_hit / 8.0
        for _ in range(8):
            k = k + dk
            hs = np.maximum(1.0 - r["lift"][Y, X]
                            - _lookup(N, np.clip(puv + sslope * k[:, None], lo, hi))[..., 3] / 255.0, 0.0)
            blocked = np.maximum(blocked, (d_hit - k) - hs)
        out[Y, X] = 1.0 - np.clip(blocked * 6.0, 0.0, 1.0) * strength
    return out


# --- contrast -------------------------------------------------------------------

def face_contrast(img, r, texel, min_texels=6):
    """Per visible face: the relative contrast of its luminance (std over
    mean) after a box blur one art texel wide, reading only the face's own
    pixels, over the pixels far enough inside its border that the blur
    does not reach a box edge's bevel (atlas.py's, a fifth of a texel at
    most). {face id: contrast}, for faces showing at least min_texels
    texels."""
    from scipy import ndimage
    lum = lib.luminance(np.clip(img, 0, 1))
    k = max(1, int(round(texel)))
    out = {}
    for f in np.unique(r["face"][r["hit"]]):
        m = (r["face"] == f) & r["hit"]
        if m.sum() < min_texels * texel * texel:
            continue
        num = ndimage.uniform_filter(np.where(m, lum, 0.0), k)
        den = ndimage.uniform_filter(m.astype(np.float64), k)
        core = ndimage.binary_erosion(m, iterations=k // 2 + int(np.ceil(0.2 * k)))
        if core.sum() < texel * texel:
            continue
        v = (num / np.maximum(den, 1e-6))[core]
        out[int(f)] = float(v.std() / max(v.mean(), 1e-6))
    return out


def legibility(flat, marched, layers, min_px=4):
    """Per visible face, how much of the art survives the march: for each
    art texel, the pixels showing it after the march over the pixels
    showing it on the flat face (capped at 1), counted over texels the
    flat view shows at least min_px pixels of. {face id: (share of those
    texels keeping at least half their area, mean kept area, distinct
    art colours shown flat, distinct colours shown marched)}."""
    out = {}
    hit = flat["hit"] & marched["hit"]
    for f in np.unique(flat["face"][hit]):
        m = hit & (flat["face"] == f)
        b = int(flat["brush"][m][0])
        albedo = layers[b][0]
        ah, aw = albedo.shape[:2]

        def ids(r):
            uv = r["uv"][m]
            return (np.clip(np.floor(uv[:, 1] * ah).astype(int), 0, ah - 1) * aw
                    + np.clip(np.floor(uv[:, 0] * aw).astype(int), 0, aw - 1))
        a, c = ids(flat), ids(marched)
        ta, na = np.unique(a, return_counts=True)
        tc, nc = np.unique(c, return_counts=True)
        on = dict(zip(tc, nc))
        keep = na >= min_px
        if keep.sum() < 4:
            continue
        share = np.array([min(on.get(t, 0) / n, 1.0) for t, n in zip(ta[keep], na[keep])])
        rgb = (albedo.reshape(-1, 4)[:, :3] * 255).round().astype(int)
        col = lambda t: len({tuple(rgb[i]) for i in t})  # noqa: E731
        out[int(f)] = (float((share >= 0.5).mean()), float(share.mean()), col(ta[keep]), col(tc))
    return out


# --- shading -------------------------------------------------------------------

def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def sky(dy):
    """Sky radiance for directions with world height dy (-1..1)."""
    dy = np.asarray(dy)[..., None]
    above = SKY_HORIZON + (SKY_ZENITH - SKY_HORIZON) * np.clip(dy, 0, 1) ** 0.6
    below = SKY_HORIZON + (SKY_GROUND - SKY_HORIZON) * np.clip(-dy * 4.0, 0, 1)
    return np.where(dy >= 0, above, below)


SKY_AVG = 0.5 * (sky(0.5) + sky(-0.3))


def shade(r, sun_view, up_view, sun_power=2.8, sky_power=0.9, self_shadow=None):
    """Shade a rasterised view. sun_view and up_view are the sun's
    direction and world up, in view space. self_shadow (shadow()) scales
    the material occlusion and the sun's specular, as the shader folds it
    in."""
    hit = r["hit"]
    nxy = r["n"][..., :2] / 127.5 - 1.0
    nz = np.sqrt(np.clip(1 - (nxy ** 2).sum(-1), 0, 1))
    # +U is image right; green above 128 tilts toward the top of the
    # image, which is minus dP/dv.
    n = nxy[..., :1] * r["T"] - nxy[..., 1:2] * r["B"] + nz[..., None] * r["F"]
    n /= np.linalg.norm(n, axis=-1, keepdims=True) + 1e-9
    ao = r["n"][..., 2] / 255.0
    ss = np.ones(hit.shape) if self_shadow is None else self_shadow
    ao = ao * ss
    sm = r["s"][..., 0] / 255.0
    g = r["s"][..., 1]
    metal = g >= 230
    albedo = srgb_to_linear(r["a"])
    f0 = np.where(metal[..., None], albedo, (np.minimum(g, 229) / 255.0)[..., None])
    up = np.asarray(up_view, np.float64)
    L = np.asarray(sun_view, np.float64)
    L = L / np.linalg.norm(L)
    V = np.array((0.0, 0.0, 1.0))
    Hv = (L + V) / np.linalg.norm(L + V)
    ndl = (n * L).sum(-1)
    ndv = np.clip(n[..., 2], 1e-3, 1)
    ndh = np.clip((n * Hv).sum(-1), 0, 1)
    vdh = float(np.clip((V * Hv).sum(), 0, 1))
    rough = np.clip(1 - sm, 0.0, 1.0)
    a = np.clip(rough ** 2, 0.002, 1)
    a2 = a * a
    D = a2 / (np.pi * (ndh * ndh * (a2 - 1) + 1) ** 2)
    k = a / 2
    ndl_c = np.clip(ndl, 0, 1)
    G = (ndl_c / (ndl_c * (1 - k) + k)) * (ndv / (ndv * (1 - k) + k))
    F = f0 + (1 - f0) * (1 - vdh) ** 5
    spec = (D * G / np.maximum(4 * ndl_c * ndv, 1e-4))[..., None] * F * ndl_c[..., None]
    sss = r["s"][..., 2]
    wrap = np.where(sss >= 65, 0.5 * (sss - 65) / 190.0, 0.0)
    diff_ndl = np.clip((ndl + wrap) / (1 + wrap), 0, 1)
    # The shader raises the occlusion's effect on direct light so the self
    # shadow reaches it in full.
    direct_ao = (1 - 0.4 * (1 - ao / np.maximum(ss, 1e-3))) * ss
    # Sky: irradiance by the normal's height, and a reflection by the
    # reflected view direction's, blurred toward the average with
    # roughness.
    ny = (n * up).sum(-1)
    irr = 0.5 * (sky(ny) + SKY_AVG) * sky_power
    R = 2 * n[..., 2:3] * n - V
    ry = (R * up).sum(-1)
    env = (sky(ry) * (1 - rough[..., None]) ** 2 + SKY_AVG * (1 - (1 - rough[..., None]) ** 2)) * sky_power
    fr = f0 + (np.maximum(1 - rough[..., None], f0) - f0) * ((1 - ndv) ** 5)[..., None]
    kd = np.where(metal[..., None], 0.0, 1 - fr)
    e = 0.35 * sun_power * direct_ao
    col = (albedo * kd * ((e * diff_ndl)[..., None] + irr * ao[..., None])
           + spec * e[..., None] + env * fr * ao[..., None])
    out = linear_to_srgb(col)
    bg = np.array((0.16, 0.17, 0.19))
    return np.where(hit[..., None], out, bg)


def save(img, path, scale=1):
    im = Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
    if scale != 1:
        im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
    im.save(path)
    return path


# Suns in model space (left handed, as in the file: +Z the front, +X the
# side the view swings toward). High: above, in front, a little toward
# the visible side, so the front, the side and the top are all lit. Low:
# from the hidden side, a little in front, grazing the front face.
SUN_HIGH = (0.30, 0.65, 0.70)
SUN_LOW = (-0.92, 0.22, 0.32)
# --night's lamp, in view space (x right, y up, z toward the viewer).
LAMP = (0.25, 0.35, 1.0)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("model", help="the .b3d, found under the game's art")
    ap.add_argument("maps", help="directory of _n.png and _s.png companions")
    ap.add_argument("out")
    ap.add_argument("layers", nargs="+", help="layer string per brush, in brush order; "
                    "blank.png or an empty string leaves a brush undrawn")
    ap.add_argument("--game", default=lib.DEFAULT_GAME)
    ap.add_argument("--texel", type=float, default=12.0, help="screen pixels per art texel")
    ap.add_argument("--yaw", type=float, default=35.0, help="degrees from the front toward model +X")
    ap.add_argument("--pitch", type=float, default=20.0, help="degrees looking down")
    ap.add_argument("--turn", type=float, default=0.0,
                    help="degrees to turn the model about up first, for a model not facing +Z")
    ap.add_argument("--parallax", action="store_true",
                    help="march the stored height as the entity shader does, with its self shadow")
    ap.add_argument("--contrast", action="store_true",
                    help="print each visible face's contrast with maps on over maps off")
    ap.add_argument("--legibility", action="store_true",
                    help="with --parallax, print per face the share of art texels keeping half "
                    "their area through the march")
    ap.add_argument("--night", action="store_true",
                    help="also write night.png and night_maps_off.png: a lamp close in front, "
                    "a little above the view, and almost no sky")
    ap.add_argument("--crop", default=None, metavar="X0,Y0,X1,Y1",
                    help="also write crop.png: the face with this art texel rectangle, "
                    "maps off, maps on, low sun on, three times enlarged")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    strings = {i: s for i, s in enumerate(a.layers) if s and s != "blank.png"}
    if not strings:
        raise SystemExit("no brush has a texture")
    tris = triangles(a.model, list(strings), a.game)
    basis = view_basis(a.yaw, a.pitch, a.turn)
    rot, right, up, toward = basis
    M = np.stack([right, up, toward])
    flip = np.array((-1.0, 1.0, 1.0))
    to_view = lambda d: M @ (rot @ (np.asarray(d, np.float64) * flip))  # noqa: E731
    views = {}
    for on in (True, False):
        layers = {b: composite(s, a.maps, a.game, maps_on=on) for b, s in strings.items()}
        if on:
            layers_on = layers
            upt = units_per_texel(tris, {b: layers[b][0].shape[:2] for b in layers})
            ppu = a.texel / upt
        views[on] = rasterise(tris, layers, basis, ppu, int(a.texel * 2))
    upv = M @ np.array((0.0, 1.0, 0.0))
    hi, lo = to_view(SUN_HIGH), to_view(SUN_LOW)
    ss_hi = ss_lo = None
    if a.parallax:
        depths = {b: relief_depth(layers_on[b][1], tris[b], layers_on[b][0].shape[1])
                  for b in layers_on}
        for b, d in depths.items():
            print("brush %d relief %.3f node (%.2f art texels for the full height range)"
                  % (b, d, 16 * d))
        flat_on = views[True]
        views[True] = march(views[True], layers_on, depths)
        if a.legibility:
            leg = legibility(flat_on, views[True], layers_on)
            worst = None
            for f, (kept, area, c0, c1) in sorted(leg.items()):
                m = flat_on["face"] == f
                b = int(flat_on["brush"][m][0])
                ah, aw = layers_on[b][0].shape[:2]
                rect = np.round(flat_on["rect"][m][0] * (aw, ah, aw, ah)).astype(int).tolist()
                print("    legibility brush %d face %s: %.0f%% of texels keep half their area, "
                      "mean area %.0f%%, colours %d of %d" % (b, rect, 100 * kept, 100 * area, c1, c0))
                if worst is None or kept < worst[0]:
                    worst = (kept, b, rect)
            if worst:
                print("legibility worst face brush %d %s: %.0f%% of texels keep half their area"
                      % (worst[1], worst[2], 100 * worst[0]))
        ss_hi, ss_lo = shadow(views[True], hi, upv), shadow(views[True], lo, upv)
    shots = {
        "maps_on": shade(views[True], hi, upv, self_shadow=ss_hi),
        "maps_off": shade(views[False], hi, upv),
        "low_sun": shade(views[True], lo, upv, sun_power=3.2, self_shadow=ss_lo),
        "low_sun_maps_off": shade(views[False], lo, upv, sun_power=3.2),
    }
    if a.night:
        # A lantern beside the viewer: light from nearly the view direction,
        # so a glossy face throws its highlight straight back, as the
        # owner's night frame by a lantern did. Directional, not a point
        # light: no falloff across the model.
        lamp = np.array(LAMP) / np.linalg.norm(LAMP)
        ss_lamp = shadow(views[True], lamp, upv) if a.parallax else None
        shots["night"] = shade(views[True], lamp, upv, sun_power=1.6, sky_power=0.06,
                               self_shadow=ss_lamp)
        shots["night_maps_off"] = shade(views[False], lamp, upv, sun_power=1.6, sky_power=0.06)
    if a.contrast:
        # A face the art draws in one or two near shades has almost no
        # contrast to keep, and any relief at all multiplies it; those are
        # listed apart, by how much contrast the maps add.
        flat_art = 0.05
        r0 = views[False]
        for on, off in (("maps_on", "maps_off"), ("low_sun", "low_sun_maps_off")):
            c_on = face_contrast(shots[on], views[True], a.texel)
            c_off = face_contrast(shots[off], views[False], a.texel)
            ratios = {f: c_on[f] / c_off[f] for f in c_on if f in c_off and c_off[f] >= flat_art}
            plain = {f: c_on[f] - c_off[f] for f in c_on if f in c_off and c_off[f] < flat_art}
            if ratios:
                v = np.array(list(ratios.values()))
                print("%s over %s: contrast ratio per face min %.2f median %.2f max %.2f (%d faces)"
                      % (on, off, v.min(), np.median(v), v.max(), len(v)))
            if plain:
                print("  %d near uniform faces (art contrast under %.2f): maps add %.3f at most"
                      % (len(plain), flat_art, max(plain.values())))
            for f in sorted(set(c_on) & set(c_off)):
                m = (r0["face"] == f) & r0["hit"]
                b = int(r0["brush"][m][0])
                ah, aw = layers_on[b][0].shape[:2]
                rect = np.round(r0["rect"][m][0] * (aw, ah, aw, ah)).astype(int)
                print("    brush %d face %s off %.3f on %.3f ratio %.2f"
                      % (b, rect.tolist(), c_off[f], c_on[f], c_on[f] / max(c_off[f], 1e-6)))
    if a.crop:
        x0, y0, x1, y1 = (float(t) for t in a.crop.split(","))
        r = views[False]
        tiles = []
        for k in ("maps_off", "maps_on", "low_sun"):
            b0 = next(iter(strings))
            aw, ah = layers_on[b0][0].shape[1], layers_on[b0][0].shape[0]
            rect = r["rect"] * np.array((aw, ah, aw, ah))
            m = r["hit"] & np.all(np.abs(rect - (x0, y0, x1, y1)) < 0.5, -1)
            if not m.any():
                raise SystemExit("no visible face with the rectangle %s" % a.crop)
            ys, xs = np.nonzero(m)
            tiles.append(shots[k][ys.min():ys.max() + 1, xs.min():xs.max() + 1])
        gap = np.full((tiles[0].shape[0], 6, 3), 0.1)
        save(np.concatenate([tiles[0], gap, tiles[1], gap, tiles[2]], 1), out / "crop.png", 3)
        if a.night:
            cut = lambda k: shots[k][ys.min():ys.max() + 1, xs.min():xs.max() + 1]  # noqa: E731
            save(np.concatenate([cut("night_maps_off"), gap, cut("night")], 1),
                 out / "crop_night.png", 3)
    paths = [save(v, out / (k + ".png")) for k, v in shots.items()]
    gap = np.full((shots["maps_on"].shape[0], 12, 3), 0.1)
    row = np.concatenate([shots["maps_off"], gap, shots["maps_on"], gap,
                          shots["low_sun"], gap, shots["low_sun_maps_off"]], 1)
    paths.append(save(row, out / "compare.png"))
    for p in paths:
        print(p)


if __name__ == "__main__":
    main()
