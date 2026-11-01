# Starting and joining

## Starting a game

The main screen's first button is **Continue**, named with the world you
played last and its game ("Continue: Barrelreach, Kindred Holdfast"). It
starts that world again with the same game and settings. With no world
played yet, the first button is **New world** instead.

**Your worlds** lists every world as a table of world, game and last
played, newest first; search above it filters the rows. Choosing a row shows
its game, mods, play mode and hosting beside it, with **Play** in the
footer, **Change options** to change play mode, mods, materials or hosting
before playing, and **Delete world**, which asks first and moves the world
to `.goanna-trash` rather than deleting it.

**New world** takes four steps, each with a default, so Next, Next, Next and
Create makes a world: the game; the name and an optional seed (empty means a new
map each time); options (the world generator, materials, creative mode, damage
and mods); and hosting, which is off unless you tick Open to LAN. The world
generator can be the game's default or one of several Terrain Diffusion worlds.
Each is a whole 62 km world at a metre a node; they differ in where they are,
not in how detailed they are, and the picker shows a map and a size for each.
The one you choose downloads once, is verified against its published hash, and
is kept for later worlds; choosing a second world does not discard the first.
Generated data belongs to each world and is not overwritten when the shared
cache changes.

Do not select Terrain Diffusion for an existing populated conventional world.
The launcher rejects that combination because old mapblocks would remain and
produce two overlapping landscapes.

PBR companion maps are independently versioned assets rather than part of the
Goanna executable download. Install a bundle once and Goanna composes its
terrain, billboard and creature tranches under
`user://content/goanna-assets/profiles/<game>/textures`. The Materials dropdown
can also select a conventional installed texture pack such as Craft and Ruin,
or Standard to disable PBR.

When joining a remote server, choose **PBR: server materials**, an installed
game profile, or **Standard, no PBR** under Materials and shaders on the Join
a game screen.
Remote selection is client-side and supplies only normal and material
companions, so a server's Iron, Stone or other style textures stay visible.
Hosting starts a normal Luanti server and can expose a name, description,
password, port, player limit and public-list announcement.

Large mod sets and a new world's preparation can take longer to start than
an ordinary world. Goanna waits up to five minutes for the local server;
if startup times out, the message includes its log path.

## Server media

Goanna keeps the server's announced textures, sounds and models in
`user://cache/media`, shared across connections by content hash. Each join
checks the cached bytes against the server's hashes and downloads missing
or corrupt files. A changed file is downloaded again. If the cache cannot
be written, joining still continues with downloaded media.

The join screen distinguishes **Loading cached media**, **Downloading
media** and **Preparing world**. The download count excludes cache hits;
preparation loads the media into textures and models for the new session.
Before media is announced, the screen reports the connection or definition
stage and elapsed time. Preparation reports texture decoding counts, then
the texture pack, mapped materials and node visuals. Stages without a
known total use an indeterminate bar rather than a completed percentage.
Texture decoding yields between batches; pack loading and node visual
construction still run as individual main thread steps.

A failed local server start shows its error with the following Lua context
and the actual log path. **Open server log** opens that file in the
desktop's associated application; **Copy log path** copies the path.
This cache is separate from the enhanced material bundles below.

## Enhanced materials

Enhanced materials (the depth, gloss and relief on a game's surfaces) come
in bundles, one set for each supported game. The first time you join a
world whose materials you do not have, Goanna downloads them while you
join, and the connecting screen shows how far it has got. They are used
from that first visit. **Skip and play now** joins straight away with the
server's own art instead; the download carries on, and the materials apply
from your next connection. A server tells a client nothing about which game
it runs, so Goanna works it out from the textures the server sends, which
is why this waits until they have arrived. Settings, Updates, Download
material updates turns all of it off.

To run a server of your own for other players, see
[hosting](../host/index.md).
