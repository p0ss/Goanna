#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Run Goanna against a live server with the proof shader pack loaded, take a
# screenshot, and check that the pack's screen space chain actually drew. See
# docs/develop/shaderpack-testing.md.
#
# The client runs in headless gamescope through tools/goanna-headless, on the
# GPU, so no window reaches the desktop. The screenshot is read back from
# Godot's own viewport, which renders for real there, so the pixels are the
# ones a desktop window would give; Godot's --headless cannot produce one.
# The launcher takes the shared GPU lock, and this waits up to
# GOANNA_LOCK_WAIT seconds (default 1800) for it rather than refusing. It
# still refuses while another game client or a compute job is on the GPU.
# GOANNA_SOFTWARE=1 renders on lavapipe instead, which checks the harness
# but not the look. The window is 1600 by 900, the project's own window
# size, which is what the desktop runs got.
#
# Needs a Luanti server that answers on GOANNA_HOST:GOANNA_PORT
# (127.0.0.1:30000 by default). GODOT_BIN overrides the Godot binary.
# GOANNA_NAME, GOANNA_PASS, GOANNA_TOD and GOANNA_VIEW are passed through if
# set; the default player name is shaderproof, so pick another if that name
# is taken on the server. The run directory is printed on failure; set
# GOANNA_SHADERPACK_TEST_DIR to choose it and keep it. It holds the client's
# log (goanna.log, gamescope's output included), the shot and instance.json,
# the launcher's record of the run.
set -euo pipefail
case "${1:-}" in -h | --help)
    # Usage is the header comment above.
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); if (/^(SPDX|Copyright)/) next
        if (!started && $0 == "") next; started = 1; print }' "$0"
    exit 0 ;;
esac

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
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

headless=$repo_dir/tools/goanna-headless
lock_wait=${GOANNA_LOCK_WAIT:-1800}
software=()
if [[ "${GOANNA_SOFTWARE:-}" == 1 ]]; then
	software=(--software)
fi
export GODOT_BIN="$godot_bin"

printf 'shaderpack test: running Goanna in headless gamescope against %s:%s, log %s\n' "$host" "$port" "$log"
# GOANNA_SHOT makes main.gd save a.png about eight seconds in and quit; the
# wait's timeout is a backstop in case it never gets that far, and stops the
# client when it runs out.
set +e
"$headless" start --project "$repo_dir" --server "$host:$port" --name "$player" \
	--password "${GOANNA_PASS:-}" --size 1600x900 --lock-wait "$lock_wait" \
	--label "shaderpack test" "${software[@]}" \
	--env GOANNA_SHADERPACK="$pack" \
	--env GOANNA_SHOT="$run_dir" \
	--env GOANNA_TOD="${GOANNA_TOD:-0.5}" \
	--env GOANNA_VIEW="${GOANNA_VIEW:-a:0,6,14:-10,0}" \
	>"$run_dir/instance.json" 2>"$run_dir/start.err"
start_status=$?
instance=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("id", ""))' \
	"$run_dir/instance.json" 2>/dev/null)
wait_status=1
if [[ $start_status -eq 0 && -n "$instance" ]]; then
	"$headless" wait "$instance" --timeout 120 >"$run_dir/wait.json"
	wait_status=$?
	client_log=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["client_log"])' \
		"$run_dir/instance.json")
	cp "$client_log" "$log" 2>/dev/null
fi
set -e

fail=0
say_fail() {
	printf 'shaderpack test: FAIL: %s\n' "$1" >&2
	fail=1
}

# The client's exit status does not reach the launcher, so a crash is read
# from the log, and a client that never quit from the wait's timeout.
if [[ $start_status -ne 0 ]]; then
	say_fail "the headless launcher did not start Goanna: $(cat "$run_dir/start.err")"
elif [[ $wait_status -ne 0 ]]; then
	say_fail "Goanna did not quit within 120 s; it was stopped"
elif grep -q -E 'handle_crash|Program crashed' "$log"; then
	say_fail "Godot crashed"
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
elif ! python3 "$repo_dir/tools/test/shaderpack_check.py" "$shot"; then
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
