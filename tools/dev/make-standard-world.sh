#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Make Goanna's standard test world, test_world_do_not_delete, from scratch.
# The menu backgrounds, the graphics benchmark and the scenes in
# tools/dev/standard-scenes.json are all in it.
#
#   tools/dev/make-standard-world.sh [--name NAME] [--seed SEED]
#       [--radius NODES] [--centre X,Z] [--ymin Y] [--ymax Y] [--threads N]
#
# It writes a new Mineclonia world under the Luanti flatpak's worlds
# directory, starts one server on it with no client, pregenerates the box
# --radius nodes around the origin (or --centre) from --ymin to --ymax with
# a worldmod that calls core.emerge_area (tools/dev/standard-world-pregen.lua),
# waits for the server to shut itself down, removes that worldmod, and
# installs a fresh copy of goanna_server_mod as the render service does.
#
# It never touches an existing world: if NAME exists it refuses.
#
# The world is the one the old test_world was replaced with on 2026-10-13
# (docs/agents/agent-interfaces.md, "The standard world"):
#
#   game      Mineclonia as installed (release 38561), its own defaults
#   mapgen    v7, Luanti's defaults, seed below; Mineclonia sets mg_flags
#             and the new structure generator (mcl_levelgen ersatz) itself
#   emerge    one emerge thread
#
# The same seed gives the same terrain, water and villages, but not the
# same trees, ores or ground cover: two runs of this script with the same
# arguments differed in those on 2026-10-13. A remade world is the same
# place, so the scenes' poses still find their subjects, but a frame framed
# against a particular tree can come out different. Keep the world itself.
#
# Defaults: seed 20261013, radius 1600, y -112 to 207. On the development
# machine on 2026-10-13 that was 6724 mapchunks in 22 minutes and 480 MB of
# disk.
#
# The server uses at most a few GB of RAM. Check free -g first; run no more
# than one of these at a time.
set -euo pipefail
case "${1:-}" in -h | --help)
    # Usage is the header comment above.
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); if (/^(SPDX|Copyright)/) next
        if (!started && $0 == "") next; started = 1; print }' "$0"
    exit 0 ;;
esac

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
data_dir=${GOANNA_DATA_DIR:-$HOME/.var/app/org.luanti.luanti/.minetest}
name=test_world_do_not_delete
seed=20261013
radius=1600
cx=0
cz=0
ymin=-112
ymax=207
threads=1
while [ $# -gt 0 ]; do
	case "$1" in
	--name) name=$2; shift 2 ;;
	--seed) seed=$2; shift 2 ;;
	--radius) radius=$2; shift 2 ;;
	--centre) cx=${2%,*}; cz=${2#*,}; shift 2 ;;
	--ymin) ymin=$2; shift 2 ;;
	--ymax) ymax=$2; shift 2 ;;
	--threads) threads=$2; shift 2 ;;
	*) printf 'make-standard-world: unknown argument %s (see --help)\n' "$1" >&2; exit 2 ;;
	esac
done

world="$data_dir/worlds/$name"
if [ -e "$world" ]; then
	printf 'make-standard-world: %s exists; this never replaces a world\n' "$world" >&2
	exit 1
fi
if [ ! -f "$data_dir/games/mineclonia/game.conf" ]; then
	printf 'make-standard-world: no Mineclonia under %s/games\n' "$data_dir" >&2
	exit 1
fi

mkdir -p "$world/worldmods/goanna_standard_pregen"
cat >"$world/world.mt" <<EOF
gameid = mineclonia
world_name = $name
backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
mod_storage_backend = sqlite3
creative_mode = true
enable_damage = false
server_announce = false
EOF
printf 'name = goanna_standard_pregen\ndescription = Pregenerates the standard world, then stops\n' \
	>"$world/worldmods/goanna_standard_pregen/mod.conf"
cp "$repo_dir/tools/dev/standard-world-pregen.lua" "$world/worldmods/goanna_standard_pregen/init.lua"

# The flatpak sees only its own data directory, so the conf and the log
# live in the world.
conf="$world/pregen.conf"
log="$world/pregen.log"
port=$((30700 + RANDOM % 200))
cat >"$conf" <<EOF
fixed_map_seed = $seed
mg_name = v7
num_emerge_threads = $threads
server_announce = false
bind_address = 127.0.0.1
mcl_doWeatherCycle = false
mobs_spawn = false
goanna_pregen_min = ($((cx - radius)),$ymin,$((cz - radius)))
goanna_pregen_max = ($((cx + radius)),$ymax,$((cz + radius)))
goanna_pregen_parallel = $((threads * 4))
EOF

setsid flatpak run --command=luanti org.luanti.luanti --server \
	--world "$world" --gameid mineclonia --port "$port" \
	--config "$conf" --logfile "$log" >"$world/pregen.out" 2>&1 </dev/null &
launcher_pid=$!

# Every process under the launcher, found from its PID: the server runs in
# the flatpak sandbox, a few levels below the launcher.
tree() {
	local pids=$1 next
	while [ -n "$pids" ]; do
		printf '%s\n' $pids
		next=""
		for p in $pids; do
			next="$next $(ps -o pid= --ppid "$p" 2>/dev/null | tr '\n' ' ')"
		done
		pids=$(printf '%s' "$next" | xargs)
	done
}
stop_server() {
	local pids
	pids=$(tree "$launcher_pid" | tac)
	[ -z "$pids" ] && return 0
	for p in $pids; do kill "$p" 2>/dev/null || true; done
	sleep 10
	for p in $pids; do kill -9 "$p" 2>/dev/null || true; done
}
trap stop_server EXIT INT TERM

printf 'make-standard-world: pregenerating %s, seed %s, log %s\n' "$name" "$seed" "$log"
last=""
while kill -0 "$launcher_pid" 2>/dev/null; do
	sleep 10
	line=$(grep -a 'GOANNA_PREGEN' "$log" 2>/dev/null | tail -n 1 || true)
	if [ -n "$line" ] && [ "$line" != "$last" ]; then
		printf '%s\n' "$line" | sed 's/.*GOANNA_PREGEN_*/pregen: /'
		last=$line
	fi
	if grep -aq 'ERROR\[Main\]' "$log" 2>/dev/null; then
		printf 'make-standard-world: the server logged an error, see %s\n' "$log" >&2
		exit 1
	fi
done
wait "$launcher_pid" || true
trap - EXIT INT TERM

if ! grep -aq 'GOANNA_PREGEN_DONE' "$log"; then
	printf 'make-standard-world: the server stopped before pregeneration finished, see %s\n' \
		"$log" >&2
	exit 1
fi
grep -a 'GOANNA_PREGEN_DONE' "$log" | sed 's/.*GOANNA_PREGEN_DONE/done:/'

rm -rf "$world/worldmods/goanna_standard_pregen"
cp -r "$repo_dir/goanna_server_mod" "$world/worldmods/goanna_server_mod"
printf 'make-standard-world: %s ready, map_meta.txt:\n' "$world"
grep -E '^(seed|mg_name|mg_flags|chunksize|water_level|mcl_)' "$world/map_meta.txt" || true
