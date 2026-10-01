"""Offline front view of a Mineclonia figure with authored maps.

This is for judging a skin's maps without a GPU. Two figures are known
(FIGURES below): the default player ("player", the default) and the plains
farmer villager ("villager", mobs_mc_villager.b3d with its base, biome,
profession and badge layers). It does what the client does to get the
maps onto the model, then lights the front of the figure with a few lines
of shading:

  albedo   the layer string the game draws (the figure's "skin") evaluated
           as Luanti evaluates it: [colorize:<colour>:alpha as apply_colorize
           with keep_alpha (the colour, the mask's own alpha) and every ^ as
           blit_pixel, integer for integer, at the art's size.
  maps     composited the way src/goanna_overlay_companions.h does: each
           layer's companions are its own image's, or for a colouring mask
           the part's (mcl_skins_hair_1_mask takes mcl_skins_hair_1_n.png);
           a layer with none contributes the neutral, flat and rough; the
           first layer covers everything, each later one goes over by its
           albedo alpha; _n mixes in all four channels, of _s only the
           smoothness mixes, and F0, scattering and emission come whole
           from the topmost layer covering a pixel at 0.5 or more. Every
           input is sampled nearest at the largest size.
  geometry the front facing triangles of the model the skin is drawn on
           (mcl_armor_character.b3d or mobs_mc_villager.b3d, brush 0), as
           the file has them (the villager's arms are crossed in the mesh
           itself), rasterised orthographically from the front, nearest
           first, a pixel of a layer with albedo alpha under 0.5 letting
           the one behind show (the player's hat layer carries the fringe,
           the villager's hat box is drawn only where the straw is). Each triangle's tangent frame comes from
           its own positions and UVs, so a mirrored limb's normal map is
           mirrored as on the model.
  decode   red above 128 tilts the normal toward +U (image right), green
           above 128 toward the top of the image, no flip, as
           docs/materials.md has it for entities.
  shading  in linear light: a sun (direct, with the material occlusion at
           0.4 of its effect, as the client's AO light affect), a sky
           ambient brighter on upward normals and fully occluded by the
           material occlusion, a GGX specular from the sun with roughness
           (1 - smoothness) squared, Schlick Fresnel on F0 (the _s green
           byte, or the albedo for a metal), Smith visibility. A pixel
           whose _s blue byte says it scatters gets a wrapped diffuse
           term, a crude stand in for the client's backlight. Then
           clipped and encoded as sRGB.

What it does not model, so do not read these off it: shadows (no box
shadows another, the hair casts nothing on the face; the only darkening
between parts is the occlusion baked into the maps), any reflection of
the sky or surroundings (the specular is the sun's alone, so a glossy eye
or a clasp is dark where it does not catch the sun), the sides of the
boxes (only front faces are drawn), mipmapping and filtering (sampled
nearest at the map's own resolution, as close up), the client's tone
mapping, fog, exposure and any post process, and the entity shader
itself. It is a judge of what the maps contain, not of how the game will
look.

Writes, at 16 px per art texel unless --texel says otherwise:
  front.png          sun from the upper left and in front, maps on
  front_maps_off.png the same with every map neutral (flat, rough)
  front_low_sun.png  sun low from the figure's right side (viewer's left),
                     grazing, to show weave, strands and stitches
  front_low_sun_maps_off.png
  head_3x.png, head_3x_maps_off.png, head_3x_low_sun.png
                     the head (and the hair's front layer) at 3x, nearest
  compare.png        maps off, maps on, low sun on, low sun off, side by
                     side at the same framing
  villager only:
  hat_above.png, hat_above_maps_off.png, hat_above_low_sun.png
                     the head and hat seen from 40 degrees above the
                     front, at 3x, for the hat's top and brim, which the
                     front view sees edge on

    python3 tools/pbr_author/preview_figure.py <maps dir> <out dir> [--figure villager]
"""
import argparse
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import atlas  # noqa: E402
import lib  # noqa: E402

DEFAULT_SKIN = ("(mcl_skins_base_1_mask.png^[colorize:#EEB592FF:alpha)^mcl_skins_base_1.png"
                "^mcl_skins_eye_1.png^(mcl_skins_bottom_1_mask.png^[colorize:#383532FF:alpha)"
                "^mcl_skins_bottom_1.png^mcl_skins_footwear_1.png"
                "^(mcl_skins_top_1_mask.png^[colorize:#346840FF:alpha)^mcl_skins_top_1.png"
                "^(mcl_skins_hair_1_mask.png^[colorize:#715D57FF:alpha)^mcl_skins_hair_1.png")
MODEL = "mcl_armor_character.b3d"
VILLAGER_FARMER = ("mobs_mc_villager_base.png^mobs_mc_villager_plains.png"
                   "^mobs_mc_villager_profession_farmer.png^mobs_mc_stone.png")
# Per figure: the layer string, the model, the head's front face in art
# texels with the art's size (to check the view is not mirrored), art
# texels per model unit, and the head crop in model units (x0, x1, y0, y1)
# after the view's reflection.
FIGURES = {
    "player": {"skin": DEFAULT_SKIN, "model": MODEL, "head_front": (8, 8, 16, 16),
               "art": (64, 32), "texels_per_unit": 2.0, "head": (-2.4, 2.4, 13.1, 17.9),
               "above": False},
    # The villager's head is 8 texels over 4.3 units. Its hat box reaches
    # 2.5 either side and 18.66 up, the nose 12.31 down.
    "villager": {"skin": VILLAGER_FARMER, "model": "mobs_mc_villager.b3d",
                 "head_front": (8, 8, 16, 18), "art": (64, 64), "texels_per_unit": 8 / 4.3,
                 "head": (-2.8, 2.8, 12.0, 18.9), "above": True},
}
NEUTRAL_N = (128, 128, 255, 255)
NEUTRAL_S = (0, 10, 0, 255)


def parse_layers(texture):
    """[(image stem, tint or None)] bottom first, for the plain form above."""
    out = []
    for part in re.findall(r"\([^)]*\)|[^\^()]+", texture):
        part = part.strip("()")
        m = re.match(r"([\w.]+)\.png(?:\^\[colorize:#([0-9A-Fa-f]{6})[0-9A-Fa-f]{0,2}:alpha)?$", part)
        if not m:
            raise ValueError("not a plain layer: %r" % part)
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
    """(albedo 0..1 at the art's size, _n bytes, _s bytes at the map size)."""
    layers = parse_layers(texture)
    albedo = None
    alphas = []
    comps = []
    for image, tint in layers:
        a = load8(lib.source_path(image, game))
        if tint:
            a = atlas._colorize_alpha(a, tint)
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


def front_triangles(game, brush=0, model=MODEL, pitch=0.0, keep=None):
    """Front facing triangles as (positions, uvs 0..1, outward normal), in
    a right handed view space: x right, y up, z toward the viewer. Luanti's
    model space is left handed (Irrlicht's), so seen from the front, from
    +Z, model +X is on the viewer's left; x is reflected for that. The
    outward normal is taken from the file's winding before the reflection,
    which turns the winding over. pitch (degrees) looks down from above
    the front: the model turns about x so its top partly faces the viewer,
    and every triangle facing the viewer at all is kept. keep, a function
    of a triangle's model positions, drops the triangles it refuses."""
    out = []
    flip = np.array((-1.0, 1.0, 1.0))
    a = np.radians(pitch)
    rot = np.array(((1.0, 0.0, 0.0), (0.0, np.cos(a), -np.sin(a)), (0.0, np.sin(a), np.cos(a))))
    for pos, uv, tris in atlas.read_b3d(atlas.model_path(model, game)):
        for b, idx in tris:
            if b != brush:
                continue
            for t in idx:
                p = pos[t].astype(np.float64)
                if keep is not None and not keep(p):
                    continue
                n = np.cross(p[1] - p[0], p[2] - p[0])
                n /= np.linalg.norm(n) + 1e-12
                if pitch:
                    p, n = p @ rot.T, rot @ n
                if n[2] > (0.05 if pitch else 0.5):
                    out.append((p * flip, uv[t].astype(np.float64), n * flip))
    return out


def check_orientation(tris, rect=(8, 8, 16, 16), art=(64, 32)):
    """The view must show the art as drawn: on the head's front face
    (rect, in texels of an art of size art) u grows to the right of the
    screen. A model that faces the other way fails here rather than
    previewing a mirror image."""
    x0, y0, x1, y1 = rect
    w, h = art
    for p, uv, _ in tris:
        if uv[:, 0].min() * w >= x0 - 0.1 and uv[:, 0].max() * w <= x1 + 0.1 \
                and uv[:, 1].min() * h >= y0 - 0.1 and uv[:, 1].max() * h <= y1 + 0.1:
            e = np.stack([p[1] - p[0], p[2] - p[0]], 1)
            duv = np.stack([uv[1] - uv[0], uv[2] - uv[0]], 1)
            dpdu = (e @ np.linalg.inv(duv))[:, 0]
            if dpdu[0] <= 0:
                raise SystemExit("head front u grows to model -X: the view would be mirrored")
            return
    raise SystemExit("no head front face found")


def rasterise(tris, albedo, N, S, ppu, margin):
    """Per screen pixel: albedo, _n, _s and the tangent frame, or nothing."""
    allp = np.concatenate([t[0] for t in tris])
    x0, x1 = allp[:, 0].min(), allp[:, 0].max()
    y0, y1 = allp[:, 1].min(), allp[:, 1].max()
    W = int(np.ceil((x1 - x0) * ppu)) + 2 * margin
    H = int(np.ceil((y1 - y0) * ppu)) + 2 * margin
    depth = np.full((H, W), -np.inf)
    out = {"a": np.zeros((H, W, 3)), "n": np.zeros((H, W, 4)), "s": np.zeros((H, W, 4)),
           "T": np.zeros((H, W, 3)), "B": np.zeros((H, W, 3)), "F": np.zeros((H, W, 3)),
           "hit": np.zeros((H, W), bool)}
    ah, aw = albedo.shape[:2]
    mh, mw = N.shape[:2]
    for p, uv, fn in sorted(tris, key=lambda t: t[0][:, 2].mean()):
        sx = (p[:, 0] - x0) * ppu + margin
        sy = (y1 - p[:, 1]) * ppu + margin
        bx0, bx1 = int(np.floor(sx.min())), int(np.ceil(sx.max()))
        by0, by1 = int(np.floor(sy.min())), int(np.ceil(sy.max()))
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
        ai = np.clip((v * ah).astype(int), 0, ah - 1), np.clip((u * aw).astype(int), 0, aw - 1)
        mi = np.clip((v * mh).astype(int), 0, mh - 1), np.clip((u * mw).astype(int), 0, mw - 1)
        alpha = albedo[ai][..., 3]
        ys, xs = np.nonzero(inside & (alpha >= 0.5))
        if not len(ys):
            continue
        Y, X = ys + by0, xs + bx0
        ok = (Y >= 0) & (Y < H) & (X >= 0) & (X < W)
        ys, xs, Y, X = ys[ok], xs[ok], Y[ok], X[ok]
        nearer = z[ys, xs] > depth[Y, X]
        ys, xs, Y, X = ys[nearer], xs[nearer], Y[nearer], X[nearer]
        depth[Y, X] = z[ys, xs]
        out["a"][Y, X] = albedo[ai][ys, xs, :3]
        out["n"][Y, X] = N[mi][ys, xs]
        out["s"][Y, X] = S[mi][ys, xs]
        # Tangent frame from this triangle: dP/du and dP/dv.
        e = np.stack([p[1] - p[0], p[2] - p[0]], 1)
        duv = np.stack([uv[1] - uv[0], uv[2] - uv[0]], 1)
        inv = np.linalg.inv(duv)
        dpdu, dpdv = (e @ inv).T
        out["T"][Y, X] = dpdu / np.linalg.norm(dpdu)
        out["B"][Y, X] = dpdv / np.linalg.norm(dpdv)
        out["F"][Y, X] = fn
        out["hit"][Y, X] = True
    return out


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def shade(r, sun, sun_power=2.8, sky=0.5):
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
    L = np.asarray(sun, np.float64)
    L = L / np.linalg.norm(L)
    V = np.array((0.0, 0.0, 1.0))
    Hv = (L + V) / np.linalg.norm(L + V)
    ndl = (n * L).sum(-1)
    ndv = np.clip(n[..., 2], 1e-3, 1)
    ndh = np.clip((n * Hv).sum(-1), 0, 1)
    vdh = float(np.clip((V * Hv).sum(), 0, 1))
    a = np.clip((1 - sm) ** 2, 0.002, 1)
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
    kd = np.where(metal[..., None], 0.0, 1 - F)
    amb = sky * (0.6 + 0.4 * n[..., 1]) * ao
    # The sun's irradiance on a surface facing it, in units where a white
    # surface reads 1 at sun_power 2.86.
    e = 0.35 * sun_power * direct_ao
    col = albedo * (kd * (e * diff_ndl)[..., None] + amb[..., None]) + spec * e[..., None]
    out = linear_to_srgb(col)
    bg = np.array((0.16, 0.17, 0.19))
    return np.where(hit[..., None], out, bg)


def save(img, path, scale=1):
    im = Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
    if scale != 1:
        im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
    im.save(path)
    return path


SUN_FRONT = (-0.45, 0.55, 0.70)
SUN_LOW = (-0.93, 0.12, 0.34)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("maps")
    ap.add_argument("out")
    ap.add_argument("--game", default=lib.DEFAULT_GAME)
    ap.add_argument("--texel", type=int, default=16, help="screen pixels per art texel")
    ap.add_argument("--figure", default="player", choices=sorted(FIGURES))
    ap.add_argument("--skin", default=None, help="the layer string (default the figure's)")
    a = ap.parse_args()
    fig = FIGURES[a.figure]
    skin = a.skin or fig["skin"]
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    tris = front_triangles(a.game, model=fig["model"])
    check_orientation(tris, fig["head_front"], fig["art"])
    # The player's model is two art texels to a unit (the body is 4 units
    # and 8 texels wide); the villager's a little less.
    ppu = fig["texels_per_unit"] * a.texel
    margin = a.texel
    views = {}
    comps = {}
    for on in (True, False):
        comps[on] = composite(skin, a.maps, a.game, maps_on=on)
        views[on] = rasterise(tris, *comps[on], ppu, margin)
    shots = {
        "front": shade(views[True], SUN_FRONT),
        "front_maps_off": shade(views[False], SUN_FRONT),
        "front_low_sun": shade(views[True], SUN_LOW, sun_power=3.2),
        "front_low_sun_maps_off": shade(views[False], SUN_LOW, sun_power=3.2),
    }
    paths = [save(v, out / (k + ".png")) for k, v in shots.items()]
    # The head: the player's head and hat boxes span y 13.3 to 17.7 and x
    # -2.2 to 2.2; crop that (the figure's "head") with a little room and
    # scale it up.
    allp = np.concatenate([t[0] for t in tris])
    x0, y1 = allp[:, 0].min(), allp[:, 1].max()
    hx0, hx1, hy0, hy1 = fig["head"]
    cx0 = int((hx0 - x0) * ppu) + margin
    cx1 = int((hx1 - x0) * ppu) + margin
    cy0 = int((y1 - hy1) * ppu) + margin
    cy1 = int((y1 - hy0) * ppu) + margin
    for k, src in (("head_3x", "front"), ("head_3x_maps_off", "front_maps_off"),
                   ("head_3x_low_sun", "front_low_sun")):
        paths.append(save(shots[src][max(cy0, 0):cy1, max(cx0, 0):cx1], out / (k + ".png"), 3))
    gap = np.full((shots["front"].shape[0], 12, 3), 0.1)
    row = np.concatenate([shots["front_maps_off"], gap, shots["front"], gap,
                          shots["front_low_sun"], gap, shots["front_low_sun_maps_off"]], 1)
    paths.append(save(row, out / "compare.png"))
    if fig["above"]:
        # The head, hat and brim from 40 degrees above the front: every
        # triangle wholly above the head crop's lowest point.
        above = front_triangles(a.game, model=fig["model"], pitch=40.0,
                                keep=lambda p: p[:, 1].min() >= fig["head"][2])
        for on, suffix in ((True, ""), (False, "_maps_off")):
            r = rasterise(above, *comps[on], ppu, margin)
            paths.append(save(shade(r, SUN_FRONT), out / ("hat_above%s.png" % suffix), 3))
            if on:
                paths.append(save(shade(r, SUN_LOW, sun_power=3.2), out / "hat_above_low_sun.png", 3))
    for p in paths:
        print(p)


if __name__ == "__main__":
    main()
