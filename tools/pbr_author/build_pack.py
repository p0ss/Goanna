#!/usr/bin/env python3
"""Run every authored script and install the result into a pack.

  tools/pbr_author/build_pack.py [--stems a,b] [--stage <dir>]
      [--install <pack textures dir>] [--check]

Each tools/pbr_author/<stem>.py is run with the stage directory as its
argument. With --install the three files it wrote (albedo, _n, _s) replace
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
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import lib  # noqa: E402

SKIP = {"lib.py", "build_pack.py", "__init__.py"}


def scripts(stems):
    if stems:
        return [HERE / (s + ".py") for s in stems]
    # Family modules carry run(stem) for their one line per stem scripts
    # and are not stems themselves.
    return sorted(p for p in HERE.glob("*.py")
            if p.name not in SKIP and not p.name.endswith("_family.py"))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--stems", default="")
    ap.add_argument("--stage", type=Path, default=Path("/tmp/goanna-authored"))
    ap.add_argument("--install", type=Path, default=None)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()
    args.stage.mkdir(parents=True, exist_ok=True)
    stems = [s for s in args.stems.split(",") if s]
    done = []
    failed = []
    for script in scripts(stems):
        stem = script.stem
        if not script.exists():
            print("%-36s no script" % stem)
            failed.append(stem)
            continue
        r = subprocess.run([sys.executable, str(script), str(args.stage)],
                capture_output=True, text=True)
        lines = [l for l in r.stdout.splitlines() if l.startswith(("ok  ", "FAIL"))]
        ok = r.returncode == 0 and lines and not any(l.startswith("FAIL") for l in lines)
        cls = lib.class_of(stem)
        try:
            m = lib.metrics(args.stage, stem)
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
    print("%d built, %d failed" % (len(done), len(failed)))
    if args.check or args.install is None:
        return
    installed = []
    for stem in done:
        for suffix in (".png", "_n.png", "_s.png"):
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
    print("installed %d sets into %s" % (len(installed), args.install))


if __name__ == "__main__":
    main()
