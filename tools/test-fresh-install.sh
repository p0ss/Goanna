#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Run project/tests/fresh_install.gd (Get ready to play from nothing) in clean
# containers of several Linux distributions, none of which has Luanti or
# Flatpak: find no Luanti, set up the bundled server, download and unpack
# the starter game, start a world and wait for the server to listen.
#
# Each container gets a minimal copy of the project (the scripts the setup
# uses, no GDExtension and no import cache), the server mod beside it and the
# bundled server under dist/, as a source checkout has them. The host's Godot
# is mounted read only. Needs the bundled server built first
# (tools/build-luanti-server.sh) and network access for the game download.
#
# Usage: tools/test-fresh-install.sh [image ...]
# GODOT_BIN names the Godot binary. PODMAN overrides the container command
# (see tools/build-luanti-server.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$(pwd)
podman_cmd=${PODMAN:-podman}
godot=${GODOT_BIN:-$(command -v godot || true)}
if [ -z "$godot" ] || [ ! -x "$godot" ]; then
	echo "set GODOT_BIN to a Godot 4.5 binary" >&2
	exit 2
fi
if [ $# -eq 0 ]; then
	set -- docker.io/library/ubuntu:22.04 docker.io/library/ubuntu:24.04 \
		docker.io/library/debian:12 registry.fedoraproject.org/fedora:42 \
		docker.io/library/archlinux:latest
fi
bundle=$(ls -d "$repo"/dist/luanti-server/luanti-*-server-linux-x86_64 2>/dev/null | head -1)
if [ -z "$bundle" ]; then
	echo "no bundled server in dist/luanti-server; run tools/build-luanti-server.sh" >&2
	exit 2
fi
work=${GOANNA_FRESH_DIR:-$HOME/.cache/goanna-fresh-install}
rm -rf "$work"
status=0
results=()
for image in "$@"; do
	tree="$work/$(printf '%s' "$image" | tr '/:' '__')"
	mkdir -p "$tree/project/tests" "$tree/dist/luanti-server"
	cp project/local_server.gd project/asset_store.gd project/owned_process.gd \
		project/terrain_worlds.json "$tree/project/"
	cp project/tests/fresh_install.gd "$tree/project/tests/"
	printf 'config_version=5\n\n[application]\n\nconfig/name="Goanna"\n' > "$tree/project/project.godot"
	cp -r goanna_server_mod "$tree/"
	cp -r "$bundle" "$tree/dist/luanti-server/"
	printf '== %s\n' "$image"
	# shellcheck disable=SC2086
	$podman_cmd run --rm -v "$tree:/goanna:Z" -v "$godot:/usr/local/bin/godot:ro,Z" \
		"$image" godot --headless --path /goanna/project \
		--script res://tests/fresh_install.gd > "$tree/output.log" 2>&1 || true
	grep -E "fresh install|ERROR|error while loading" "$tree/output.log" || true
	if ! grep -q "fresh install: PASS" "$tree/output.log"; then
		status=1
		results+=("FAIL $image (log: $tree/output.log)")
	else
		results+=("PASS $image")
	fi
done
printf '%s\n' "${results[@]}"
exit $status
