#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Run Goanna against a live server with the proof shader pack loaded, take a
# screenshot, and check that the pack's screen space chain actually drew. See
# docs/shaderpack-testing.md.
#
# Needs a graphical display (the screenshot comes from the real viewport) and
# a Luanti server that answers on GOANNA_HOST:GOANNA_PORT (127.0.0.1:30000 by
# default). GODOT_BIN overrides the Godot binary. GOANNA_NAME, GOANNA_PASS,
# GOANNA_TOD and GOANNA_VIEW are passed through if set; the default player
# name is shaderproof, so pick another if that name is taken on the server.
# The run directory is printed on failure; set GOANNA_SHADERPACK_TEST_DIR to
# choose it and keep it.
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
	printf 'shaderpack test: Godot not found; set GODOT_BIN=/path/to/godot\n' >&2
	exit 1
fi

host=${GOANNA_HOST:-127.0.0.1}
port=${GOANNA_PORT:-30000}
player=${GOANNA_NAME:-shaderproof}
pack=$repo_dir/project/tests/shaderpacks/proof
if [[ ! -f "$pack/shaders/final.fsh" ]]; then
	printf 'shaderpack test: proof pack missing at %s\n' "$pack" >&2
	exit 1
fi

run_dir=${GOANNA_SHADERPACK_TEST_DIR:-}
keep_dir=1
if [[ -z "$run_dir" ]]; then
	run_dir=$(mktemp -d "${TMPDIR:-/tmp}/goanna-shaderpack.XXXXXX")
	keep_dir=0
fi
mkdir -p "$run_dir"
log=$run_dir/goanna.log
shot=$run_dir/a.png
rm -f "$shot"

printf 'shaderpack test: running Goanna against %s:%s, log %s\n' "$host" "$port" "$log"
# GOANNA_SHOT makes main.gd save a.png about eight seconds in and quit; the
# timeout is a backstop in case it never gets that far.
set +e
timeout 120 env \
	GOANNA_SHADERPACK="$pack" \
	GOANNA_SHOT="$run_dir" \
	GOANNA_HOST="$host" \
	GOANNA_PORT="$port" \
	GOANNA_NAME="$player" \
	GOANNA_PASS="${GOANNA_PASS:-}" \
	GOANNA_TOD="${GOANNA_TOD:-0.5}" \
	GOANNA_VIEW="${GOANNA_VIEW:-a:0,6,14:-10,0}" \
	"$godot_bin" --path "$repo_dir/project" >"$log" 2>&1
godot_status=$?
set -e

fail=0
say_fail() {
	printf 'shaderpack test: FAIL: %s\n' "$1" >&2
	fail=1
}

if [[ $godot_status -ne 0 ]]; then
	say_fail "Godot exited with status $godot_status"
fi

# The session reports its state once a second. If the last report is still
# "connecting", nothing answered; "denied" means the server refused the name.
last_state=$(grep -oE '^\[ *[0-9.]+s\] [a-z-]+' "$log" | tail -n 1 | awk '{print $NF}' || true)
case "$last_state" in
	connecting)
		say_fail "no server answered at $host:$port (set GOANNA_HOST and GOANNA_PORT)" ;;
	denied)
		say_fail "server at $host:$port denied player $player (set GOANNA_NAME or GOANNA_PASS)" ;;
	"")
		say_fail "no session state reported; Goanna did not get as far as connecting" ;;
esac

if ! grep -q '^Goanna Iris: proof ready, 2 of 2 passes compiled' "$log"; then
	say_fail 'no "Goanna Iris: proof ready, 2 of 2 passes compiled" line in the log'
fi
# Godot's own "vertex_array is null" and "vertex_buffer_owner" errors are
# unrelated noise; only the Iris errors count.
if grep -q '^ERROR: Goanna Iris:' "$log"; then
	say_fail 'Iris reported errors:'
	grep '^ERROR: Goanna Iris:' "$log" | sed 's/^/  /' >&2
fi

if [[ ! -f "$shot" ]]; then
	say_fail "no screenshot at $shot"
elif ! python3 "$repo_dir/tools/shaderpack_check.py" "$shot"; then
	fail=1
fi

if [[ $fail -ne 0 ]]; then
	printf 'shaderpack test: FAIL: log at %s, shot at %s\n' "$log" "$shot" >&2
	exit 1
fi
printf 'shaderpack test: PASS: proof pack chain drew (%s)\n' "$shot"
if [[ $keep_dir -eq 0 ]]; then
	rm -rf "$run_dir"
fi
