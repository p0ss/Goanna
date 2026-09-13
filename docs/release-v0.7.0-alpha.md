# Goanna v0.7.0-alpha

Goanna 0.7.0 adds downloadable material and terrain assets, a world picker,
and a licence gate for the art that goes into them. It is a larger release
than 0.6.1, and parts of it are groundwork whose player-visible half is not
finished.

## Enhanced materials as versioned assets

PBR companion maps are no longer part of the executable download. They are
independently versioned ZIP bundles, verified against a published SHA-256
before they are installed, and composed into a per-game texture profile. A
bundle carries its own manifest, and the runtime rejects unsafe archive
paths, payload hashes that do not match, and normal/material maps that do not
form complete pairs.

The catalogue that indexes them is a tracked file served from this
repository, so a client sees new bundles by refetching one small file rather
than by being rebuilt. Bundle URLs are absolute and point at an immutable
release, so the archives never move even though the index does.

## Choosing a world

Terrain Diffusion used to mean one world named by seven constants. There are
six now, listed in `project/terrain_worlds.json`, and world creation shows a
map, a size and a description for each. They are published as
`worlds-2026.09.1` on the Terrain Diffusion repository.

The default is the same landscape Goanna has always shipped, cut down to the
part a Luanti world can actually reach: its 25 tiles are byte for byte the
tiles of the old bake, and the 231 discarded ones lay past the edge of the
map. That is an 86.2 MB download replaced by 7.2 MB. Its starting point
moved from 398 m in a rain shadow to a coast at 6 m with fresh water nearby.

## Licence gate for community art

Every baked source now passes `tools/check-pbr-licenses.py`. A package whose
notice covers all its media passes on that notice; a package with a mixed
notice is qualified only by the exact licence recorded against each selected
file at intake, and fails if that mapping is missing, if any file carries no
exact licence, or if any recorded licence is outside the accepted set. GPL
family media is rejected outright and cannot be admitted through the per-file
path.

Attribution shipped inside every bundle no longer names the absolute path the
source game was installed at.

## The free camera is no longer offered on other people's servers

F toggled a camera that detaches from the player: `step_player` stops running
while it is on, so the camera leaves the body behind and passes through
terrain. That is reach a vanilla client does not have, and on a community
server it is a cheat. It is now accepted only on a server this client started
for itself. The documentation previously claimed flying moved the player
position the server sees, which was false.

## Ice, and what is under the water

Ice has procedural internal fractures and depth-writing transmission, drawn
through a separate background view so it does not fight water's transparency
ordering. Ice also keeps ownership of its interface with water, so an
underwater view no longer sees through missing side faces. Validated in a
disposable Mineclonia ice fixture on Luanti 5.17.0 and Godot 4.5.1, including
submerged sides and waterline captures.

## Distant terrain and streaming

The largest body of work in this release, and mostly invisible until it goes
wrong:

- Prepared terrain persists through bounded worker queues, and raw caches are
  bound to node definitions rather than rebuilt per request.
- Provisional coverage is retained while its replacement loads, and near
  meshes are kept until the far replacement is actually published, so walking
  or flying does not open holes.
- Detail is selected by projected size and altitude rather than by distance
  alone, sparse regions cost less to capture, and boundary faces extend to
  the neighbouring detailed ground.
- Far region skirts wound both Z faces the same way once the mesher's Z
  mirroring was accounted for, so back-face culling dropped one of every
  pair and opened repeated horizontal cracks through every terraced far
  hillside. The winding split now matches the box mesher's edge directions,
  covered by a test that asserts each of the four skirt directions.

Remaining terrain transitions, frontier coverage limits and the cost of the
ice background view are documented rather than claimed as solved.

## Starting a local game

Start Game could only find Luanti on PATH or as the org.luanti.luanti
flatpak. A Snap install puts its wrapper on an interactive shell's PATH,
which the desktop session launching Goanna does not necessarily have, and a
distribution package can put its games where the old lookup never searched.
The data directory now follows whichever install answered instead of assuming
`~/.minetest`. A world whose PBR profile is present but incomplete now says
so rather than starting with half its materials.

## The bake pipeline behind the art

- Sources are staged from `COMMUNITY_LOCK.json`, each archive checked against
  the hash the lock records, because the licence audit is written against the
  archive the lock names.
- A bake reuses a previous run's saved generations and produces only the
  gaps, which turned a six to seven hour re-bake into two and a half hours
  after a reboot took a night's work off tmpfs.
- The acceptance gate measures the texels the source actually authored
  instead of averaging whole images including the neutral fill written into
  cut-outs. That removed 59 false failures on community billboards and
  uncovered 31 real ones whose height never reaches its reference inside the
  art.
- Minetest Game's terrain tranche is baked from pinned ContentDB release
  38214 rather than whatever copy was installed on the baking machine.

## Lighting and materials

- LabPBR perceptual smoothness converts to Godot's perceptual roughness with
  `1 - smoothness`. Goanna squared that value before Godot squared it again,
  which read every surface with a companion map as polished.
- Lamp shadows and direct lamp admission share one budget, so an unshadowed
  lamp can no longer light the inside of a wall it should not reach.
- Light-source ownership is carried explicitly through the mesher instead of
  being guessed from a triangle's position, which failed for thin torch and
  lantern models and let them cast shadows from their own flame.
- Emission masks are attenuated in linear light, so partially glowing texels
  are not suppressed twice.
- Dry bark keeps a roughness floor, and stone and brickwork keep their
  authored UVs instead of being shifted per node.
- An Appearance tab separates look preferences from the hardware quality
  profile, and clear air moved out of the Environment into the atmosphere
  volume so mist composites over sky and terrain alike.

## Not finished, and not claimed

The default-look work in this release is a checkpoint. Two review passes were
rejected; `docs/default-look.md` records what landed and what is open,
including that the daylight treatment is too slight to call an overhaul and
that the shared lamp and shadow budget can drop visible room lighting as the
camera moves.

Downloading and creating a Terrain Diffusion world from the published
archives has been done and observed. Installing a material bundle from a
served catalogue has not: that path is verified as far as the download, the
hash and the unpacking, and no further.

There are no PBR companion maps for Asuna. It renders with the server's own
textures. A bake exists but has not been packaged, audited or published.

`tools/check-pbr-quality.py` reports strong wrap seams for review rather than
failing them, and High Basin has water standing above its bank on about a
tenth of its water perimeter, which steep terrain makes more likely.

## Still alpha

Goanna remains an alpha-quality Linux project targeting Godot 4.5 and a
Vulkan-capable GPU. Mineclonia is still the most thoroughly tested game, and
the Luanti client remains the compatibility reference. Windows and macOS are
not play-tested.
