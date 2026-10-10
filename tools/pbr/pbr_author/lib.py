"""Shared pieces for hand authored LabPBR sets, tools/pbr/pbr_author/<stem>.py.

The bake (tools/pbr/pbr_bake.py) upscales 16 px pixel art and asks DeepBump for
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
  ao         tools/pbr/pbr_bake.py's own ao_from_height, from the same height.
  smoothness float array 0..1; _s R. F0 byte 10 (dielectric) unless the
             class is metal, B is the class scattering byte (leaves, ice,
             snow) or 0, A is 255 (no emission).
  cut-out    where the art draws nothing (source alpha under 128) both
             maps are forced to the bake's neutral, after every field is
             derived. See cutout_mask.
  size       256, the bake's map size, so a set drops into the pack; 128
             and 512 for the other texture resolution tiers (SIZE).
  marker     _n and _s carry a goanna_pipeline=authored PNG text chunk, so
             tools/pbr/check-pbr-quality.py measures the height above by the
             rule it is built to rather than the bake's. See PIPELINE_KEY.

Targets the ramp is judged on (tools/pbr/pbr_author/README.md has the why):

  mean tilt    stone, cobble, gravel 28 to 40 deg; planks 18 to 28;
               dirt 15 to 25; sand 8 to 16; leaves 20 to 30
  ao minimum   at or under 0.35 for anything with joints or cracks
  smoothness   standard deviation at or above 0.08, mean at the class level
               (CLASS_SPEC in tools/pbr/pbr_bake.py), which the packer enforces
  seam         seam_energy near 1.0 on every map: the tile must repeat

metrics() reports all of these; preview() renders a lit swatch to a PNG for
a person to look at. The scripts cannot see, so they should print metrics()
and stop, and leave the looking to whoever runs the ramp.
"""

import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image, PngImagePlugin

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import pbr_bake  # noqa: E402

# The map size, one per texture resolution tier: 256 is the release pack,
# GOANNA_PBR_SIZE=128 builds the Low and Lowest one and 512 the Ultra one.
# Pixel measures written for 256 scale by PX, so a 512 map has the same
# features at twice the resolution and a 128 map at half. A measure that
# would fall under one pixel at 128 is kept at one (a chamfer, a bevel) or,
# for the micro surface, drawn at the 256 resolution and averaged down
# (SUPERSAMPLE, downsample), so a feature finer than a pixel fades rather
# than aliasing.
SIZE = int(os.environ.get("GOANNA_PBR_SIZE", "256"))
if SIZE not in (128, 256, 512):
    raise ValueError("GOANNA_PBR_SIZE must be 128, 256 or 512, not %d" % SIZE)
PX = SIZE / 256.0
# How many times finer the micro surface is drawn than the map: 2 at 128,
# else 1, which leaves the 256 and 512 builds exactly as they were.
SUPERSAMPLE = int(round(1.0 / PX)) if PX < 1.0 else 1
# What the micro surface's slopes are multiplied by: PX at 128, else 1. A
# chamfer cannot go under one pixel, so at 128 every step is twice as wide
# on the block as at 256 and half as steep, while a pore or a strand keeps
# its own slope. Unfaded, the micro surface stood twice as strong against
# the steps as in the reviewed 256 look, and the client's relief measure
# (the normal's slope over the height's, extrude.relief_depth) read up to
# twice the depth on skins whose steps carry micro detail: the chain mail
# leggings 0.12 node against 0.058. Faded by the same half, the balance
# and the measure are the 256 build's. The smoothness swing is not faded.
MICRO_FADE = PX if PX < 1.0 else 1.0


def px(measure, minimum=1):
    """A pixel measure written for the 256 map, at this map's size, rounded
    to whole pixels and never under minimum when the measure itself is
    above zero, so a one pixel chamfer stays one pixel at 128 rather than
    rounding to none. At 256 it is the measure, rounded."""
    v = float(measure) * PX
    if v <= 0.0:
        return 0
    return max(int(minimum), int(round(v)))


def downsample(field, f):
    """field averaged over f by f pixel blocks: a 2D field, or the first
    two axes of a 3D one. The shape must divide by f."""
    if f == 1:
        return field
    h, w = field.shape[:2]
    rest = field.shape[2:]
    return field.reshape((h // f, f, w // f, f) + rest).mean(axis=(1, 3)).astype(field.dtype)
# Every map this module writes carries a PNG text chunk naming the pipeline
# that made it, because the two pipelines encode the _n alpha differently and
# a reader cannot tell them apart from the bytes without guessing.
# tools/pbr/pbr_bake.py writes height as a class sized depth below a neutral 255;
# pack() below writes the authored field across the whole byte and leaves the
# depth to the shader's own class table (goanna_class_depth in
# project/shaders/nodes_array_common.gdshaderinc). tools/pbr/check-pbr-quality.py
# reads the chunk and picks the height rules from it. The chunk travels with
# the file: build_pack.py installs by copying bytes and tools/pbr/pbr_bundle.py
# stores the same bytes in the archive.
PIPELINE_KEY = "goanna_pipeline"
PIPELINE = "authored"
REPO = Path(__file__).resolve().parents[3]
GAMES_DIR = Path(os.environ.get("GOANNA_GAMES_DIR", os.path.expanduser(
        "~/.var/app/org.luanti.luanti/.minetest/games")))
# Per game: where its art is (a game root, indexed recursively) and which
# pack of packed _s files class_of reads the class back from. A script
# names its game with GAME = "..." at module level and passes it to
# load_source and class_of; the default keeps the Mineclonia scripts as
# they were. GOANNA_GAME_TEXTURES and GOANNA_PACK_TEXTURES override the
# default game's two paths, for a one off run.
GAMES = {
    "mineclonia": {
        "art": Path(os.environ.get("GOANNA_GAME_TEXTURES", str(GAMES_DIR / "mineclonia"))),
        "pack": Path(os.environ.get("GOANNA_PACK_TEXTURES", str(REPO / "pbr_packs/mineclonia/textures"))),
        "install": REPO / "pbr_packs/mineclonia/textures",
    },
    "kythen": {
        "art": GAMES_DIR / "kythen",
        "pack": Path(os.path.expanduser("~/.local/share/goanna-pbr-audit/bakes/kythen-terrain-v1")),
        "install": REPO / "pbr_packs/kythen/textures",
    },
    "minetest_game": {
        "art": GAMES_DIR / "minetest_game",
        "pack": REPO / "pbr_packs/minetest_game/textures",
        "install": REPO / "pbr_packs/minetest_game/textures",
    },
    # VoxeLibre installs as gameid mineclone2. Most of its art is
    # Mineclonia's, byte for byte, so its specs and classes start as
    # Mineclonia's and the frozen classes file is what class lookups read.
    # Its media audit (tools/pbr/pbr_audit_voxelibre.py) excludes stems whose
    # notices fail the media policy; build_pack.py never installs those,
    # and the audit rewrites the pack's ATTRIBUTION.md after an install.
    "voxelibre": {
        "art": GAMES_DIR / "mineclone2",
        "pack": REPO / "pbr_packs/voxelibre/textures",
        "install": REPO / "pbr_packs/voxelibre/textures",
        "excluded": REPO / "pbr_packs/manifests/voxelibre-pack-v1.excluded.json",
    },
}

# Community mods author like games: their art is the pinned release as
# tools/pbr/pbr_stage_sources.py stages it from pbr_packs/COMMUNITY_LOCK.json,
# and each has its own pack, since a mod runs under several games.
COMMUNITY_SRC = Path(os.environ.get("GOANNA_AUDIT_ROOT",
                                    os.path.expanduser("~/.local/share/goanna-pbr-audit"))) / "src"
for _mod in ("draconis", "goblins", "sum_airship", "animalia", "edit_skin",
             "cottages", "basic_materials", "dfcaverns", "nextgen_fungi",
             "steampunk_blimp", "mcl_decor", "mobs_animal", "mobs_monster", "bees",
             "x_farming", "moretrees"):
    GAMES[_mod] = {
        "art": COMMUNITY_SRC / _mod / _mod,
        "pack": REPO / "pbr_packs" / _mod / "textures",
        "install": REPO / "pbr_packs" / _mod / "textures",
    }
# Edit Skin draws on the game's player model, player_api's character.b3d.
GAMES["edit_skin"]["model_roots"] = [GAMES_DIR / "minetest_game"]
DEFAULT_GAME = "mineclonia"
GAME_TEXTURES = GAMES[DEFAULT_GAME]["art"]
PACK_TEXTURES = GAMES[DEFAULT_GAME]["pack"]
DIELECTRIC_F0 = pbr_bake.DIELECTRIC_F0


# --- inputs -----------------------------------------------------------------

_source_index = {}


def source_path(stem, game=DEFAULT_GAME):
    """Where the game keeps this stem's art. The art path may be a flat
    directory (mineclone2 ships one) or a game root whose mods each carry a
    textures directory (Mineclonia, Kythen), so it is indexed once per
    game, recursively."""
    root = GAMES[game]["art"]
    if game not in _source_index:
        idx = {}
        for p in sorted(root.rglob("*.png")):
            idx.setdefault(p.stem, p)
        _source_index[game] = idx
    idx = _source_index[game]
    if stem not in idx:
        raise FileNotFoundError("%s under %s" % (stem, root))
    return idx[stem]


def load_source(stem, game=DEFAULT_GAME):
    """The game's own art, RGBA float 0..1, at its own size: 16 px for
    Mineclonia, 32 px for most of Kythen. Every helper scales by the art's
    size, so a script need not care, but a strip or a sheet (an animation,
    a painting) comes back tall or wide and a script should check the
    shape it gets."""
    p = source_path(stem, game)
    return np.asarray(Image.open(p).convert("RGBA")).astype(np.float32) / 255.0


def art_size(stem, game=DEFAULT_GAME):
    """Texels across the art, for the seam measure's join spacing."""
    with Image.open(source_path(stem, game)) as im:
        return im.width


def load_baked_albedo(stem, game=DEFAULT_GAME):
    """The bake's 256 px albedo, RGB float, for a script that wants to keep
    it rather than upscale the source itself."""
    p = GAMES[game]["pack"] / (stem + ".png")
    return np.asarray(Image.open(p).convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)).astype(np.float32) / 255.0


def upscale(img, size=SIZE, smooth=False):
    """Nearest neighbour keeps the art's texel plateaus; smooth is bilinear
    and wraps at the tile edge, which PIL's resize does not (a smooth
    upscale of a periodic layout read a seam of about 8 on the ramp's
    measure before this wrapped)."""
    arr = np.clip(np.asarray(img, dtype=np.float32), 0.0, 1.0)
    if not smooth:
        a8 = (arr * 255.0 + 0.5).astype(np.uint8)
        mode = "RGBA" if a8.ndim == 3 and a8.shape[2] == 4 else ("RGB" if a8.ndim == 3 else "L")
        im = Image.fromarray(a8, mode).resize((size, size), Image.NEAREST)
        return np.asarray(im).astype(np.float32) / 255.0
    h, w = arr.shape[:2]
    # Sample positions in source texels, texel centres at .5, wrapping.
    ys = (np.arange(size) + 0.5) * h / size - 0.5
    xs = (np.arange(size) + 0.5) * w / size - 0.5
    y0 = np.floor(ys).astype(int)
    x0 = np.floor(xs).astype(int)
    fy = (ys - y0)[:, None]
    fx = (xs - x0)[None, :]
    y0 %= h
    x0 %= w
    y1 = (y0 + 1) % h
    x1 = (x0 + 1) % w
    if arr.ndim == 3:
        fy = fy[..., None]
        fx = fx[..., None]
    a = arr[y0][:, x0]
    b = arr[y0][:, x1]
    c = arr[y1][:, x0]
    d = arr[y1][:, x1]
    return ((a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy).astype(np.float32)


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


def band(field, half_width=0.05, centre=0.5):
    """A height field held in a narrow band about the middle instead of
    stretched to the full byte. The shader gives the full 0..1 range the
    depth of the material's class (a mortar joint for stone), so a nearly
    flat material that fills the range comes out as pumice: terracotta did,
    at 0.05 of a node per texel of noise. half_width is the material's real
    relief as a share of that class depth; 0.05 is a fired tile, 0.02 a
    cast slab, 0.5 a cobble. The field is standardised first so its own
    amplitude does not matter."""
    f = field.astype(np.float32)
    f = f - f.mean()
    # By range, not by standard deviation: a field that is mostly plateau
    # with a few flecks has a small deviation, and dividing by it threw the
    # flecks to the clip instead of into the band.
    f = f / max(float(np.abs(f).max()), 1e-6)
    return np.clip(centre + half_width * f, 0.0, 1.0)


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


# The horizon test reads a rise per map pixel, so at 128, where a step
# spans half the pixels, the same step read twice as steep and every joint
# came out darker than at 256 (seen on the GPU, 2026-10-05: stone's joints
# black at 128 against grey at 256). AO_SCALE takes the rise per 256 px map
# pixel instead. At 256 it is 1 and nothing changes; the 512 build keeps its
# own reading, lighter than 256's, as it was reviewed.
AO_SCALE = PX if PX < 1.0 else 1.0


def ao_from_height(height, radius_px=6):
    img = Image.fromarray((np.clip(height, 0, 1) * 255.0 + 0.5).astype(np.uint8), "L")
    return np.clip(pbr_bake.ao_from_height(img, strength=AO_SCALE, radius_px=radius_px, wrap=True),
                   0.0, 1.0).astype(np.float32)


# --- atlases ----------------------------------------------------------------
# A model atlas (a mob skin) does not tile and is cut into UV islands: two
# faces packed side by side in the image are not neighbours on the model,
# and the image's left edge is not next to its right. These variants of the
# two derivations above take an island map (one id per map pixel, -1 for
# none) and never read a neighbour across an island border or the image
# edge; a missing neighbour stands in as the pixel's own value, so a face
# runs flat to its edge.

def _island_same(islands, dy, dx):
    """Whether the pixel (dy, dx) away is in the same island and inside
    the image."""
    h, w = islands.shape
    pad = np.pad(islands, ((abs(dy), abs(dy)), (abs(dx), abs(dx))), constant_values=-2)
    ys, xs = abs(dy) + dy, abs(dx) + dx
    return pad[ys:ys + h, xs:xs + w] == islands


def _island_shift(field, islands, dy, dx):
    """field shifted by (dy, dx) without wrapping, with every sample that
    would come from another island or from outside the image replaced by
    the pixel's own value."""
    h, w = field.shape
    pad_f = np.pad(field, ((abs(dy), abs(dy)), (abs(dx), abs(dx))), mode="edge")
    ys, xs = abs(dy) + dy, abs(dx) + dx
    return np.where(_island_same(islands, dy, dx), pad_f[ys:ys + h, xs:xs + w], field)


def island_gradient(field, islands, axis):
    """Central difference inside an island, one sided at its border (a
    border pixel's slope is the slope to its one neighbour, not half of
    it), 0 where the pixel has no neighbour on that axis."""
    dy, dx = (1, 0) if axis == 0 else (0, 1)
    fwd = _island_same(islands, dy, dx)
    back = _island_same(islands, -dy, -dx)
    n = fwd.astype(np.float32) + back
    diff = _island_shift(field, islands, dy, dx) - _island_shift(field, islands, -dy, -dx)
    return np.where(n > 0, diff / np.maximum(n, 1.0), 0.0).astype(np.float32)


def normal_from_height_islands(height, strength, islands, slope=None):
    """normal_from_height without wrapping or crossing an island border.
    slope, when given, is (x, y) rise over run per pixel, image right and
    down, added to the height's own: detail too fine to differentiate."""
    h = height.astype(np.float32) * strength
    dx = island_gradient(h, islands, 1)
    dy = island_gradient(h, islands, 0)
    if slope is not None:
        dx = dx + slope[0]
        dy = dy + slope[1]
    n = np.stack([-dx, dy, np.ones_like(h)], axis=-1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return n[..., :2]


def ao_from_height_islands(height, islands, radius_px=6, directions=8):
    """pbr_bake.ao_from_height's horizon test, the same constants, reading
    only the pixel's own island."""
    h = (np.clip(height, 0, 1) * 255.0 + 0.5).astype(np.uint8).astype(np.float32) / 255.0
    occ = np.zeros_like(h)
    for d in range(directions):
        ang = 2.0 * np.pi * d / directions
        cx, cy = np.cos(ang), np.sin(ang)
        horizon = np.zeros_like(h)
        for r in range(1, radius_px + 1):
            sx, sy = int(round(cx * r)), int(round(cy * r))
            horizon = np.maximum(horizon, (_island_shift(h, islands, sy, sx) - h) / float(r))
        occ += np.clip(horizon, 0.0, None)
    occ = occ / float(directions)
    return np.clip(1.0 - occ * AO_SCALE * 4.0, 0.0, 1.0).astype(np.float32)


def class_of(stem, game=DEFAULT_GAME):
    """The bake's class for a stem, read back from its packed _s bytes and
    its name, the way tools/pbr/pbr_spec_variance.py infers it. The class
    decides the smoothness level, the scattering byte, the tilt target and
    the parallax depth, so a script should take it from here rather than
    guess. A game with no bake for the stem gets a guess from the name
    alone, and the script should say what it settled on."""
    import pbr_spec_variance
    pack = GAMES[game]["pack"]
    cls = pbr_spec_variance.infer_class(stem, pack) if pack.exists() else None
    if cls is None:
        for needle, c in pbr_spec_variance.NAME_HINTS:
            if needle in stem:
                return c
        for needle, c in (("stone", "stone"), ("rock", "stone"), ("brick", "stone"),
                ("clay", "soil"), ("earth", "soil"), ("moss", "leaves"), ("bark", "wood"),
                ("grass", "leaves"), ("thatch", "leaves"), ("cobble", "stone")):
            if needle in stem:
                return c
        return "default"
    return cls


def class_spec(cls):
    """(smoothness, f0, is_metal) from the bake's table."""
    return pbr_bake.CLASS_SPEC.get(cls, pbr_bake.DEFAULT_SPEC)


def sss_byte(cls):
    s = pbr_bake.CLASS_SSS.get(cls, 0.0)
    return int(round(65 + s * 190)) if s > 0.0 else 0


# --- packing ---------------------------------------------------------------

def pipeline_chunk():
    """The PNG text chunk that marks a map as authored. See PIPELINE_KEY."""
    info = PngImagePlugin.PngInfo()
    info.add_text(PIPELINE_KEY, PIPELINE)
    return info


def cutout_mask(albedo, alpha=None):
    """Which texels of a map the art does not draw, or None when it fills
    the tile.

    tools/pbr/pbr_bake.py's mask_transparent_regions puts a neutral default in
    exactly these texels of everything the bake writes, because a node's
    cut-out (a torch's air, a rail's gaps) never had material there to
    infer a surface from, and tools/pbr/check-pbr-quality.py holds both
    pipelines to it. The rule is the bake's: the source's own alpha byte
    under 128, nearest sampled to the map's size. It is read here from the
    alpha a script upscaled into the albedo, which is that same alpha at
    SIZE, quantised the way pack() is about to write it. alpha overrides
    that, for a script whose albedo is RGB although its art is a cut-out.
    """
    if alpha is None and np.ndim(albedo) == 3 and np.shape(albedo)[2] == 4:
        alpha = albedo[..., 3]
    if alpha is None:
        return None
    byte = (np.clip(np.asarray(alpha, dtype=np.float32), 0.0, 1.0)
            * 255.0 + 0.5).astype(np.uint8)
    mask = byte < 128
    return mask if mask.any() else None


SMOOTH_CEILING = 0.95


def _fits(values):
    """True when no value needs the smoothness clip, so a plain shift
    onto the level already puts the mean there."""
    return values.size == 0 or (values.min() >= 0.0 and values.max() <= SMOOTH_CEILING)


def _clipped_offset(deviation, level):
    """The offset t for which clip(deviation + t, 0, SMOOTH_CEILING) has
    mean level, by bisection (the clipped mean rises monotonically in t).

    A plain shift of the deviation onto the level and then a clip is not
    mean preserving: soil's level is 0.05 and a script's spread of 0.08 or
    more puts up to two fifths of the texels below zero, so the clip raised
    every Mineclonia soil to a mean of 0.09 to 0.11, over the quality
    gate's 0.075, and the rougher the script made the recesses the smoother
    the set came out. Shifting further down instead keeps the mean on the
    level and the shape of everything above zero; the recesses that were
    going to be clipped to fully rough still are."""
    target = min(max(level, 0.0), SMOOTH_CEILING)
    lo = -float(deviation.max())
    hi = SMOOTH_CEILING - float(deviation.min())
    for _ in range(60):
        t = 0.5 * (lo + hi)
        if np.clip(deviation + t, 0.0, SMOOTH_CEILING).mean() < target:
            lo = t
        else:
            hi = t
    return 0.5 * (lo + hi)


def pack(stem, out_dir, albedo, height, smoothness, cls, normal_strength,
        metal_mask=None, ao_radius=None, keep_mean=True, emission=None, f0=None,
        fine_detail=0.35, art_texels=16, alpha=None, normal_detail=None,
        islands=None, ao_height=None, sss=None, normal_slope=None, occlusion=None):
    """Write <stem>.png, <stem>_n.png and <stem>_s.png. albedo is RGB or
    RGBA float at SIZE; height and smoothness are SIZE x SIZE floats.
    The smoothness mean, over the ordinary texels the art draws, is moved
    onto the class level unless keep_mean is False, because the level was
    chosen on purpose and the ramp compares spread, not level. emission, when given, is a SIZE x SIZE float 0..1
    of how much each texel glows (the lit coals of a furnace, the body of
    glowstone); it goes to the _s alpha as LabPBR has it, 255 for none and
    0 to 254 for the strength, which nodes_array.gdshader reads as
    EMISSION = ALBEDO * strength * emission_strength. f0, when given, is
    a SIZE x SIZE float of dielectric reflectance at normal incidence for
    texels that are not metal (water 0.02, most things 0.04, diamond 0.17,
    emerald 0.16), written to the _s green byte as LabPBR's linear F0 up
    to 229; metal texels keep their metal byte. alpha, when given, is the
    source's alpha at SIZE for a cut-out whose albedo is RGB; a script
    that upscales the art as RGBA need not pass it. See cutout_mask.
    normal_detail, when given, is a height field added for the normal only
    (see the note where it is used). islands, when given, is a model
    atlas's island map at the map's size (tools/pbr/pbr_author/atlas.py): the
    normal and the occlusion are then derived without wrapping and without
    reading across an island border. ao_height, when given, is the field
    the occlusion is derived from instead of height: a skin part's own
    height where nothing is drawn over it and the height of what is drawn
    over it elsewhere, so a lock of hair shades the shirt beside it. sss,
    when given, is the _s blue byte per pixel (0 to 255) in place of the
    class's one value: skin scatters, the shirt over it does not.
    normal_slope and occlusion, with islands only, are a micro kind's
    normal given as slopes, (x, y) rise over run per map pixel added to the
    height's, and a factor 0..1 the occlusion is multiplied by (micro.py,
    SLOPE_KINDS)."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    # Texels the art does not draw are neutralised in both maps after
    # everything is derived, never before: the fields are built across the
    # whole tile so that a drawn texel beside a hole gets the slope and the
    # occlusion it would have had, and only the holes themselves are
    # overwritten. This is tools/pbr/pbr_bake.py's mask_transparent_regions,
    # applied to the authored path, and the constants are that function's
    # own so the two cannot drift apart.
    cutout = cutout_mask(albedo, alpha)
    height = np.clip(height, 0.0, 1.0).astype(np.float32)
    # The map takes the height field's shape: SIZE square for a tile, taller
    # for an animation strip, wider for a model atlas (extrude.py).
    shape = height.shape
    # Texel scale relief is scaled down before anything is derived from
    # the height. Under a grazing lamp in a cave every grain of noise
    # became its own shadow and stone read as rubble; a one texel groove
    # keeps this share of its depth, anything broader is untouched. Pass
    # fine_detail=1.0 for a surface whose texel scale detail is the point.
    if fine_detail < 0.999:
        fine = height - blur(height, max(1, round(PX)))
        height = np.clip(height - (1.0 - fine_detail) * fine, 0.0, 1.0)
    # normal_detail is surface character finer than the relief (pores,
    # grain, scratches), in the same units as height. It reaches the normal
    # only: the stored height, which the shader's parallax marches, and the
    # occlusion stay the macro field, so fine detail never blurs a step.
    nh = height if normal_detail is None else height + normal_detail
    radius = round(6 * PX) if ao_radius is None else ao_radius
    if islands is None:
        xy = normal_from_height(nh, normal_strength)
        ao = ao_from_height(height, radius)
    else:
        xy = normal_from_height_islands(nh, normal_strength, islands, normal_slope)
        ah = height if ao_height is None else np.clip(ao_height, 0.0, 1.0).astype(np.float32)
        ao = ao_from_height_islands(ah, islands, radius)
        if occlusion is not None:
            ao = (ao * np.clip(occlusion, 0.0, 1.0)).astype(np.float32)
    n = np.zeros(shape + (4,), dtype=np.float32)
    n[..., :2] = xy * 0.5 + 0.5
    n[..., 2] = ao
    n[..., 3] = height
    n8 = (n * 255.0 + 0.5).astype(np.uint8)
    if cutout is not None:
        n8[cutout] = pbr_bake.NEUTRAL_N
    Image.fromarray(n8, "RGBA").save(
            out_dir / (stem + "_n.png"), pnginfo=pipeline_chunk())

    level, _, is_metal = class_spec(cls)
    sm = np.clip(smoothness, 0.0, 1.0).astype(np.float32)
    if metal_mask is None:
        metal_mask = np.full(shape, bool(is_metal))
    if keep_mean:
        # The class level is the matrix's, so the mean is taken over the
        # ordinary texels: a metal vein or a gem sitting at 0.9 must not
        # drag the stone around it down to make the whole map average out.
        base = ~metal_mask
        if f0 is not None:
            base = base & (np.asarray(f0, dtype=np.float32) <= 0.05)
        # Nor is a cut-out's hole a texel of the surface: it is overwritten
        # with the neutral fill below, and a script's hole floor, low and
        # rough, held the mean down so that everything drawn sat well above
        # the level. The torch and the tall grass top came out 0.2 and 0.17
        # over it.
        if cutout is not None and (base & ~cutout).any():
            base = base & ~cutout
        ref = float(sm[base].mean()) if base.any() else float(sm.mean())
        # Only ever lowered: the ceiling's clip pulls a glassy class's mean
        # under its level, which the gate does not mind and which those
        # sets were judged with, so they keep the plain shift.
        offset = level
        if not _fits(sm[base] - ref + level):
            offset = min(level, _clipped_offset(sm[base] - ref, level))
        sm = np.clip(sm - ref + offset, 0.0, SMOOTH_CEILING)
        # No isolated mirror texels on an ordinary surface. A scatter of
        # smooth "dust" texels on sand each threw a pinpoint sun glint, and
        # seen through water at a grazing sun those came out as coloured
        # specks across the whole sea. Ordinary texels stay within a
        # spread of the class level; metal, gems and the glassy classes
        # keep what the script gave them.
        if cls not in ("glass", "ice", "metal"):
            sm = np.where(base, np.minimum(sm, level + 0.25), sm)
    s = np.zeros(shape + (4,), dtype=np.float32)
    s[..., 0] = sm
    diel = np.full(shape, float(DIELECTRIC_F0), dtype=np.float32)
    if f0 is not None:
        diel = np.clip(np.asarray(f0, dtype=np.float32) * 255.0, 0.0, 229.0)
    s[..., 1] = np.where(metal_mask, 255.0, diel) / 255.0
    s[..., 2] = (sss_byte(cls) if sss is None else np.asarray(sss, np.float32)) / 255.0
    if emission is None:
        s[..., 3] = 1.0
    else:
        e = np.clip(emission, 0.0, 1.0).astype(np.float32)
        s[..., 3] = np.where(e > 0.002, e * 254.0 / 255.0, 1.0)
    s8 = (s * 255.0 + 0.5).astype(np.uint8)
    # The bake masks _s as well as _n wherever the spec map has per texel
    # correspondence to the source, and skips it only for its flat class
    # spec, which is one constant colour at FLAT_SPEC_SIZE with nothing to
    # line up against the art. An authored _s is per texel at the map's own
    # size, so it is the case the bake does mask: no smoothness, no F0, no
    # scattering and no emission are carried in a hole.
    if cutout is not None:
        s8[cutout] = pbr_bake.NEUTRAL_S
    Image.fromarray(s8, "RGBA").save(
            out_dir / (stem + "_s.png"), pnginfo=pipeline_chunk())

    a = np.clip(albedo, 0.0, 1.0)
    if a.ndim == 3 and a.shape[2] == 4:
        Image.fromarray((a * 255.0 + 0.5).astype(np.uint8), "RGBA").save(out_dir / (stem + ".png"))
    else:
        Image.fromarray((a[..., :3] * 255.0 + 0.5).astype(np.uint8), "RGB").save(out_dir / (stem + ".png"))
    return metrics(out_dir, stem, art_texels)


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
    # Rows and columns separately, so a map taller than it is wide (an
    # animation strip) is measured along both its sides.
    rows = [np.abs(a[j] - a[j - 1]).mean() for j in range(step, a.shape[0], step)]
    cols = [np.abs(a[:, j] - a[:, j - 1]).mean() for j in range(step, a.shape[1], step)]
    inner = (np.mean(rows) if rows else 0.0) + (np.mean(cols) if cols else 0.0)
    return float(wrap / max(inner, 1e-3))


def metrics(out_dir, stem, art_texels=16):
    """Everything the targets above ask for, from the files as written.
    art_texels is the art's width, for the albedo seam's join spacing."""
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
        "seam_albedo": seam_energy(a, max(1, SIZE // max(art_texels, 1))),
        "emissive_share": float((s[..., 3] < 0.999).mean()),
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

# 3d_armor is a modpack; its art and models sit under the pack root.
GAMES["3d_armor"] = {
    "art": COMMUNITY_SRC / "3d_armor" / "3d_armor",
    "pack": REPO / "pbr_packs" / "3d_armor" / "textures",
    "install": REPO / "pbr_packs" / "3d_armor" / "textures",
}
