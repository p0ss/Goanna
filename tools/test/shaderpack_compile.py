#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Translate and compile a shader pack's screen space chain without a GPU.

Runs build/goanna_iris_pack_test --dump on each pack, which loads it with
Goanna's own loader and writes every composite chain pass as the Vulkan GLSL
the effect would hand Godot, then compiles each stage with glslangValidator
(the same front end Godot's shader_compile_spirv_from_source uses). It says
which passes compile, which fail and the first error of each, and which
uniforms the passes declare that nothing supplies.

    tools/test/shaderpack_compile.py PACK [PACK ...] [--out DIR] [--json]
        [--option NAME=VALUE ...]

PACK is a pack root or its shaders/ directory, unpacked. A pass that
compiles here can still fail at pipeline creation on the GPU, so this is
the cheap first check, not the run. Packs are third party data: nothing in
them is executed, they are only read by the loader and the compiler.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def find_glslang():
    env = os.environ.get("GLSLANG")
    if env:
        return env
    return shutil.which("glslangValidator")


def read_manifest(path):
    out = {"passes": [], "notes": []}
    cur = None
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            indented = line.startswith("  ")
            key, _, value = line.strip().partition("\t")
            if not indented:
                if key == "pass":
                    cur = {"name": value, "warnings": [], "extra": {}}
                    out["passes"].append(cur)
                else:
                    out["notes"].append((key, value))
            elif cur is not None:
                if key == "warning":
                    cur["warnings"].append(value)
                elif key == "extra_uniform":
                    name, _, how = value.partition("\t")
                    cur["extra"][name] = how
                else:
                    cur[key] = value
    return out


def compile_stage(glslang, path, stage):
    r = subprocess.run([glslang, "-V", "--target-env", "vulkan1.1", "-S", stage, "-o", os.devnull, path],
                       capture_output=True, text=True, timeout=120)
    if r.returncode == 0:
        return None
    lines = [l for l in (r.stdout + r.stderr).splitlines() if "ERROR" in l and path in l or l.startswith("ERROR:")]
    return lines[0].replace(path, os.path.basename(path)) if lines else (r.stdout + r.stderr).strip()[:300]


def run_pack(pack, out_dir, options, glslang, test_bin):
    os.makedirs(out_dir, exist_ok=True)
    r = subprocess.run([test_bin, "--dump", pack, out_dir] + options, capture_output=True, text=True,
                       cwd=REPO, timeout=600)
    man = read_manifest(os.path.join(out_dir, "manifest.txt"))
    man["dump_exit"] = r.returncode
    for p in man["passes"]:
        p["errors"] = {}
        if "translate_error" in p or "read_error" in p:
            p["ok"] = False
            continue
        for stage, ext in (("vert", ".vert"), ("frag", ".frag")):
            e = compile_stage(glslang, os.path.join(out_dir, p["name"] + ext), stage)
            if e:
                p["errors"][stage] = e
        p["ok"] = not p["errors"]
    return man


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("packs", nargs="+")
    ap.add_argument("--out", help="directory for the translated GLSL (default: a temporary one)")
    ap.add_argument("--json", action="store_true", help="print the full result as JSON")
    ap.add_argument("--option", action="append", default=[], help="NAME=VALUE option override")
    args = ap.parse_args()

    glslang = find_glslang()
    if not glslang:
        sys.exit("glslangValidator not found: put it on PATH or set GLSLANG")
    test_bin = os.path.join(REPO, "build", "goanna_iris_pack_test")
    if not os.path.exists(test_bin):
        sys.exit("build the loader first: cmake --build build --target goanna_iris_pack_test")
    base = args.out or tempfile.mkdtemp(prefix="goanna-shaderpack-compile-")
    results = {}
    failed = False
    for pack in args.packs:
        name = os.path.basename(os.path.normpath(pack))
        if name in ("shaders", "pack"):
            name = os.path.basename(os.path.dirname(os.path.normpath(pack)))
        res = run_pack(pack, os.path.join(base, name), args.option, glslang, test_bin)
        results[name] = res
        ok = sum(1 for p in res["passes"] if p["ok"])
        print(f"== {name}: {ok} of {len(res['passes'])} passes compile")
        for key, value in res["notes"]:
            if key in ("load_error", "disabled", "property_warning", "custom_unresolved", "unknown_override"):
                print(f"   {key}: {value}")
        for p in res["passes"]:
            zero = sorted(n for n, how in p["extra"].items() if how == "zero")
            line = f"   {p['name']:12s} {'ok' if p['ok'] else 'FAIL'}"
            if zero:
                line += "  zero: " + " ".join(zero)
            print(line)
            for k in ("read_error", "translate_error"):
                if k in p:
                    print(f"      {k}: {p[k]}")
            for stage, e in p["errors"].items():
                print(f"      {stage}: {e}")
        if res["dump_exit"] != 0 or any(not p["ok"] for p in res["passes"]):
            failed = True
    print(f"translated GLSL in {base}")
    if args.json:
        print(json.dumps(results, indent=1))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
