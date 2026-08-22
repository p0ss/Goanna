#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# The acceptance harness for docs/launch-target.md task 1: start Goanna
# against an empty settings file, start a new local world through the menu
# path (not a hand started server), wait on the control channel for the far
# field to reach a real size, take a horizon shot and a close shot, and
# check both with shotcheck.py --launch-target.
#
# The empty settings file is XDG_DATA_HOME pointed at a scratch directory:
# Godot puts user:// under it, so there is no goanna.cfg and every value is
# the code's default. This works on Linux, which is what this script
# targets; docs/launch-target.md's GOANNA_CFG=<path> portable fallback is
# not implemented. GOANNA_LOCAL_TEST="game:world" is menu.gd's own
# development guard for driving the "start a local game" screen without a
# human at the keyboard; see the comment above SKIP_VARS in project/menu.gd.
#
# Needs a graphical display (the screenshots come from the real viewport, so
# this will not run headless), GOANNA_LAUNCH_TARGET_GAME installed for
# Luanti (mineclonia by default, the only game with a bundled texture map),
# and Python 3 with Pillow and numpy for shotcheck.py. GODOT_BIN overrides
# the Godot binary.
#
# Every run starts a brand new world, named from the current time unless
# GOANNA_LAUNCH_TARGET_WORLD is set, because the point of this harness is
# the fresh world experience docs/launch-target.md opens with: a reused
# world's earlier pregeneration would hide a regression here. Nothing in
# this script deletes a world; they accumulate under Luanti's own data
# directory and are left for inspection.
#
# The run directory (log, shots, settings.json) is printed on failure; set
# GOANNA_LAUNCH_TARGET_DIR to choose it and keep it always.
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_dir"

godot_bin=${GODOT_BIN:-}
if [[ -z "$godot_bin" ]]; then
	for candidate in godot godot4 "$repo_dir/../Godot_v4.5.1-stable_linux.x86_64"; do
		if command -v "$candidate" >/dev/null 2>&1; then
			godot_bin=$(command -v "$candidate")
			break
		fi
	done
fi
if [[ -z "$godot_bin" || ! -x "$godot_bin" ]]; then
	printf 'launch target test: Godot not found; set GODOT_BIN=/path/to/godot\n' >&2
	exit 1
fi

game=${GOANNA_LAUNCH_TARGET_GAME:-mineclonia}
world=${GOANNA_LAUNCH_TARGET_WORLD:-goanna_launch_target_$(date +%s)}
control_port=${GOANNA_LAUNCH_TARGET_PORT:-30800}
far_min=${GOANNA_LAUNCH_TARGET_FAR_MIN:-500}
far_timeout_ms=${GOANNA_LAUNCH_TARGET_FAR_TIMEOUT_MS:-180000}
startup_timeout_s=${GOANNA_LAUNCH_TARGET_STARTUP_TIMEOUT_S:-90}

run_dir=${GOANNA_LAUNCH_TARGET_DIR:-}
keep_dir=1
if [[ -z "$run_dir" ]]; then
	run_dir=$(mktemp -d "${TMPDIR:-/tmp}/goanna-launch-target.XXXXXX")
	keep_dir=0
fi
mkdir -p "$run_dir"
profile_dir="$run_dir/profile"
mkdir -p "$profile_dir"
log="$run_dir/goanna.log"
horizon="$run_dir/horizon.png"
wall="$run_dir/wall.png"
settings_json="$run_dir/settings.json"
rm -f "$log" "$horizon" "$wall" "$settings_json"

printf 'launch target test: starting %s:%s (profile %s), log %s\n' "$game" "$world" "$profile_dir" "$log"

env \
	XDG_DATA_HOME="$profile_dir" \
	GOANNA_LOCAL_TEST="$game:$world" \
	GOANNA_CONTROL="$control_port" \
	"$godot_bin" --path "$repo_dir/project" >"$log" 2>&1 &
gpid=$!

cleanup() {
	if kill -0 "$gpid" 2>/dev/null; then
		kill "$gpid" 2>/dev/null || true
		for i in $(seq 1 50); do
			kill -0 "$gpid" 2>/dev/null || break
			sleep 0.2
		done
		if kill -0 "$gpid" 2>/dev/null; then
			kill -9 "$gpid" 2>/dev/null || true
		fi
	fi
}
trap cleanup EXIT

fail=0
say_fail() {
	printf 'launch target test: FAIL: %s\n' "$1" >&2
	fail=1
}

# Drives the control channel: waits for it to come up, waits for the far
# field to pass far_min, finds the ground under the player (spawn terrain is
# not known in advance), takes the wall shot two nodes ahead of it and the
# horizon shot from high above looking out, then writes settings.json and
# quits. Configuration comes through the environment rather than shell
# interpolation into the script, because the heredoc below is quoted.
export GLT_CONTROL_PORT="$control_port"
export GLT_FAR_MIN="$far_min"
export GLT_FAR_TIMEOUT_MS="$far_timeout_ms"
export GLT_STARTUP_TIMEOUT_S="$startup_timeout_s"
export GLT_HORIZON="$horizon"
export GLT_WALL="$wall"
export GLT_SETTINGS_JSON="$settings_json"
export GLT_GAME="$game"
export GLT_WORLD="$world"
export GLT_SHADER_PACK="${GOANNA_SHADERPACK:-}"

driver_timeout=$(( startup_timeout_s + far_timeout_ms / 1000 + 90 ))
set +e
timeout "$driver_timeout" python3 - <<'PY'
import json
import os
import socket
import sys
import time

host = "127.0.0.1"
port = int(os.environ["GLT_CONTROL_PORT"])
far_min = int(os.environ["GLT_FAR_MIN"])
far_timeout_ms = int(os.environ["GLT_FAR_TIMEOUT_MS"])
startup_timeout_s = float(os.environ["GLT_STARTUP_TIMEOUT_S"])
horizon_path = os.environ["GLT_HORIZON"]
wall_path = os.environ["GLT_WALL"]
settings_path = os.environ["GLT_SETTINGS_JSON"]

_next_id = [0]


def call(sock, cmd, args=None, timeout=60.0):
    _next_id[0] += 1
    req = {"id": _next_id[0], "cmd": cmd, "args": args or {}}
    sock.settimeout(timeout)
    sock.sendall((json.dumps(req) + "\n").encode("utf-8"))
    buf = b""
    while b"\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            raise RuntimeError("control channel closed waiting for a reply to %s" % cmd)
        buf += chunk
    reply = json.loads(buf.split(b"\n", 1)[0].decode("utf-8"))
    if not reply.get("ok"):
        raise RuntimeError("%s failed: %s" % (cmd, reply.get("error")))
    return reply["result"]


def connect():
    deadline = time.monotonic() + startup_timeout_s
    last_exc = None
    while time.monotonic() < deadline:
        try:
            return socket.create_connection((host, port), timeout=5.0)
        except OSError as exc:
            last_exc = exc
            time.sleep(1.0)
    raise RuntimeError("no control channel on %s:%d after %gs (%s); is another "
                        "GOANNA_CONTROL session already on this port, or did the "
                        "local server fail to start? see the log"
                        % (host, port, startup_timeout_s, last_exc))


GROUND_SNIPPET = (
    'var p = client.server_player_position()\n'
    'var y = int(p.y) + 2\n'
    'while y > int(p.y) - 40:\n'
    '\tvar n = client.node_name_at(Vector3(p.x, y, p.z))\n'
    '\tif n != "air" and n != "ignore":\n'
    '\t\treturn {"y": y, "node": n, "player": [p.x, p.y, p.z]}\n'
    '\ty -= 1\n'
    'return {"node": "", "player": [p.x, p.y, p.z]}'
)


def main():
    sock = connect()
    try:
        # The cold verify rule (docs/control-channel.md): nothing has been set
        # yet, so nothing should have deviated from what the code just booted
        # with. If it has, the profile was not actually empty.
        dev = call(sock, "deviations")
        if dev:
            raise RuntimeError("settings deviated from startup before the first "
                                "command: %s" % dev)

        call(sock, "wait",
             {"expr": "client.render_stats().far_remote >= %d" % far_min,
              "timeout_ms": far_timeout_ms},
             timeout=far_timeout_ms / 1000.0 + 30.0)

        ground = call(sock, "run", {"src": GROUND_SNIPPET})["value"]
        if not ground.get("node"):
            raise RuntimeError("no solid ground found under the player at %s"
                                % ground.get("player"))
        px, py, pz = ground["player"]
        gy = ground["y"]

        # The wall shot: close to the ground, looking two nodes ahead and down
        # at it, which is solid wherever the player is standing even though the
        # terrain shape at a fresh spawn is not known in advance.
        call(sock, "pose", {"x": px, "y": py + 0.2, "z": pz, "fly": True})
        call(sock, "look", {"x": px + 2.0, "y": gy, "z": pz})
        wall_meta = call(sock, "shot", {"path": wall_path})

        # The horizon shot: high above the same spot, looking out at a shallow
        # downward angle. Camera moves alone here (pose, not tp), so this does
        # not ask the server for anything the far field around the player has
        # not already streamed or summarised.
        call(sock, "pose", {"x": px, "y": py + 150.0, "z": pz, "fly": True})
        call(sock, "look", {"x": px + 300.0, "y": py + 100.0, "z": pz})
        horizon_meta = call(sock, "shot", {"path": horizon_path})

        render_stats = call(sock, "eval", {"expr": "client.render_stats()"})["value"]
        settings = call(sock, "settings")
        final_dev = call(sock, "deviations")

        with open(settings_path, "w") as f:
            json.dump({
                "game": os.environ["GLT_GAME"],
                "world": os.environ["GLT_WORLD"],
                "shader_pack": os.environ.get("GLT_SHADER_PACK", ""),
                "render_stats": render_stats,
                "settings": settings,
                "deviations": final_dev,
                "horizon_shot": horizon_meta,
                "wall_shot": wall_meta,
            }, f, indent=2)

        call(sock, "quit")
    finally:
        sock.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("launch target drive: FAIL: %s" % exc, file=sys.stderr)
        sys.exit(1)
PY
driver_status=$?
set -e

if [[ $driver_status -ne 0 ]]; then
	say_fail "driving the client failed; see $log"
fi

if [[ -f "$horizon" && -f "$wall" && -f "$settings_json" ]]; then
	if ! python3 "$repo_dir/tools/shotcheck.py" --launch-target \
			--settings "$settings_json" "$horizon" "$wall"; then
		fail=1
	fi
else
	say_fail "missing output: expected $horizon, $wall and $settings_json"
fi

if [[ $fail -ne 0 ]]; then
	printf 'launch target test: FAIL: run directory %s\n' "$run_dir" >&2
	tail -n 40 "$log" >&2 || true
	exit 1
fi
printf 'launch target test: PASS: %s\n' "$run_dir"
if [[ $keep_dir -eq 0 ]]; then
	rm -rf "$run_dir"
fi
