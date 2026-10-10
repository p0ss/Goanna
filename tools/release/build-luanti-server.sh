#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Build a portable Luanti server for Linux from the pinned luanti/ submodule,
# unmodified, for the Linux release to carry. Upstream publishes no Linux
# build at all, only Windows and macOS ones, so a Linux player without
# Flatpak had no way to start a game without a package manager and a
# password. This server needs neither: Goanna copies it into its own data
# folder and runs it from there (local_server.gd, "goanna" installs).
#
# It is built in Ubuntu 22.04 so that it runs on glibc 2.35 and anything newer
# (Ubuntu 22.04 and later, so Pop!_OS 22.04 and Mint 21, Debian 12 and later,
# current Fedora and Arch), with
# LuaJIT, SQLite, zstd, zlib and the C++ runtime linked in statically. Only
# the server is built: no client, no curl, no gettext, no curses, no other
# database backends. RUN_IN_PLACE, so its data is the folder it sits in.
#
# Usage: tools/release/build-luanti-server.sh [output_dir]
#   default output: dist/luanti-server/
# PODMAN overrides the container command, for a machine whose default podman
# storage is broken, e.g.
#   PODMAN="podman --root $HOME/.cache/podroot --runroot $HOME/.cache/podrun"
set -euo pipefail
case "${1:-}" in -h | --help)
    # Usage is the header comment above.
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); if (/^(SPDX|Copyright)/) next
        if (!started && $0 == "") next; started = 1; print }' "$0"
    exit 0 ;;
esac
cd "$(dirname "$0")/../.."
repo=$(pwd)
out=${1:-$repo/dist/luanti-server}
podman_cmd=${PODMAN:-podman}
image=docker.io/library/ubuntu:22.04
# LuaJIT from its rolling v2.1 branch, pinned. Ubuntu 22.04's is 2.1.0-beta3,
# which Luanti warns is "known not to build/work correctly in all cases".
luajit_commit=c6ffc141a8762b41703f9287d63d93622a13dd8f
luajit_sha256=6e5fec07750add912e7c3eae0c194d24cd6d023714e1f04a0298a5b4819e4457

version=$(sed -n 's/^set(VERSION_MAJOR \([0-9]*\)).*/\1/p' luanti/CMakeLists.txt).$(sed -n 's/^set(VERSION_MINOR \([0-9]*\)).*/\1/p' luanti/CMakeLists.txt).$(sed -n 's/^set(VERSION_PATCH \([0-9]*\)).*/\1/p' luanti/CMakeLists.txt)
name="luanti-${version}-server-linux-x86_64"
mkdir -p "$out"
rm -rf "${out:?}/$name"

# shellcheck disable=SC2086
$podman_cmd run --rm \
	-v "$repo/luanti:/src:ro,Z" -v "$out:/out:Z" \
	-e NAME="$name" -e LJ_COMMIT="$luajit_commit" -e LJ_SHA="$luajit_sha256" \
	-e LUANTI_COMMIT="$(git -C luanti rev-parse HEAD)" \
	"$image" bash -euo pipefail -c '
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
	g++ make cmake ninja-build curl ca-certificates libsqlite3-dev zlib1g-dev libzstd-dev >/dev/null
lib=/usr/lib/x86_64-linux-gnu
curl -sSL -o /luajit.tgz https://github.com/LuaJIT/LuaJIT/archive/$LJ_COMMIT.tar.gz
echo "$LJ_SHA  /luajit.tgz" | sha256sum -c - >/dev/null
mkdir /luajit && tar -xzf /luajit.tgz -C /luajit --strip-components=1
make -s -C /luajit -j"$(nproc)" BUILDMODE=static PREFIX=/opt/luajit >/dev/null
make -s -C /luajit install PREFIX=/opt/luajit >/dev/null
# A RUN_IN_PLACE build writes its binary into the source tree, which is
# mounted read only, so it builds a copy.
cp -r /src /work
cmake -S /work -B /build -G Ninja -DCMAKE_BUILD_TYPE=Release \
	-DBUILD_CLIENT=FALSE -DBUILD_SERVER=TRUE -DRUN_IN_PLACE=TRUE \
	-DENABLE_CURL=OFF -DENABLE_GETTEXT=OFF -DENABLE_CURSES=OFF \
	-DENABLE_LEVELDB=OFF -DENABLE_POSTGRESQL=OFF -DENABLE_REDIS=OFF \
	-DENABLE_PROMETHEUS=OFF -DENABLE_SPATIAL=OFF -DENABLE_UPDATE_CHECKER=OFF \
	-DLUA_INCLUDE_DIR=/opt/luajit/include/luajit-2.1 -DLUA_LIBRARY=/opt/luajit/lib/libluajit-5.1.a \
	-DSQLITE3_LIBRARY=$lib/libsqlite3.a -DZSTD_LIBRARY=$lib/libzstd.a \
	-DZLIB_LIBRARY=$lib/libz.a \
	-DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++ -static-libgcc" >/build.log
ninja -C /build luantiserver >>/build.log
dest=/out/$NAME
mkdir -p $dest/bin $dest/games $dest/mods $dest/worlds
cp /work/bin/luantiserver $dest/bin/
strip $dest/bin/luantiserver
cp -r /src/builtin $dest/
# The placeholder files a run in place build carries, which is also how
# local_server.gd tells one from a system install.
cp /src/mods/mods_here.txt $dest/mods/
cp /src/games/games_here.txt $dest/games/ 2>/dev/null || true
mkdir -p $dest/textures && cp /src/textures/texture_packs_here.txt $dest/textures/ 2>/dev/null || true
cp /src/LICENSE.txt /src/README.md $dest/
cp /luajit/COPYRIGHT $dest/doc/LuaJIT-COPYRIGHT 2>/dev/null || { mkdir -p $dest/doc; cp /luajit/COPYRIGHT $dest/doc/LuaJIT-COPYRIGHT; }
mkdir -p $dest/doc && cp /src/doc/lgpl-2.1.txt $dest/doc/ 2>/dev/null || true
cat > $dest/NOTICE.txt <<NOTE
This is the Luanti server, built unmodified by tools/release/build-luanti-server.sh
in the Goanna repository from:

  Luanti  $LUANTI_COMMIT  (https://github.com/luanti-org/luanti)
  LuaJIT  $LJ_COMMIT  (https://github.com/LuaJIT/LuaJIT)

on Ubuntu 22.04 with GCC 11, with LuaJIT, SQLite, zstd, zlib and the C++
runtime linked in statically. Luanti is LGPL-2.1-or-later (LICENSE.txt,
doc/lgpl-2.1.txt); LuaJIT is MIT (doc/LuaJIT-COPYRIGHT). The source of both is
at the addresses above, and the Luanti source at that commit is also the
luanti/ submodule of https://github.com/p0ss/Goanna.
NOTE
chmod -R a+rX $dest
echo "built $dest"
ldd $dest/bin/luantiserver
'
printf '%s\n' "$out/$name"
