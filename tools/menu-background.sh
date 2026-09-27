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
# The client runs in headless gamescope through tools/goanna-headless, never as
# a window on the desktop, at 2560x1440 on the Ultra profile, dressed in the
# pack named by GOANNA_BACKGROUND_PACK: by default the 512 px authored
# Mineclonia pack (tools/pbr_author/README.md, "The 512 px pack"), which is
# the one worth a still this close. The GPU must be free first
# (tools/goanna-headless gpu-free); this refuses otherwise.
#
# Needs project/bin built and the world named below present in the detected
# Luanti install.
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
data_dir=${GOANNA_DATA_DIR:-$HOME/.var/app/org.luanti.luanti/.minetest}
world=${GOANNA_BACKGROUND_WORLD:-test_world}
port=${GOANNA_BACKGROUND_PORT:-30530}
pack=${GOANNA_BACKGROUND_PACK:-$repo_dir/baked/authored-mineclonia-512/textures}
profile=${GOANNA_BACKGROUND_PROFILE:-ultra}
size=${GOANNA_BACKGROUND_SIZE:-2560x1440}
out="$repo_dir/project/menu_background.png"
headless="$repo_dir/tools/goanna-headless"

pos_x=-100; pos_y=31; pos_z=340; yaw=-116.6; pitch=-8; tod=0.245

if [ ! -d "$data_dir/worlds/$world" ]; then
	printf 'menu-background: no world %s under %s\n' "$world" "$data_dir/worlds" >&2
	exit 1
fi

if [ ! -d "$pack" ]; then
	printf 'menu-background: no pack at %s (GOANNA_BACKGROUND_PACK)\n' "$pack" >&2
	exit 1
fi
if ! "$headless" gpu-free | grep -q '"free": true'; then
	printf 'menu-background: the GPU is in use; see %s gpu-free\n' "$headless" >&2
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
launcher_pid=$!
# The server runs inside the flatpak sandbox, so killing the launcher left
# it running: one started on 2026-09-27 was found ten hours later. It is
# found by its own log file, which nothing else is started with.
stop_server() {
	kill "$launcher_pid" 2>/dev/null || true
	ps -eo pid=,args= | awk -v log="--logfile $log" 'index($0, "luanti.bin") && index($0, log) {print $1}' |
		while read -r pid; do kill "$pid" 2>/dev/null || true; done
}
cleanup() { stop_server; }
trap cleanup EXIT INT TERM

for _ in $(seq 1 60); do
	grep -qE 'listening on|ERROR' "$log" 2>/dev/null && break
	sleep 1
done
if ! grep -q 'listening on' "$log" 2>/dev/null; then
	printf 'menu-background: server did not start, see %s\n' "$log" >&2
	exit 1
fi

started=$("$headless" start --cpu-compositor --server "127.0.0.1:$port" --name menubg --size "$size" \
	--label "menu background" --env "GOANNA_PACK=$pack" --env GOANNA_PACK_SET=1)
client_id=$(printf '%s' "$started" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
control=$(printf '%s' "$started" | python3 -c 'import json,sys; print(json.load(sys.stdin)["control_port"])')
cleanup() {
	"$headless" stop "$client_id" >/dev/null 2>&1 || true
	stop_server
}

# settle true is the whole point: it waits for the near mesh rather than
# capturing the far tier the menu used to show.
python3 - "$control" "$out" "$profile" "$pos_x" "$pos_y" "$pos_z" "$pitch" "$yaw" "$tod" <<'PY'
import json, socket, sys, time
control, out, profile = int(sys.argv[1]), sys.argv[2], sys.argv[3]
x, y, z, pitch, yaw, tod = (float(v) for v in sys.argv[4:10])
s = socket.create_connection(("127.0.0.1", control), timeout=300)
f = s.makefile("rwb")


def cmd(name, **args):
    f.write((json.dumps({"id": 1, "cmd": name, "args": args}) + "\n").encode())
    f.flush()
    return json.loads(f.readline().decode().strip())


# Every setting the profile names, as the settings panel's picker applies it.
values = cmd("eval", expr='GraphicsProfiles.PROFILES["%s"]' % profile).get("result")
if isinstance(values, dict) and "value" in values:
    values = values["value"]
if not isinstance(values, dict) or not values:
    sys.exit("menu-background: no profile %s: %s" % (profile, values))
for key, value in values.items():
    reply = cmd("set", key=key, value=value)
    if not reply.get("ok"):
        sys.exit("menu-background: could not set %s: %s" % (key, reply))
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
sys.exit(0 if reply.get("ok") else 1)
PY

printf 'menu-background: wrote %s\n' "$out"
