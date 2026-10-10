#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Retake the stills behind the main menu, project/menu_backgrounds/*.jpg. The
# menu shows one of them at random on each launch (menu.gd, BACKGROUNDS).
#
# The menu used to run a live session as its backdrop. That could not be quick
# (it boots a Luanti server and streams a world), and because it was looked at
# long before the near mesh arrived it showed the far tier, which draws no
# fences, lanterns or flowers at all and renders leaves as solid cubes. A still
# of the settled scene is both faster and higher fidelity, so the live path now
# only exists to take these pictures.
#
# The scenes were scouted on 2026-09-28 and 2026-09-29 and are all in
# test_world. The menu's panel sits in the middle of the screen, so each is
# framed with its subject to one side of the centre. Each has its own time:
# golden hour now lands just before the sun meets the terrain ridge toward it
# (docs/systems/sky-orchestration.md), and that ridge differs from place to place.
#
#   headland  the plains village on its headland from the water, at sunset
#   lantern   a lantern lit street in the eastern village, at blue hour
#   lava      a lava pool in birch forest, at dusk
#
# GOANNA_BACKGROUND_SCENES picks a subset, space separated.
#
# The client runs in headless gamescope through tools/goanna-headless, never as
# a window on the desktop, at 2560x1440 on the Ultra profile, dressed in the
# pack named by GOANNA_BACKGROUND_PACK: by default the 512 px authored
# Mineclonia pack (tools/pbr/pbr_author/README.md, "The 512 px pack"), which is
# the one worth a still this close. The GPU must be free first
# (tools/goanna-headless gpu-free); this refuses otherwise.
#
# Needs project/bin built, the world named below present in the detected
# Luanti install, and Python's Pillow to write the JPEGs.
set -euo pipefail
case "${1:-}" in -h | --help)
    # Usage is the header comment above.
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); if (/^(SPDX|Copyright)/) next
        if (!started && $0 == "") next; started = 1; print }' "$0"
    exit 0 ;;
esac

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
data_dir=${GOANNA_DATA_DIR:-$HOME/.var/app/org.luanti.luanti/.minetest}
world=${GOANNA_BACKGROUND_WORLD:-test_world}
port=${GOANNA_BACKGROUND_PORT:-30530}
pack=${GOANNA_BACKGROUND_PACK:-$repo_dir/baked/authored-mineclonia-512/textures}
profile=${GOANNA_BACKGROUND_PROFILE:-ultra}
size=${GOANNA_BACKGROUND_SIZE:-2560x1440}
scenes=${GOANNA_BACKGROUND_SCENES:-headland lantern lava}
out_dir="$repo_dir/project/menu_backgrounds"
headless="$repo_dir/tools/goanna-headless"

if [ ! -d "$data_dir/worlds/$world" ]; then
	printf 'menu-background: no world %s under %s\n' "$world" "$data_dir/worlds" >&2
	exit 1
fi

if [ ! -d "$pack" ]; then
	printf 'menu-background: no pack at %s (GOANNA_BACKGROUND_PACK)\n' "$pack" >&2
	exit 1
fi
if ! python3 -c 'import PIL' 2>/dev/null; then
	printf 'menu-background: needs Python Pillow to write the JPEGs\n' >&2
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
	ps -eo pid=,args= | awk -v lf="--logfile $log" 'index($0, "luanti.bin") && index($0, lf) {print $1}' |
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

mkdir -p "$out_dir"
# settle true is the whole point: it waits for the near mesh rather than
# capturing the far tier the menu used to show.
python3 - "$control" "$out_dir" "$profile" $scenes <<'PY'
import json, os, socket, sys, tempfile, time
from PIL import Image

control, out_dir, profile = int(sys.argv[1]), sys.argv[2], sys.argv[3]
wanted = sys.argv[4:]

# Godot coordinates (Luanti's Z negated) and main.gd's yaw and pitch, as the
# control channel's shot sidecar reports them.
SCENES = {
    "headland": dict(pos=(835.0, 18.0, 812.0), yaw=38.0, pitch=-5.0, tod=0.768),
    "lantern": dict(pos=(935.0, 7.0, 1285.0), yaw=36.87, pitch=-1.15, tod=0.80),
    "lava": dict(pos=(-92.0, 43.0, -280.0), yaw=-49.4, pitch=-10.75, tod=0.785),
}
unknown = [n for n in wanted if n not in SCENES]
if unknown:
    sys.exit("menu-background: no scene %s; the scenes are %s" % (", ".join(unknown), ", ".join(SCENES)))

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
# In fly mode the player's own body draws as a flat quad across the frame.
cmd("set", key="show_body", value=0)
# Fly, or the player falls between scenes: on 2026-09-29 it dropped into the
# lava pool, died, and every later run started on the death screen, where
# the server streams next to nothing and every still was far tier boxes.
cmd("fly", on=True)
if cmd("ui_tree").get("result", {}).get("window") == "death_screen":
    cmd("ui_click", text="Respawn")
    time.sleep(3)
    cmd("fly", on=True)
cmd("wait", frames=20)
cmd("weather", kind="clear")

failed = False
with tempfile.TemporaryDirectory() as tmp:
    for name in wanted:
        sc = SCENES[name]
        x, y, z = sc["pos"]
        cmd("time", tod=sc["tod"], server=True)
        # The camera goes first. The client streams around the camera, not
        # the server's idea of the player, and main.gd eases its sky, fog and
        # ground measures over seconds; a camera left at the last scene (or
        # at spawn, under a dark oak canopy) until just before the shot
        # captured far tier boxes under the wrong sky on 2026-09-29.
        cmd("pose", x=x, y=y, z=z, pitch=sc["pitch"], yaw=sc["yaw"], fly=True)
        # The server streams the near blocks around its own idea of the
        # player, so a refused teleport leaves only the far tier to shoot.
        reply = cmd("tp", x=x, y=y, z=z)
        if not reply.get("ok"):
            print("menu-background: %s teleport refused: %s" % (name, reply.get("error")))
            failed = True
            continue
        # Long enough for the near mesh and for the ridge probe, which sets
        # when this spot's golden hour falls, to see the far terrain.
        time.sleep(45)
        cmd("pose", x=x, y=y, z=z, pitch=sc["pitch"], yaw=sc["yaw"], fly=True)
        time.sleep(3)
        png = os.path.join(tmp, name + ".png")
        reply = cmd("shot", path=png, hide_ui=True, settle=True, warm=40)
        result = reply.get("result", {})
        print("menu-background: %s %s %s, %s blocks meshed"
              % (name, "captured" if reply.get("ok") else "FAILED",
                 result.get("size"), result.get("blocks_meshed")))
        if not reply.get("ok"):
            failed = True
            continue
        # JPEG at 95: a third of the PNG's size, and nothing to see at this
        # quality in a full screen still behind a menu.
        out = os.path.join(out_dir, name + ".jpg")
        Image.open(png).convert("RGB").save(out, "JPEG", quality=95, subsampling=0)
        print("menu-background: wrote %s" % out)
sys.exit(1 if failed else 0)
PY
