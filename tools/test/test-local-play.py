#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Check local sessions with Godot's dummy renderer and a scratch server."""
import argparse
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time


def main():
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN") or
                        shutil.which("godot") or str(repo.parent / "Godot_v4.5.1-stable_linux.x86_64"))
    parser.add_argument("--server", default=shutil.which("luantiserver") or
                        shutil.which("luanti") or
                        "/var/lib/flatpak/app/org.luanti.luanti/current/active/files/bin/luanti.bin")
    parser.add_argument("--players", type=int, default=4)
    args = parser.parse_args()
    if args.players < 2 or args.players > 16:
        parser.error("--players must be between 2 and 16 for this test server")
    scratch = Path(tempfile.mkdtemp(prefix="goanna-local-play-"))
    print(f"Local play test files: {scratch}", flush=True)
    games = scratch / "games"
    games.mkdir()
    (games / "devtest").symlink_to(repo / "luanti/games/devtest", target_is_directory=True)
    world = scratch / "world"
    fixture = world / "worldmods/localplay_fixture"
    fixture.mkdir(parents=True)
    (world / "world.mt").write_text("gameid = devtest\nbackend = sqlite3\nplayer_backend = sqlite3\nauth_backend = sqlite3\n")
    (fixture / "mod.conf").write_text("name = localplay_fixture\ndepends = basenodes\n")
    (fixture / "init.lua").write_text('''core.register_on_joinplayer(function(player)
    local name = player:get_player_name()
    local index = tonumber(name:match("_(%d+)$")) or 1
    core.after(0.5, function()
        local p = core.get_player_by_name(name)
        if not p then return end
        p:set_pos({x=index*4, y=4, z=0})
        p:set_physics_override({gravity=0})
        local inv = p:get_inventory()
        inv:set_size("main", 32)
        inv:set_list("main", {})
        inv:set_stack("main", 1, "basenodes:stone " .. index)
    end)
end)
''')
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    conf = scratch / "server.conf"
    conf.write_text("bind_address = 127.0.0.1\nserver_announce = false\n"
                    "max_users = 16\nmg_name = singlenode\nenable_damage = false\n"
                    "max_block_send_distance = 2\ntime_speed = 0\n")
    env = dict(os.environ, LUANTI_USER_PATH=str(scratch),
               XDG_CONFIG_HOME=str(scratch / "config"), XDG_DATA_HOME=str(scratch / "data"))
    # Do not inherit a developer's active server, automation or render options.
    env = {k: v for k, v in env.items() if not k.startswith("GOANNA_")}
    env.update(GOANNA_TEST_PORT=str(port), GOANNA_TEST_PLAYERS=str(args.players), GOANNA_NO_POINTER_CAPTURE="1",
               GOANNA_NO_STORE="1", GOANNA_VIEW_RANGE="2", GOANNA_FAR_DISTANCE="0")
    with (scratch / "server.log").open("w") as server_log:
        server = subprocess.Popen([args.server, "--server", "--world", str(world),
                                   "--gameid", "devtest", "--config", str(conf),
                                   "--port", str(port), "--logfile", str(scratch / "debug.log")],
                                  env=env, stdout=server_log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if server.poll() is not None:
                    raise RuntimeError((scratch / "server.log").read_text())
                if "listening on" in (scratch / "server.log").read_text():
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError("Server did not become ready")
            with (scratch / "client.log").open("w") as client_log:
                result = subprocess.run([args.godot, "--headless", "--path", str(repo / "project"),
                                         "--script", "res://tests/local_play_server.gd"], env=env,
                                        stdout=client_log, stderr=subprocess.STDOUT, timeout=100)
            log = (scratch / "client.log").read_text()
            if result.returncode or "SCRIPT ERROR" in log or "ERROR:" in log:
                print(log)
                return 1
            print(f"{args.players} connections, independent inventories and player removal passed. No GPU used.")
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
