#!/usr/bin/env python3
"""Build every authored set for a game and install the result into a pack.

  tools/pbr_author/build_pack.py [--game kythen] [--stems a,b] [--stage <dir>]
      [--install [<pack textures dir>]] [--check]

A game with a stem list, tools/pbr_author/stems/<game>.txt, is built by
extrude.py: every listed stem through the texel extrusion rule and its
spec, checked by extrude.check. Mineclonia is built this way. Mob skins
listed in stems/<game>.mobs.txt are built by atlas.py and checked by
atlas.check in the same run, and their installed sets get a licence note
naming their mod. A mob skin installs only its _n and _s, never the
albedo atlas.py writes to the stage for previews: the client draws the
game's own art.

A game without one runs its per stem scripts, as Kythen still does. A script belongs to the game it declares with GAME = "..." at module level;
one that declares none is Mineclonia's. Each tools/pbr_author/<stem>.py is
run with the stage directory as its argument. A bare --install goes to the
game's shipped pack (lib.GAMES). With --install the three files it wrote (albedo, _n, _s) replace
the pack's, and an "Authored" section is appended to the pack's
ATTRIBUTION.md naming the stems, since the albedo is the game's art
upscaled and the maps are derived from it: the same licence and the same
attribution as the bake, with a different tool in the chain. --check only
runs the scripts and prints their check lines, installing nothing.

A script that fails its checks is reported and still installed unless
--strict is given, because a set that misses a tilt target by a degree is
still a surface and the bake it replaces is not.
"""

import argparse
import datetime
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import lib  # noqa: E402

SKIP = {"lib.py", "build_pack.py", "__init__.py"}


GAME_LINE = re.compile(r'^GAME\s*=\s*"([a-z_]+)"', re.M)


def game_of(script):
    """The game a script declares with GAME = "..." at module level, or the
    default game when it declares none (the Mineclonia scripts predate the
    line)."""
    m = GAME_LINE.search(script.read_text())
    return m.group(1) if m else lib.DEFAULT_GAME


def scripts(stems, game):
    if stems:
        return [HERE / (s + ".py") for s in stems]
    # Family modules carry run(stem) for their one line per stem scripts
    # and are not stems themselves.
    found = sorted(p for p in HERE.glob("*.py")
            if p.name not in SKIP and not p.name.endswith("_family.py"))
    return [p for p in found if game_of(p) == game]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--stems", default="")
    ap.add_argument("--game", default=lib.DEFAULT_GAME,
            help="only scripts declaring this GAME (default %s)" % lib.DEFAULT_GAME)
    ap.add_argument("--stage", type=Path, default=None)
    ap.add_argument("--install", nargs="?", const="default", default=None,
            help="install into this pack textures dir, or the game's shipped pack when bare")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()
    if args.game not in lib.GAMES:
        sys.exit("unknown game %s; lib.GAMES knows %s" % (args.game, ", ".join(lib.GAMES)))
    if args.stage is None:
        args.stage = Path("/tmp/goanna-authored") / args.game
    if args.install == "default":
        args.install = lib.GAMES[args.game]["install"]
    elif args.install is not None:
        args.install = Path(args.install)
    args.stage.mkdir(parents=True, exist_ok=True)
    stems = [s for s in args.stems.split(",") if s]
    done = []
    failed = []
    stem_list = HERE / "stems" / (args.game + ".txt")
    if stem_list.exists():
        import atlas
        import extrude
        # Mob skins are model atlases, listed apart in stems/<game>.mobs.txt
        # and built by atlas.py: extrude.py would tile them, wrap them and
        # bevel across their UV islands.
        mobs = {s for s, _, _ in atlas.mobs_list(args.game)}
        listed = stem_list.read_text().split() + sorted(mobs)
        for stem in stems or listed:
            tool = atlas if stem in mobs else extrude
            try:
                tool.build(stem, args.stage, args.game)
                bad = [l[5:] for l in tool.check(stem, args.stage, args.game)
                       if l.startswith("FAIL")]
            except Exception as e:  # noqa: BLE001 - reported per stem
                bad = ["error: %s" % e]
            print("%-44s %s" % (stem, "ok" if not bad else "FAIL " + "; ".join(bad)))
            (failed if bad and (args.strict or bad[0].startswith("error")) else done).append(stem)
        args.atlases = sorted(mobs & set(done))
        return install(args, done, failed)
    for script in scripts(stems, args.game):
        stem = script.stem
        if not script.exists():
            print("%-36s no script" % stem)
            failed.append(stem)
            continue
        r = subprocess.run([sys.executable, str(script), str(args.stage)],
                capture_output=True, text=True)
        lines = [l for l in r.stdout.splitlines() if l.startswith(("ok  ", "FAIL"))]
        ok = r.returncode == 0 and lines and not any(l.startswith("FAIL") for l in lines)
        cls = lib.class_of(stem, args.game)
        try:
            m = lib.metrics(args.stage, stem, lib.art_size(stem, args.game))
            summary = "tilt %4.1f ao_min %.2f smooth_sd %.3f" % (
                    m["tilt_mean_deg"], m["ao_min"], m["smooth_sd"])
        except FileNotFoundError:
            summary = "wrote nothing"
            ok = False
        print("%-36s %-8s %s %s" % (stem, cls, "ok  " if ok else "FAIL", summary))
        if r.returncode != 0:
            print("    " + (r.stderr.strip().splitlines() or ["no output"])[-1])
        for l in lines:
            if l.startswith("FAIL"):
                print("    " + l)
        (done if ok or not args.strict else failed).append(stem)
        if not ok:
            failed.append(stem) if stem not in failed and args.strict else None
    return install(args, done, failed)


def install(args, done, failed):
    print("%d built, %d failed" % (len(done), len(failed)))
    if args.check or args.install is None:
        return
    args.install.mkdir(parents=True, exist_ok=True)
    installed = []
    # A mob skin installs its companions only. The client draws the game's
    # own art and scales the maps to it; an albedo upscaled to map size
    # broke mcl_skins, whose bracketed (mask^[colorize) groups Luanti blits
    # at their own 64 x 32 size into the corner of the 1024 wide part, and
    # would break any mod that combines or crops a skin by coordinates.
    atlases = set(getattr(args, "atlases", []))
    for stem in done:
        for suffix in (("_n.png", "_s.png") if stem in atlases else (".png", "_n.png", "_s.png")):
            src = args.stage / (stem + suffix)
            if src.exists():
                (args.install / (stem + suffix)).write_bytes(src.read_bytes())
        installed.append(stem)
    attribution = args.install.parent / "ATTRIBUTION.md"
    if attribution.exists() and installed:
        with attribution.open("a") as f:
            f.write("\n## Authored sets, %s\n\n" % datetime.date.today().isoformat())
            f.write("The following textures were rebuilt by tools/pbr_author/ from the\n"
                    "same game art: the albedo is that art upscaled without repainting,\n"
                    "and the normal, occlusion, height and specular maps are derived from\n"
                    "height and smoothness fields authored on it. Same licence, same\n"
                    "attribution as the bake above.\n\n")
            f.write("- textures: " + ", ".join(sorted(installed)) + "\n")
            atlases = [s for s in getattr(args, "atlases", []) if s in installed]
            if atlases:
                f.write(atlas_attribution(args.game, atlases))
    print("installed %d sets into %s" % (len(installed), args.install))


def atlas_attribution(game, stems):
    """The licence note for mob skins. The bake never read them, so the
    per mod list above does not name their mod; this does, with the mod's
    own licence files, which can differ per file."""
    root = lib.GAMES[game]["art"]
    by_mod = {}
    for stem in stems:
        mod = lib.source_path(stem, game).parent.parent
        by_mod.setdefault(mod, []).append(stem)
    out = ["\nThe sets below are mob skins (model atlases, tools/pbr_author/atlas.py).\n"
           "They are derived from the skin art of the mod named, under that mod's\n"
           "media licence; read its licence files for the terms that apply to each\n"
           "file. The models are only read for their UV layout and are not copied.\n"
           "Only their maps are installed; the art itself is not.\n"]
    for mod, names in sorted(by_mod.items()):
        out.append("\n### `%s`\n\n" % mod.relative_to(root))
        for p in sorted(mod.iterdir()):
            # mcl_skins keeps the per file authors and licences of its art
            # in media_credits.txt.
            if p.is_file() and p.name.upper().startswith(("LICENSE", "CREDITS", "COPYING",
                                                            "MEDIA_CREDITS")):
                out.append("- licence file: `%s`\n" % p.relative_to(root))
        out.append("- textures: " + ", ".join(sorted(names)) + "\n")
        masks = sorted({atlas_spec_mask(s, game) for s in names} - {None})
        if masks:
            out.append("- also read (colouring masks, not copied): " + ", ".join(masks) + "\n")
    return "".join(out)


def atlas_spec_mask(stem, game):
    import extrude
    return extrude.load_spec(stem, game).get("mask")


if __name__ == "__main__":
    main()
