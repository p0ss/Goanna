#!/usr/bin/env python3
"""Count what a texture pack covering several Luanti games would actually have
to draw, and write it out as a spreadsheet.

The naive answer is to add up each game's texture count, which badly
overcounts: the MineClone family shares a great deal of art byte for byte,
and every game has a dirt and a grass whatever it calls them. The useful
answer needs three different notions of "the same texture", because they
disagree and each is right about something:

  identical   the same bytes, so it is literally one asset in two games and
              drawing it once covers both.
  concept     the same thing under different names, once the owning mod's
              prefix is stripped (mcl_core_dirt and default_dirt are both
              dirt). Different art, same job, so one drawing could serve
              both if you are willing to unify the look.
  distinct    everything else, one drawing each.

Face suffixes (_top, _side, _bottom, _front) are deliberately NOT collapsed:
they are separate images a person has to draw.

    tools/texture_census.py --games-dir ~/.minetest/games \\
        --games minetest_game,mineclonia,mineclone2,asuna --out census.csv

Writes one row per concept, with the names each game uses, so it can be
sorted by how many games a row covers and worked through top down.
"""

import argparse
import collections
import csv
import hashlib
import os
import re
import sys

# Cross game naming differences that are real synonyms rather than different
# things. Deliberately short: every entry here merges two rows in the output,
# so a wrong one hides work rather than saving it.
SYNONYMS = [
    ("cobblestone", "cobble"),
    ("grass_block", "grass"),
    ("stonebrick", "stone_brick"),
    ("treetop", "tree_top"),
]

# Prefixes worth stripping beyond the owning mod's own name, for games whose
# filenames do not follow the mod name convention.
EXTRA_PREFIXES = ("mcl_core_", "mcl_", "vl_", "default_", "asuna_")


def owning_mod(path, game_dir):
    d = os.path.dirname(path)
    while d.startswith(game_dir) and len(d) > len(game_dir):
        if os.path.exists(os.path.join(d, "mod.conf")):
            return os.path.basename(d)
        d = os.path.dirname(d)
    return ""


def category(path, game_dir):
    """Rough bucket from where the file sits, so node textures can be done
    before inventory icons and HUD art."""
    rel = os.path.relpath(path, game_dir).replace(os.sep, "/")
    for token, name in (("/ITEMS/", "item"), ("/ENTITIES/", "entity"),
            ("/HUD/", "hud"), ("/MAPGEN/", "mapgen"), ("/PLAYER/", "player"),
            ("/ENVIRONMENT/", "environment"), ("/CORE/", "core"),
            ("/HELP/", "help"), ("/MISC/", "misc")):
        if token in rel:
            return name
    return "other"


def concept_of(stem, mod):
    s = stem.lower()
    if mod and s.startswith(mod.lower() + "_"):
        s = s[len(mod) + 1:]
    else:
        for pre in EXTRA_PREFIXES:
            if s.startswith(pre):
                s = s[len(pre):]
                break
    for a, b in SYNONYMS:
        s = s.replace(a, b)
    return s.strip("_") or stem.lower()


LICENCE_TOKENS = [
    (r'CC[\s-]?BY[\s-]?SA[\s-]?4(\.0)?', "CC BY-SA 4.0"),
    (r'CC[\s-]?BY[\s-]?SA[\s-]?3(\.0)?', "CC BY-SA 3.0"),
    (r'CC[\s-]?BY[\s-]?4(\.0)?', "CC BY 4.0"),
    (r'CC[\s-]?BY[\s-]?3(\.0)?', "CC BY 3.0"),
    (r'CC[\s-]?0|creativecommons\.org/publicdomain/zero', "CC0"),
    (r'\bMIT\b', "MIT"),
    (r'LGPL[\s-]?v?2\.1', "LGPL-2.1"),
    (r'\bLGPL\b', "LGPL"),
    (r'GPL[\s-]?v?3', "GPL-3.0"),
    (r'\bGPLv?2\b', "GPL-2.0"),
    (r'Apache', "Apache-2.0"),
    (r'WTFPL|DO WHAT THE FUCK', "WTFPL"),
    (r'public domain', "public domain"),
]
# Headings that start the media half of a licence file. Code and media are
# licensed separately in nearly every Luanti game, and the code licence is
# usually the more restrictive of the two, so reading the wrong half gives a
# systematically wrong answer.
MEDIA_HEADING = re.compile(
        r'^.{0,8}(licen[sc]es? (of|for) media|media licen[sc]es?|'
        r'credits licensing for media|licen[sc]es? of (textures|media)).*$',
        re.I | re.M)
CODE_HEADING = re.compile(r'^.{0,8}licen[sc]es? (of|for) (source|code).*$', re.I | re.M)


def _licences_in(text):
    out = []
    for pat, name in LICENCE_TOKENS:
        if re.search(pat, text, re.I) and name not in out:
            out.append(name)
    return out


def parse_licence_file(path):
    """(media licences, whole file licences, media section text).

    Split at the media heading where there is one, because a file that says
    LGPL for code and CC BY-SA for media means the second for our purposes.
    """
    try:
        text = open(path, errors="replace").read()
    except OSError:
        return [], [], ""
    m = MEDIA_HEADING.search(text)
    if not m:
        return [], _licences_in(text), ""
    start = m.end()
    nxt = CODE_HEADING.search(text, start)
    section = text[start:nxt.start() if nxt else len(text)]
    return _licences_in(section), _licences_in(text), section


# Author names, which every licence in play except CC0 requires you to keep.
# Two formats cover nearly all of it. minetest_game writes a "Copyright (C)
# <years>:" line followed by an indented list of names, one per line.
# Mineclonia's media files use markdown bullets, "* Name", "* [Name](url)",
# sometimes with the licence in brackets after.
COPYRIGHT_BLOCK = re.compile(r'Copyright\s*\(C\)[^\n:]*:?\s*\n((?:[ \t]+\S[^\n]*\n)+)', re.I)
BULLET = re.compile(r'^\s*[*-]\s+(.+?)\s*$', re.M)
MD_LINK = re.compile(r'\[([^\]]+)\]\([^)]*\)')
NOISE = re.compile(r'\((?:CC[^)]*|MIT|GPL[^)]*|LGPL[^)]*|CC0)\)|<[^>]*>|https?://\S+', re.I)


LICENCE_NAMES = {n.lower() for _, n in LICENCE_TOKENS} | {
    "cc0", "cc by", "cc by-sa", "gpl v3", "gpl", "lgpl", "lgpl v2.1", "mit",
    "mit license", "apache", "wtfpl", "public domain", "gplv3", "cc-by-sa"}


def _clean_name(raw):
    n = MD_LINK.sub(r'\1', raw)
    n = NOISE.sub("", n).strip(" \t,;.-*")
    if not n or len(n) > 60:
        return ""
    # lines that are prose rather than a credit
    if re.search(r'\b(licen[sc]e|copyright|texture|sound|model|derived|based on|'
            r'modified|the following|all rights)\b', n, re.I):
        return ""
    if n.lower().startswith(("http", "www.")) or n.count(" ") > 6:
        return ""
    if n.lower().strip(" .") in LICENCE_NAMES:
        return ""
    # A credit is a person or a handle. These are the things that kept coming
    # back instead: filenames in backticks, section labels ending in a colon,
    # and prose introductions. Free-form markdown credit files do not extract
    # reliably, so the rule here is to emit nothing rather than a wrong name,
    # and let licence_source point at the file for a human to read.
    if "`" in raw or n.endswith(":") or ".png" in n.lower() or ".ogg" in n.lower():
        return ""
    if re.match(r'^(source|origin|license|licence|credits|textures?|models?|sounds?)\b',
            n, re.I):
        return ""
    if n.lower().startswith(("modifications", "original ", "some ", "all ", "the ")):
        return ""
    return n


def _names_in(text, allow_bullets=True):
    out = []
    for m in COPYRIGHT_BLOCK.finditer(text):
        for line in m.group(1).splitlines():
            n = _clean_name(line)
            if n and n not in out:
                out.append(n)
    if allow_bullets:
        for m in BULLET.finditer(text):
            n = _clean_name(m.group(1))
            if n and n not in out:
                out.append(n)
    return out


def credits_for(stem, entries, game_names):
    """Author names for one texture, most specific first.

    If the texture's own filename appears in a licence file, the names in that
    neighbourhood are the ones that belong to it. Otherwise the mod's whole
    credit list, and failing that the game's. Over-crediting is the safe error
    here: a name too many is untidy, a name missing is the thing the licence
    actually forbids.
    """
    for path, media, whole, section in entries:
        body = section or ""
        if not body or stem not in body:
            continue
        lines = body.splitlines()
        for i, line in enumerate(lines):
            if stem in line:
                near = "\n".join(lines[max(0, i - 6):i + 7])
                names = _names_in(near)
                if names:
                    return names, "near filename"
    for path, media, whole, section in entries:
        base = os.path.basename(path).lower()
        bullets = any(k in base for k in ("licen", "credit", "attribut"))
        names = _names_in(section or "", allow_bullets=bullets)
        if names:
            return names, "mod"
    return game_names, "game"


def licence_for(stem, mod_dir, game_dir, cache):
    """Best guess at one texture's licence, with where it came from.

    Three tiers, and the confidence column says which was used, because they
    are not equally trustworthy:
      named   the texture's own filename appears in a licence file, next to a
              licence. Only this one is actually per file.
      mod     the owning mod declares exactly one media licence.
      game    fall back to the game wide statement.
    A mod declaring several media licences without naming files gets them all
    listed and a confidence of "ambiguous", which is the honest answer: a
    person has to read it.
    """
    if mod_dir == game_dir:
        # No owning mod could be found. Walking the game from here would pick
        # up whichever deep media file happened to sort first, which is how a
        # two line note about two barrel sound effects came to license 1,767
        # textures as CC0.
        return [], "game", ""
    if mod_dir not in cache:
        entries = []
        for root, _, files in os.walk(mod_dir):
            for fn in files:
                low = fn.lower()
                if low.startswith(("license", "licence", "copying", "credits")) \
                        or low in ("attributes.txt", "attribution.txt"):
                    path = os.path.join(root, fn)
                    media, whole, section = parse_licence_file(path)
                    entries.append((path, media, whole, section))
        # Deepest first. A LICENSE.txt sitting inside textures/ is about the
        # textures and nothing else; one at the mod root is usually about the
        # code, with the media as an afterthought or absent. mcl_amethyst has
        # exactly this shape, a one line textures/LICENSE.txt crediting
        # Nova_Wostra under CC BY-SA 4.0, and taking the mod root file instead
        # answered with the code licence.
        entries.sort(key=lambda e: -e[0].count(os.sep))
        cache[mod_dir] = entries
    entries = cache[mod_dir]

    # tier 0: a licence file living inside a media directory. It has no
    # separate "media" heading because the whole file is about media.
    for path, media, whole, section in entries:
        parts = path.replace(os.sep, "/").split("/")
        if "textures" in parts[:-1] and whole:
            return (media or whole), "media dir", os.path.relpath(path, game_dir)

    # tier 1: the filename itself, or a * glob, appears beside a licence
    for path, media, whole, section in entries:
        body = section or ""
        if not body:
            continue
        for line in body.splitlines():
            if stem in line or (stem + ".png") in line:
                lic = _licences_in(line)
                if lic:
                    return lic, "named", os.path.relpath(path, game_dir)
    # tier 2: the mod declares media licences of its own
    for path, media, whole, section in entries:
        if len(media) == 1:
            return media, "mod", os.path.relpath(path, game_dir)
    for path, media, whole, section in entries:
        if len(media) > 1:
            return media, "ambiguous", os.path.relpath(path, game_dir)
    # tier 3: a licence file with no media heading at all. Asuna's is like
    # this: one LICENSE saying the game as a whole is GPL-3.0 with specific
    # works listed under other terms. Reading the whole file conflates the code
    # licence with the media licence, which is why this is its own confidence
    # level rather than being folded into the ones above.
    for path, media, whole, section in entries:
        if whole:
            return whole, "unsplit", os.path.relpath(path, game_dir)
    return [], "game", ""


def game_licence(game_dir):
    fallback = ([], "")
    for fn in ("LEGAL.md", "LICENSE.txt", "license.txt", "LICENSE", "README.md"):
        p = os.path.join(game_dir, fn)
        if not os.path.exists(p):
            continue
        media, whole, section = parse_licence_file(p)
        if media:
            return media, fn
        if whole and not fallback[0]:
            fallback = (whole, fn)
    return fallback


def game_credits(game_dir):
    for fn in ("LEGAL.md", "LICENSE.txt", "license.txt"):
        p = os.path.join(game_dir, fn)
        if not os.path.exists(p):
            continue
        media, whole, section = parse_licence_file(p)
        names = _names_in(section or "", allow_bullets=True)
        if names:
            return names
    return []


def scan(game_dir):
    out = {}
    cache = {}
    game_lic, game_lic_file = game_licence(game_dir)
    game_names = game_credits(game_dir)
    for root, _, files in os.walk(game_dir):
        for f in files:
            if not f.lower().endswith(".png"):
                continue
            stem = f[:-4]
            if stem in out:
                continue
            path = os.path.join(root, f)
            try:
                digest = hashlib.md5(open(path, "rb").read()).hexdigest()
            except OSError:
                continue
            mod = owning_mod(path, game_dir)
            mod_dir = os.path.dirname(path)
            while mod_dir.startswith(game_dir) and len(mod_dir) > len(game_dir) \
                    and not os.path.exists(os.path.join(mod_dir, "mod.conf")):
                mod_dir = os.path.dirname(mod_dir)
            lic, conf, src = licence_for(stem, mod_dir, game_dir, cache)
            if not lic:
                lic, src = game_lic, game_lic_file
            cred, cred_conf = credits_for(stem, cache.get(mod_dir, []), game_names)
            out[stem] = {"path": path, "mod": mod, "md5": digest,
                    "concept": concept_of(stem, mod),
                    "category": category(path, game_dir),
                    "licence": " / ".join(lic) if lic else "unknown",
                    "licence_confidence": conf,
                    "licence_source": src,
                    "credits": "; ".join(cred[:12]),
                    "credits_n": len(cred),
                    "credits_confidence": cred_conf}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--games-dir", required=True)
    ap.add_argument("--games", required=True, help="comma separated game directory names")
    ap.add_argument("--out", required=True, help="CSV to write")
    args = ap.parse_args()

    games = [g.strip() for g in args.games.split(",") if g.strip()]
    per = {}
    for g in games:
        d = os.path.join(os.path.expanduser(args.games_dir), g)
        if not os.path.isdir(d):
            print("skipping missing game:", d)
            continue
        per[g] = scan(d)
        print("%-16s %5d texture names" % (g, len(per[g])))
    if not per:
        return 1
    games = [g for g in games if g in per]

    by_concept = collections.defaultdict(lambda: collections.defaultdict(list))
    for g, m in per.items():
        for stem, info in m.items():
            by_concept[info["concept"]][g].append((stem, info))

    rows = []
    for concept in sorted(by_concept):
        present = by_concept[concept]
        digests = {i["md5"] for gm in present.values() for _, i in gm}
        cats = {i["category"] for gm in present.values() for _, i in gm}
        mods = {i["mod"] for gm in present.values() for _, i in gm if i["mod"]}
        lics = sorted({i["licence"] for gm in present.values() for _, i in gm})
        confs = {i["licence_confidence"] for gm in present.values() for _, i in gm}
        srcs = sorted({i["licence_source"] for gm in present.values() for _, i in gm
                if i["licence_source"]})
        creds = []
        for gm in present.values():
            for _, i in gm:
                for c in i["credits"].split("; "):
                    if c and c not in creds:
                        creds.append(c)
        ccs = {i["credits_confidence"] for gm in present.values() for _, i in gm}
        row = {
            "credits": "; ".join(creds[:12]),
            "credits_n": len(creds),
            "credits_confidence": ("near filename" if "near filename" in ccs
                    else "mod" if "mod" in ccs else "game"),
            "licence": " | ".join(lics),
            "licence_confidence": ("named" if confs == {"named"} else
                    "media dir" if "media dir" in confs and "ambiguous" not in confs else
                    "ambiguous" if "ambiguous" in confs else
                    "unsplit" if "unsplit" in confs else
                    "mod" if "mod" in confs else "game"),
            "licence_source": " | ".join(srcs[:3]),
            "concept": concept,
            "games": len(present),
            "identical_art": "yes" if len(digests) == 1 and len(present) > 1 else "no",
            "images": sum(len(v) for v in present.values()),
            "distinct_art": len(digests),
            "category": ",".join(sorted(cats)),
            "mods": ",".join(sorted(mods)),
        }
        for g in games:
            row[g] = ",".join(sorted(s for s, _ in present.get(g, [])))
        rows.append(row)

    rows.sort(key=lambda r: (-r["games"], -r["images"], r["concept"]))
    fields = ["concept", "games", "credits", "credits_n", "credits_confidence",
            "licence", "licence_confidence", "licence_source",
            "identical_art", "distinct_art", "images", "category", "mods"] + games
    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in rows:
            w.writerow(r)

    total_names = sum(len(m) for m in per.values())
    all_digests = {i["md5"] for m in per.values() for i in m.values()}
    shared = [r for r in rows if r["games"] > 1]
    print()
    print("texture names across all games      %6d" % total_names)
    print("distinct images (byte identical)    %6d" % len(all_digests))
    print("concepts (name normalised)          %6d" % len(rows))
    print("  in more than one game             %6d" % len(shared))
    print("  of those, byte identical          %6d"
            % len([r for r in shared if r["identical_art"] == "yes"]))
    print()
    lic_count = collections.Counter(r["licence"] for r in rows)
    conf_count = collections.Counter(r["licence_confidence"] for r in rows)
    print()
    print("licence guess by confidence:")
    for k in ("named", "media dir", "mod", "ambiguous", "unsplit", "game"):
        if conf_count.get(k):
            print("  %-10s %6d" % (k, conf_count[k]))
    print()
    print("most common licence guesses:")
    for lic, n in lic_count.most_common(8):
        print("  %6d  %s" % (n, lic))
    print()
    print("wrote", args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
