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
           (docs/materials.md, entities). The tangent frame is per
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

Writes into <out dir>:
  maps_on.png           sun high, from the front and the visible side
  maps_off.png          the same with every map neutral (flat, rough)
  low_sun.png           sun low from the hidden side, grazing the front,
                        to show weave, fur, scales and creases
  low_sun_maps_off.png
  compare.png           maps off, maps on, low sun on, low sun off, side
                        by side, the order preview_figure.py uses

    python3 tools/pbr_author/preview_mob.py <model.b3d> <maps dir> <out dir> \\
        <layers for brush 0> [<layers for brush 1> ...]

for example

    python3 tools/pbr_author/preview_mob.py mobs_mc_iron_golem.b3d maps out \\
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
           "hit": np.zeros((H, W), bool)}
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
            else:
                dpdu, dpdv = (e @ np.linalg.inv(duv)).T
                T = dpdu / np.linalg.norm(dpdu)
                Bv = dpdv / np.linalg.norm(dpdv)
            out["T"][Y, X] = T
            out["B"][Y, X] = Bv
            out["F"][Y, X] = fn
            out["hit"][Y, X] = True
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


def shade(r, sun_view, up_view, sun_power=2.8, sky_power=0.9):
    """Shade a rasterised view. sun_view and up_view are the sun's
    direction and world up, in view space."""
    hit = r["hit"]
    nxy = r["n"][..., :2] / 127.5 - 1.0
    nz = np.sqrt(np.clip(1 - (nxy ** 2).sum(-1), 0, 1))
    # +U is image right; green above 128 tilts toward the top of the
    # image, which is minus dP/dv.
    n = nxy[..., :1] * r["T"] - nxy[..., 1:2] * r["B"] + nz[..., None] * r["F"]
    n /= np.linalg.norm(n, axis=-1, keepdims=True) + 1e-9
    ao = r["n"][..., 2] / 255.0
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
    direct_ao = 1 - 0.4 * (1 - ao)
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
            upt = units_per_texel(tris, {b: layers[b][0].shape[:2] for b in layers})
            ppu = a.texel / upt
        views[on] = rasterise(tris, layers, basis, ppu, int(a.texel * 2))
    upv = M @ np.array((0.0, 1.0, 0.0))
    hi, lo = to_view(SUN_HIGH), to_view(SUN_LOW)
    shots = {
        "maps_on": shade(views[True], hi, upv),
        "maps_off": shade(views[False], hi, upv),
        "low_sun": shade(views[True], lo, upv, sun_power=3.2),
        "low_sun_maps_off": shade(views[False], lo, upv, sun_power=3.2),
    }
    paths = [save(v, out / (k + ".png")) for k, v in shots.items()]
    gap = np.full((shots["maps_on"].shape[0], 12, 3), 0.1)
    row = np.concatenate([shots["maps_off"], gap, shots["maps_on"], gap,
                          shots["low_sun"], gap, shots["low_sun_maps_off"]], 1)
    paths.append(save(row, out / "compare.png"))
    for p in paths:
        print(p)


if __name__ == "__main__":
    main()
