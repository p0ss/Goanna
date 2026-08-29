# Goanna

Goanna is a Godot renderer and client for [Luanti](https://www.luanti.org/)
worlds. It connects to ordinary Luanti servers and uses the same protocol,
games, worlds and gameplay rules, while replacing the traditional client
renderer with Godot.

Goanna is an alpha-quality project. The Luanti client remains the reference
client for compatibility and reliability.

![A forested valley rendered in Goanna](docs/forest.png)

Goanna is first and foremost a graphics project: these screenshots show the
intended direction: large views, dynamic lighting and detailed materials while
remaining connected to an ordinary Luanti world.

| Landscapes | Lighting and materials |
| --- | --- |
| ![Village and surrounding terrain](docs/village.png) | ![Dynamic lighting](docs/light.png) |
| ![Underwater terrain](docs/underwater.png) | ![Lava and volcanic terrain](docs/lava.png) |

## Highlights

- Modern Godot lighting, shadows, materials and sky rendering.
- Luanti-compatible movement, interaction, inventory, formspecs, entities,
  sounds and particles.
- Multi-tier distant terrain with local persistence, server summaries and
  occlusion-aware rendering.
- Optional Terrain Diffusion worlds with a downloadable 1 m-per-node default
  bake.
- LabPBR material maps and an experimental Iris screen-space shader pipeline.
- Local-game hosting through an ordinary Luanti server on localhost.

## Try it

Goanna currently targets Linux, Godot 4.5 and a Vulkan-capable GPU. Luanti is
needed to start a local game; it is not needed when joining a remote server.

```sh
git clone --recurse-submodules --shallow-submodules \
  https://github.com/p0ss/Goanna.git goanna
cd goanna
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build
/path/to/Godot_v4.5.1-stable_linux.x86_64 --path project
```

The menu provides Start Game, Join Game, Content, Settings and About. See
[docs/players.md](docs/players.md) for controls, requirements, Terrain
Diffusion downloads and current limitations. See
[docs/developers.md](docs/developers.md) to build, test or extend Goanna.

## Compatibility and scope

Goanna does not modify servers and does not grant abilities by default. It
requests and displays no more than a normal client unless a server explicitly
enables an optional Goanna capability. It is not affiliated with or endorsed
by Luanti.

The most thoroughly tested game is Mineclonia. Other Luanti games and servers
may work, but the long tail of node drawtypes, animated textures, particles,
formspecs and item models is still incomplete. Windows and macOS are not
currently play-tested.

## Documentation

Player-facing documentation starts at [docs/players.md](docs/players.md).
Developer-facing documentation starts at [docs/developers.md](docs/developers.md).
The specialised references remain available for contributors:

- [Building and validation](docs/building.md), [requirements](docs/requirements.md)
- [Benchmarking graphics settings](docs/benchmark.md), [rendering baseline](docs/baseline.md)
- [Distant terrain](docs/far-rendering.md), [materials](docs/materials.md),
  [PBR plan](docs/pbr-plan.md)
- [Protocol coverage](docs/protocol-coverage.md), [capabilities](docs/capabilities.md),
  [control channel](docs/control-channel.md)
- [Iris compatibility](docs/iris-compat.md), [shader-pack testing](docs/shaderpack-testing.md)
- [Transplanting Luanti code](docs/transplanting.md), [validation](docs/validation.md)
- [Launch target](docs/launch-target.md), [roadmap](docs/roadmap.md)

## Contributing and licence

Build reports from machines other than the author's, compatibility reports,
focused tests and reviews of the Luanti transplant boundaries are especially
useful. See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/style.md](docs/style.md).

Goanna is LGPL-2.1-or-later. The complete dependency and media accounting is
in [THIRD-PARTY.md](THIRD-PARTY.md).
