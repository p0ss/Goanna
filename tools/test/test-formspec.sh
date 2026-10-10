#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Check formspec support: first that every upstream formspec element has a
# Goanna status (tools/test/check-formspec-coverage.py), then the conformance
# test project/tests/formspec_conformance.gd under Godot's --headless dummy
# renderer, which needs no GPU and opens no window.
#
# Usage: GODOT_BIN=/path/to/godot tools/test/test-formspec.sh
set -euo pipefail
case "${1:-}" in -h | --help)
    # Usage is the header comment above.
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); if (/^(SPDX|Copyright)/) next
        if (!started && $0 == "") next; started = 1; print }' "$0"
    exit 0 ;;
esac

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"

python3 tools/test/check-formspec-coverage.py

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
	printf 'formspec conformance: Godot not found; set GODOT_BIN=/path/to/godot\n' >&2
	exit 1
fi

godot_args=(--headless)
if [[ -n "${GOANNA_FORMSPEC_SHOTS:-}" ]]; then
	# Godot's headless display driver has only a dummy renderer, so there is no
	# viewport texture to save. Screenshot mode therefore needs a real display.
	godot_args=()
fi

"$godot_bin" "${godot_args[@]}" --path project --script res://tests/formspec_conformance.gd
