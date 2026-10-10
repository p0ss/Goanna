# Starting and joining

## Starting a game

Start Game lets you select an existing world or create one. New worlds can
choose the installed game's default generator or one of several Terrain
Diffusion worlds. Each is a whole 62 km world at a metre a node; they differ
in where they are, not in how detailed they are, and the picker shows a map
and a size for each. The one you choose downloads once, is verified against
its published hash, and is kept for later worlds; choosing a second world
does not discard the first. Generated data belongs to each world and is not
overwritten when the shared cache changes.

Do not select Terrain Diffusion for an existing populated conventional world.
The launcher rejects that combination because old mapblocks would remain and
produce two overlapping landscapes.

The same screen controls creative mode, damage, mods and optional hosting.
PBR companion maps are independently versioned assets rather than part of the
Goanna executable download. Install a bundle once and Goanna composes its
terrain, billboard and creature tranches under
`user://content/goanna-assets/profiles/<game>/textures`. The Materials dropdown
can also select a conventional installed texture pack such as Craft and Ruin,
or Standard to disable PBR.

When joining a remote server, choose **PBR: server materials**, an installed
game profile, or **Standard, no PBR** on the Join Game screen.
Remote selection is client-side and supplies only normal and material
companions, so a server's Iron, Stone or other style textures stay visible.
Hosting starts a normal Luanti server and can expose a name, description,
password, port, player limit and public-list announcement.

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
