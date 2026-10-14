#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Check cold, warm and damaged media caches against a disposable server."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import zlib


def main():
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", required=True)
    parser.add_argument("--godot", required=True)
    args = parser.parse_args()
    scratch = Path(tempfile.mkdtemp(prefix="goanna-media-cache-"))
    print(f"Media cache test files: {scratch}", flush=True)
    games = scratch / "games"
    games.mkdir()
    (games / "devtest").symlink_to(repo / "luanti/games/devtest", target_is_directory=True)
    world = scratch / "world"
    world.mkdir()
    (world / "world.mt").write_text("gameid = devtest\nbackend = sqlite3\n"
                                   "player_backend = sqlite3\nauth_backend = sqlite3\n"
                                   "mod_storage_backend = sqlite3\n")
    fixture = world / "worldmods/media_cache_fixture"
    (fixture / "textures").mkdir(parents=True)
    (fixture / "mod.conf").write_text("name = media_cache_fixture\n")
    (fixture / "init.lua").write_text("-- Media cache fixture, no game behaviour.\n")
    texture = fixture / "textures/goanna_media_cache_probe.png"

    def write_texture(red):
        def chunk(kind, data):
            return (struct.pack(">I", len(data)) + kind + data +
                    struct.pack(">I", zlib.crc32(kind + data)))
        texture.write_bytes(b"\x89PNG\r\n\x1a\n" +
                            chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) +
                            chunk(b"IDAT", zlib.compress(bytes([0, red, 17, 31]))) +
                            chunk(b"IEND", b""))

    write_texture(19)
    conf = scratch / "server.conf"
    conf.write_text("bind_address = 127.0.0.1\nserver_announce = false\n"
                    "mg_name = singlenode\nmax_block_send_distance = 1\n"
                    "static_spawnpoint = (0,10,0)\n")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    env = {k: v for k, v in os.environ.items() if not k.startswith("GOANNA_")}
    env.update(LUANTI_USER_PATH=str(scratch), LUANTI_GAME_PATH=str(games),
               XDG_DATA_HOME=str(scratch / "data"), XDG_CONFIG_HOME=str(scratch / "config"),
               GOANNA_TEST_PORT=str(port), GOANNA_NO_STORE="1")
    help_text = subprocess.run([args.server, "--help"], capture_output=True,
                               text=True, check=True).stdout
    server_mode = ["--server"] if "--server" in help_text else []
    server_log_path = scratch / "server.log"

    def join(label, warm=False, cold=False):
        result_path = scratch / f"{label}.json"
        env["GOANNA_TEST_RESULT"] = str(result_path)
        offset = server_log_path.stat().st_size
        with (scratch / f"{label}.log").open("w") as log:
            result = subprocess.run([args.godot, "--headless", "--path", str(repo / "project"),
                                     "--script", "res://tests/media_cache.gd"], env=env,
                                    stdout=log, stderr=subprocess.STDOUT, timeout=120)
        if result.returncode or not result_path.exists():
            raise RuntimeError((scratch / f"{label}.log").read_text())
        assert "SCRIPT ERROR" not in (scratch / f"{label}.log").read_text()
        status = json.loads(result_path.read_text())
        total, cached, downloaded = (status[key] for key in
                                    ("media_announced", "media_cached", "media_downloaded"))
        assert total > 0 and cached + downloaded == total, status
        assert status["media_received"] == total and status["media_cache_checked"], status
        requests = b"requested media file(s)" in server_log_path.read_bytes()[offset:]
        if warm:
            assert cached == total and downloaded == 0 and not requests, status
        else:
            assert downloaded > 0 and requests, status
        if cold:
            assert cached == 0, status
        print(f"{label}: {cached} cached, {downloaded} downloaded; ready", flush=True)
        return status

    with server_log_path.open("w") as log:
        server = subprocess.Popen([args.server, *server_mode, "--gameid", "devtest",
                                   "--world", str(world), "--config", str(conf), "--port", str(port),
                                   "--verbose", "--logfile", str(scratch / "debug.log")],
                                  env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 30
            while "listening on" not in server_log_path.read_text():
                if server.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError(server_log_path.read_text())
                time.sleep(0.1)
            join("cold", cold=True)
            join("warm", warm=True)
            cache = scratch / "data/godot/app_userdata/Goanna/cache/media"
            entries = sorted(cache.iterdir())
            assert len(entries) > 2
            entries[0].write_bytes(b"corrupt cache entry")
            entries[1].unlink()
            join("damaged")
            assert hashlib.sha1(entries[0].read_bytes()).hexdigest() == entries[0].name
            assert entries[1].exists()
            join("repaired", warm=True)
            # The filename is unchanged, but the server now announces new bytes.
            server.terminate()
            server.wait(timeout=10)
            write_texture(23)
            offset = server_log_path.stat().st_size
            server = subprocess.Popen(server.args, env=env, stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 30
            while b"listening on" not in server_log_path.read_bytes()[offset:]:
                if server.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError(server_log_path.read_bytes()[offset:])
                time.sleep(0.1)
            assert join("changed")["media_downloaded"] == 1
            join("changed-warm", warm=True)
            shutil.rmtree(cache)
            cache.write_text("A file prevents creating the cache directory")
            join("unavailable", cold=True)
            print("Media cache: PASS (real devtest server, dummy renderer, no GPU)")
        finally:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


if __name__ == "__main__":
    main()
