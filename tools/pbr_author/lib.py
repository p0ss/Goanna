"""Shared pieces for hand authored LabPBR sets, tools/pbr_author/<stem>.py.

The bake (tools/pbr_bake.py) upscales 16 px pixel art and asks DeepBump for
relief, and what comes back is a plateau per source texel with a soft edge:
mean tilt six degrees over the Mineclonia pack, occlusion never under 0.81,
one smoothness for the whole tile. An authored set starts from the same 16
px art but decides what the surface *is*: which texels are one stone and
which are the mortar between, how deep the mortar is, what the grain does
inside a plank, where the dust sits. Every map is derived from one height
field plus one smoothness field that the author builds, so the normal, the
occlusion and the roughness agree with each other by construction.

Conventions, all fixed here so a per stem script cannot get them wrong:

  height     float array, 0 deep to 1 high, tileable (every operator here
             wraps). Encoded to the _n alpha as is.
  normal     from the height by central differences, wrapped; R is minus
             the x slope, G is plus the y slope with y running down the
             image, which is what the bake writes and what
             nodes_array.gdshader reads (it does no green flip).
  ao         tools/pbr_bake.py's own ao_from_height, from the same height.
  smoothness float array 0..1; _s R. F0 byte 10 (dielectric) unless the
             class is metal, B is the class scattering byte (leaves, ice,
             snow) or 0, A is 255 (no emission).
  size       256, the bake's map size, so a set drops into the pack.

Targets the ramp is judged on (tools/pbr_author/README.md has the why):

  mean tilt    stone, cobble, gravel 28 to 40 deg; planks 18 to 28;
               dirt 15 to 25; sand 8 to 16; leaves 20 to 30
  ao minimum   at or under 0.35 for anything with joints or cracks
  smoothness   standard deviation at or above 0.08, mean at the class level
               (CLASS_SPEC in tools/pbr_bake.py), which the packer enforces
  seam         seam_energy near 1.0 on every map: the tile must repeat

metrics() reports all of these; preview() renders a lit swatch to a PNG for
a person to look at. The scripts cannot see, so they should print metrics()
and stop, and leave the looking to whoever runs the ramp.
"""

import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import pbr_bake  # noqa: E402

SIZE = 256
GAME_TEXTURES = Path(os.environ.get("GOANNA_GAME_TEXTURES", os.path.expanduser(
        "~/.var/app/org.luanti.luanti/.minetest/games/mineclonia")))
PACK_TEXTURES = Path(os.environ.get("GOANNA_PACK_TEXTURES",
        str(Path(__file__).resolve().parent.parent.parent / "pbr_packs/mineclonia/textures")))
DIELECTRIC_F0 = pbr_bake.DIELECTRIC_F0


# --- inputs -----------------------------------------------------------------

_source_index = None


def source_path(stem):
    """Where the game keeps this stem's art. GAME_TEXTURES may be a flat
    directory (mineclone2 ships one) or a game root whose mods each carry a
    textures directory (Mineclonia), so it is indexed once, recursively."""
    global _source_index
    if _source_index is None:
        _source_index = {}
        for p in sorted(GAME_TEXTURES.rglob("*.png")):
            _source_index.setdefault(p.stem, p)
    if stem not in _source_index:
        raise FileNotFoundError("%s under %s" % (stem, GAME_TEXTURES))
    return _source_index[stem]


def load_source(stem):
    """The game's own 16 px art, RGBA float 0..1, (16, 16, 4). Larger art
    (a 32 px animation strip, a 64 px painting) comes back at its own size;
    a script should check the shape it gets."""
    p = source_path(stem)
    return np.asarray(Image.open(p).convert("RGBA")).astype(np.float32) / 255.0


def load_baked_albedo(stem):
    """The bake's 256 px albedo, RGB float, for a script that wants to keep
    it rather than upscale the source itself."""
    p = PACK_TEXTURES / (stem + ".png")
    return np.asarray(Image.open(p).convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)).astype(np.float32) / 255.0


def upscale(img, size=SIZE, smooth=False):
    """Nearest neighbour keeps the art's texel plateaus; smooth is bilinear."""
    arr = (np.clip(img, 0, 1) * 255.0 + 0.5).astype(np.uint8)
    mode = "RGBA" if arr.ndim == 3 and arr.shape[2] == 4 else ("RGB" if arr.ndim == 3 else "L")
    im = Image.fromarray(arr, mode).resize((size, size), Image.BILINEAR if smooth else Image.NEAREST)
    return np.asarray(im).astype(np.float32) / 255.0


def luminance(rgb):
    return rgb[..., 0] * 0.2126 + rgb[..., 1] * 0.7152 + rgb[..., 2] * 0.0722


# --- fields -----------------------------------------------------------------

def value_noise(size, cells, seed):
    """Tileable smooth value noise in -1..1 on a cells x cells lattice."""
    rng = np.random.default_rng(seed)
    lat = rng.uniform(-1.0, 1.0, (cells, cells))
    t = (np.arange(size) / size) * cells
    i0 = np.floor(t).astype(int) % cells
    i1 = (i0 + 1) % cells
    f = t - np.floor(t)
    f = f * f * (3 - 2 * f)
    fy, fx = f[:, None], f[None, :]
    a = lat[i0][:, i0]
    b = lat[i0][:, i1]
    c = lat[i1][:, i0]
    d = lat[i1][:, i1]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def fbm(size, base_cells, octaves, seed, gain=0.5):
    """Tileable fractal noise, roughly -1..1, cells doubling per octave."""
    out = np.zeros((size, size), dtype=np.float32)
    amp = 1.0
    total = 0.0
    cells = base_cells
    for o in range(octaves):
        out += amp * value_noise(size, cells, seed + 101 * o)
        total += amp
        amp *= gain
        cells *= 2
    return out / total


def white_noise(size, seed):
    return np.random.default_rng(seed).uniform(-1.0, 1.0, (size, size)).astype(np.float32)


def blur(field, radius):
    """Wrapped box blur, radius in texels; 0 returns the field."""
    if radius <= 0:
        return field
    out = field.astype(np.float32)
    k = 2 * radius + 1
    acc = np.zeros_like(out)
    for d in range(-radius, radius + 1):
        acc += np.roll(out, d, axis=0)
    out = acc / k
    acc = np.zeros_like(out)
    for d in range(-radius, radius + 1):
        acc += np.roll(out, d, axis=1)
    return acc / k


def segments(src_rgb, tolerance=0.06):
    """Label connected regions of similar colour in 16 px art, wrapping at
    the edges: the stones of a cobble, the planks of a floor. Returns an
    int label map the size of the art and the label count. tolerance is the
    RGB distance that still counts as the same region."""
    h, w = src_rgb.shape[:2]
    labels = -np.ones((h, w), dtype=int)
    n = 0
    for y in range(h):
        for x in range(w):
            if labels[y, x] >= 0:
                continue
            stack = [(y, x)]
            labels[y, x] = n
            while stack:
                cy, cx = stack.pop()
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = (cy + dy) % h, (cx + dx) % w
                    if labels[ny, nx] >= 0:
                        continue
                    if np.abs(src_rgb[ny, nx, :3] - src_rgb[cy, cx, :3]).max() <= tolerance:
                        labels[ny, nx] = n
                        stack.append((ny, nx))
            n += 1
    return labels, n


def warp_labels(labels, size=SIZE, amp=6.0, seed=7, cells=12):
    """Upscale a 16 px label map to the map size with its region boundaries
    bent, so a stone found in the art has a rounded, irregular silhouette
    rather than the square outline of the texels it came from. Each map
    texel looks up its label at a source position displaced by a tileable
    noise field of amp texels. np.kron gives the square version; the first
    authored stony sets used it and every dome carried the pixel grid."""
    h, w = labels.shape
    sy = size // h
    sx = size // w
    wy = fbm(size, cells, 2, seed) * amp
    wx = fbm(size, cells, 2, seed + 31) * amp
    ys = (np.arange(size)[:, None] + wy + 0.5) / sy
    xs = (np.arange(size)[None, :] + wx + 0.5) / sx
    iy = np.floor(ys).astype(int) % h
    ix = np.floor(xs).astype(int) % w
    return labels[iy, ix]


def region_edges(labels_hi):
    """1 where a texel's neighbour (wrapped) has another label, else 0."""
    e = np.zeros(labels_hi.shape, dtype=np.float32)
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        e = np.maximum(e, (np.roll(labels_hi, (dy, dx), axis=(0, 1)) != labels_hi).astype(np.float32))
    return e


def distance_to_edge(edge, max_dist=24):
    """Wrapped texel distance from the nearest edge texel, capped."""
    d = np.full(edge.shape, float(max_dist), dtype=np.float32)
    d[edge > 0.5] = 0.0
    for _ in range(max_dist):
        nd = d.copy()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nd = np.minimum(nd, np.roll(d, (dy, dx), axis=(0, 1)) + 1.0)
        if np.array_equal(nd, d):
            break
        d = nd
    return d


def normalise01(field, lo_pct=0.5, hi_pct=99.5):
    lo, hi = np.percentile(field, (lo_pct, hi_pct))
    if hi - lo < 1e-6:
        return np.zeros_like(field)
    return np.clip((field - lo) / (hi - lo), 0.0, 1.0)


# --- derived maps -----------------------------------------------------------

def normal_from_height(height, strength):
    """Tangent xy in -1..1 from a 0..1 height, wrapped central differences.
    strength is the height of the full 0..1 range in texels: 8 means the
    deepest point is eight texels below the highest."""
    h = height.astype(np.float32) * strength
    dx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * 0.5
    dy = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * 0.5
    n = np.stack([-dx, dy, np.ones_like(h)], axis=-1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return n[..., :2]


def ao_from_height(height, radius_px=6):
    img = Image.fromarray((np.clip(height, 0, 1) * 255.0 + 0.5).astype(np.uint8), "L")
    return np.clip(pbr_bake.ao_from_height(img, radius_px=radius_px, wrap=True), 0.0, 1.0).astype(np.float32)


def class_of(stem):
    """The bake's class for a stem, read back from its packed _s bytes and
    its name, the way tools/pbr_spec_variance.py infers it. The class
    decides the smoothness level, the scattering byte, the tilt target and
    the parallax depth, so a script should take it from here rather than
    guess."""
    import pbr_spec_variance
    return pbr_spec_variance.infer_class(stem, PACK_TEXTURES) or "default"


def class_spec(cls):
    """(smoothness, f0, is_metal) from the bake's table."""
    return pbr_bake.CLASS_SPEC.get(cls, pbr_bake.DEFAULT_SPEC)


def sss_byte(cls):
    s = pbr_bake.CLASS_SSS.get(cls, 0.0)
    return int(round(65 + s * 190)) if s > 0.0 else 0


# --- packing ---------------------------------------------------------------

def pack(stem, out_dir, albedo, height, smoothness, cls, normal_strength,
        metal_mask=None, ao_radius=6, keep_mean=True):
    """Write <stem>.png, <stem>_n.png and <stem>_s.png. albedo is RGB or
    RGBA float at SIZE; height and smoothness are SIZE x SIZE floats.
    The smoothness mean is moved onto the class level unless keep_mean is
    False, because the level was chosen on purpose and the ramp compares
    spread, not level."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    height = np.clip(height, 0.0, 1.0).astype(np.float32)
    xy = normal_from_height(height, normal_strength)
    ao = ao_from_height(height, ao_radius)
    n = np.zeros((SIZE, SIZE, 4), dtype=np.float32)
    n[..., :2] = xy * 0.5 + 0.5
    n[..., 2] = ao
    n[..., 3] = height
    Image.fromarray((n * 255.0 + 0.5).astype(np.uint8), "RGBA").save(out_dir / (stem + "_n.png"))

    level, _, is_metal = class_spec(cls)
    sm = np.clip(smoothness, 0.0, 1.0).astype(np.float32)
    if keep_mean:
        sm = np.clip(sm - sm.mean() + level, 0.0, 0.9)
    s = np.zeros((SIZE, SIZE, 4), dtype=np.float32)
    s[..., 0] = sm
    if metal_mask is None:
        metal_mask = np.full((SIZE, SIZE), bool(is_metal))
    s[..., 1] = np.where(metal_mask, 255.0, float(DIELECTRIC_F0)) / 255.0
    s[..., 2] = sss_byte(cls) / 255.0
    s[..., 3] = 1.0
    Image.fromarray((s * 255.0 + 0.5).astype(np.uint8), "RGBA").save(out_dir / (stem + "_s.png"))

    a = np.clip(albedo, 0.0, 1.0)
    if a.ndim == 3 and a.shape[2] == 4:
        Image.fromarray((a * 255.0 + 0.5).astype(np.uint8), "RGBA").save(out_dir / (stem + ".png"))
    else:
        Image.fromarray((a[..., :3] * 255.0 + 0.5).astype(np.uint8), "RGB").save(out_dir / (stem + ".png"))
    return metrics(out_dir, stem)


# --- judging ----------------------------------------------------------------

def seam_energy(arr, step=1):
    """How badly a map fails to tile: the wrap-around edge difference
    against the difference across an ordinary join inside the map, so 1 is
    seamless. step is the join spacing to compare against: 1 for a
    continuous field, 16 for art upscaled by nearest from 16 px, where every
    row inside a source texel equals its neighbour and the only real joins
    are the texel boundaries every sixteen rows."""
    a = arr.astype(np.float32)
    if a.ndim == 2:
        a = a[..., None]
    wrap = np.abs(a[0] - a[-1]).mean() + np.abs(a[:, 0] - a[:, -1]).mean()
    joins = range(step, a.shape[0], step)
    inner = np.mean([np.abs(a[j] - a[j - 1]).mean() + np.abs(a[:, j] - a[:, j - 1]).mean()
            for j in joins])
    return float(wrap / max(inner, 1e-3))


def metrics(out_dir, stem):
    """Everything the targets above ask for, from the files as written."""
    out_dir = Path(out_dir)
    n = np.asarray(Image.open(out_dir / (stem + "_n.png")).convert("RGBA")).astype(np.float32) / 255.0
    s = np.asarray(Image.open(out_dir / (stem + "_s.png")).convert("RGBA")).astype(np.float32) / 255.0
    a = np.asarray(Image.open(out_dir / (stem + ".png")).convert("RGB")).astype(np.float32) / 255.0
    xy = n[..., :2] * 2.0 - 1.0
    slope = np.sqrt((xy ** 2).sum(-1)).clip(0, 0.999)
    z = np.sqrt(np.clip(1.0 - slope ** 2, 0.0, 1.0))
    # Shading a raking light would produce, the DeepBump memory's measure.
    light = np.array([0.6, 0.0, 0.8])
    ndl = np.clip(xy[..., 0] * light[0] + xy[..., 1] * light[1] + z * light[2], 0, 1)
    return {
        "tilt_mean_deg": float(np.degrees(np.arcsin(slope)).mean()),
        "tilt_p90_deg": float(np.degrees(np.arcsin(np.percentile(slope, 90)))),
        "ao_min": float(n[..., 2].min()),
        "ao_mean": float(n[..., 2].mean()),
        "height_sd": float(n[..., 3].std()),
        "ndl_sd": float(ndl.std()),
        "smooth_mean": float(s[..., 0].mean()),
        "smooth_sd": float(s[..., 0].std()),
        "albedo_lum_sd": float(luminance(a).std()),
        "seam_n": seam_energy(n[..., :3]),
        "seam_s": seam_energy(s[..., 0]),
        "seam_albedo": seam_energy(a, 16),
    }


def check(m, cls):
    """Pass or fail lines against the targets, for the script to print."""
    tilt = {"stone": (28, 40), "gravel": (28, 40), "wood": (18, 28), "soil": (15, 25),
            "sand": (8, 16), "leaves": (20, 30), "snow": (6, 14), "cloth": (6, 14)}.get(cls, (15, 30))
    lines = []
    ok = tilt[0] <= m["tilt_mean_deg"] <= tilt[1]
    lines.append("%s tilt %.1f deg (want %d to %d)" % ("ok  " if ok else "FAIL", m["tilt_mean_deg"], tilt[0], tilt[1]))
    jointed = cls in ("stone", "gravel", "wood", "soil")
    ok = m["ao_min"] <= 0.35 or not jointed
    lines.append("%s ao min %.2f (want <= 0.35 on jointed surfaces)" % ("ok  " if ok else "FAIL", m["ao_min"]))
    ok = m["smooth_sd"] >= 0.08
    lines.append("%s smoothness sd %.3f (want >= 0.08), mean %.3f" % ("ok  " if ok else "FAIL", m["smooth_sd"], m["smooth_mean"]))
    for k in ("seam_n", "seam_s"):
        ok = m[k] <= 1.6
        lines.append("%s %s %.2f (want about 1, seamless)" % ("ok  " if ok else "FAIL", k, m[k]))
    # The albedo is the game's art and its wrap is the art's own design: a
    # plank joint on the tile edge is a step there on purpose. Reported so a
    # script can prefer the bake's soft upscale when it is bad, never a
    # failure, because nothing the script controls can change it.
    lines.append("note seam_albedo %.2f (the art's own wrap; informational)" % m["seam_albedo"])
    return lines


def preview(out_dir, stem, path, light=(0.5, -0.4, 0.75), scale=2):
    """A lit swatch: albedo times Lambert from the normal times the AO, with
    a Blinn highlight sized by the smoothness. Not the renderer, just enough
    for a person to see whether the joints read as joints. Tiled two by two
    so a seam shows."""
    out_dir = Path(out_dir)
    n = np.asarray(Image.open(out_dir / (stem + "_n.png")).convert("RGBA")).astype(np.float32) / 255.0
    s = np.asarray(Image.open(out_dir / (stem + "_s.png")).convert("RGBA")).astype(np.float32) / 255.0
    a = np.asarray(Image.open(out_dir / (stem + ".png")).convert("RGB")).astype(np.float32) / 255.0
    xy = n[..., :2] * 2.0 - 1.0
    z = np.sqrt(np.clip(1.0 - (xy ** 2).sum(-1), 0.0, 1.0))
    nrm = np.stack([xy[..., 0], xy[..., 1], z], -1)
    l = np.array(light, dtype=np.float32)
    l /= np.linalg.norm(l)
    ndl = np.clip((nrm * l).sum(-1), 0.0, 1.0)
    hv = l + np.array([0.0, 0.0, 1.0])
    hv /= np.linalg.norm(hv)
    ndh = np.clip((nrm * hv).sum(-1), 0.0, 1.0)
    shin = 2.0 + 200.0 * s[..., 0] ** 2
    spec = (ndh ** shin) * (0.04 + 0.5 * s[..., 0]) * (shin + 8) / 8 * 0.15
    lit = a * (0.25 * n[..., 2:3] + 0.9 * ndl[..., None]) + spec[..., None]
    lit = np.clip(lit, 0, 1) ** (1 / 2.2)
    tile = np.concatenate([np.concatenate([lit, lit], 1)] * 2, 0)
    im = Image.fromarray((tile * 255 + 0.5).astype(np.uint8), "RGB")
    if scale != 1:
        im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
    im.save(path)
    return path
