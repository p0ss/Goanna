# Goanna v0.9.0-alpha

Goanna 0.9.0 is mostly about the interface. Server forms are sent and drawn
the way the vanilla client sends and draws them, node items are drawn from
their own meshes rather than from a folded cube, and both sit under a new
dark glass style. The Luanti pin moves to 5.17.0, which brought animation
along several tracks with it. Away from the interface, lava draws as lava,
the sun stays out of caves, and a dig is measured from the shape a node
actually has.

## Changes

- **Luanti 5.17.0, and every animation track.** The `luanti/` submodule
  moves from 5.16.1 to 5.17.0: protocol version 53, formspec version 11.
  Entities play every animation track a 5.17 server sends, with priority,
  blend and start frame. Seen on fresh Mineclonia, Minetest Game and
  devtest worlds on the Luanti 5.17.0 Flatpak with Godot 4.5.1, and the
  older messages against a Luanti 5.10.0 server. Nothing between 5.10 and
  5.17 has been joined, and an entity the server hides still does not
  animate, where vanilla animates it.
- **Animated node tiles.** Tiles play their frames on the vanilla client's
  clock, the cube-like ones from animation arrays, so nothing changes per
  frame on the CPU. On a fresh Mineclonia world, 41 animated tiles and
  13.45 ms median frame time against 13.59 ms with the animation off. An
  animated node still shows its first frame as an inventory icon.
- **Formspecs sent and drawn as upstream does.** Buttons, labels, fields,
  slots, tooltips, hypertext, tables and scrollbars follow the upstream
  classes they come from, forms older than version 3 use upstream's element
  order, and a submission carries the fields `GUIFormSpecMenu::acceptInput`
  sends, not every control in the form. That last one is why Mineclonia's
  player settings back arrow saved the player's settings and showed itself
  again instead of returning to the inventory, in both styles and before
  the glass existed. Checked by 460 suite checks and side by side with the
  vanilla 5.17.0 client at 1600 by 900 on Mineclonia's forms, Minetest
  Game's and two of VoxeLibre's.
- **Node item icons drawn from the item mesh.** A node item without an
  inventory image takes upstream's item mesh, rasterised in software the
  way `drawItemStack` draws it, in place of a folded cube that read a mesh
  node's atlas as cube faces and made every stair and slab a cube. Against
  the vanilla client, Mineclonia's list slots are within 0.9 of 255 mean
  absolute difference per cell, where they were 4.4 to 70.7, and its
  creative inventory first opens in 80 to 89 ms against 170 to 178 ms. Flat
  inventory images still ignore a stack's colour metadata.
- **The dark glass interface style.** Settings, Appearance, Interface style
  chooses between Dark glass, now the default, and Game theme. In glass,
  Goanna's screens and every server form sit on panes that blur and darken
  the world behind them, a form's window chrome replaced and its content
  kept, with text a game wrote for a light theme lifted until it reads.
  Over snow, open sky, sand and water, a forest, a cave and a night at
  1600 by 900, interface text measures 9.1:1 or better and a slot's count
  4.6:1, and the glass costs 0.07 to 0.11 ms a frame with a form open, on
  an RTX 3090 another process was using at about 40 per cent. Dark and mid
  tone items stand out less on a glass slot tile than on Mineclonia's light
  grey slot, and the Minetest Game sweep and the main menu recapture were
  not redone after the GPU fault of 19 September.
- **Enhanced materials for Mineclonia, and a catalogue that resolves.**
  Mineclonia's material maps are published as `org.goanna.mineclonia.pack`,
  1021 normal and material map pairs, 95 MB, 177 of them authored by hand
  and the rest baked. Goanna asks for a bundle by itself once a server
  announces art the bundle covers. Every map was composed again for this
  release, and the first attempt at that was wrong: the bake had been
  pre-multiplying its height field by the material depth that
  `nodes_array.gdshader` applies again at draw time, so composing to that
  convention halved the relief of every baked stem, and the quality gate
  agreed because it enforced the same convention. Both now write the
  field across the byte and apply the depth once. The asset epoch the
  0.8.0 catalogue pointed at was never
  published, so until now every bundle URL answered 404 and no client could
  install one; the catalogue now names `assets-2026.09.2`, which is
  published, and Kythen terrain moves to 1.1.0 with it. Watched working
  on 20 September: a client with a fresh profile joined a Mineclonia
  world on a Luanti 5.17.0 server, fetched the archive from the
  published catalogue, checked it against its recorded hash, installed
  1021 pairs and composed its profile, with nothing in the log. That is
  the first time any client has installed a bundle. Three limits worth
  knowing. A bundle carries material maps only, so the art stays the
  server's own rather than the 256 px upscale the authored texture pack
  carries. A world hosted in Goanna serves those maps with no setting to
  find, where joining a remote server still means choosing Installed
  Mineclonia PBR on the Join Game screen, because the default choice hands
  the session no pack and a pack cannot be changed after connecting. And
  11 of the 1021 ship with a recorded quality failure, dirt, clay, podzol,
  the rails, a torch and a grass top, each a few per cent smoother than a
  band the classification review itself calls a default rather than a
  judgement; `asset_bundles/recipes/` names them and says why they ship.
- **The sun no longer shines into caves.** The sun's only occluder was the
  shadow map, and the server never sends the ground above a cave, so a cave
  had sunlit floor patches and shadows cast the wrong way. The node,
  foliage and entity shaders now scale every directional light by Luanti's
  own sunlight. On a copy of the reporting world, Luanti 5.16.1 and Godot
  4.5.1, the cave frame with the sun on matches the sun switched off to
  within the noise floor. Water, glass, ice and lava are not gated.
- **Lava draws as lava.** A real liquid at light level 6 or more takes its
  own shader and its source tile's artwork, flowing and falling blocks
  included. Near lava is subdivided to eight segments a node and carries a
  velocity field from the neighbouring liquid levels, so the art moves with
  the flow, dark texels rise as crust and the glow is the inverse of the
  same mask. Verified with Godot 4.5.1 on an RTX 3090 by fixtures and by
  captures from disposable Minetest Game and Mineclonia caves. The cost of a
  large lava lake near the player is not measured, a pack's separate flowing
  artwork is replaced by the source artwork, and the full animation strip is
  not played.
- **Digging carves the node's own shape.** Damage is measured from the
  surface a node actually has, derived from its own resolved boxes, so a
  blow on a slab, a stair or a ramp lands on that shape rather than on an
  inset from a cube's six faces. A stored carve shows a persistent crack
  stage to every player, and a game can claim the `goanna_carve` key so a
  client's guess never overwrites the game's own answer. The port of
  Kythen's rule matches the reference generated from its Lua over 7083
  checks, and in play it has been watched carving a cube on a Minetest Game
  world. No slab or stair has been watched carving against a server.
- **Luanti is found where it is packaged.** A report from a Pop!_OS machine
  said no game was installed: the lookup searched one user directory and one
  hard coded Flatpak path. Goanna now keeps every install it finds, packages,
  user and system Flatpak, Snap, AppImages, the Windows zip and source
  checkouts, reading each one's directories by Luanti's own rules, and a
  Luanti screen in the menu lists them, remembers the choice and can install
  one. Verified in an Ubuntu 24.04 container, where the scan found the
  package and its two games and brought a server up, and on this machine,
  where the 5.17.0 Flatpak and its eight games are found in 16 ms. Not
  verified: anything on Windows itself, the Flathub install end to end, and
  the machine the report came from.
- **Test clients stay off the owner's desktop.** In test mode Goanna never
  captures the OS pointer or asks for focus, `tools/goanna-headless` runs a
  client inside gamescope's headless backend, `tools/goanna-mcp` runs any
  number of them as named instances, and the control channel's `ui_*` and
  `key` commands drive a form from inside. Through the MCP server, on a
  fresh Mineclonia world: two instances at once, a form opened, read, typed
  into and clicked, and nothing of Goanna's on the desktop. That ran on
  software rendering because the GPU had faulted, so two headless clients
  sharing the GPU is an open risk to verify, not a result.

## Still alpha

Linux, Godot 4.5, Vulkan. Mineclonia is the most tested game, VoxeLibre
reaches only two forms of the parity pass, and every number here was
measured at 1600 by 900 on one RTX 3090. Other GPUs and other resolutions
are not covered. A Windows package is exported beside the Linux one, but no
Windows export has ever been launched by anyone; a report either way would
be useful. macOS is not built.
