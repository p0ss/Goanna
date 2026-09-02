#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Retake project/menu_background.png, the still behind the main menu.
#
# The menu used to run a live session as its backdrop. That could not be quick
# (it boots a Luanti server and streams a world), and because it was looked at
# long before the near mesh arrived it showed the far tier, which draws no
# fences, lanterns or flowers at all and renders leaves as solid cubes. A still
# of the settled scene is both faster and higher fidelity, so the live path now
# only exists to take this picture.
#
# The scene is the graphics benchmark's village (tools/bench_plans/graphics.json
# places it, and its "close" scene is this camera), because that is the one
# scene in the repository whose look is checked regularly.
#
# Needs a display, project/bin built, and the world named below present in the
# detected Luanti install. GODOT_BIN overrides the Godot binary.
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
godot_bin=${GODOT_BIN:-godot}
data_dir=${GOANNA_DATA_DIR:-$HOME/.var/app/org.luanti.luanti/.minetest}
world=${GOANNA_BACKGROUND_WORLD:-test_world}
port=${GOANNA_BACKGROUND_PORT:-30530}
control=${GOANNA_BACKGROUND_CONTROL:-30801}
out="$repo_dir/project/menu_background.png"

# The bench plan's "close" scene, converted to main.gd's yaw convention
# (main.gd, yaw = atan2(-d.x, -d.z) in degrees).
#
# 0.245 is the minute the sun comes up behind this view, and it is a narrow
# window worth naming: swept in steps of 0.005, the sky's mean red minus blue
# over the top third jumps from -62 at 0.240 to -31 at 0.245, so a coarser
# sweep steps straight over the warm phase and concludes there is not one.
# Sampled either side it is blue before and washed out after. Here the horizon
# glow, the stars, the purple in the clouds and the lit lanterns and bell are
# all in frame at once, which no other time of day manages.
#
# The sun sets behind the camera, so the sunset side has no warm phase in this
# composition at all; do not go looking for one there.
pos_x=-100; pos_y=31; pos_z=340; yaw=-116.6; pitch=-8; tod=0.245

if [ ! -d "$data_dir/worlds/$world" ]; then
	printf 'menu-background: no world %s under %s\n' "$world" "$data_dir/worlds" >&2
	exit 1
fi

log="$data_dir/menu_background_server.log"
rm -f "$log"
# The flatpak cannot see outside its own data directory, so the server log has
# to live there rather than beside this script.
setsid flatpak run --command=luanti org.luanti.luanti --server \
	--world "$data_dir/worlds/$world" --gameid mineclonia --port "$port" \
	--config "$data_dir/goanna_local_server.conf" --logfile "$log" \
	>/dev/null 2>&1 </dev/null &
server_pid=$!
cleanup() { kill "$server_pid" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

for _ in $(seq 1 60); do
	grep -qE 'listening on|ERROR' "$log" 2>/dev/null && break
	sleep 1
done
if ! grep -q 'listening on' "$log" 2>/dev/null; then
	printf 'menu-background: server did not start, see %s\n' "$log" >&2
	exit 1
fi

client_log=$(mktemp)
# x11 (through XWayland) and fullscreen, because the project's viewport is
# 1600x900 and Wayland does not let a client size its own window: under Wayland
# the still came out at 1600x900 however it was asked for, and this is what
# gets it to the display's own resolution.
GOANNA_HOST=127.0.0.1 GOANNA_PORT="$port" GOANNA_NAME=menubg \
	GOANNA_CONTROL="$control" \
	"$godot_bin" --path "$repo_dir/project" --display-driver x11 --fullscreen \
	>"$client_log" 2>&1 &
client_pid=$!
cleanup() {
	kill "$client_pid" 2>/dev/null || true
	kill "$server_pid" 2>/dev/null || true
}
for _ in $(seq 1 120); do
	grep -q 'TOSERVER_CLIENT_READY sent' "$client_log" 2>/dev/null && break
	sleep 1
done

# settle true is the whole point: it waits for the near mesh rather than
# capturing the far tier the menu used to show.
python3 - "$control" "$out" "$pos_x" "$pos_y" "$pos_z" "$pitch" "$yaw" "$tod" <<'PY'
import json, socket, sys, time
control, out = int(sys.argv[1]), sys.argv[2]
x, y, z, pitch, yaw, tod = (float(v) for v in sys.argv[3:9])
s = socket.create_connection(("127.0.0.1", control), timeout=300)
f = s.makefile("rwb")


def cmd(name, **args):
    f.write((json.dumps({"id": 1, "cmd": name, "args": args}) + "\n").encode())
    f.flush()
    return json.loads(f.readline().decode().strip())


cmd("run", src="DisplayServer.window_set_size(Vector2i(2560, 1440))\nreturn true")
cmd("wait", frames=20)
cmd("weather", kind="clear")
cmd("time", tod=tod, server=True)
cmd("tp", x=x, y=y, z=z)
time.sleep(6)
cmd("pose", x=x, y=y, z=z, pitch=pitch, yaw=yaw, fly=True)
time.sleep(3)
reply = cmd("shot", path=out, hide_ui=True, settle=True, warm=40)
result = reply.get("result", {})
print("menu-background: %s %s, %s blocks meshed"
      % ("captured" if reply.get("ok") else "FAILED",
         result.get("size"), result.get("blocks_meshed")))
cmd("quit")
sys.exit(0 if reply.get("ok") else 1)
PY

printf 'menu-background: wrote %s\n' "$out"
