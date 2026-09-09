#!/usr/bin/env python3
"""Select community-mod world materials for a PBR bake.

ContentDB archives mix node textures with UI art, screenshots, particles and
entity atlases.  This deliberately conservative selector keeps small square
PNGs referenced by a register_node call.  Packages which construct stained
glass names dynamically can be opted in as texture-directory families.

The output has the same shape as tools/goanna_nodedef_dump.lua, so it can be
passed directly to tools/pbr_bake.py --nodedefs.  Existing companions are
excluded to avoid rebaking a base-game texture merely reused by a mod.
"""

import argparse
import json
import re
from pathlib import Path

from PIL import Image


PNG_RE = re.compile(r"[A-Za-z0-9_@.\-]+\.png")
REGISTER_PATTERNS = {
    "node": re.compile(r"(?:minetest|core)\.register_node\s*\("),
    "item": re.compile(r"(?:minetest|core)\.register_(?:craftitem|tool)\s*\("),
    "creature": re.compile(r"(?:minetest|core)\.register_entity\s*\("),
}
FLAT_DRAWTYPES = {
    "plantlike", "firelike", "signlike", "torchlike", "raillike",
    "rooted_plantlike", "plantlike_rooted", "allfaces", "allfaces_optional",
}
EXCLUDE = (
    "inventory", "_inv", "wield", "icon", "logo", "screenshot", "preview",
    "particle", "crosshair", "formspec", "button", "background", "mask",
    "guide", "palette", "blank", "unknown_node", "_overlay", "footprint",
    "cloud",
)
DYNAMIC_FAMILIES = {"glass_stained", "stainedglass"}
LITERAL_FAMILIES = {
    "advtrains", "cottages", "everness", "fachwerk", "goblins", "lanterns",
    "mesecons", "moreblocks", "morelights", "pipeworks", "xdecor",
}
CREATURE_FAMILIES = {"animalia", "goblins"}
PACKAGE_CAPS = {
    "advtrains": 40, "ebiomes": 60, "ethereal": 60, "everness": 100,
    "mesecons": 60, "naturalbiomes": 60, "pipeworks": 60,
    "techage_modpack": 150, "xdecor": 60,
}
MATERIAL_WORDS = (
    "stone", "brick", "cobble", "wood", "plank", "metal", "steel", "copper",
    "bronze", "brass", "glass", "tile", "block", "wall", "floor", "roof",
    "ore", "sand", "dirt", "clay", "crystal", "ice", "pipe", "tube",
    "machine", "rail", "gravel", "concrete", "asphalt", "slate",
)


def register_blocks(text, pattern):
    for match in pattern.finditer(text):
        start = match.start()
        depth = 0
        quote = None
        escape = False
        for pos in range(match.end(), len(text)):
            char = text[pos]
            if quote:
                if escape:
                    escape = False
                elif char == "\\":
                    escape = True
                elif char == quote:
                    quote = None
                continue
            if char in "\"'":
                quote = char
            elif char in "({[":
                depth += 1
            elif char in (")", "}", "]"):
                depth -= 1
                if depth <= 0:
                    yield text[start:pos + 1]
                    break


def table_field(block, field):
    """Return a Lua table field without consuming later inventory artwork."""
    match = re.search(r"\b%s\s*=\s*\{" % re.escape(field), block)
    if not match:
        return ""
    start = block.find("{", match.start())
    depth = 0
    quote = None
    escape = False
    for pos in range(start, len(block)):
        char = block[pos]
        if quote:
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == quote:
                quote = None
            continue
        if char in "\"'":
            quote = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return block[start:pos + 1]
    return ""


def node_tile_names(block):
    names = set()
    for field in ("tiles", "overlay_tiles", "special_tiles"):
        names.update(PNG_RE.findall(table_field(block, field)))
    return names


def item_image_names(block):
    names = set()
    for match in re.finditer(r"\b(?:inventory_image|wield_image)\s*=\s*"
                             r"[\"']([^\"']+)", block):
        names.update(PNG_RE.findall(match.group(1)))
    return names


def material_class(name, package=""):
    lower = name.lower()
    # This package names minerals such as silver, celestine and pumice. Those
    # substrings describe rock species, not metal, glass or ice materials.
    if package == "too_many_stones":
        return "stone"
    if "sandstone" in lower:
        return "stone"
    if any(word in lower for word in ("soil", "dirt", "earth", "mud")):
        return "soil"
    if "gravel" in lower:
        return "gravel"
    if "snow" in lower:
        return "snow"
    if "ice" in lower and "device" not in lower:
        return "ice"
    if any(word in lower for word in ("cloth", "wool", "fabric", "carpet")):
        return "cloth"
    if "sand" in lower:
        return "sand"
    if any(word in lower for word in ("glass", "crystal", "ice", "lens")):
        return "glass"
    if any(word in lower for word in (
            "steel", "metal", "copper", "bronze", "brass", "gold", "silver",
            "tin", "iron", "pipe", "tube", "rail", "machine", "motor",
            "gear", "chain", "grate", "wire", "cable")):
        return "metal"
    if any(word in lower for word in ("wood", "tree", "trunk", "log", "plank")):
        return "wood"
    if any(word in lower for word in (
            "leaf", "leaves", "grass", "plant", "flower", "moss", "bush",
            "fern", "vine", "mushroom", "cactus")):
        return "organic"
    return "stone"


def valid_texture(path, tranche):
    lower = path.name.lower()
    if any(word in lower for word in EXCLUDE):
        return False
    try:
        with Image.open(path) as image:
            width, height = image.size
    except OSError:
        return False
    if tranche == "terrain":
        return width == height and 8 <= width <= 64
    return 8 <= width <= 1024 and 8 <= height <= 1024


def relevance(stem):
    lower = stem.lower()
    score = sum(5 for word in MATERIAL_WORDS if word in lower)
    score += 2 if any(word in lower for word in ("side", "top", "bottom")) else 0
    score -= 3 if any(word in lower for word in ("active", "on", "off", "front")) else 0
    score -= sum(char.isdigit() for char in lower)
    return score


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sources", required=True)
    parser.add_argument("--existing-pack", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--tranche", choices=("terrain", "billboard", "creature"),
                        default="terrain")
    parser.add_argument("--include-packages", default="")
    parser.add_argument("--exclude-packages", default="")
    args = parser.parse_args()

    root = Path(args.sources)
    existing = Path(args.existing_pack)
    include = {item for item in args.include_packages.split(",") if item}
    exclude = {item for item in args.exclude_packages.split(",") if item}
    records = []
    selected = {}
    for package in sorted(path for path in root.iterdir() if path.is_dir()):
        if (include and package.name not in include) or package.name in exclude:
            continue
        names = set()
        literal_names = set()
        for lua in package.rglob("*.lua"):
            try:
                text = lua.read_text(errors="ignore")
            except OSError:
                continue
            literal_names.update(PNG_RE.findall(text))
            if args.tranche in ("terrain", "billboard"):
                for block in register_blocks(text, REGISTER_PATTERNS["node"]):
                    match = re.search(r"drawtype\s*=\s*[\"']([^\"']+)", block)
                    drawtype = match.group(1) if match else "normal"
                    flat = drawtype in FLAT_DRAWTYPES
                    if args.tranche == "terrain" and drawtype in (
                            "airlike", "liquid", "flowingliquid"):
                        continue
                    if flat == (args.tranche == "billboard"):
                        names.update(node_tile_names(block))
            if args.tranche == "billboard":
                for block in register_blocks(text, REGISTER_PATTERNS["item"]):
                    names.update(item_image_names(block))
            elif args.tranche == "creature":
                for block in register_blocks(text, REGISTER_PATTERNS["creature"]):
                    names.update(PNG_RE.findall(block))
        textures = {path.name: path for path in package.rglob("*.png")
                    if "texture" in str(path.parent).lower()}
        if args.tranche == "terrain" and package.name in DYNAMIC_FAMILIES:
            names.update(textures)
        if args.tranche == "terrain" and package.name in LITERAL_FAMILIES:
            names.update(literal_names)
        if args.tranche == "creature" and package.name in CREATURE_FAMILIES:
            names.update(literal_names)
        for name in sorted(names):
            path = textures.get(name)
            stem = Path(name).stem
            if not path or not valid_texture(path, args.tranche):
                continue
            if (existing / (stem + "_n.png")).exists():
                continue
            # Flat Luanti media names collide globally. Keep the first pinned
            # package deterministically and expose collisions in the record.
            if stem in selected:
                selected[stem]["collisions"].append(package.name)
                continue
            selected[stem] = {
                "package": package.name,
                "source": str(path.relative_to(root)),
                "class": material_class(name, package.name),
                "collisions": [],
            }

    if args.tranche == "terrain":
        selected = {stem: item for stem, item in selected.items()
                    if item["class"] != "organic"}
    caps = PACKAGE_CAPS.items() if args.tranche == "terrain" else ()
    for package, cap in caps:
        members = [(stem, item) for stem, item in selected.items()
                   if item["package"] == package]
        keep = {stem for stem, _item in sorted(
            members, key=lambda pair: (-relevance(pair[0]), pair[0]))[:cap]}
        selected = {stem: item for stem, item in selected.items()
                    if item["package"] != package or stem in keep}

    classes = {
        "metal": ("default_metal_footstep", "normal", {}),
        "glass": ("default_glass_footstep", "glasslike", {}),
        "wood": ("default_wood_footstep", "normal", {"wood": 1}),
        "organic": ("default_grass_footstep", "normal", {"flora": 1}),
        "sand": ("default_sand_footstep", "normal", {}),
        "gravel": ("default_gravel_footstep", "normal", {}),
        "soil": ("default_dirt_footstep", "normal", {}),
        "snow": ("default_snow_footstep", "normal", {}),
        "ice": ("default_ice_footstep", "normal", {}),
        "cloth": ("default_cloth_footstep", "normal", {}),
        "stone": ("default_hard_footstep", "normal", {}),
    }
    for kind, (sound, drawtype, groups) in classes.items():
        tiles = [stem + ".png" for stem, item in selected.items()
                 if item["class"] == kind]
        if tiles:
            records.append({"sound_footstep": sound, "drawtype": drawtype,
                            "groups": groups, "tiles": sorted(tiles)})
    Path(args.out).write_text(json.dumps(records, indent=2, sort_keys=True) + "\n")
    manifest = Path(args.out).with_suffix(".sources.json")
    manifest.write_text(json.dumps(selected, indent=2, sort_keys=True) + "\n")
    counts = {kind: sum(item["class"] == kind for item in selected.values())
              for kind in classes}
    print(json.dumps({"selected": len(selected), "classes": counts}, sort_keys=True))


if __name__ == "__main__":
    main()
