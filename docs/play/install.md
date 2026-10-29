# Installing Goanna

## What you need

The current supported development target is Linux with Godot 4.5 and a
working Vulkan driver. A discrete GPU is strongly recommended. Goanna renders
more lighting and distant terrain than the vanilla client, so performance
depends on GPU, CPU, view distance, shader settings and the server's streaming
limits. See [system requirements](requirements.md) for measured guidance.

Luanti is required only for Start Game. Goanna launches the Luanti server
locally and connects through the normal protocol. Join Game can connect to a
remote server without a local Luanti installation.

### Which Luanti Start Game uses

Goanna looks for Luanti where each kind of package puts it: distribution
packages (Debian and Ubuntu keep their games under
`/usr/share/games/minetest`), Flatpak (user and system installations), Snap,
AppImages in the usual folders, and on Windows the unpacked zip or the
self-extracting build. When it finds more than one, it uses the one you chose,
or else the first that has a game. **Change** on the Start Game screen lists
everything it found, with each install's games and data folder.

### Get ready to play

If Goanna finds no Luanti, or the one it found has no games, Start Game
offers **Get ready to play**: one button that gets both, with no password
and no package manager.

- **The server.** The Linux release carries its own Luanti 5.17.0 server
  (`Goanna/luanti-server/`), built unmodified from upstream and needing
  nothing from the system. Goanna copies it into its own data folder, where
  its worlds are kept. On Windows it downloads the official Luanti zip, as
  Install Luanti does below. Run from a source checkout on Linux, it uses
  `dist/luanti-server/` after `tools/release/build-luanti-server.sh`, or else
  Flathub.
- **The game.** Choose Mineclonia 0.123.1 (30 MB), VoxeLibre 0.92.3
  (85 MB), or Kindred Holdfast preview (177 MB, plus Mineclonia if missing).
  Downloads come from pinned Goanna mirrors on GitHub, with SHA-256 checks,
  and do not need ContentDB. Existing games are kept. Luanti's own Content
  tab can update upstream games or add others later.
- **Kindred Holdfast preview.** Installs the four Kindred packages together
  as a separate modpack on Mineclonia. Start Game selects Mineclonia and
  enables the modpack for a fresh world. This is a development preview;
  saved worlds may not migrate between previews. Separately installed
  Kindred packages must be moved aside before installing it.

It then opens Start Game with a new world ready. Checked from nothing to a
running world in clean Ubuntu 22.04 and 24.04, Debian 12, Fedora 42 and Arch
containers (`tools/test/test-fresh-install.sh`), and through the menu on Bazzite
with a GPU. The server needs glibc 2.35 or newer, so Ubuntu 22.04, Debian 12
or anything later. macOS has no Goanna release yet, so it is not covered.

**Choose Luanti myself**, or **Change** on the Start Game screen, opens the
list of what Goanna found instead, with these options:

- **Locate Luanti** takes the folder Luanti was unpacked into, its `bin`
  folder, the Luanti program itself, or an AppImage.
- **Install Luanti** installs the Flathub build on Linux (the confirmation
  shows the exact `flatpak` commands first). On Windows it downloads the
  official Luanti 5.17.0 zip from GitHub, checks it against the hash Goanna
  carries, and unpacks it into Goanna's own data folder, where its worlds are
  kept too. On macOS, or on Linux without Flatpak, use **Download page** or
  your distribution's packages instead.
- **Get ready to play** appears when the chosen Luanti has nothing to start,
  and installs your chosen game as above.
- **Open Luanti** starts that install's own client, where other games can be
  installed from its Content tab; press **Rescan** after.
- **Show where Goanna looked** lists every place it searched, for a bug
  report when your install is still not found.

Not yet tried on Windows itself: the Windows lookup, the Windows install and
Get ready to play on Windows have only been exercised against the real zip
unpacked on Linux.

To add another game later, open **Content > Install a game ...**. The
choices are the same as first-run setup. Downloads require a connection to
GitHub; the game archives are not bundled with Goanna.

## Maintaining the game mirrors

`tools/release/build-game-mirrors.py` prepares archives and records their
hashes, upstream sources and the Kindred source revision in `catalogue.json`
and `SHA256SUMS`. Upstream game archives retain all source and licence
files. Kindred is built from a named commit with `git archive`, which honours
its export exclusions and leaves unfinished checkout changes out.

Publish the archives, catalogue and checksums under an immutable
`games-YYYY.MM.N` GitHub pre-release. Keep it a pre-release so the updater
does not mistake it for a Goanna application release. Check every public
archive against its recorded SHA-256 before shipping the installer URLs in
`project/net/local_server.gd`. Never replace an already published archive;
use a new tag and update the installer pins instead.

## Updates

A downloaded release keeps itself up to date. When the menu opens it asks
GitHub for the newest release, and if there is one it offers **Update and
restart** on the main screen. The update downloads, is checked against the
maintainer's signature, replaces Goanna's own files and starts the new
version. Worlds, settings and materials are kept in Goanna's data folder and
are not touched. **About** shows the version you have, checks on demand and
can turn the check off. If Goanna is installed somewhere it cannot write to,
it says so and you download the new release yourself. A source checkout
never updates itself.

Releases before 0.11.0 do not have this, so moving from 0.10.0 means one
last download by hand.
