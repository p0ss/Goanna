# Player guide

Goanna is an alternative Luanti client. You use the same account, servers,
games and worlds as with Luanti's own client. A server does not need to know
about Goanna for ordinary play.

## Requirements

The current supported development target is Linux with Godot 4.5 and a
working Vulkan driver. A discrete GPU is strongly recommended. Goanna renders
more lighting and distant terrain than the vanilla client, so performance
depends on GPU, CPU, view distance, shader settings and the server's streaming
limits. See [requirements.md](requirements.md) for measured guidance.

Luanti is required only for Start Game. Goanna launches the Luanti server
locally and connects through the normal protocol. Join Game can connect to a
remote server without a local Luanti installation.

## Starting a game

Start Game lets you select an existing world or create one. New worlds can
choose the installed game's default generator or Terrain Diffusion. Terrain
Diffusion's default 1 m world downloads a versioned bake once, verifies it,
and caches it for later worlds. Generated data belongs to each world and is
not overwritten when the shared cache changes.

Do not select Terrain Diffusion for an existing populated conventional world.
The launcher rejects that combination because old mapblocks would remain and
produce two overlapping landscapes.

The same screen controls creative mode, damage, mods and optional hosting.
Hosting starts a normal Luanti server and can expose a name, description,
password, port, player limit and public-list announcement.

## Controls

WASD moves, the mouse looks, Space jumps, Shift sneaks, and the left and right
mouse buttons dig and place. Number keys select the hotbar. `I` opens the
inventory, `T` opens chat, `F` toggles the free camera, and Escape opens the
pause menu. The exact bindings and camera options can be changed in Settings.

The performance overlay can show FPS, draw calls, object and triangle counts,
terrain queues, occlusion and world position. It is useful when reporting a
performance or streaming problem.

## Rendering options

Goanna's important visual systems are adjustable while connected:

- View and far distance control how much live and remembered terrain is drawn.
- Terrain occlusion removes regions hidden behind opaque nearby geometry.
- Material settings control normals, roughness, specular, emission, bevels and
  surface detail.
- Lighting settings control SDFGI, ambient light, lamps, shadows and shafts.
- Volumetric atmosphere controls valley mist and thick cloud volumes; set it
  to zero to disable the froxel volume on slower hardware.
- Player effect particles can be disabled independently of weather and block
  particles.

Terrain that has not arrived from the server cannot be reconstructed by a
normal client. Goanna can display remembered blocks and server-provided coarse
summaries when the server grants its far-rendering capability; otherwise the
horizon is limited by the server's send and generation distance.

## Current limitations

The project is alpha quality. Known gaps include some dropped-item models,
animated node textures, parts of particle behaviour, connected textures and
the long tail of game-specific formspec and drawtype behaviour. Shader-pack
support currently covers the screen-space composite/final path, not the full
world gbuffers pipeline.

When reporting a problem, include the game and server, whether it is a new or
existing world, your view/far distances, the performance overlay and a
screenshot if the issue is visual.
