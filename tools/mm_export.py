#!/usr/bin/env python3
"""Export Material Maker materials to PNG channel sets without the GUI.

  tools/mm_export.py <out dir> [--size 256] [--target "Godot/Godot 4 Standard"]
      [--limit 90] <file.ptex or directory> ...

Runs the Material Maker flatpak (io.github.RodZill4.Material-Maker) with
tools/mm_export.gd in place of its start scene, because 1.7's own
--export-material never opens the DirAccess it tests and exports nothing.
The renderer needs a GPU and a display, so this opens a window for the
duration; it needs no clicks. Each material writes
<name>_albedo/_normal/_orm/_heightmap/_emission.png and a .tres in the
Godot 4 Standard layout that tools/pbr_from_mm.py reads. A material whose
graph no longer compiles in this Material Maker (an old website upload,
say) is reported and skipped after --limit seconds.

The out directory and the inputs must be under the home directory, which
is all the flatpak can see.
"""

import argparse
import subprocess
import sys
import time
from pathlib import Path

APP = "io.github.RodZill4.Material-Maker"
SCRIPT = Path(__file__).resolve().with_name("mm_export.gd")


def run_batch(cmd, files, args, logf, status):
    """One runner over these files. Returns the files it exported and the
    file that hung, if one did (the runner is then dead)."""
    if status.exists():
        status.unlink()
    proc = subprocess.Popen(cmd + [str(f.resolve()) for f in files], stdout=logf, stderr=subprocess.STDOUT)
    by_name = {f.name: f for f in files}
    seen = 0
    done = []
    hung = None
    # A material is hung when the script says so, or when nothing has been
    # said for the limit plus startup time: the wait in the script itself
    # is not always reached.
    last = time.time()
    current = None
    while True:
        lines = status.read_text(errors="replace").splitlines() if status.exists() else []
        for line in lines[seen:]:
            print(line)
            words = line.split()
            if len(words) >= 3 and words[1] == "loading":
                current = by_name.get(words[2])
            if line.endswith(" exported") and len(words) == 3:
                done.append(by_name[words[1]])
            if "did not finish" in line:
                hung = by_name[words[1]]
        if len(lines) != seen:
            last = time.time()
        seen = len(lines)
        if hung is None and current is not None and time.time() - last > args.limit + 30:
            print("mm_export: %s stalled" % current.name)
            hung = current
        if hung is not None or (lines and lines[-1] == "mm_export: done"):
            break
        if proc.poll() is not None:
            print("runner exited early; see %s" % logf.name)
            break
        if time.time() - last > args.limit + 90:
            print("gave up waiting; see %s" % logf.name)
            break
        time.sleep(0.5)
    kill_instance(proc.pid)
    proc.wait()
    return done, hung


def kill_instance(wrapper_pid):
    """Kill only the sandbox this run started: flatpak kill with the
    application id would take the user's own Material Maker window too."""
    out = subprocess.run(["flatpak", "ps", "--columns=instance,pid,application"],
            capture_output=True, text=True).stdout
    for line in out.splitlines():
        cols = line.split()
        if len(cols) != 3 or cols[2] != APP:
            continue
        # The column is the sandbox's bwrap, a child of our flatpak run.
        ppid = subprocess.run(["ps", "-o", "ppid=", "-p", cols[1]],
                capture_output=True, text=True).stdout.strip()
        if cols[1] == str(wrapper_pid) or ppid == str(wrapper_pid):
            subprocess.run(["flatpak", "kill", cols[0]], stderr=subprocess.DEVNULL)
            return
    # The runner exited on its own.


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("out", type=Path)
    ap.add_argument("inputs", nargs="+", type=Path)
    ap.add_argument("--size", type=int, default=256)
    ap.add_argument("--target", default="Godot/Godot 4 Standard")
    ap.add_argument("--limit", type=float, default=90.0)
    args = ap.parse_args()
    files = []
    for p in args.inputs:
        if p.is_dir():
            files += sorted(p.glob("*.ptex"))
        elif p.suffix == ".ptex":
            files.append(p)
    if not files:
        sys.exit("no .ptex inputs")
    args.out.mkdir(parents=True, exist_ok=True)
    cmd = ["flatpak", "run", "--command=godot-runner", APP, "--audio-driver", "Dummy",
            "--main-pack", "/app/bin/material-maker.pck", "--script", str(SCRIPT), "--",
            "-o", str(args.out.resolve()), "--size", str(args.size), "--target", args.target,
            "--limit", str(args.limit)]
    log = args.out / "mm_export.log"
    status = args.out / "mm_export.status"
    # A material whose render hangs blocks every render after it in the
    # same process, so the runner is killed and relaunched on the files
    # after the one that hung.
    failed = []
    todo = list(files)
    with log.open("w") as logf:
        while todo:
            done, hung = run_batch(cmd, todo, args, logf, status)
            if hung is None:
                failed += [f for f in todo if f not in done]
                break
            failed += [f for f in todo[:todo.index(hung)] if f not in done]
            failed.append(hung)
            todo = todo[todo.index(hung) + 1:]
    print("log: %s" % log)
    if failed:
        print("failed: " + ", ".join(f.name for f in failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
