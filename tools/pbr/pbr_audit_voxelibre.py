#!/usr/bin/env python3
"""Per file media audit of the VoxeLibre stems Goanna authors maps for.

VoxeLibre's LEGAL.md is a mixed notice: textures are Pixel Perfection
(CC BY-SA 4.0) unless otherwise noted, a few named works carry their own
terms, other files fall under CC BY-SA 3.0, and each mod's own README may
say something else again. The archive-wide string therefore qualifies
nothing on its own (docs/pbr-community-review.md), and this writes the
per file mapping that check-pbr-licenses.py reads instead.

Each stem is assigned to the mod that registers it, and the most specific
notice that covers it decides: a notice naming the file, then the mod's own
media notice, then its modpack's, then LEGAL.md. Where two notices that
both cover a file give different accepted licences, the share-alike one is
recorded, since that is the more restrictive and the one the bundle carries
anyway. An unscoped licence line over a mod is read as covering its
textures, the stricter reading. GPL-3.0 media is accepted for texture
packs, and the maps derived from it are GPL-3.0; media the policy rejects
goes to the exclusion list, never to the ledger.

The rules below were read from release 38585 on 2026-10-05. A new release
must be read again before this is rerun against it.
"""

import argparse
import json
import re
import textwrap
from pathlib import Path

PACKAGE = "voxelibre"
RELEASE = 38585

PP = "Pixel Perfection by XSSheep, with changes by VoxeLibre contributors"
LEGAL = "LEGAL.md"

# Stems whose registering mod is not their prefix, or that have no prefix.
OWNER_RULES = [
    (r"^default_furnace_", "mcl_furnaces"),
    (r"^default_rail", "mcl_minecarts"),
    (r"^default_tnt_", "mcl_tnt"),
    (r"^default_bookshelf$", "mcl_books"),
    (r"^default_", "mcl_core"),
    (r"^mcl_gold_block_polished$", "mcl_core"),
    (r"^wool_", "mcl_wool"),
    (r"^farming_mushroom_", "mcl_mushrooms"),
    (r"^farming_", "mcl_farming"),
    (r"^flowers_", "mcl_flowers"),
    (r"^doors_", "mcl_doors"),
    (r"^hardened_clay", "mcl_colorblocks"),
    (r"^mcl_(chiseled|cobbled|cracked|polished)_deepslate", "mcl_deepslate"),
    (r"^mcl_composter_", "mcl_composters"),
    (r"^mcl_backstone_", "mcl_blackstone"),
    (r"^mcl_stripped_mangrove_", "mcl_mangrove"),
    (r"^mcl_fences_fence_(gate_)?red_nether_brick$", "mclx_fences"),
    (r"^mcl_fences_fence_gate_nether_brick$", "mclx_fences"),
    (r"^respawn_anchor_", "mcl_beds"),
    (r"^lodestone_", "mcl_compass"),
    (r"^(blast_furnace)_", "mcl_blast_furnace"),
    (r"^smoker_", "mcl_smoker"),
    (r"^cake_", "mcl_cake"),
    (r"^crafting_workbench_", "mcl_crafting_table"),
    (r"^fletching_table_", "mcl_fletching_table"),
    (r"^loom_", "mcl_loom"),
    (r"^grindstone_", "mcl_grindstone"),
    (r"^beacon_", "mcl_beacons"),
    (r"^mob_spawner$", "mcl_mobspawners"),
    (r"^jeija_commandblock_", "mesecons_commandblock"),
    (r"^jeija_lightstone_", "mesecons_lightstone"),
    (r"^jeija_torches_", "mesecons_torch"),
    (r"^jeija_wall_lever_", "mesecons_walllever"),
    (r"^redstone_redstone_block$", "mesecons_torch"),
    (r"^redstone_redstone_dust_", "mesecons_wires"),
    (r"^vl_sensors_", "mesecons_solarpanel"),
]

# Notices that name files. (pattern, licence, author, notice)
FILE_RULES = [
    (r"^mcl_blackstone_basalt_(side|top|top_polished)$", "CC-BY-SA-3.0",
     "Lifora", "mods/ITEMS/mcl_blackstone/README.md"),
    (r"^mcl_crimson_(warped_hyphae_wood|crimson_hyphae_wood|crimson_fungus)$",
     "CC-BY-SA-4.0", "Exhale", "mods/ITEMS/mcl_crimson/README.md"),
    (r"^fletching_table_", "CC-BY-SA-4.0", "MrRar",
     "mods/ITEMS/mcl_fletching_table/README.md"),
    (r"^loom_", "CC-BY-SA-4.0", "MrRar", "mods/ITEMS/mcl_loom/README.md"),
    (r"^mcl_mud(_bricks|_packed_mud)?$", "CC0-1.0", "TheRandomLegoBrick",
     "mods/ITEMS/mcl_mud/README.txt"),
    (r"^mcl_stonecutter_", "CC0-1.0", "RandomLegoBrick",
     "mods/ITEMS/mcl_stonecutter/README.md"),
    (r"^mcl_bells_bell_", "CC0-1.0", "cora", "mods/ITEMS/mcl_bells/README.md"),
    (r"^mcl_doors_(door_iron_(lower|upper)|trapdoor_(acaica|birch|spruce|dark_oak|jungle))$",
     "CC-BY-SA-4.0", "kingoscargames, after Pixel Perfection by XSSheep",
     "mods/ITEMS/mcl_doors/README.txt"),
    (r"^mcl_colorblocks_glazed_terracotta_", "CC-BY-SA-4.0", "MysticTempest",
     LEGAL),
    (r"^mcl_core_charcoal_block$", "CC-BY-SA-4.0",
     "blitzdoughnuts, after Pixel Perfection by XSSheep", LEGAL),
    (r"^mcl_cherry_blossom_.*(wood|log|planks|bark|tree)", "CC-BY-SA-4.0",
     "Nova_Wostra, refined by EmoryNB", LEGAL),
]

# Mods' own media notices. (licence, author, notice, note on any other
# notice that covers the same files)
MOD_RULES = {
    "mcl_core": ("CC-BY-SA-4.0", PP, "mods/ITEMS/mcl_core/README.txt",
                 "the mod notice says MIT and credits Faithful 1.11 by Vattic"
                 " and xMrVizzy; LEGAL.md says Pixel Perfection, CC BY-SA 4.0"),
    "mcl_flowerpots": ("CC-BY-SA-4.0", PP, "mods/ITEMS/mcl_flowerpots/license.txt",
                       "the mod notice says MIT and credits Faithful 1.11; LEGAL.md says"
                       " Pixel Perfection, CC BY-SA 4.0"),
    "mcl_mobspawners": ("CC-BY-SA-4.0", PP, "mods/ITEMS/mcl_mobspawners/README.md",
                        "the mod notice says MIT; LEGAL.md says Pixel Perfection,"
                        " CC BY-SA 4.0"),
    "mcl_tnt": ("CC-BY-SA-4.0", PP, "mods/ITEMS/mcl_tnt/README.txt",
                "the mod notice says MIT; LEGAL.md says Pixel Perfection,"
                " CC BY-SA 4.0"),
    "mclx_fences": ("CC-BY-SA-4.0", PP, "mods/ITEMS/mclx_fences/README.txt",
                    "the mod notice says MIT; LEGAL.md says Pixel Perfection,"
                    " CC BY-SA 4.0"),
    "mcl_beds": ("CC-BY-SA-3.0", "BlockMen, with changes by VoxeLibre"
                 " contributors", "mods/ITEMS/mcl_beds/license.txt", None),
    "mcl_minecarts": ("CC-BY-SA-3.0", "XSSheep",
                      "mods/ENTITIES/mcl_minecarts/README.txt", None),
    "mcl_bamboo": ("CC-BY-SA-3.0", "Nicu", "mods/ITEMS/mcl_bamboo/README.md",
                   "the mod notice says CC-BY-SA without a version; LEGAL.md"
                   " places files not otherwise noted under 3.0"),
    "mcl_farming": ("CC-BY-SA-4.0", "PilzAdam and VoxeLibre contributors",
                    "mods/ITEMS/mcl_farming/README.txt", None),
    "mcl_lectern": ("CC-BY-SA-4.0", "Michieal", "mods/ITEMS/mcl_lectern/README.txt",
                    None),
    "mcl_blackstone": ("CC-BY-SA-4.0", "debian044 and VoxeLibre contributors",
                       "mods/ITEMS/mcl_blackstone/README.md", None),
    "mcl_fences": ("GPL-3.0", "BlockMen and VoxeLibre contributors",
                   "mods/ITEMS/mcl_fences/README.txt",
                   "the notice reads \"License of source code and textures:"
                   " GNU GPLv3\"; Mineclonia's copy says WTFPL"),
    "mcl_flowers": ("GPL-3.0", "Ironzorg, VanessaE, jojoa1997 and VoxeLibre"
                    " contributors", "mods/ITEMS/mcl_flowers/README.txt",
                    "the notice has a bare \"GNU GPLv3\" line over the mod"
                    " and no media notice, so it may or may not cover the"
                    " textures; GPL-3.0 is the stricter reading and is"
                    " recorded. Without it LEGAL.md's CC BY-SA 4.0 applies"),
    "mobs_mc": ("CC-BY-SA-4.0", PP, "mods/ENTITIES/mobs_mc/LICENSE-media.md", None),
}

# The REDSTONE modpack's README places its media under CC BY-SA 3.0.
REDSTONE = ("CC-BY-SA-3.0", "Mesecons authors (Jeija, VanessaE, sfan5,"
            " temperest, minerd247) and VoxeLibre contributors",
            "mods/ITEMS/REDSTONE/README", None)
SENSORS = ("CC-BY-SA-3.0", "Lifora", "mods/ITEMS/REDSTONE/README", None)

# Notices whose media fails pbr_packs/MEDIA_POLICY.json: (licence, notice,
# reason). None in release 38585.
EXCLUDED_MODS = {}


def mod_index(root):
    index = {}
    for conf in root.joinpath("mods").rglob("*"):
        if conf.name in ("mod.conf", "init.lua"):
            index.setdefault(conf.parent.name, conf.parent)
    return index


def owner(stem, mods):
    for pattern, mod in OWNER_RULES:
        if re.search(pattern, stem):
            return mod
    best = None
    for name in mods:
        if (stem == name or stem.startswith(name + "_")) and \
                (best is None or len(name) > len(best)):
            best = name
    return best


def decide(stem, mod, mods, root):
    path = mods[mod].relative_to(root).as_posix()
    if mod in EXCLUDED_MODS:
        licence, notice, why = EXCLUDED_MODS[mod]
        return None, {"mod": path, "media_license": licence,
                      "notice": notice, "reason": why}
    for pattern, licence, author, notice in FILE_RULES:
        if re.search(pattern, stem):
            return {"media_license": licence, "author": author,
                    "notice": notice}, None
    if mod in MOD_RULES:
        licence, author, notice, also = MOD_RULES[mod]
    elif path.startswith("mods/ITEMS/REDSTONE/"):
        licence, author, notice, also = SENSORS if mod == "mesecons_solarpanel" \
            else REDSTONE
    else:
        licence, author, notice, also = "CC-BY-SA-4.0", PP, LEGAL, None
    record = {"media_license": licence, "author": author, "notice": notice}
    if also:
        record["note"] = also
    return record, None


ATTRIBUTION_HEAD = """# Attribution for these maps

Built by tools/pbr/pbr_author/ from the textures of the game VoxeLibre
(gameid `mineclone2`, ContentDB release %d, by Lizzy Fleckenstein, Wuzzy,
davedevils and many others; repository
<https://git.minetest.land/VoxeLibre/VoxeLibre>). The albedo is the game's
art upscaled without repainting, and the normal, occlusion, height and
specular maps are derived from height and smoothness fields authored on
that art. These are derivative works of the game's art, not new art, so
they carry the source's licence and its attribution requirements,
including the share-alike term, and are offered under the same licence as
each source texture below.

VoxeLibre's `LEGAL.md` states that no non-free licences are used for
media, that textures are based on the Pixel Perfection resource pack by
XSSheep (CC BY-SA 4.0) unless otherwise noted, and that other files fall
under CC BY-SA 3.0 unless noted otherwise. Individual mods' notices say
more, and the most specific notice covering each texture is the one
recorded here. Where two notices both cover a texture and disagree, the
share-alike licence is recorded and the other is named.

Every texture was checked against the notices of the release named above
by tools/pbr/pbr_audit_voxelibre.py on 2026-10-05. The per file record, with
each texture's source path and owning mod, is
pbr_packs/manifests/voxelibre-pack-v1.sources.json.

Licence texts:

- CC BY-SA 4.0: <https://creativecommons.org/licenses/by-sa/4.0/>
- CC BY-SA 3.0: <https://creativecommons.org/licenses/by-sa/3.0/>
- CC0 1.0: <https://creativecommons.org/publicdomain/zero/1.0/>
- GPL-3.0: <https://www.gnu.org/licenses/gpl-3.0.html>
"""

ATTRIBUTION_EXCLUDED = """
## Left out

These textures were authored but are not in the bundle, because the
notice covering them does not meet Goanna's media policy
(pbr_packs/MEDIA_POLICY.json). Players see the game's own art for them.
"""

LICENCE_NAMES = {"CC-BY-SA-4.0": "CC BY-SA 4.0", "CC-BY-SA-3.0": "CC BY-SA 3.0",
                 "CC0-1.0": "CC0 1.0", "GPL-3.0": "GPL-3.0"}

LICENCE_NOTES = {"GPL-3.0": """
The maps for these textures are offered under the GNU General Public
License, version 3. Their source, the form they are modified in, is in
the Goanna repository <https://github.com/p0ss/Goanna>: each stem's spec,
tools/pbr/pbr_author/specs/voxelibre/<stem>.json where it has one, and its
class in tools/pbr/pbr_author/stems/voxelibre.classes.json, built by
`tools/pbr/pbr_author/build_pack.py --game voxelibre`. Goanna's own code is
LGPL-2.1-or-later and is not affected; the pack is a separate work shipped
beside it.
"""}


def wrapped(words, width=80):
    lines, line = [], ""
    for word in words:
        if line and len(line) + 2 + len(word) > width - 1:
            lines.append(line + ",")
            line = word
        else:
            line = line + ", " + word if line else word
    return lines + [line] if line else lines


def counted(stems):
    return "%d texture%s" % (len(stems), "" if len(stems) == 1 else "s")


def attribution(ledger, excluded):
    text = [ATTRIBUTION_HEAD % RELEASE]
    groups = {}
    for stem, record in ledger.items():
        key = (record["media_license"], record["notice"], record["author"],
               record.get("note", ""))
        groups.setdefault(key, []).append(stem)
    for licence in sorted({key[0] for key in groups}):
        text.append("\n## %s\n" % LICENCE_NAMES.get(licence, licence))
        text.append(LICENCE_NOTES.get(licence, ""))
        for key in sorted(k for k in groups if k[0] == licence):
            stems = sorted(groups[key])
            text.append("\n### %s under `%s`\n" % (counted(stems), key[1]))
            items = ["- author: " + key[2]] + (["- note: " + key[3]] if key[3] else [])
            text.append("\n" + "\n".join(textwrap.fill(item, 80, subsequent_indent="  ")
                                           for item in items) + "\n\n")
            text.append("\n".join(wrapped(stems)) + "\n")
    if excluded:
        text.append(ATTRIBUTION_EXCLUDED)
        reasons = {}
        for stem, record in excluded.items():
            reasons.setdefault((record["notice"], record["reason"]), []).append(stem)
        for (notice, reason), stems in sorted(reasons.items()):
            text.append("\n### %s under `%s`\n\n" % (counted(stems), notice))
            text.append(textwrap.fill("The notice has " + reason, 80) + "\n\n")
            text.append("\n".join(wrapped(sorted(stems))) + "\n")
    return "".join(text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True,
                        help="the staged game directory (mineclone2/)")
    parser.add_argument("--stems", default="tools/pbr/pbr_author/stems/voxelibre.txt")
    parser.add_argument("--out", default="pbr_packs/manifests/voxelibre-pack-v1")
    parser.add_argument("--attribution", default="pbr_packs/voxelibre/ATTRIBUTION.md")
    args = parser.parse_args()
    root = Path(args.source)
    if not root.joinpath(LEGAL).is_file():
        raise SystemExit("%s has no LEGAL.md; point --source at mineclone2/" % root)
    mods = mod_index(root)
    stems = [line.strip() for line in Path(args.stems).read_text().splitlines()
             if line.strip()]
    ledger, excluded, failures = {}, {}, []
    for stem in stems:
        found = list(root.rglob(stem + ".png"))
        mod = owner(stem, mods)
        if len(found) != 1 or mod is None:
            failures.append("%s: %d source files, owner %s" % (stem, len(found), mod))
            continue
        record, rejected = decide(stem, mod, mods, root)
        source = found[0].relative_to(root).as_posix()
        if rejected:
            excluded[stem] = dict(rejected, source=source)
            continue
        ledger[stem] = dict(record, package=PACKAGE, release=RELEASE,
                            source=source,
                            mod=mods[mod].relative_to(root).as_posix())
    for failure in failures:
        print("FAIL " + failure)
    if failures:
        return 1
    out = Path(args.out)
    out.with_suffix(".sources.json").write_text(
        json.dumps(ledger, indent=2, sort_keys=True) + "\n")
    out.with_suffix(".excluded.json").write_text(
        json.dumps(excluded, indent=2, sort_keys=True) + "\n")
    Path(args.attribution).write_text(attribution(ledger, excluded))
    counts = {}
    for record in ledger.values():
        counts[record["media_license"]] = counts.get(record["media_license"], 0) + 1
    print("%d admitted (%s), %d excluded" % (
        len(ledger), ", ".join("%s %d" % kv for kv in sorted(counts.items())),
        len(excluded)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
