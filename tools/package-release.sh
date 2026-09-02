#!/usr/bin/env bash
# Export a genuine, standalone Goanna build: a Godot export plus the small
# slice of Luanti's own base texture pack it reads at run time from
# res://../luanti (see goanna_client.cpp, GoannaClient::connect_to). The
# GDExtension binary alone is not runnable; this is what makes something a
# player can unzip and run without building anything or cloning the repo.
#
# Usage: tools/package-release.sh <linux|windows> [version]
#
# Requires a Godot 4.5 binary on PATH as `godot`, or set GODOT_BIN. Requires
# the matching GDExtension binary already built (see docs/building.md) and
# Godot's export templates for 4.5.1 installed. Linux packages are verified
# by this script (run headless against GOANNA_HOST/PORT if set); Windows
# packages are exported but cannot be launched from Linux, so they are
# handed over unverified. Say so wherever they end up.

set -euo pipefail
cd "$(dirname "$0")/.."

PLATFORM="${1:-}"
VERSION="${2:-dev}"
GODOT_BIN="${GODOT_BIN:-godot}"

case "$PLATFORM" in
    linux)
        PRESET="Linux"
        STAGE="dist/linux-stage"
        EXE="Goanna.x86_64"
        ARCHIVE="dist/Goanna-${VERSION}-linux-x86_64.zip"
        ;;
    windows)
        PRESET="Windows"
        STAGE="dist/windows-stage"
        EXE="Goanna.exe"
        ARCHIVE="dist/Goanna-${VERSION}-windows-x86_64.zip"
        ;;
    *)
        echo "usage: $0 <linux|windows> [version]" >&2
        exit 2
        ;;
esac

rm -rf "$STAGE"
mkdir -p "$STAGE"
"$GODOT_BIN" --headless --path project --export-debug "$PRESET"
test -f "$STAGE/$EXE" || { echo "export did not produce $STAGE/$EXE" >&2; exit 1; }

# res://../luanti resolves relative to the executable, so the texture pack
# has to sit one level above wherever the exported files end up. Nest the
# export under Goanna/ inside the package so the layout works after unzip:
#   Goanna-<version>-<platform>-x86_64/
#     Goanna/          the export: exe, .pck, the GDExtension .so or .dll
#     luanti/           just textures/base/pack (~450 KiB), nothing else
#     pbr_packs/        bundled Minetest Game and Mineclonia material worldmods
python3 tools/check-pbr-packs.py
PKG="dist/Goanna-${VERSION}-${PLATFORM}-x86_64"
rm -rf "$PKG"
mkdir -p "$PKG/Goanna" "$PKG/luanti/textures" "$PKG/pbr_packs"
cp -r "$STAGE"/* "$PKG/Goanna/"
cp -r luanti/textures/base "$PKG/luanti/textures/"
cp -r pbr_packs/minetest_game pbr_packs/mineclonia "$PKG/pbr_packs/"
chmod +x "$PKG/Goanna/$EXE" 2>/dev/null || true

# Godot's exporter copies the GDExtension shared library itself (declared in
# goanna.gdextension) but knows nothing about ITS dependencies. On Windows
# libgoanna...dll dynamically links zlib1.dll and zstd.dll (vcpkg's
# x64-windows triplet is dynamic CRT, not static); Linux links zstd
# statically and treats libz as a near-universal system dependency, so it
# needs nothing extra. Bundle what Windows actually needs to launch.
if [ "$PLATFORM" = "windows" ]; then
    for dep in zlib1.dll zstd.dll; do
        if [ -f "project/bin/$dep" ]; then
            cp "project/bin/$dep" "$PKG/Goanna/"
        else
            echo "warning: project/bin/$dep not found, Windows package will not launch" >&2
        fi
    done
fi

if [ "$PLATFORM" = "linux" ] && [ -n "${GOANNA_HOST:-}" ]; then
    echo "Verifying against ${GOANNA_HOST}:${GOANNA_PORT:-30000}..."
    ( cd "$PKG/Goanna" && GOANNA_SMOKE=8 ./Goanna.x86_64 --headless 2>&1 | tail -5 )
fi

( cd dist && zip -qr "$(basename "$ARCHIVE")" "$(basename "$PKG")" )
echo "Packaged: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
echo "Run with: unzip, then Goanna/Goanna.x86_64 (or Goanna/Goanna.exe on Windows)"
if [ "$PLATFORM" = "windows" ]; then
    echo "Not launched. Nobody has run a Windows export of this yet: say so."
fi
