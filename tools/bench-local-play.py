#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Measure local players in one rendered process using a disposable world copy."""
import argparse
import importlib.util
import json
import math
import os
import re
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import time

import goanna_headless as headless

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("benchmark", REPO / "tools/goanna-bench.py")
FEATURE_KEYS = re.findall(r'"(render_[a-z_]+)": true',
                         (REPO / "project/render_features.gd").read_text())
SCENES = json.loads((REPO / "tools/local-feature-scenes.json").read_text())["scenes"]
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


def snapshot_world(source, target):
    """Use SQLite backup so a live source database is copied consistently."""
    target.mkdir(parents=True)
    for path in source.iterdir():
        dest = target / path.name
        if path.suffix == ".sqlite":
            with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as src:
                with sqlite3.connect(dest) as dst:
                    src.backup(dst)
        elif path.name.endswith(("-wal", "-shm")):
            continue
        elif path.is_dir():
            shutil.copytree(path, dest)
        else:
            shutil.copy2(path, dest)


def free_udp_port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def run_code(control, source):
    source = "\n".join("\t" * ((len(line) - len(line.lstrip(" "))) // 4) + line.lstrip(" ")
                       for line in source.splitlines())
    return control.send("run", {"src": source})["value"]


def hardware_sample(pid):
    result = {"time": time.time()}
    try:
        status = Path(f"/proc/{pid}/status").read_text()
        for line in status.splitlines():
            if line.startswith(("VmRSS:", "VmHWM:")):
                key, value, _ = line.split()
                result[key.rstrip(":") + "_kib"] = int(value)
        smi = subprocess.run(["nvidia-smi", "--query-gpu=memory.used,utilization.gpu,temperature.gpu",
                              "--format=csv,noheader,nounits"], capture_output=True,
                             text=True, timeout=5)
        result["gpu"] = smi.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return result


def settle(control, timeout, quiet_seconds=10):
    deadline = time.monotonic() + timeout
    stable_since = None
    previous = None
    keys = ("blocks_queued", "near_ready", "mesh_queued", "mesh_running", "mesh_ready", "lod_regions_dirty",
            "near_regions_dirty", "near_regions_building",
            "lod_chain_queue", "lod_building", "surface_inflight", "surface_building",
            "surface_uploads", "lod_storage_pending", "lod_storage_queued",
            "lod_storage_active", "lod_storage_ready", "lod_storage_retry_regions")
    while time.monotonic() < deadline:
        players = run_code(control, "return main.bench.snapshot()")
        signature = [(p["render"].get("block_meshes"), p["render"].get("blocks_queued"))
                     for p in players]
        ready = all(p["status"].get("state") == "ready" and
                    p["render"].get("block_meshes", 0) > 0 and
                    all(p["render"].get(k, 0) == 0 for k in keys) for p in players)
        if ready and signature == previous:
            stable_since = stable_since or time.monotonic()
            if time.monotonic() - stable_since >= quiet_seconds:
                return {"settled": True, "players": players}
        else:
            stable_since = None
        previous = signature
        time.sleep(1)
    return {"settled": False, "players": players}


def validate_scene(scene, players, evidence):
    """Reject inactive test cases rather than pricing an absent effect."""
    if any(p["status"].get("state") != "ready" for p in players):
        raise RuntimeError("A player is not connected and ready")
    if scene != "wet" and any(e["precipitation"] > 0 for e in evidence):
        raise RuntimeError("Dry fixture received unexpected precipitation")
    if scene == "underwater" and not all(p["underwater"] for p in players):
        raise RuntimeError("Underwater fixture did not submerge every camera")
    if scene == "wet" and not all(abs(p["wetness"] - 0.8) < 0.001 for p in players):
        raise RuntimeError("Wet fixture did not hold wetness")
    if scene == "wet" and not all(e["weather"].get("drops_visible") and
                                 e["weather"].get("rain", 0) > 0.5 for e in evidence):
        raise RuntimeError("Wet fixture is not raining visibly")
    if scene == "night":
        for p, e in zip(players, evidence):
            if p["features"]["requested"]["render_dynamic_lights"] and p["render"].get("lights_in_range", 0) == 0:
                raise RuntimeError("Night fixture has no node lights in range")
            if p["features"]["requested"]["render_carried_light"] and e["carried_light_energy"] <= 0:
                raise RuntimeError("Night fixture needs a carried torch")
    if scene == "grass" and not all(e["grass_material"] or
            p["settings"]["procedural_grass"] == 0 for p, e in zip(players, evidence)):
        raise RuntimeError("Grass fixture has no procedural grass material")
    if scene == "ice" and not all(p["features"]["ice_capture"] or not
            p["features"]["requested"]["render_ice_transmission"] for p in players):
        raise RuntimeError("Ice fixture has no active background capture")
    if scene == "dusk" and any(p["features"]["requested"]["render_shafts"] for p in players):
        if not any(p["features"]["active"]["render_shafts"] and e["sun_in_view"]
                   for p, e in zip(players, evidence)):
            raise RuntimeError("Dusk fixture has inactive shaft strength")


def check_worker_reset(control, out, timeout):
    """Cancel an observed regional job and require its replacement to drain."""
    before = run_code(control, """var game = main.bench.games[0]
var terrain_client = game.client
var grass = terrain_client.procedural_grass()
terrain_client.set_procedural_grass(not grass)
terrain_client.set_procedural_grass(grass)
for frame in 300:
    await main.get_tree().process_frame
    var stats = terrain_client.render_stats()
    if stats.get("near_regions_building", 0) > 0:
        var workers = int(stats["mesh_threads"])
        terrain_client.set_mesh_threads(workers - 1 if workers >= 16 else workers + 1)
        return stats
return {}""")
    if not before:
        raise RuntimeError("Worker-reset check did not observe an in-flight region")
    after = settle(control, timeout)
    run_code(control, "main.bench.games[0].client.set_mesh_threads(%d)\nreturn true"
             % before["mesh_threads"])
    restored = settle(control, timeout)
    (out / "worker-reset.json").write_text(json.dumps(
        {"before": before, "after": after, "restored": restored}, indent=2))
    if not after["settled"] or not restored["settled"]:
        raise RuntimeError("Worker reset stranded terrain work")


def check_wall(control, out, timeout):
    """Exercise server edits after timing; retain each view and its own state."""
    evidence = []
    for index, (wall, occlusion) in enumerate([
            ("close", False), ("close", True), ("open", True),
            ("close", True), ("close", False)]):
        run_code(control, 'main.client.send_chat("/perf_wall %s")\n'
                 'for game in main.bench.games:\n'
                 '    game.ui._apply_setting("lamp_occlusion", %d)\nreturn true'
                 % (wall, int(occlusion)))
        expected = "air" if wall == "open" else "mcl_core:stonebrick"
        deadline = time.monotonic() + timeout
        while True:
            nodes = run_code(control, 'return main.bench.games.map(func(g): '
                             'return g.client.node_name_at(Vector3(-72, 62, 378)))')
            if all(node == expected for node in nodes):
                break
            if time.monotonic() > deadline:
                raise RuntimeError("A connection did not receive the wall edit")
            time.sleep(0.25)
        state = settle(control, timeout)
        if not state["settled"]:
            raise RuntimeError("Wall edit did not finish terrain publication")
        time.sleep(0.2)
        label = "wall-%d-%s-%s" % (index, wall, "on" if occlusion else "off")
        run_code(control, 'await main.get_tree().process_frame\n'
                 'main.get_tree().root.get_texture().get_image().save_png(%s)\nreturn true'
                 % json.dumps(str(out / (label + ".png"))))
        resources = run_code(control, """var views = []
for game in main.bench.games:
    var meshes = []
    for node in game.client.find_children("*", "MeshInstance3D", true, false):
        var mesh = node.mesh
        if mesh != null and mesh.has_meta("goanna_shared_terrain"):
            var materials = []
            for i in mesh.get_surface_count():
                var material = node.get_surface_override_material(i)
                materials.append(material.get_instance_id() if material else 0)
            meshes.append({"mesh": mesh.get_instance_id(), "materials": materials})
    views.append({"enabled": game.client.lamp_occlusion(), "meshes": meshes})
return views""")
        evidence.append({"label": label, "nodes": nodes, "state": state,
                         "resources": resources})
        (out / "wall-validation.json").write_text(json.dumps(evidence, indent=2))


def trial(args, count, out, baseline):
    out.mkdir()
    world = out / "world"
    subprocess.run(["cp", "-a", "--reflink=auto", str(baseline), str(world)], check=True)
    fixture = world / "worldmods/local_benchmark"
    fixture.mkdir()
    (fixture / "mod.conf").write_text("name = local_benchmark\noptional_depends = mcl_weather\n")
    shutil.copy2(REPO / "tools/local-feature-fixture.lua", fixture / "init.lua")
    port = free_udp_port()
    config = out / "server.conf"
    config.write_text("bind_address = 127.0.0.1\nserver_announce = false\n"
                      "max_users = 16\nenable_damage = false\ntime_speed = 0\nmobs_spawn = false\n"
                      "mcl_doWeatherCycle = false\nweather_allow_abm = false\n"
                      f"goanna_benchmark_scene = {args.scene}\n"
                      "max_block_send_distance = 12\n"
                      "max_simultaneous_block_sends_per_client = 40\n")
    env = {k: v for k, v in os.environ.items() if not k.startswith("GOANNA_")}
    env["LUANTI_USER_PATH"] = str(out)
    games = out / "games"
    games.mkdir()
    (games / args.game.name).symlink_to(args.game, target_is_directory=True)
    control = None
    instance = None
    dummy = None
    with (out / "server.log").open("w") as log:
        server = subprocess.Popen([str(args.server), "--server", "--world", str(world),
                                   "--gameid", args.game.name, "--config", str(config),
                                   "--port", str(port), "--logfile", str(out / "debug.log")],
                                  env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 90
            while "listening on" not in (out / "server.log").read_text():
                if server.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Server failed to start; see " + str(out / "server.log"))
                time.sleep(0.5)
            child_env = {"GOANNA_LOCAL_PLAY": str(count), "GOANNA_NO_STORE": "1",
                         "DISABLE_GAMESCOPE_WSI": "1",
                         "XDG_DATA_HOME": str(out / "data"), "XDG_CONFIG_HOME": str(out / "config")}
            if args.no_shared_terrain:
                child_env["GOANNA_NO_SHARED_TERRAIN"] = "1"
            profile = out / "data/godot/app_userdata/Goanna/goanna.cfg"
            profile.parent.mkdir(parents=True)
            profile.write_text("[settings]\nasset_updates=false\n")
            if args.dummy:
                control_port = headless.free_control_port()
                child_env.update(GOANNA_CONTROL=str(control_port), GOANNA_HOST="127.0.0.1",
                                 GOANNA_PORT=str(port), GOANNA_NAME="localbench",
                                 GOANNA_NO_POINTER_CAPTURE="1")
                with (out / "client.log").open("w") as client_log:
                    dummy = subprocess.Popen([headless.find_godot(args.project),
                        "--headless", "--path", str(args.project),
                        "--resolution", f"{args.width}x{args.height}"],
                        env=dict(env, **child_env), stdout=client_log, stderr=subprocess.STDOUT)
                instance = {"control_port": control_port, "child_pid": dummy.pid, "dummy": True}
                deadline = time.monotonic() + 120
                while not headless.control_ping(control_port):
                    if dummy.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError("Dummy client failed; see client.log")
                    time.sleep(0.5)
            else:
                instance = headless.start_goanna(args.project, port=port,
                    name="localbench", width=args.width, height=args.height,
                    env=child_env, software=args.software, label=f"local benchmark: {count} players")
            (out / "instance.json").write_text(json.dumps(instance, indent=2))
            control = benchmark.Control("127.0.0.1", instance["control_port"], timeout=120)
            if args.dummy:
                run_code(control, f"main.get_tree().root.size = Vector2i({args.width}, {args.height})\nreturn true")
            run_code(control, 'var profile_name = ' + json.dumps(args.profile) + '\n' + '''var games = [main]
if main.player_slot != null:
    games = main.player_slot.shell.slots.map(func(s): return s.game)
for game in games:
    game.ui._apply_setting("procedural_grass", 0.0)
    var profile = load("res://graphics_profiles.gd").PROFILES[profile_name]
    for key in profile:
        game.ui._apply_setting(key, profile[key])
var recorder = load("res://local_bench.gd").new()
recorder.main = main
recorder.games = games
main.bench = recorder
main.get_tree().current_scene.add_child(recorder)
return games.size()''')
            # Wait until spawn placement has completed before fixing cameras.
            deadline = time.monotonic() + 120
            while not run_code(control, "return main.bench.games.all(func(g): return g.placed)"):
                if server.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Players did not become ready; see server.log")
                time.sleep(1)
            if SCENES[args.scene].get("fixture"):
                deadline = time.monotonic() + 120
                while "GOANNA_FIXTURE_READY " + args.scene not in (out / "server.log").read_text():
                    if server.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError("Fixture failed; see server.log")
                    time.sleep(0.5)
            scene = dict(SCENES[args.scene])
            settings = dict(scene.get("settings", {}), **args.settings)
            scene["settings"] = settings
            scene["travel_speed"] = args.travel_speed
            scene["travel_layout"] = args.travel_layout
            scene["spread_radius"] = args.spread_radius
            for key in ("poll_budget_ms", "mesh_workers"):
                if getattr(args, key) is not None:
                    scene[key] = getattr(args, key)
            if args.msaa is not None:
                scene["msaa"] = args.msaa
            if args.screen_aa is not None:
                scene["screen_aa"] = args.screen_aa
            known = run_code(control, "return main.ui.SETTINGS.map(func(s): return s[1])")
            if any(key not in known for key in settings):
                raise RuntimeError("Unknown scene setting: " + str(set(settings) - set(known)))
            run_code(control, "main.bench.configure_scene(%s, %s)\nreturn true" %
                     (json.dumps(scene), json.dumps(settings)))
            sweep_keys = sorted({key for values in (args.setting_sweep or {}).values() for key in values})
            if any(key not in known for key in sweep_keys):
                raise RuntimeError("Unknown sweep setting")
            sweep_baseline = run_code(control, "var keys = %s\nvar values = []\nfor game in main.bench.games:\n    var row = {}\n    for key in keys:\n        row[key] = game.ui._setting_value(key, -1.0)\n    values.append(row)\nreturn values" % json.dumps(sweep_keys))
            results = {}
            for phase in args.phases:
                if phase != "streaming":
                    prepared = run_code(control, "return await main.bench.prepare(%s)" %
                                        ("true" if phase == "apart" else "false"))
                    if not prepared:
                        raise RuntimeError("Server did not confirm a player's benchmark position")
                    if args.travel_layout == "grouped":
                        run_code(control, "for i in main.bench.directions.size():\n    main.bench.directions[i] = Vector3(0, 0, 1)\nreturn true")
                    state = settle(control, args.settle_timeout)
                    (out / f"{phase}-settle.json").write_text(json.dumps(state, indent=2))
                    print(f"{count} players {phase}: settled={state['settled']}", flush=True)
                    if not args.dummy and any(p["render"].get("block_meshes", 0) == 0
                                              for p in state["players"]):
                        raise RuntimeError("A player has no terrain meshes; refusing an empty-scene benchmark")
                    # Preserve timeout results, but never label them settled.
                else:
                    time.sleep(args.warmup)
                    # The recorder starts movement atomically with recording.
                variants = [(phase, [], {})]
                if args.feature_sweep:
                    variants = [(phase + "-control-before", [], {})]
                    variants += [(phase + "-without-" + key, [key], {}) for key in args.feature_sweep]
                    variants += [(phase + "-control-after", [], {})]
                if args.setting_sweep:
                    variants = [(phase + "-control-before", [], {})]
                    variants += [(phase + "-" + name, [], values)
                                 for name, values in args.setting_sweep.items()]
                    variants += [(phase + "-control-after", [], {})]
                for label, disabled, overrides in variants:
                    if args.setting_sweep:
                        rows = [dict(row, **overrides) for row in sweep_baseline]
                        run_code(control, "var rows = %s\nfor i in main.bench.games.size():\n    for key in rows[i]:\n        main.bench.games[i].ui._apply_setting(key, rows[i][key])\nreturn true" % json.dumps(rows))
                    if args.feature_sweep:
                        if not run_code(control, "return main.bench.set_feature_variant(%s)" %
                                        json.dumps(disabled)):
                            raise RuntimeError("Unknown feature variant")
                    if phase != "streaming":
                        time.sleep(args.warmup)
                    evidence = run_code(control, "return main.bench.scene_evidence()")
                    before = run_code(control, "return main.bench.snapshot()")
                    (out / (label + "-preflight.json")).write_text(json.dumps(
                        {"players": before, "evidence": evidence}, indent=2))
                    if not args.dummy:
                        validate_scene(args.scene, before, evidence)
                    control.send("bench", {"action": "start", "label": label,
                                           "phase": "steady" if phase != "streaming" else "move_full"})
                    samples = []
                    until = time.monotonic() + args.seconds
                    while time.monotonic() < until:
                        samples.append(hardware_sample(instance["child_pid"]))
                        time.sleep(1)
                    result = control.send("bench", {"action": "stop", "dir": str(out / label)})
                    result["dummy_renderer"] = args.dummy
                    result["software_renderer"] = args.software
                    result["settled_before_recording"] = state["settled"]
                    result["profile"] = args.profile
                    result["scene"] = args.scene
                    result["scene_controls"] = scene
                    result["disabled_features"] = disabled
                    result["setting_overrides"] = overrides
                    result["state_before"] = before
                    result["scene_evidence"] = evidence
                    results[label] = result
                    (out / label / "hardware.json").write_text(json.dumps(samples, indent=2))
                    (out / label / "state-before.json").write_text(json.dumps(before, indent=2))
                    # Capture the whole composition, not player 1's viewport.
                    if not args.dummy:
                        run_code(control, "await main.get_tree().process_frame\n"
                                 "main.get_tree().root.get_texture().get_image().save_png(%s)\nreturn true" %
                                 json.dumps(str(out / label / "screen.png")))
                    print(json.dumps({"players": count, "phase": label,
                                      "software_renderer": args.software, "stats": result["phases"]}), flush=True)
                    (out / "results.json").write_text(json.dumps(results, indent=2))
                if phase == "streaming" and args.check_stream_drain:
                    # Keep the endpoint pose while testing that deferred work
                    # reaches the screen. Recording has already stopped, so
                    # this wait cannot improve the measured streaming FPS.
                    run_code(control, "main.bench.moving = false\nreturn true")
                    drain_start = time.monotonic()
                    drained = settle(control, args.settle_timeout)
                    drained["seconds_including_quiet_window"] = time.monotonic() - drain_start
                    (out / "streaming-drain.json").write_text(json.dumps(drained, indent=2))
                    print(f"{count} players streaming: drained={drained['settled']}", flush=True)
                    if not drained["settled"]:
                        raise RuntimeError("Streaming work did not drain; see streaming-drain.json")
                    if not args.dummy:
                        run_code(control, "await main.get_tree().process_frame\n"
                                 "main.get_tree().root.get_texture().get_image().save_png(%s)\nreturn true" %
                                 json.dumps(str(out / "streaming-drained.png")))
            if args.check_worker_reset:
                check_worker_reset(control, out, args.settle_timeout)
            if args.wall_check:
                check_wall(control, out, args.settle_timeout)
            return results
        finally:
            try:
                if control is not None:
                    control.close()
                if dummy is not None:
                    if dummy.poll() is None:
                        dummy.terminate()
                        try:
                            dummy.wait(timeout=15)
                        except subprocess.TimeoutExpired:
                            dummy.kill()
                            dummy.wait()
                elif instance is not None:
                    headless.stop(instance["id"])
                    shutil.copy2(instance["client_log"], out / "client.log")
                    log_text = (out / "client.log").read_text(errors="replace")
                    failures = ("SCRIPT ERROR:", "SHADER ERROR:", "ERROR:",
                                "handle_crash:", "Program crashed")
                    if any(marker in log_text for marker in failures):
                        raise RuntimeError("Client reported an error, including during shutdown; see client.log")
            finally:
                if server.poll() is None:
                    server.terminate()
                    try:
                        server.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=REPO / "project",
                        help="Frozen or current client project to render")
    parser.add_argument("--wall-check", action="store_true",
                        help="Validate closed/open/restored wall edits after occlusion recordings")
    parser.add_argument("--check-worker-reset", action="store_true",
                        help="Interrupt a regional mesh job and require the terrain queues to drain")
    parser.add_argument("--no-shared-terrain", action="store_true",
                        help="Disable process terrain caches for an implementation control")
    parser.add_argument("--travel-layout", choices=["radial", "grouped"], default="radial",
                        help="Grouped players move in the same direction; use --spread-radius 8")
    parser.add_argument("--world", required=True, type=Path)
    parser.add_argument("--game", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--server", type=Path, default=Path(
        "/var/lib/flatpak/app/org.luanti.luanti/current/active/files/bin/luanti.bin"))
    parser.add_argument("--players", nargs="+", type=int, default=[1, 2, 4, 6, 1])
    parser.add_argument("--seconds", type=float, default=45)
    parser.add_argument("--settle-timeout", type=float, default=180)
    parser.add_argument("--check-stream-drain", action="store_true",
                        help="Stop at the route endpoint and require terrain queues to settle")
    parser.add_argument("--width", type=int, default=1920)
    parser.add_argument("--height", type=int, default=1080)
    parser.add_argument("--software", action="store_true",
                        help="Render on the CPU for visual checks; not a GPU benchmark")
    parser.add_argument("--dummy", action="store_true",
                        help="Validate orchestration without rendering; not a GPU benchmark")
    parser.add_argument("--profile", choices=["lowest", "low", "medium", "high", "ultra"], default="low")
    parser.add_argument("--phases", nargs="+", choices=["together", "apart", "streaming"],
                        default=["together", "apart", "streaming"])
    parser.add_argument("--feature-sweep", nargs="+", choices=FEATURE_KEYS,
                        help="Disable one feature at a time, bracketed by restored controls")
    parser.add_argument("--poll-budget-ms", type=float, help="Total main-thread poll budget, divided across players")
    parser.add_argument("--mesh-workers", type=int, help="Total mesh workers, divided across players (at least one each)")
    parser.add_argument("--travel-speed", type=float, default=8)
    parser.add_argument("--spread-radius", type=float, default=192)
    parser.add_argument("--scene", choices=SCENES, default="circle")
    parser.add_argument("--settings", type=json.loads, default={},
                        help='Numeric setting overrides, e.g. {"shadow_lamps":0}')
    parser.add_argument("--setting-sweep", type=json.loads,
                        help='Named numeric overrides, restored between cases: {"sparse":{"grass_density":0.3}}')
    parser.add_argument("--msaa", type=int, choices=range(4), help="Fixed viewport MSAA enum")
    parser.add_argument("--screen-aa", type=int, choices=[0, 1], help="Fixed FXAA enum")
    parser.add_argument("--warmup", type=float, default=5,
                        help="Seconds to warm up after each live feature change")
    args = parser.parse_args()
    if args.wall_check and (args.scene != "occlusion" or args.dummy):
        parser.error("wall checks require the rendered occlusion scene")
    if args.setting_sweep is not None:
        if not isinstance(args.setting_sweep, dict) or not args.setting_sweep or any(
                not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", name) or
                name in ("control-before", "control-after") or not isinstance(values, dict) or
                any(not isinstance(value, (int, float)) or not math.isfinite(value) for value in values.values())
                for name, values in args.setting_sweep.items()):
            parser.error("setting sweep must map safe case names to numeric settings")
        if args.feature_sweep or "streaming" in args.phases:
            parser.error("setting sweeps require stationary phases without a feature sweep")
    if not isinstance(args.settings, dict) or any(
            not isinstance(v, (int, float)) for v in args.settings.values()):
        parser.error("settings must be an object of numeric values")
    if args.scene != "circle" and args.phases != ["together"]:
        parser.error("feature scenes require --phases together; circle supports travel")
    if args.feature_sweep and "render_grass_aa" in args.feature_sweep and (
            "msaa" in SCENES[args.scene] or args.msaa is not None or args.screen_aa is not None):
        parser.error("fixed AA overrides render_grass_aa; compare fresh --msaa/--screen-aa trials")
    if (args.poll_budget_ms is not None and args.poll_budget_ms <= 0) or (
            args.mesh_workers is not None and not 1 <= args.mesh_workers <= 64):
        parser.error("poll budget must be positive; mesh workers must be between 1 and 64")
    if args.travel_speed <= 0 or args.spread_radius <= 0:
        parser.error("travel speed and spread radius must be positive")
    if args.seconds <= 0 or args.warmup < 0:
        parser.error("seconds must be positive and warmup non-negative")
    if args.feature_sweep and "streaming" in args.phases:
        parser.error("feature sweeps need stationary phases; streaming needs fresh trials")
    if "streaming" in args.phases and ("apart" not in args.phases or
            args.phases.index("apart") + 1 != args.phases.index("streaming")):
        parser.error("streaming must follow apart to establish its route")
    for attr in ("world", "game", "output", "server", "project"):
        setattr(args, attr, getattr(args, attr).resolve())
    if any(p < 1 or p > 16 for p in args.players):
        parser.error("players must be between 1 and 16")
    if not args.dummy and not args.software and (headless.gpu_clients() or headless.driver_errors()):
        parser.error("GPU is occupied or the driver has recent errors")
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "plan.json").write_text(json.dumps(vars(args), default=str, indent=2))
    baseline = args.output / "baseline"
    snapshot_world(args.world, baseline)
    results = []
    for index, count in enumerate(args.players):
        results.append({"players": count, "runs": trial(args, count,
                       args.output / f"{index:02d}-{count}p", baseline)})
        (args.output / "results.json").write_text(json.dumps(results, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
