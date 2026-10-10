# Goanna

Goanna is a game client for [Luanti](https://www.luanti.org/), the voxel
game engine formerly called Minetest. It is a standalone program built on
the Godot engine. It speaks Luanti's own network protocol to ordinary,
unmodified servers, plays the same games, worlds and rules as Luanti's own
client, and draws them with a renderer of its own: distant terrain to the
horizon, dynamic light and shadow, PBR materials, water, weather and sky.

It is alpha quality. Luanti's own client remains the reference for
compatibility and reliability, and Goanna is not affiliated with or
endorsed by the Luanti project.

![A forested valley rendered in Goanna](assets/forest.png)

## Find your part

**[Play](play/index.md).** Install Goanna, start a world or join a server,
learn the controls and settings, and see what does not work yet. Start
here if you want to play.

**[Host](host/index.md).** Run a server that Goanna players can join, grant
the optional capabilities of the Goanna server mod, and set up an AI game
master.

**[Develop](develop/index.md).** Build Goanna from source, run its tests and
benchmarks, follow the house style, and carry Luanti code across the right
way.

**[Agents](agents/index.md).** For coding agents and the people running
them: the rules for test clients and the GPU, the control channel that
drives a running client, the player agent interface and the director.

**[Systems](systems/index.md).** How each part of the renderer and client
works today: far rendering, terrain storage, materials, water, sky,
weather, lava, ice, particles, the interface and more.

**[Design](design/index.md).** Plans and proposals: the founding plan, the
roadmap, the far rendering and material plans, shader pack loading, server
capabilities and Freeminer servers.

**[History](history/index.md).** Dated logs and investigations, kept as
written, for anyone who wants to know why something is the way it is.

**[Releases](releases/index.md).** What changed in each version.

## Status

Linux is the supported platform, with Godot 4.5 and a Vulkan capable GPU.
Mineclonia is the most thoroughly tested game. Windows and macOS are not
play tested, and controller support has only been tested with synthetic
input. The [player guide](play/index.md) lists
the current limitations.

## Licence

Goanna is LGPL-2.1-or-later, except the texture packs under `pbr_packs/` and
the asset bundles built from them, which carry their source media's licence
per file. The full accounting is in
[THIRD-PARTY.md](https://github.com/p0ss/Goanna/blob/main/THIRD-PARTY.md).
The source is on [GitHub](https://github.com/p0ss/Goanna).
