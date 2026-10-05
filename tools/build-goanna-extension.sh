#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Build the Goanna GDExtension for the Linux release in an Ubuntu 22.04
# container, so it loads on glibc 2.35 and anything newer, with the C++
# runtime linked in statically.
#
# A library built on the development machine (Fedora 44, glibc 2.43) asked
# for GLIBC_2.43 (acosf, asinf, atan2f) and GLIBC_2.38 (the C23 strtol and
# sscanf family), so on anything older it failed to load. Godot then could
# not find GoannaClient, main.gd failed to parse, and Start Game showed a
# grey screen. Found on a Steam Deck on 2026-10-03; every Linux release up
# to then had the same fault outside Fedora 44 and its relatives. The
# fresh-install container checks never caught it because they ran a scratch
# project without the extension.
#
# It builds what is committed (HEAD and its submodules, by git archive), not
# the working tree, which other sessions edit. The library goes to the
# output directory, never to project/bin; package-release.sh takes it from
# there when GOANNA_EXTENSION points at it.
#
# Usage: tools/build-goanna-extension.sh [output_dir]
#   default output: dist/extension-linux/
# PODMAN overrides the container command, as for build-luanti-server.sh, and
# GOANNA_BUILD_CACHE the work directory (default ~/.cache/goanna-extbuild,
# off tmpfs: the build tree is several gigabytes).
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$(pwd)
out=${1:-$repo/dist/extension-linux}
cache=${GOANNA_BUILD_CACHE:-$HOME/.cache/goanna-extbuild}
podman_cmd=${PODMAN:-podman}
image=docker.io/library/ubuntu:22.04
rev=$(git rev-parse --short HEAD)

rm -rf "$cache/src"
mkdir -p "$cache/src" "$cache/build" "$out"
git archive HEAD | tar -x -C "$cache/src"
for sub in godot-cpp luanti whisper.cpp; do
	mkdir -p "$cache/src/$sub"
	git -C "$sub" archive HEAD | tar -x -C "$cache/src/$sub"
done

# shellcheck disable=SC2086
$podman_cmd run --rm \
	-v "$cache/src:/src:ro,Z" -v "$cache/build:/build:Z" -v "$out:/out:Z" \
	-e REV="$rev" \
	"$image" bash -euo pipefail -c '
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
	g++-12 cmake ninja-build python3 zlib1g-dev libzstd-dev binutils >/dev/null
# The library is written beside the source (project/bin), which is read
# only here, so the build works on a copy.
rm -rf /build/work && cp -r /src /build/work
cmake -S /build/work -B /build/tree -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
	-DCMAKE_C_COMPILER=gcc-12 -DCMAKE_CXX_COMPILER=g++-12 \
	-DZSTD_STATIC_LIB=/usr/lib/x86_64-linux-gnu/libzstd.a \
	-DCMAKE_SHARED_LINKER_FLAGS="-static-libstdc++ -static-libgcc" >/build/cmake.log
ninja -C /build/tree goanna >/build/ninja.log
lib=$(ls /build/work/project/bin/libgoanna.linux.*.so)
cp "$lib" /out/
echo "built $(basename "$lib") at $REV"
ldd /out/$(basename "$lib")
echo "newest glibc symbol: $(objdump -T /out/$(basename "$lib") | grep -o "GLIBC_[0-9.]*" | sort -V | uniq | tail -1)"
'
ls "$out"/libgoanna.linux.*.so
