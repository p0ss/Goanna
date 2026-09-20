#!/usr/bin/env python3
"""Draft a classification review from a game's own definition dump.

A hand written review is the ideal, and for a game of a few hundred textures
it is also a fortnight of work. The definition dump already carries the
evidence a reviewer would use first: the drawtype says whether a face tiles
or is a cut-out billboard, and the footstep sound names the material. This
turns that into review records so a bake has bands and treatments, marks
every record as derived rather than judged, and leaves the per-texture
argument to a person.

What it does not do is decide anything the data does not say. Material comes
from tools/pbr_bake.py's own classifier, the bands are that module's
material defaults, and confidence stays moderate with review_required set,
so nothing here can be mistaken for an approved release record.

Each record names the field that produced its class: the node and its
footstep sound, its drawtype, or its material group. Where the registration
names no material at all, the record says so, keeps the neutral default
class and writes no bands, because a band invented for an unknown material
is read downstream as a measurement. tools/check-pbr-quality.py compares a
bake against whatever bands it finds, and a derived band that is narrower
than the checker's own default for an unknown material turns a guess into a
failure.
"""

import argparse
import collections
import json
from pathlib import Path

import pbr_bake

# Drawtypes whose face is a cut-out sprite: it has an alpha edge, it is never
# seen repeating, and relief on it belongs to the silhouette rather than a
# surface.
BILLBOARD_DRAWTYPES = {
    "plantlike", "firelike", "signlike", "torchlike", "raillike",
}
ROOTED = "plantlike_rooted"
LIQUID_DRAWTYPES = {"liquid", "flowingliquid"}
# plantlike_rooted is a tiling drawtype and not a billboard one, which reads
# backwards until you look at what the dump holds for such a node: its tiles
# are the ground cube the plant is rooted in, and the plant itself lives in
# special_tiles, which the dump does not carry. Mineclonia's
# mcl_ocean:kelp_sand lists default_sand.png, so calling the drawtype a
# billboard marked sand, gravel, stone and coral blocks as cut-out sprites
# that do not tile.
#
# mesh is deliberately absent: a mesh node's texture is a UV sheet for one
# model, so its opposite edges are not meant to meet. liquid is present
# because a liquid drawtype only reaches a record at all when shader_owned
# below has already found it is a solid block drawn through the liquid path,
# and such a block is an ordinary cube.
TILING_DRAWTYPES = {
    "normal", "nodebox", "allfaces", "allfaces_optional", "glasslike",
    "glasslike_framed", "glasslike_framed_optional", ROOTED, "liquid",
}
# How much a class derived from each kind of evidence is worth. A footstep
# sound and a material naming drawtype are the game saying what the thing is
# made of; a digging group is the game saying which tool breaks it, which
# correlates with material but is not a statement about it.
EVIDENCE_CONFIDENCE = {"footstep": 0.7, "drawtype": 0.7, "group": 0.45,
                       "unnamed": 0.45}
NO_EVIDENCE_CONFIDENCE = 0.2


def shader_owned(node):
    """True when the renderer, not a baked map, owns this node's surface.

    An airlike node has no face at all, and a liquid's surface is the
    shader's. The drawtype alone does not prove a liquid though: Mineclonia
    registers ice and frosted ice with drawtype liquid so they blend and
    connect the way water does, and those are walkable blocks with ordinary
    art on them. Every genuine liquid in that dump carries a viscosity and
    every one of the solids carries none, so the viscosity decides.
    """
    drawtype = node.get("drawtype") or ""
    if drawtype == "airlike":
        return True
    return (drawtype in LIQUID_DRAWTYPES
            and float(node.get("liquid_viscosity") or 0) > 0)


def bands(material):
    """Smoothness band and relief from the bake's own material defaults."""
    centre = pbr_bake.CLASS_SPEC.get(material, pbr_bake.DEFAULT_SPEC)[0]
    relief = pbr_bake.CLASS_HEIGHT_DEPTH.get(
        material, pbr_bake.DEFAULT_HEIGHT_DEPTH)
    return round(max(0.02, centre * 0.4), 3), round(min(0.95, centre * 1.5), 3), relief


def material_evidence(node):
    """The node's material class and the field that named it.

    tools/pbr_bake.py's classify_node stays the only classifier. To find out
    which field carried the class, this asks the same function what each
    field says with the others absent, so a rationale can only ever name a
    field that really produces the answer. A second copy of the rules here
    would drift from the ones the bake applies, and the file would then
    describe evidence the bake never used.
    """
    material = pbr_bake.classify_node(node)
    if not material:
        return None, "", ""
    drawtype = node.get("drawtype") or ""
    footstep = node.get("sound_footstep") or ""
    groups = node.get("groups") or {}
    # In classify_node's own order of precedence.
    if drawtype in pbr_bake.GLASSY_DRAWTYPES and material == "glass":
        return material, "drawtype", "its drawtype %s" % drawtype
    if pbr_bake.classify_node({"sound_footstep": footstep}) == material:
        return material, "footstep", "its footstep sound %s" % footstep
    named = sorted(g for g in groups if pbr_bake.GROUP_CLASS.get(g) == material)
    if named:
        return material, "group", "its group %s" % named[0]
    if pbr_bake.DRAWTYPE_CLASS.get(drawtype) == material:
        return material, "drawtype", "its drawtype %s" % drawtype
    return material, "unnamed", "its own registration"


def owning_nodes(nodes):
    """The nodes whose material the texture actually is.

    A stem is usually listed by more than one node, and a flat majority across
    all of them takes the wrong answer twice in Mineclonia:

    A sprite drawn in a container keeps the container's sound.
    flowers_tulip.png is a tile of both mcl_flowers:tulip_orange (plantlike,
    grass footstep) and mcl_flowerpots:flower_pot_tulip_orange (mesh, hard
    footstep), and the flat vote called the tulip stone. Where any node draws
    the texture as a cut-out sprite, that node owns it.

    A rooted plant copies the ground's face, not its sound. Mineclonia
    registers a sea pickle for every ground it can sit on, ten of them for
    default_sand.png alone, and gives all of them default_dirt_footstep
    whatever the ground is. That outvoted the five real sand nodes and called
    sand soil, gravel soil, and every coral block soil. Where a non rooted
    node lists the texture, the rooted copies do not vote.
    """
    sprites = [n for n in nodes if (n.get("drawtype") or "") in BILLBOARD_DRAWTYPES]
    if sprites:
        return sprites
    own = [n for n in nodes if (n.get("drawtype") or "") != ROOTED]
    return own or nodes


def vote(nodes):
    """(material, evidence kind, rationale clause) for one texture stem."""
    tally = collections.Counter()
    detail = {}
    for node in owning_nodes(nodes):
        material, kind, clause = material_evidence(node)
        if not material:
            continue
        tally[material] += 1
        detail.setdefault(material, (kind, clause, node.get("name") or "?"))
    if not tally:
        return None, "", ""
    material = tally.most_common(1)[0][0]
    kind, clause, name = detail[material]
    return material, kind, "%s names it through %s" % (name, clause)


def node_records(nodes, game):
    """One record per texture stem a node draws with."""
    # A texture a genuine liquid draws with is that liquid's surface art
    # wherever else it turns up. Mineclonia's mangrove roots show
    # default_water_source_animated on an ordinary cube face, which was
    # enough to put the water sheet in the terrain tranche and bake a soil
    # normal map for it.
    shader_stems = {tile[:-4] for node in nodes if shader_owned(node)
                    for tile in node.get("tiles", []) if tile.endswith(".png")}
    by_stem = collections.OrderedDict()
    for node in nodes:
        if shader_owned(node):
            continue
        for tile in node.get("tiles", []):
            if tile.endswith(".png") and tile[:-4] not in shader_stems:
                by_stem.setdefault(tile[:-4], []).append(node)

    textures = {}
    for stem, owners in by_stem.items():
        drawtypes = {node.get("drawtype") or "" for node in owners}
        billboard = bool(drawtypes & BILLBOARD_DRAWTYPES)
        material, kind, clause = vote(owners)
        record = {
            "primary_material": material or "default",
            "secondary_materials": [],
            "metalness_policy": "predominant" if material == "metal" else "none",
        }
        if material:
            low, high, relief = bands(material)
            record.update(smoothness_min=low, smoothness_max=high,
                          relief_strength=relief)
        record.update({
            "treatment": "billboard" if billboard else "terrain",
            "tiles": bool(drawtypes & TILING_DRAWTYPES) and not billboard,
            "confidence": EVIDENCE_CONFIDENCE.get(kind, NO_EVIDENCE_CONFIDENCE),
        })
        if material:
            record["rationale"] = (
                "Derived from %s's own node registration: %s. The bands are "
                "the pipeline's %s defaults, not a per texture judgement."
                % (game, clause, material))
        else:
            first = owners[0].get("name") or "?"
            drawn_by = (first if len(owners) == 1
                        else "%s and %d others" % (first, len(owners) - 1))
            record["rationale"] = (
                "%s's registration names no material for this texture: no "
                "node drawing it (%s) carries a footstep sound, a material "
                "group or a material naming drawtype. The class is the "
                "neutral default and this record sets no bands, so nothing "
                "downstream reads a guess as a measurement."
                % (game, drawn_by))
        record["review_required"] = True
        textures[stem] = record
    return textures


def item_records(items, game, taken):
    """One record per item icon that no node already covers."""
    textures = {}
    for item in items:
        for tile in item.get("textures", []):
            if not tile.endswith(".png"):
                continue
            stem = tile[:-4]
            if stem in taken or stem in textures:
                continue
            textures[stem] = {
                "primary_material": "default",
                "secondary_materials": [],
                "metalness_policy": "none",
                "treatment": "item",
                "tiles": False,
                "confidence": NO_EVIDENCE_CONFIDENCE,
                "rationale": "An item icon in %s's registration (%s) with no "
                             "node to take a material from. The item "
                             "definition carries no material evidence at all, "
                             "so this record names no material and sets no "
                             "bands." % (game, item.get("name") or "?"),
                "review_required": True,
            }
    return textures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--nodedefs", required=True)
    parser.add_argument("--itemdefs")
    parser.add_argument("--out", required=True)
    parser.add_argument("--review-version", required=True)
    parser.add_argument("--game", required=True,
                        help="name of the game, for the rationale")
    parser.add_argument("--note", action="append", default=[],
                        help="a sentence about this game's own art that the "
                             "dump cannot say for itself, kept in the "
                             "document's derivation block. Repeatable. This "
                             "is where a family that is still a guess gets "
                             "written down instead of being left implied")
    args = parser.parse_args()

    nodes = json.loads(Path(args.nodedefs).read_text())
    textures = node_records(nodes, args.game)
    if args.itemdefs:
        textures.update(item_records(json.loads(Path(args.itemdefs).read_text()),
                                     args.game, set(textures)))

    derived = sum(1 for record in textures.values()
                  if record["primary_material"] != "default")
    document = {
        "schema_version": 1,
        "review_version": args.review_version,
        "reviewed_manifests": [Path(args.nodedefs).name] +
                              ([Path(args.itemdefs).name] if args.itemdefs else []),
        "resolution": "derived",
        "derivation": {
            "tool": "tools/pbr_review_from_defs.py",
            "material_from": "the class tools/pbr_bake.py's classify_node reads "
                             "out of the node's own footstep sound, drawtype or "
                             "material group",
            "bands_from": "the pipeline's per class defaults in "
                          "tools/pbr_bake.py, not measurement of the art",
            "with_a_material": derived,
            "without_a_material": len(textures) - derived,
            "caveat": "No record here is a per texture judgement. A record "
                      "with a material states which node and which field "
                      "named it; a record without one sets no bands. Both "
                      "carry review_required.",
            "notes": list(args.note),
        },
        "textures": dict(sorted(textures.items())),
    }
    Path(args.out).write_text(json.dumps(document, indent=2) + "\n")
    counts = collections.Counter()
    evidence = collections.Counter()
    for record in textures.values():
        counts["%s/%s" % (record["treatment"], record["primary_material"])] += 1
        evidence[record["confidence"]] += 1
    print(json.dumps({"textures": len(textures),
                      "with_a_material": derived,
                      "by_treatment_and_material": dict(sorted(counts.items())),
                      "by_confidence": {str(k): v for k, v
                                        in sorted(evidence.items())}},
                     indent=2))


if __name__ == "__main__":
    main()
