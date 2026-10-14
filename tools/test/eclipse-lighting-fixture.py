#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Prepare Eclipse input experiments and a matching Minecraft fixture.

Writes disposable pack copies and render-service jobs, never edits the source
pack or launches a client. The inverse curve is a diagnostic approximation:
inverting averaged brightness does not recover averaged raw node light.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shutil


NODES = [
    {"box": [[-8, 0, 8], [8, 5, 8]], "node": "mcl_core:stonebrick"},
    {"box": [[3, 5, 2], [7, 5, 7]], "node": "mcl_core:stonebrick"},
    {"box": [[8, 0, 2], [8, 5, 7]], "node": "mcl_core:stonebrick"},
    {"box": [[-6, -2, 1], [-1, -2, 5]], "node": "mcl_core:stonebrick"},
    {"box": [[-6, -1, 1], [-1, -1, 5]], "node": "mcl_core:water_source"},
    {"pos": [6, 0, 6], "node": "mcl_lanterns:lantern_floor"},
]
POSE = {"name": "overview", "pos": [-2, 3, -10],
        "look_at": [1, 1.8, 5], "fov": 70}
VARIANTS = ["baseline", "inverse-levels", "old-lighting-off",
            "neutral-vertex-colour", "geometry-only"]
PHASES = {"day": 0.5, "dusk": 0.73, "night": 0.0}
LIGHT_PROBE = """core.after(2, function()
    core.emerge_area(P(0,0,0), P(9,7,9), function(_,_,remaining)
        if remaining ~= 0 then return end
        local rows = {}
        for z=0,7 do
            local p = P(6,1,z)
            local n = core.get_node(p)
            rows[#rows+1] = {pos=p, name=n.name, day=n.param1%16,
                night=math.floor(n.param1/16)}
        end
        core.log("action", "GOANNA_LIGHT_PROBE_LOADED "..core.write_json(rows))
    end)
end)"""


def light_curve():
    # ensureSettings() and Luanti light.cpp: fixed Goanna defaults, gamma 1.
    values = [0]
    for level in range(1, 15):
        x = level / 15
        brightness = (-0.5 * x + 1.5) * x * x
        brightness += 0.2 * math.exp(-0.5 * ((x - 0.5) / 0.2) ** 2)
        values.append(min(255, max(values[-1] + 1, int(255 * brightness))))
    return values + [255]


def inverse_shader(curve):
    lines = ["float probe_level(float packed) {",
             "    float b = clamp(packed / 240.0, 0.0, 1.0) * 255.0;"]
    for i in range(15):
        lo, hi = curve[i:i + 2]
        lines.append(f"    if (b <= {hi}.0) return 16.0 * "
                     f"({i}.0 + (b - {lo}.0) / {hi - lo}.0);")
    lines += ["    return 240.0;", "}",
              "vec4 probe_coords(vec4 p) {",
              "    return vec4(probe_level(p.x), probe_level(p.y), p.zw);",
              "}"]
    return "\n".join(lines) + "\n"


def prepare_pack(source, target, variant, curve):
    shutil.copytree(source, target)
    shaders = target / "shaders"
    changes = []
    if variant == "old-lighting-off":
        with (shaders / "shaders.properties").open("a") as f:
            f.write("\noldLighting=false\n")
        changes.append("oldLighting=false")
    for path in shaders.rglob("*.vsh"):
        text = path.read_text()
        if variant == "inverse-levels" and "gl_MultiTexCoord1" in text:
            text = text.replace("gl_MultiTexCoord1", "probe_coords(gl_MultiTexCoord1)")
            pos = text.index("\n") + 1
            text = text[:pos] + inverse_shader(curve) + text[pos:]
        elif variant == "neutral-vertex-colour":
            text = re.sub(r"\bgl_Color\b", "vec4(1.0)", text)
        else:
            continue
        path.write_text(text)
        changes.append(str(path.relative_to(target)))
    if variant == "geometry-only":
        for pattern in ("composite*.*sh", "deferred*.*sh"):
            for path in shaders.rglob(pattern):
                changes.append("removed " + str(path.relative_to(target)))
                path.unlink()
        for path in shaders.rglob("final.fsh"):
            path.write_text("#version 330 compatibility\nuniform sampler2D colortex0;\n"
                            "in vec2 texcoord;\nlayout(location=0) out vec4 colour;\n"
                            "void main() { colour = texture(colortex0, texcoord); }\n")
            changes.append(str(path.relative_to(target)))
    return changes


def minecraft_fixture(out):
    names = {"mcl_core:stonebrick": "minecraft:stone_bricks",
             "mcl_core:water_source": "minecraft:water",
             "mcl_lanterns:lantern_floor": "minecraft:lantern[hanging=false]"}
    origin = [1000, 64, 1000]
    def coord(p):
        return " ".join(str(origin[i] + p[i]) for i in range(3))
    lines = ["# Run only in a disposable Java world: this replaces the fixture volume.",
             "# First teleport to 1000 70 1000 and wait for nearby chunks to load.",
             "gamerule doDaylightCycle false", "weather clear",
             "fill 976 62 976 1024 71 1024 minecraft:air",
             "fill 976 63 976 1024 63 1024 minecraft:stone"]
    for node in NODES:
        if "box" in node:
            a, b = node["box"]
            lines.append(f"fill {coord(a)} {coord(b)} {names[node['node']]}")
        else:
            lines.append(f"setblock {coord(node['pos'])} {names[node['node']]}")
    pos, target = POSE["pos"], POSE["look_at"]
    d = [target[i] - pos[i] for i in range(3)]
    yaw = math.degrees(math.atan2(-d[0], d[2]))
    pitch = -math.degrees(math.atan2(d[1], math.hypot(d[0], d[2])))
    feet = [origin[i] + pos[i] + 0.5 for i in range(3)]
    feet[1] -= 1.62
    lines += ["gamemode spectator @s", "# Camera assumes eye height 1.62 and FOV 70.",
              "tp @s %.3f %.3f %.3f %.5f %.5f" % (*feet, yaw, pitch),
              "# Start at noon; match sun direction explicitly before comparison.",
              "time set noon"]
    (out / "minecraft-fixture.mcfunction").write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pack", type=Path, help="Eclipse root containing shaders/")
    parser.add_argument("--out", type=Path, required=True, help="new output directory")
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--variants", nargs="+", choices=VARIANTS, default=VARIANTS)
    parser.add_argument("--phases", nargs="+", choices=PHASES, default=["day", "night"])
    args = parser.parse_args()
    source, out = args.pack.resolve(), args.out.resolve()
    if not (source / "shaders/gbuffers_textured_lit.vsh").is_file():
        parser.error("expected the Eclipse pack used by the shader checkpoint")
    out.mkdir(parents=True, exist_ok=False)
    curve = light_curve()
    manifest = {"source": str(source), "source_hashes": {}, "curve": curve,
                "changes": {}, "minecraft_reference": "not captured",
                "notes": ["Inverse levels are approximate after vertex averaging.",
                          "Neutral vertex colour removes tint, AO and face shading together.",
                          "Geometry-only still includes lighting and fog inside gbuffers.",
                          "SSAO and soft shadows are off in every variant.",
                          "Goanna eye brightness remains fixed at 240,240.",
                          "Luanti day light includes artificial light, not just sky.",
                          "Minecraft block light and game light-source strengths can differ."]}
    for path in sorted(source.rglob("*")):
        if path.is_file():
            manifest["source_hashes"][str(path.relative_to(source))] = hashlib.sha256(path.read_bytes()).hexdigest()
    variants = []
    for name in args.variants:
        target = out / "packs" / name
        manifest["changes"][name] = prepare_pack(source, target, name, curve)
        for phase in args.phases:
            variants.append({"name": name + "-" + phase, "time": PHASES[phase],
                             "env": {"GOANNA_SHADERPACK": str(target),
                                     "GOANNA_SHADERPACK_OPTIONS": "SSAO_ENABLED=false,SOFT_SHADOWS=false"}})
    job = {"label": "Eclipse lighting input isolation", "build": str(args.build.resolve()),
           "out": str(out / "frames"), "size": [1280, 720], "tier": "high",
           "nodes": NODES, "poses": [POSE], "variants": variants, "warm": 30,
           "lua": [LIGHT_PROBE],
           "profile": {"view_range": 8, "far_distance": 0, "lod_distance": 128}}
    (out / "job.json").write_text(json.dumps(job, indent=2) + "\n")
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    minecraft_fixture(out)
    print(out / "job.json")


if __name__ == "__main__":
    main()
