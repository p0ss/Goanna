#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Rank a PBR pack's stems by how much a player sees them, and batch the
ones still to be authored by material family.

Input is the JSON the pbr_census worldmod writes (tools/pbr_census/init.lua):
exposed face counts per node and context, and every item's tiles, groups
and recipe evidence. Output is two JSON files, the per stem census and the
batches, which tools/pbr_census/README.md describes.

    python3 tools/pbr_census/rank.py \\
        --census <world>/pbr_census.json \\
        --pack pbr_packs/mineclonia/textures \\
        --out pbr_packs/census/mineclonia-2026-09.json \\
        --batches pbr_packs/census/mineclonia-2026-09-batches.json

Every weight below is a judgement, not a measurement. They are written into
the output beside the raw counts, so anyone who disagrees can reweigh the
same counts without running the server again.
"""

import argparse
import collections
import json
import math
import re
import statistics
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools"))
sys.path.insert(0, str(REPO / "tools" / "pbr_author"))

# How much each context counts, as a share of what a player looks at. The
# surface is where a player spends most of the day; caves and liquids are
# visited; the Nether less and the End least. The villages stand in for
# what players build, which natural generation barely contains.
CTX_WEIGHTS = {"surface": 0.50, "cave": 0.17, "liquid": 0.08,
               "nether": 0.08, "end": 0.02, "village": 0.15}
# The final score: measured exposure, plus the build heuristic below.
EXPOSURE_WEIGHT = 0.88
BUILD_WEIGHT = 0.12
# A billboard node (a tuft of grass, a torch) counted once, in faces.
BILLBOARD_FACES = {"plantlike": 1.5, "firelike": 1.5}
BUCKETS = ("top", "bottom", "side", "rotated", "billboard")

# Build heuristic, per placeable item. See README.md.
CATEGORY_FACTOR = {"building_block": 1.0, "deco_block": 0.8}
OTHER_CATEGORY = 0.4
UNOBTAINABLE = 0.3       # creative only, or found but never crafted or mined
COLOUR_FAMILY = 0.25     # one of sixteen colours: players pick a few
SHAPE_FACTOR = 0.5       # stairs, slabs, walls, fences: the stem is the block's
UTILITY_FACTOR = 3.0     # blocks every base has and a player faces daily,
                         # not applied to one colour of a colour family
VARIANT_FACTOR = 0.25    # further items drawing a stem already counted
UTILITY = re.compile(
    r"crafting_table|:furnace$|:chest$|:trapped_chest|:barrel|:bed_|"
    r"wooden_door|door$|trapdoor$|:ladder|:torch$|:glass$|glass_pane|"
    r"pane_natural|:bookshelf$|:anvil$|enchanting_table|brewing_stand|"
    r":smoker$|blast_furnace|stonecutter|:loom$|smithing_table|grindstone|"
    r"cartography_table|fletching_table|composter|lectern|jukebox|"
    r"noteblock|hopper$|cauldron$|lanterns:(soul_)?lantern|campfire|"
    r"farmland|hay_block|:crafter$")
SHAPES = ("stair", "slab", "wall", "fence", "fence_gate", "pane")
COLOURS = ["light_blue", "light_grey", "dark_green", "dark_grey", "white",
           "orange", "magenta", "yellow", "lime", "pink", "grey", "gray",
           "silver", "cyan", "purple", "blue", "brown", "green", "red",
           "black", "violet"]

PNG_TOKEN = re.compile(r"([A-Za-z0-9_.\-]+)\.png")


def png_text(path):
    out = {}
    b = path.read_bytes()
    i = 8
    while i < len(b):
        n = struct.unpack(">I", b[i:i + 4])[0]
        t = b[i + 4:i + 8]
        if t == b"tEXt":
            k, v = b[i + 8:i + 8 + n].split(b"\0", 1)
            out[k.decode()] = v.decode("latin1")
        if t == b"IDAT":
            break
        i += 12 + n
    return out


def pack_stems(pack):
    names = {p.name[:-4] for p in pack.glob("*.png")}
    stems = sorted(s for s in names
                   if not (s.endswith("_n") or s.endswith("_s")))
    authored = set()
    for s in stems:
        for suffix in ("", "_n", "_s"):
            p = pack / f"{s}{suffix}.png"
            if p.exists() and png_text(p).get("goanna_pipeline") == "authored":
                authored.add(s)
                break
    return stems, authored


def stems_of(texture):
    return PNG_TOKEN.findall(texture or "")


def pad6(tiles):
    tiles = [t for t in (tiles or [])]
    if not tiles:
        return [""] * 6
    while len(tiles) < 6:
        tiles.append(tiles[-1])
    return tiles[:6]


def face_map(item, bucket):
    """{texture string: fraction} for one counted face or billboard."""
    dt = item.get("drawtype", "normal")
    tiles = item.get("tiles") or []
    if bucket == 4:
        if dt == "plantlike_rooted":
            sp = item.get("special_tiles") or tiles
            return {sp[0]: 1.0} if sp else {}
        if dt == "raillike":
            ts = [t for t in tiles[:4] if t]
            return {t: 1.0 / len(ts) for t in ts} if ts else {}
        return {tiles[0]: 1.0} if tiles else {}
    if dt == "mesh":
        uniq = [t for t in dict.fromkeys(tiles) if t]
        return {t: 1.0 / len(uniq) for t in uniq} if uniq else {}
    if dt.startswith("glasslike_framed"):
        ts = [t for t in tiles[:2] if t]
        return {t: 1.0 / len(ts) for t in ts} if ts else {}
    t6 = pad6(tiles)
    if bucket == 0:
        slots = {0: 1.0}
    elif bucket == 1:
        slots = {1: 1.0}
    elif bucket == 2:
        slots = {2: 0.25, 3: 0.25, 4: 0.25, 5: 0.25}
    else:
        slots = {k: 1.0 / 6 for k in range(6)}
    out = collections.Counter()
    overlay = item.get("overlay_tiles")
    o6 = pad6(overlay) if overlay else None
    for k, f in slots.items():
        if t6[k]:
            out[t6[k]] += f
        if o6 and o6[k]:
            out[o6[k]] += f
    return out


def cube_share(item):
    """{texture: share} of a whole block's surface, for the build weight."""
    out = collections.Counter()
    for bucket, f in ((0, 1 / 6), (1, 1 / 6), (2, 4 / 6)):
        for t, g in face_map(item, bucket).items():
            out[t] += f * g
    if not out and item.get("tiles"):
        out[item["tiles"][0]] = 1.0
    return out


def colour_key(name):
    for c in COLOURS:
        if re.search(r"(^|[_:])" + c + r"($|_)", name):
            return re.sub(r"(^|[_:])" + c + r"($|_)", r"\1*\2", name, count=1)
    return None


def build_weights(items, exposure_by_node):
    """Per node build weight, and the evidence behind each."""
    creative = {n for n, d in items.items()
                if not (d.get("groups") or {}).get("not_in_creative_inventory")}
    # an item places the node of its name, or nodes named <item>_<suffix>
    placer = {}
    for n, d in items.items():
        if d.get("type") != "node":
            continue
        if n in creative:
            placer[n] = n
            continue
        best = None
        for i in creative:
            if n.startswith(i + "_") and (best is None or len(i) > len(best)):
                best = i
        if best:
            placer[n] = best
    placed = collections.defaultdict(list)
    for n, i in placer.items():
        placed[i].append(n)
    # mined: the drop of a node players actually meet
    mined = set()
    for n, e in exposure_by_node.items():
        if e > 0:
            d = items.get(n, {})
            mined.add(d.get("drop") or n)
    colour_groups = collections.Counter(colour_key(i) for i in creative)
    out, why = {}, {}
    for i, nodes in placed.items():
        d = items[i]
        g = (d.get("groups") or {})
        cat = max((f for k, f in CATEGORY_FACTOR.items() if g.get(k)),
                  default=OTHER_CATEGORY)
        obtain = 1.0 if (d.get("recipes") or i in mined) else UNOBTAINABLE
        ck = colour_key(i)
        colour = COLOUR_FAMILY if ck and colour_groups[ck] >= 8 else 1.0
        shape = SHAPE_FACTOR if any(g.get(s) for s in SHAPES) else 1.0
        util = UTILITY_FACTOR if UTILITY.search(i) and colour == 1.0 else 1.0
        uses = 1.0 + 0.25 * math.log2(1 + d.get("used_in", 0))
        w = cat * obtain * colour * shape * util * uses
        for n in nodes:
            out[n] = w / len(nodes)
        why[i] = {"weight": round(w, 4), "category": cat, "obtain": obtain,
                  "colour": colour, "shape": shape, "utility": util,
                  "uses": round(uses, 3), "nodes": sorted(nodes)}
    return out, why


# Material families, first match wins, checked against the stem name. Each
# carries the class treatment an author should expect and the authored
# scripts that are the closest worked examples.
FAMILIES = [
    ("ores", r"_ore($|_)|ancient_debris|nether_gold|gilded",
     "stone matrix built as the host rock's script builds it; metal veins "
     "take metal_mask and high smoothness, gems take f0 (diamond 0.17, "
     "emerald 0.16) near 0.9 smoothness",
     ["mcl_core_iron_ore", "mcl_deepslate_diamond_ore", "mcl_core_coal_ore"]),
    ("doors and trapdoors", r"door|trapdoor",
     "cut-out, scissor shader, no parallax: planks or plate held flat with "
     "lib.band, rails and hinges as shallow raised lines",
     ["mcl_doors_wood_family", "doors_trapdoor_wood_family",
      "mcl_doors_iron_family"]),
    ("glowing blocks", r"glowstone|shroomlight|lamp|lightstone_.*_on|"
     r"sea_lantern|froglight|magma|_bulb_on|jack|respawn_anchor|beacon|"
     r"torches_on|redstone_torch|lit$|_on$|end_rod|glow_lichen|cave_vines_lit",
     "emission field from the art's bright texels; the unlit matrix keeps "
     "its class; compare the pumpkin face and glowstone",
     ["mcl_nether_glowstone", "farming_pumpkin_face_light",
      "jeija_torches_on"]),
    ("colour families", r"wool|concrete|glazed_terracotta|hardened_clay|"
     r"beds_bed|shulker|candle|(?<!moss_)carpet|banner|"
     r"glass_(black|blue|brown|cyan|gray|green|light_blue|lime|magenta|"
     r"orange|pink|purple|red|silver|white|yellow)|"
     r"xpanes_top_glass_(?!natural)",
     "one <family>_family.py module with a run(stem) and a one line script "
     "per colour; the weave, the cast face or the fired face held flat",
     ["wool_family", "concrete_family", "hardened_clay_family"]),
    ("glass and panes", r"glass",
     "nearly flat: frame and streaks in lib.band, the pane itself smooth; "
     "no authored glass exists yet, so judge on the ramp with extra care",
     ["default_obsidian", "doors_trapdoor_steel"]),
    ("rails, ladders and bars", r"rail|ladder|scaffolding|chain|web|bars|"
     r"lightning_rod|pane_iron|xpanes_top_iron|copper_pane",
     "cut-out, scissor shader, no parallax: relief reads from shading only",
     ["default_rail_family", "default_ladder"]),
    ("workstations and furniture", r"furnace|smoker|crafting|table|loom|"
     r"barrel|chest|bookshelf|lectern|composter|cauldron|brewing|stonecutter|"
     r"grindstone|anvil|jukebox|noteblock|beehive|bee_nest|bell|lodestone|"
     r"flowerpot|pot_|hopper|dispenser|dropper|observer|piston|comparator|"
     r"delayer|target|tnt|vault|trialspawner|spawner|sculk|conduit|"
     r"itemframe|jigsaw|structure_block|heads_|dragon_egg|endframe|"
     r"cake|bamboo_fpm|solar_panel|redstone_dust|brewing",
     "manufactured faces: flat panels in lib.band, thin joints, iron fittings "
     "with metal_mask; never the cobble recipe on a furnace",
     ["default_furnace_front", "crafting_workbench_front", "default_bookshelf",
      "default_tnt_side"]),
    ("metals and gem blocks", r"iron|gold_block|steel|copper|netherite|"
     r"raw_ores|diamond_block|emerald_block|lapis_block|coal_block|"
     r"redstone_block|amethyst_(amethyst|budding)|heavy_core",
     "polished or cast faces flat with lib.band; metal_mask and high "
     "smoothness on bare metal, patina and oxide rough; gems take f0",
     ["doors_trapdoor_steel", "mcl_doors_door_iron_lower"]),
    ("masonry and dressed stone", r"brick|tiles|polished|chiseled|smooth|"
     r"carved|pillar|purpur|quartz|prismarine|sandstone|cobbled|stonebrick|"
     r"slab|resin_brick|backstone|wall",
     "built from the mortar mask, never connected components; dressed faces "
     "held flat, no warp",
     ["default_stone_brick", "default_brick", "mcl_core_stonebrick_carved",
      "mcl_core_sandstone_normal"]),
    ("logs and planks", r"log|tree(?!_\d)|planks|_wood|wood$|hyphae|"
     r"(crimson|warped)_stem|stripped|bamboo_block|bamboo_plank|"
     r"bamboo_bottom|fence|mosaic|mangrove_roots",
     "bark as ridged fibre running the log's length, end grain as rings; "
     "planks as boards with grain along the board and a joint between",
     ["default_tree", "default_tree_top", "default_wood",
      "mcl_core_planks_spruce"]),
    ("leaves", r"leaves|leaf_litter",
     "clumps of leaf blades at the leaves class, alpha kept from the art",
     ["default_leaves", "mcl_core_leaves_spruce"]),
    ("ice and snow", r"ice|snow",
     "nearly flat: snow at the snow class tilt, ice smooth with shallow "
     "cracks and bubbles in the smoothness",
     ["default_snow"]),
    ("sands and gravels", r"sand$|gravel",
     "grains a texel or two across; sand under the sand tilt band",
     ["default_sand", "mcl_core_red_sand", "default_gravel"]),
    ("soils", r"dirt|podzol|mycelium|(^|_)mud$|packed_mud|farmland|nylium|"
     r"soul_soil|rooted|clay|grass_path|grass_block|moss_block|"
     r"pale_oak_moss$|moss_carpet",
     "soil class: sparse hollows for occlusion, clods, no warp on the dressed "
     "faces; grass tops are greyscale by design",
     ["default_dirt", "mcl_core_dirt_podzol_top", "mcl_mud",
      "mcl_core_mycelium_top"]),
    ("natural rock", r"stone|andesite|diorite|granite|deepslate|tuff|"
     r"calcite|dripstone|basalt|blackstone|netherrack|bedrock|obsidian|"
     r"cobble|budding",
     "natural stone: warp_labels allowed, domes from the art's regions, pores "
     "a few texels across",
     ["default_stone", "mcl_deepslate", "mcl_core_granite", "default_cobble"]),
    ("organic blocks", r"hay|melon|pumpkin|dried_kelp|honey|slime|sponge|"
     r"mushroom_block|wart_block|coral|bone|cactus_(side|top|bottom)|"
     r"resin_block$",
     "a bundle or a skin: fibres or cells at their own scale, never the "
     "stone recipe",
     ["mcl_farming_hayblock_side", "farming_pumpkin_side"]),
    ("crops", r"farming_|wheat|beetroot|carrot|potato|berry|cocoa|"
     r"nether_wart_stage|grain_|gourd_",
     "cut-out billboards: stalks and leaves as shallow relief in shading",
     ["mcl_flowers_tallgrass"]),
    ("flora cut-outs", r"flower|sapling|tallgrass|fern|fungus|roots|"
     r"mushroom|sprouts|propagule|petals|bush|azalea|kelp|seagrass|lichen|"
     r"lily|chorus|spore|tree_\d|root_\d|dry_shrub|papyrus|bamboo|"
     r"eyeblossom|dripleaf|vine|weeping|twisting|hanging|cactus_flower|"
     r"sculk_vein",
     "cut-out billboards through the scissor shader, relief from shading "
     "only; keep the alpha",
     ["mcl_flowers_tallgrass", "mcl_flowers_double_plant_grass_top"]),
]
SUPER = {"ores": "stone", "natural rock": "stone",
         "masonry and dressed stone": "stone", "soils": "earth",
         "sands and gravels": "earth", "ice and snow": "earth",
         "logs and planks": "wood", "leaves": "plant", "flora cut-outs": "plant",
         "crops": "plant", "organic blocks": "plant",
         "doors and trapdoors": "cut-out", "rails, ladders and bars": "cut-out",
         "glass and panes": "cut-out", "colour families": "colour",
         "glowing blocks": "device", "workstations and furniture": "device",
         "metals and gem blocks": "metal"}


def family_of(stem):
    for name, rx, _treat, _ex in FAMILIES:
        if re.search(rx, stem):
            return name
    return "unsorted"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--census", required=True, type=Path)
    ap.add_argument("--pack", default=REPO / "pbr_packs/mineclonia/textures",
                    type=Path)
    ap.add_argument("--authors", default=REPO / "tools/pbr_author", type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--batches", required=True, type=Path)
    ap.add_argument("--top", type=int, default=350)
    ap.add_argument("--cuts", default="250,350")
    ap.add_argument("--recipe", type=Path,
                    default=REPO / "asset_bundles/recipes/mineclonia-pack-1.0.0.json",
                    help="release recipe whose known_failures are listed as rework")
    ap.add_argument("--no-class", action="store_true",
                    help="skip lib.class_of (it needs numpy and Pillow)")
    args = ap.parse_args()

    census = json.loads(args.census.read_text())
    items = census["items"]
    stems, authored = pack_stems(args.pack)
    stem_set = set(stems)
    scripts = {p.stem for p in args.authors.glob("*.py")}
    mismatch = sorted((authored - scripts) | ((scripts & stem_set) - authored))

    regions = collections.Counter(r["kind"] for r in census["regions"])
    n_villages = len([v for v in census["villages"] if "faces" in v])

    # faces per texture token, per context
    faces = {c: collections.Counter() for c in CTX_WEIGHTS}
    node_faces = collections.Counter()
    unknown_nodes = collections.Counter()
    for ctx, per_node in census["counts"].items():
        for node, b in per_node.items():
            item = items.get(node)
            if not item or item.get("type") != "node":
                unknown_nodes[node] += sum(b)
                continue
            for k, v in enumerate(b):
                if not v:
                    continue
                w = v
                if k == 4:
                    w = v * BILLBOARD_FACES.get(item.get("drawtype"), 1.0)
                node_faces[node] += w
                for tex, f in face_map(item, k).items():
                    for s in stems_of(tex):
                        faces[ctx][s] += w * f

    totals = {c: sum(faces[c].values()) for c in faces}
    exposure = collections.Counter()
    for c, w in CTX_WEIGHTS.items():
        if totals[c]:
            for s, v in faces[c].items():
                exposure[s] += w * v / totals[c]
    wsum = sum(w for c, w in CTX_WEIGHTS.items() if totals[c])
    for s in exposure:
        exposure[s] /= wsum

    node_w, why = build_weights(items, node_faces)
    item_of = {n: i for i, e in why.items() for n in e["nodes"]}
    build_nodes = collections.defaultdict(collections.Counter)
    build_items = collections.defaultdict(collections.Counter)
    for n, w in node_w.items():
        for tex, f in cube_share(items[n]).items():
            for s in stems_of(tex):
                build_nodes[s][n] += w * f
                build_items[s][item_of.get(n, n)] += w * f
    # One stem drawn by many items (waxed and plain copper, every stair,
    # slab and wall of a stone) is still one texture a player builds with:
    # the strongest item counts in full, the rest at VARIANT_FACTOR.
    build = collections.Counter()
    for s, c in build_items.items():
        vals = sorted(c.values(), reverse=True)
        build[s] = vals[0] + VARIANT_FACTOR * sum(vals[1:])
    bsum = sum(build.values())
    build_share = {s: v / bsum for s, v in build.items()}

    score = collections.Counter()
    for s in set(exposure) | set(build_share):
        score[s] = EXPOSURE_WEIGHT * exposure.get(s, 0) + \
            BUILD_WEIGHT * build_share.get(s, 0)

    # which nodes carry each stem, for the home block and the brief
    stem_nodes = collections.defaultdict(collections.Counter)
    for ctx, per_node in census["counts"].items():
        cw = CTX_WEIGHTS.get(ctx, 0) / (totals[ctx] or 1)
        for node, b in per_node.items():
            item = items.get(node)
            if not item or item.get("type") != "node":
                continue
            for k, v in enumerate(b):
                for tex, f in face_map(item, k).items():
                    for s in stems_of(tex):
                        stem_nodes[s][node] += v * f * cw
    for s, c in build_nodes.items():
        for n, v in c.items():
            stem_nodes[s][n] += v / bsum * BUILD_WEIGHT / EXPOSURE_WEIGHT
    home = {s: c.most_common(1)[0][0] for s, c in stem_nodes.items() if c}
    # stems a node draws, for pulling a block's other faces into its batch
    node_stems = collections.defaultdict(set)
    for n, d in items.items():
        if d.get("type") != "node":
            continue
        for key in ("tiles", "overlay_tiles", "special_tiles"):
            for t in d.get(key) or []:
                for s in stems_of(t):
                    node_stems[n].add(s)
    stem_users = collections.defaultdict(set)
    for n, ss in node_stems.items():
        for s in ss:
            stem_users[s].add(n)

    class_of = None
    if not args.no_class:
        try:
            import lib
            class_of = lambda s: lib.class_of(s, "mineclonia")
        except Exception as e:  # numpy or Pillow missing
            print(f"lib.class_of unavailable: {e}", file=sys.stderr)

    ranked = sorted(stems, key=lambda s: (-score.get(s, 0), s))
    rank_all = {s: i + 1 for i, s in enumerate(ranked)}
    todo = [s for s in ranked if s not in authored]
    rank_todo = {s: i + 1 for i, s in enumerate(todo)}

    rows = []
    for s in ranked:
        per_ctx = {c: round(faces[c].get(s, 0), 2) for c in CTX_WEIGHTS}
        rows.append({
            "stem": s,
            "authored": s in authored,
            "rank_all": rank_all[s],
            "rank_todo": rank_todo.get(s),
            "score": round(score.get(s, 0) * 1e6, 3),
            "exposure": round(exposure.get(s, 0) * 1e6, 3),
            "build": round(build_share.get(s, 0) * 1e6, 3),
            "faces": per_ctx,
            "faces_per_region": {
                "overworld": round(sum(per_ctx[c] for c in ("surface", "cave", "liquid"))
                                   / max(1, regions["overworld"]), 2),
                "nether": round(per_ctx["nether"] / max(1, regions["nether"]), 2),
                "end": round(per_ctx["end"] / max(1, regions["end"]), 2),
                "village": round(per_ctx["village"] / max(1, n_villages), 2),
            },
            "home_node": home.get(s),
            "nodes": [n for n, _ in stem_nodes.get(s, collections.Counter()).most_common(5)],
            "family": family_of(s),
            "class": class_of(s) if class_of else None,
        })

    # the heavily used textures the pack has no stem for
    missing = []
    for s in sorted(score, key=lambda s: -score[s]):
        if s in stem_set:
            continue
        missing.append({"stem": s, "score": round(score[s] * 1e6, 3),
                        "exposure": round(exposure.get(s, 0) * 1e6, 3),
                        "faces": {c: round(faces[c].get(s, 0), 1) for c in CTX_WEIGHTS},
                        "nodes": [n for n, _ in stem_nodes.get(s, collections.Counter()).most_common(4)]})
        if len(missing) >= 60:
            break

    # --- batches ------------------------------------------------------------
    top = todo[:args.top]
    in_top = set(top)
    row_of = {r["stem"]: r for r in rows}
    # units: a stem with every other unauthored face of its home block, and
    # of the nodes the same item places (a door's upper and lower halves),
    # so faces of one block share one agent. Stems go in rank order, so a
    # texture two blocks share stays with the higher ranked one.
    units, seen = [], set()
    for s in top:
        if s in seen:
            continue
        h = home.get(s)
        unit = [s]
        if h:
            block = [h]
            if item_of.get(h) in why:
                block += why[item_of[h]]["nodes"]
            faces_of = set()
            for n in block:
                faces_of |= node_stems.get(n, set())
            block_set = set(block)
            for t in sorted(faces_of, key=lambda t: rank_all.get(t, 1e9)):
                # only faces that belong to this block: a flower pot draws
                # every plant it can hold, and those are not its faces
                if t != s and t in stem_set and t not in authored and t not in seen \
                        and (home.get(t) in block_set or (home.get(t) is None
                             and stem_users[t] <= block_set)):
                    unit.append(t)
        for t in unit:
            seen.add(t)
        units.append(unit)
    pulled = sorted(seen - in_top)

    by_family = collections.defaultdict(list)
    for u in units:
        by_family[family_of(u[0])].append(u)

    def chunk(unit_list):
        out, cur = [], []
        for u in unit_list:
            if cur and len(cur) + len(u) > 8 and len(cur) >= 5:
                out.append(cur)
                cur = []
            cur = cur + u
            if len(cur) >= 8:
                out.append(cur)
                cur = []
        if cur:
            out.append(cur)
        return out

    raw = []
    for fam, ulist in by_family.items():
        for b in chunk(ulist):
            raw.append((fam, b))
    # fold batches under five into a sibling of the same super family
    small = [x for x in raw if len(x[1]) < 5]
    big = [x for x in raw if len(x[1]) >= 5]
    by_super = collections.defaultdict(list)
    for fam, b in small:
        by_super[SUPER.get(fam, fam)].append((fam, b))
    for sup, lst in by_super.items():
        lst.sort(key=lambda x: min(rank_todo.get(s, 1e9) for s in x[1]))
        cur_f, cur = [], []
        for fam, b in lst:
            if cur and len(cur) + len(b) > 8:
                big.append((" + ".join(dict.fromkeys(cur_f)), cur))
                cur_f, cur = [], []
            cur_f.append(fam)
            cur = cur + b
        if cur:
            big.append((" + ".join(dict.fromkeys(cur_f)), cur))
    # a leftover of one or two stems joins the smallest batch of its super
    # family rather than going out as a brief of its own
    for x in [x for x in big if len(x[1]) < 3]:
        sup = SUPER.get(x[0].split(" + ")[0])
        host = [y for y in big if y is not x and len(y[1]) + len(x[1]) <= 9
                and SUPER.get(y[0].split(" + ")[0]) == sup]
        if host:
            y = min(host, key=lambda y: len(y[1]))
            big.remove(x)
            big.remove(y)
            fams = " + ".join(dict.fromkeys(y[0].split(" + ") + x[0].split(" + ")))
            big.append((fams, y[1] + x[1]))

    def key(x):
        rs = sorted(rank_todo.get(s, len(todo)) for s in x[1])
        return rs[0]

    big.sort(key=key)
    fam_info = {f: (t, e) for f, _rx, t, e in FAMILIES}
    batches, running = [], 0
    cut_values = [int(c) for c in args.cuts.split(",")]
    cuts = {}
    for i, (fam, b) in enumerate(big, 1):
        running += len(b)
        fams = fam.split(" + ")
        treat = [fam_info[f][0] for f in fams if f in fam_info]
        ex = []
        for f in fams:
            ex += [e for e in fam_info.get(f, ("", []))[1] if e not in ex]
        batches.append({
            "batch": i,
            "family": fam,
            "stems": [{"stem": s, "rank_todo": rank_todo.get(s),
                       "score": row_of[s]["score"], "home_node": home.get(s),
                       "class": row_of[s]["class"],
                       "pulled_in_as_sibling_face": s not in in_top}
                      for s in b],
            "best_rank_todo": key((fam, b)),
            "median_rank_todo": statistics.median(
                rank_todo.get(s, len(todo)) for s in b),
            "treatment": treat,
            "worked_examples": [f"tools/pbr_author/{e}.py" for e in ex],
            "cumulative_stems": running,
            "small": len(b) < 5,
        })
        for c in cut_values:
            if c not in cuts and running >= c:
                cuts[c] = i

    meta = {
        "schema": "goanna-pbr-census-rank/1",
        "census_schema": census.get("schema"),
        "game": census.get("game"), "engine": census.get("engine"),
        "mapgen": census.get("mg_name"), "map_seed": census.get("map_seed"),
        "sample_seed": census.get("sample_seed"),
        "regions": dict(regions), "villages_counted": n_villages,
        "context_face_totals": {c: round(v, 1) for c, v in totals.items()},
        "weights": {"contexts": CTX_WEIGHTS, "exposure": EXPOSURE_WEIGHT,
                    "build": BUILD_WEIGHT, "billboard_faces": BILLBOARD_FACES,
                    "build_heuristic": {
                        "category": CATEGORY_FACTOR, "other_category": OTHER_CATEGORY,
                        "unobtainable": UNOBTAINABLE, "colour_family": COLOUR_FAMILY,
                        "shape": SHAPE_FACTOR, "utility": UTILITY_FACTOR,
                        "variant": VARIANT_FACTOR,
                        "utility_pattern": UTILITY.pattern,
                        "uses": "1 + 0.25 * log2(1 + recipes using the item)"}},
        "units": "score, exposure and build are shares in parts per million",
        "pack_stems": len(stems), "authored": len(authored),
        "authored_script_mismatch": mismatch,
        "unknown_nodes": dict(unknown_nodes.most_common(20)),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps({
        "meta": meta, "stems": rows, "missing_from_pack": missing,
        "build_evidence": dict(sorted(why.items(), key=lambda kv: -kv[1]["weight"])),
    }, indent=1) + "\n")
    # Work that is not a new stem: the known failures of the last release,
    # which ship as authored or baked sets that fail one rule, and the crack.
    rework = []
    if args.recipe and args.recipe.exists():
        rec = json.loads(args.recipe.read_text())
        for part in rec.values():
            if isinstance(part, dict) and part.get("known_failures"):
                for s in part["known_failures"]:
                    r = row_of.get(s, {})
                    rework.append({"stem": s, "authored": r.get("authored"),
                                   "rank_all": r.get("rank_all"),
                                   "score": r.get("score"),
                                   "family": r.get("family"),
                                   "why": part.get("known_failures_note")})
    extras = [{
        "item": "crack_anylength",
        "what": "an authored crack texture in the pack, overriding the game's "
                "by filename",
        "why": "Mineclonia's crack_anylength.png is 16 by 160 (ten 16 px "
               "stages), and draw_crack scales one stage over the 256 px "
               "base, so a damaged block shows 16 px cracks on a 256 px face",
        "note": "not a node tile, so the census cannot rank it; every block a "
                "player digs shows it",
    }]
    args.batches.write_text(json.dumps({
        "meta": {"schema": "goanna-pbr-census-batches/1",
                 "from": str(args.out.name), "top": args.top,
                 "cuts": {str(c): {"after_batch": cuts.get(c),
                                   "stems": batches[cuts[c] - 1]["cumulative_stems"]
                                   if c in cuts else None} for c in cut_values},
                 "pulled_in_as_sibling_faces": pulled},
        "batches": batches,
        "extras": extras,
        "rework_known_failures": rework,
    }, indent=1) + "\n")
    print(f"{len(stems)} stems, {len(authored)} authored, {len(todo)} to do; "
          f"{len(batches)} batches, cuts {cuts}, {len(pulled)} sibling faces pulled in")
    if mismatch:
        print("authored flag and scripts disagree:", mismatch)


if __name__ == "__main__":
    main()
