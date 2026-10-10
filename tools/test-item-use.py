#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Test DorfCraft tool clicks on Mineclonia using a CPU-only scratch client."""
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
    parser.add_argument("--dorfcraft", type=Path, required=True)
    parser.add_argument("--godot", default=str(repo.parent / "Godot_v4.5.1-stable_linux.x86_64"))
    args = parser.parse_args()
    scratch = Path(tempfile.mkdtemp(prefix="goanna-item-use-"))
    print(f"Logs and disposable world: {scratch}", flush=True)
    world = scratch / "world"
    mods = world / "worldmods"
    mods.mkdir(parents=True)
    names = ["labour", "overseer", "rooms", "dorfcraft_runes"]
    for name in names:
        (mods / name).symlink_to(args.dorfcraft.resolve() / "mods" / name)
    probe = mods / "item_probe"
    probe.mkdir()
    (probe / "mod.conf").write_text("name = item_probe\ndepends = overseer, rooms, dorfcraft_runes\n")
    shutil.copyfile(repo / "tools/item-use-fixture.lua", probe / "init.lua")
    (world / "world.mt").write_text(
        "gameid = mineclonia\nbackend = sqlite3\nplayer_backend = sqlite3\n"
        "auth_backend = sqlite3\nmod_storage_backend = sqlite3\n" +
        "".join(f"load_mod_{name} = true\n" for name in names + ["item_probe"]))
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    conf = scratch / "server.conf"
    conf.write_text(f"port = {port}\nbind_address = 127.0.0.1\n" +
                    "server_announce = false\nmg_name = singlenode\n"
                    "mcl_singlenode_mapgen = false\nmcl_enable_lua_mapgen = false\n"
                    "mobs_spawn = false\nenable_damage = false\ntime_speed = 0\n"
                    "enable_mod_channels = true\nmax_block_send_distance = 3\n")
    env = {k: v for k, v in os.environ.items() if not k.startswith("GOANNA_")}
    env.update(XDG_DATA_HOME=str(scratch / "client-data"), GOANNA_TEST_PORT=str(port))
    with (scratch / "server.log").open("w") as log:
        server = subprocess.Popen([
            "flatpak", "run", "--die-with-parent", f"--filesystem={scratch}",
            f"--filesystem={args.dorfcraft.resolve()}", "org.luanti.luanti",
            "--server", "--world", str(world), "--config", str(conf),
            "--logfile", str(scratch / "debug.log")], stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 30
            while "listening on" not in (scratch / "server.log").read_text():
                if server.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError((scratch / "server.log").read_text())
                time.sleep(0.1)
            with (scratch / "client.log").open("w") as client_log:
                result = subprocess.run([
                    args.godot, "--headless", "--path", str(repo / "project"),
                    "--script", "res://tests/item_use.gd"], env=env,
                    stdout=client_log, stderr=subprocess.STDOUT, timeout=190)
            output = (scratch / "client.log").read_text()
            print("\n".join(line for line in output.splitlines()
                            if line.startswith(("PASS", "FAIL", "Item use:"))))
            failed = result.returncode or "SCRIPT ERROR" in output or "ERROR:" in output
            if failed:
                print(output)
            return 1 if failed else 0
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
