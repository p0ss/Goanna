#!/usr/bin/env bash
# Export a genuine, standalone Goanna build: a Godot export plus the small
# slice of Luanti's own base texture pack it reads at run time from
# res://../luanti (see goanna_client.cpp, GoannaClient::connect_to). The
# GDExtension binary alone is not runnable; this is what makes something a
# player can unzip and run without building anything or cloning the repo.
#
# Usage: tools/release/package-release.sh <linux|windows> [version]
#
# Requires a Godot 4.5 binary on PATH as `godot`, or set GODOT_BIN. Requires
# the matching GDExtension binary already built (see docs/building.md) and
# Godot's export templates for 4.5.1 installed. Linux packages are verified
# by this script (run headless against GOANNA_HOST/PORT if set); Windows
# packages are exported but cannot be launched from Linux, so they are
# handed over unverified. Say so wherever they end up.

set -euo pipefail
cd "$(dirname "$0")/../.."

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

# The extension the export copied is whatever is in project/bin, which for
# Linux is built on the development machine against its own glibc. A release
# must carry the one tools/release/build-goanna-extension.sh builds in Ubuntu 22.04
# (GOANNA_EXTENSION), and the check below refuses anything newer than glibc
# 2.35: a library asking for GLIBC_2.43 does not load on SteamOS, Ubuntu LTS
# or Mint, and Godot then shows a grey screen (Steam Deck, 2026-10-03).
if [ -n "${GOANNA_EXTENSION:-}" ]; then
    test -f "$GOANNA_EXTENSION" || { echo "GOANNA_EXTENSION $GOANNA_EXTENSION not found" >&2; exit 1; }
    cp "$GOANNA_EXTENSION" "$STAGE/$(basename "$GOANNA_EXTENSION")"
fi
if [ "$PLATFORM" = "linux" ]; then
    GLIBC_MAX="${GOANNA_GLIBC_MAX:-2.35}"
    for so in "$STAGE"/libgoanna.linux.*.so; do
        newest=$(objdump -T "$so" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -V | uniq | tail -1)
        if [ "$(printf '%s\n%s\n' "$newest" "$GLIBC_MAX" | sort -V | tail -1)" != "$GLIBC_MAX" ]; then
            echo "$(basename "$so") needs glibc $newest, newer than $GLIBC_MAX: it will not load on" >&2
            echo "SteamOS, Ubuntu LTS or Mint. Build it with tools/release/build-goanna-extension.sh and" >&2
            echo "pass GOANNA_EXTENSION=dist/extension-linux/$(basename "$so")." >&2
            exit 1
        fi
        if ldd "$so" | grep -q 'libstdc++'; then
            echo "$(basename "$so") links libstdc++ dynamically; build it with tools/release/build-goanna-extension.sh" >&2
            exit 1
        fi
    done
fi

# The presets export all_resources, so anything left lying about under
# project/ goes into the pack. 0.9.0 nearly shipped 77 MB of test
# screenshots out of project/shots, which is gitignored and so invisible in
# git status. A pack that size is a mistake, not growth, so stop rather than
# quietly double what a player downloads.
PCK_MAX="${GOANNA_PCK_MAX:-16777216}"
PCK_BYTES=$(stat -c %s "$STAGE/Goanna.pck" 2>/dev/null || echo 0)
if [ "$PCK_BYTES" -gt "$PCK_MAX" ]; then
    echo "Goanna.pck is $PCK_BYTES bytes, past the $PCK_MAX byte limit." >&2
    echo "Something under project/ is being swept into the export. Look for" >&2
    echo "test output first, then re-run with GOANNA_PCK_MAX set higher if" >&2
    echo "the growth is real." >&2
    exit 1
fi

# res://../luanti resolves relative to the executable, so the texture pack
# has to sit one level above wherever the exported files end up. Nest the
# export under Goanna/ inside the package so the layout works after unzip:
#   Goanna-<version>-<platform>-x86_64/
#     Goanna/          the export: exe, .pck, the GDExtension .so or .dll
#     luanti/           just textures/base/pack (~450 KiB), nothing else
# PBR maps are independently versioned assets installed under user://content;
# they are deliberately absent from the code archive.
python3 tools/pbr/check-pbr-packs.py
PKG="dist/Goanna-${VERSION}-${PLATFORM}-x86_64"
rm -rf "$PKG"
mkdir -p "$PKG/Goanna" "$PKG/luanti/textures"
cp -r "$STAGE"/* "$PKG/Goanna/"
cp -r luanti/textures/base "$PKG/luanti/textures/"
# The AI game master's service (docs/director-setup.md): what a model's MCP
# app starts, and the shell bridge beside it. Python 3 with no dependencies;
# it reaches a world Goanna started through files in the world folder, so a
# player needs nothing from the repository.
mkdir -p "$PKG/Goanna/director"
cp tools/goanna-director-mcp tools/goanna-director-cli "$PKG/Goanna/director/"
chmod +x "$PKG/Goanna/director/"goanna-director-*
CORE_ASSET="${GOANNA_CORE_ASSET:-dist/assets/org.goanna.mineclonia.pack-1.3.1.zip}"
test -f "$CORE_ASSET" || { echo "missing core asset bundle: $CORE_ASSET" >&2; exit 1; }
mkdir -p "$PKG/assets"
cp "$CORE_ASSET" "$PKG/assets/"
chmod +x "$PKG/Goanna/$EXE" 2>/dev/null || true
# The version the in-client updater compares releases against
# (project/updater.gd). A source checkout has none and never updates itself.
printf '{"version": "%s", "platform": "%s"}\n' "$VERSION" "$PLATFORM" > "$PKG/Goanna/version.json"

# The launcher. Godot's own wrapper only runs the binary, so its log went to
# ~/.local/share/godot/app_userdata/Goanna, hidden on a Steam Deck or a
# child's account (owner, 2026-10-03). This one writes the client's and the
# local server's logs to a logs folder beside the package whenever that is
# writable (a USB drive, an unzipped folder in Downloads), keeps the last
# run's beside them, and falls back to Godot's default otherwise.
if [ "$PLATFORM" = "linux" ]; then
    cat > "$PKG/Goanna/Goanna.sh" <<'LAUNCHER'
#!/bin/sh
printf '\033c\033]0;%s\a' Goanna
base_path="$(dirname "$(realpath "$0")")"
logs="$(dirname "$base_path")/logs"
if mkdir -p "$logs" 2>/dev/null && [ -w "$logs" ]; then
    logs="$(realpath "$logs")"
    for f in goanna.log goanna_singleplayer.log; do
        [ -f "$logs/$f" ] && mv -f "$logs/$f" "$logs/previous-$f"
    done
    export GOANNA_LOG_DIR="$logs"
    exec "$base_path/Goanna.x86_64" --log-file "$logs/goanna.log" "$@"
fi
exec "$base_path/Goanna.x86_64" "$@"
LAUNCHER
    chmod +x "$PKG/Goanna/Goanna.sh"
fi

# The Luanti server Get ready to play sets up on a Linux machine with no
# Luanti (tools/release/build-luanti-server.sh; menu.gd, local_server.gd
# bundled_server). Beside the program, where bundled_server looks. Required:
# without it a Linux player with no Luanti and no Flatpak cannot start a world.
if [ "$PLATFORM" = "linux" ]; then
    SERVER_BUNDLE=$(ls -d dist/luanti-server/luanti-*-server-linux-x86_64 2>/dev/null | head -1)
    test -n "$SERVER_BUNDLE" || { echo "no Luanti server in dist/luanti-server: run tools/release/build-luanti-server.sh" >&2; exit 1; }
    mkdir -p "$PKG/Goanna/luanti-server"
    cp -r "$SERVER_BUNDLE" "$PKG/Goanna/luanti-server/"
fi

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
