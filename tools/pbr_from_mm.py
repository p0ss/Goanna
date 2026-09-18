#!/usr/bin/env python3
"""Turn a Material Maker export into LabPBR sets for a pack.

Material Maker (io.github.RodZill4.Material-Maker) exports a material as a
set of PNGs, one per channel: albedo, normal (OpenGL, green up), roughness,
metallic, ambient occlusion, depth or height, and emission, named
<material>_<channel>.png, or in the Godot 4 format an ORM image carrying
occlusion, roughness and metallic in its channels. This packs those into
the pair the client reads (see docs/materials.md), under the stem of the
game texture they are to dress, and writes the albedo beside them.

  tools/pbr_from_mm.py <export dir> --map bricks=default_brick,gravel=default_gravel
      --out <pack textures dir> [--size 256] [--flip-green]

The map is Material Maker name to game stem. The normal's green is flipped
by default because Material Maker writes OpenGL normals (green toward
minus V) and the client reads green toward plus V, the convention
tools/pbr_author/lib.py writes; --flip-green turns that off when an export
was made with the DirectX option. Depth is stored as height, one minus the
export's value, since Material Maker's depth is deeper for larger values.

Why this exists: a texture pack assembled from free Material Maker
materials is a benchmark for the renderer that owes nothing to the bake or
the authoring, so a defect it shows is the client's. It is not a pack to
ship for a game whose art is someone else's; the material has to match the
block's art, which a generic brick does only by luck.
"""

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent / "pbr_author"))
import lib  # noqa: E402

CHANNELS = {
    "albedo": ("albedo", "basecolor", "base_color", "color", "diffuse"),
    "normal": ("normal",),
    "roughness": ("roughness", "rough"),
    "metallic": ("metallic", "metal", "metalness"),
    "ao": ("ao", "occlusion", "ambient_occlusion"),
    "depth": ("depth", "displacement"),
    "height": ("height", "heightmap"),
    "emission": ("emission", "emissive"),
    "orm": ("orm",),
}


def find(export_dir, material):
    """The channel files of one material, by suffix."""
    found = {}
    for p in sorted(Path(export_dir).glob(material + "_*.png")):
        suffix = p.stem[len(material) + 1:].lower()
        for chan, names in CHANNELS.items():
            if suffix in names:
                found[chan] = p
    return found


def load(p, size, mode="L"):
    im = Image.open(p).convert(mode).resize((size, size), Image.LANCZOS)
    return np.asarray(im).astype(np.float32) / 255.0


def convert(export_dir, material, stem, out_dir, size, flip_green):
    files = find(export_dir, material)
    if "albedo" not in files or "normal" not in files:
        return "missing %s" % ", ".join(c for c in ("albedo", "normal") if c not in files)
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    albedo = load(files["albedo"], size, "RGBA")
    normal = load(files["normal"], size, "RGB")
    if "orm" in files:
        orm = load(files["orm"], size, "RGB")
        ao, rough, metal = orm[..., 0], orm[..., 1], orm[..., 2]
    else:
        rough = load(files["roughness"], size) if "roughness" in files else np.full((size, size), 0.8, np.float32)
        metal = load(files["metallic"], size) if "metallic" in files else np.zeros((size, size), np.float32)
        ao = load(files["ao"], size) if "ao" in files else np.ones((size, size), np.float32)
    # Godot 4 Standard writes a heightmap, white high, which is what the
    # client stores; a depth export is the other way up.
    if "height" in files:
        height = load(files["height"], size)
    elif "depth" in files:
        height = 1.0 - load(files["depth"], size)
    else:
        height = lib.normalise01(np.mean(albedo[..., :3], -1))
    emission = load(files["emission"], size) if "emission" in files else None

    n = np.zeros((size, size, 4), np.float32)
    n[..., 0] = normal[..., 0]
    n[..., 1] = (1.0 - normal[..., 1]) if flip_green else normal[..., 1]
    n[..., 2] = ao
    n[..., 3] = height
    Image.fromarray((n * 255 + 0.5).astype(np.uint8), "RGBA").save(out_dir / (stem + "_n.png"))
    s = np.zeros((size, size, 4), np.float32)
    s[..., 0] = np.clip(1.0 - rough, 0.0, 0.95)
    s[..., 1] = np.where(metal > 0.5, 255.0, float(lib.DIELECTRIC_F0)) / 255.0
    s[..., 2] = 0.0
    if emission is not None:
        s[..., 3] = np.where(emission > 0.002, emission * 254.0 / 255.0, 1.0)
    else:
        s[..., 3] = 1.0
    Image.fromarray((s * 255 + 0.5).astype(np.uint8), "RGBA").save(out_dir / (stem + "_s.png"))
    Image.fromarray((albedo * 255 + 0.5).astype(np.uint8), "RGBA").save(out_dir / (stem + ".png"))
    m = lib.metrics(out_dir, stem, 1)
    return "tilt %.1f ao_min %.2f smooth %.2f +- %.2f metal %.0f%%" % (
            m["tilt_mean_deg"], m["ao_min"], m["smooth_mean"], m["smooth_sd"], (metal > 0.5).mean() * 100)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("export_dir", type=Path)
    ap.add_argument("--map", required=True, help="mm_name=stem,mm_name=stem")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--size", type=int, default=256)
    ap.add_argument("--flip-green", action="store_false", dest="flip_green",
            help="do not flip green (export was DirectX style)")
    args = ap.parse_args()
    for pair in args.map.split(","):
        if "=" not in pair:
            continue
        material, stem = pair.split("=", 1)
        print("%-28s -> %-32s %s" % (material, stem,
                convert(args.export_dir, material.strip(), stem.strip(), args.out, args.size, args.flip_green)))


if __name__ == "__main__":
    main()
