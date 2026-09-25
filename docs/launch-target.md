# Launch target

This is the acceptance checklist for a fresh Goanna install. It describes the
experience the project is trying to provide, not the history of how features
were implemented.

## A new player should be able to

- Build or install Goanna and reach a working menu.
- Start a new Luanti game or join a remote server.
- Select a world, game, generator, creative/damage mode and optional mods.
- Walk, jump, sneak, dig, place, fight, use inventories and formspecs, chat,
  hear sounds and see ordinary entities and weather.
- Understand performance through FPS, draw, object, triangle, queue and
  world-position diagnostics.
- Leave and return to a world without terrain being duplicated, lost or
  visually replaced by holes during LOD transitions.

## Rendering acceptance

- Near terrain uses the same world geometry and gameplay semantics as Luanti.
- Distant terrain has a contiguous conservative silhouette. Unknown data fades
  as atmosphere, not as transparent slices into caves or seabeds.
- LOD transitions retain the previous mesh until its replacement is ready.
- Water has an opaque far seabed representation; distant water is a surface
  effect over that fill, not a portal into underground terrain.
- Near and far materials use compatible colour, light, normal and PBR paths.
- Atmosphere provides altitude-aware mist, visible silhouettes and cloud mass
  without making the horizon uniformly white.
- Occlusion and batching reduce work in caves and behind large landforms.

## Compatibility acceptance

- A normal server can be joined without installing Goanna-specific mods.
- Optional capabilities are server-authorised through the documented control
  channel and do not silently change gameplay rules.
- Mineclonia is the primary compatibility target; devtest, minetest_game and
  other Luanti games remain useful regression targets.
- Luanti source transplants retain attribution and are easy to compare with
  their pinned upstream revision.

## Evidence required for a release

Each release candidate should include:

1. Native unit tests and Godot integration tests passing, the native tests
   through `cmake --build build --target check` so none of them is a stale
   binary, and `res://tests/asset_bundle_install.gd` among the Godot ones.
2. A clean build from a fresh checkout with submodules.
3. Every asset bundle the release relies on passing
   `tools/pbr_bundle.py verify`, which includes the height fill check
   (`tools/check-pbr-height.py`).
4. After an asset epoch is published, `tools/check-asset-catalogue.py
   --live` reporting a 200 of the catalogued size for every URL.
5. A short performance capture in an open landscape, a forest, a cave and an
   underwater scene.
6. A compatibility run against a normal Luanti server and the supported local
   game path.
7. Screenshots or captures for any changed visual system, with the relevant
   performance overlay enabled.

Items 1, 3 and 4 are described, with the defect each one exists for, under
"Release checks" in [building.md](building.md). The implementation details
behind the others live in [far-rendering.md](far-rendering.md),
[pbr-plan.md](pbr-plan.md), [validation.md](validation.md) and
[roadmap.md](roadmap.md).
