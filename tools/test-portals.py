#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Check portal routing against a disposable Mineclonia server, without a GPU."""
import argparse
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time


def main():
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, required=True, help="Mineclonia game directory")
    parser.add_argument("--server", required=True, help="Luanti server executable")
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN") or
                        shutil.which("godot") or str(repo.parent / "Godot_v4.5.1-stable_linux.x86_64"))
    parser.add_argument("--pack", type=Path, help="Optional Goanna texture pack directory")
    args = parser.parse_args()
    if not (args.game / "game.conf").is_file():
        parser.error("--game must contain game.conf")
    scratch = Path(tempfile.mkdtemp(prefix="goanna-portals-"))
    print(f"Portal test files: {scratch}", flush=True)
    games = scratch / "games"
    games.mkdir()
    (games / "mineclonia").symlink_to(args.game.resolve(), target_is_directory=True)
    world = scratch / "world"
    fixture = world / "worldmods/portal_fixture"
    fixture.mkdir(parents=True)
    (fixture / "mod.conf").write_text("name = portal_fixture\ndepends = mcl_portals\n")
    shutil.copyfile(repo / "tools/portal-fixture.lua", fixture / "init.lua")
    (world / "world.mt").write_text("gameid = mineclonia\nbackend = sqlite3\n"
                                   "player_backend = sqlite3\nauth_backend = sqlite3\n"
                                   "mod_storage_backend = sqlite3\nload_mod_portal_fixture = true\n")
    conf = scratch / "server.conf"
    conf.write_text("bind_address = 127.0.0.1\nserver_announce = false\n"
                    "mg_name = singlenode\nenable_damage = false\ntime_speed = 0\n"
                    "max_block_send_distance = 3\nstatic_spawnpoint = (0,3,-7)\n")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    env = {k: v for k, v in os.environ.items() if not k.startswith("GOANNA_")}
    env.update(LUANTI_USER_PATH=str(scratch), LUANTI_GAME_PATH=str(games),
               XDG_DATA_HOME=str(scratch / "data"), XDG_CONFIG_HOME=str(scratch / "config"),
               GOANNA_TEST_PORT=str(port), GOANNA_NO_STORE="1", GOANNA_NO_POINTER_CAPTURE="1")
    if args.pack:
        env["GOANNA_PORTAL_PACK"] = str(args.pack.resolve())
    help_text = subprocess.run([args.server, "--help"], capture_output=True, text=True, check=True).stdout
    server_mode = ["--server"] if "--server" in help_text else []
    with (scratch / "server.log").open("w") as server_log:
        server = subprocess.Popen([args.server, *server_mode, "--gameid", "mineclonia",
                                   "--world", str(world), "--config", str(conf), "--port", str(port),
                                   "--logfile", str(scratch / "debug.log")], env=env,
                                  stdout=server_log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 120
            while "listening on" not in (scratch / "server.log").read_text():
                if server.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError((scratch / "server.log").read_text())
                time.sleep(0.1)
            with (scratch / "client.log").open("w") as client_log:
                result = subprocess.run([args.godot, "--headless", "--path", str(repo / "project"),
                                         "--script", "res://tests/portal_materials.gd"], env=env,
                                        stdout=client_log, stderr=subprocess.STDOUT, timeout=160)
            log = (scratch / "client.log").read_text()
            if result.returncode or "SCRIPT ERROR" in log or "ERROR:" in log:
                print(log)
                return 1
            print("Portal routing, texture animation and player-scoped shaders passed. No GPU used.")
            return 0
        finally:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


if __name__ == "__main__":
    raise SystemExit(main())
