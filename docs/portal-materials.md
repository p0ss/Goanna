# Portal materials

`portal_nether.gdshader` and `portal_end.gdshader` draw Mineclonia's
`mcl_portals:portal` and `mcl_portals:portal_end`. Routing comes from the
received node definitions and their resolved face textures, including pack
replacements and animation frames. Blank sides and portal frames keep their
ordinary materials. No server changes are required.

The Nether sheet combines a world-anchored, warped purple field with the
server's animated artwork. Screen-space refraction samples the opaque
scene; depth checks reject samples in front of the sheet. The source alpha
controls blending against the actual framebuffer, preserving transparent
objects drawn behind the portal. Refraction adds the difference between
the bent and straight opaque samples. Clear texels contribute no colour,
glow or distortion; opaque texels transmit nothing. Emission follows frame
contacts, with a soft falloff and a slow pulse, instead of outlining every
node. Mesh contacts use the full-cube occlusion rule and the shader can
also read the lamp occlusion grid. The mesh contacts remain when that grid
is disabled. See [mesh attributes](mesh-attributes.md).

The End sheet intersects the view ray with eight virtual planes. Each has
its own star spacing, orientation and depth. Teal, pale gold and occasional
violet stars sit above a dark cloud field. Pixel footprints soften small
stars and fade unresolved detail. The real sheet stays opaque and writes
its original depth, so the effect does not reveal terrain beneath it.
Both shaders use the player's node-animation clock; the procedural motion
loops over its 60-second wrap.

Both sheets use the shared underwater absorption function. The Nether
sheet attenuates its own colour and glow; its screen samples and the scene
behind it have already been absorbed. The End sheet uses the distance to
the real surface, not the imaginary depth of its star planes. The shared
function clips the water path at the surface and accounts for scene fog.

## Checks

Build the extension before the server check:

```sh
cmake --build build -j 2
python3 tools/test/test-portals.py --game /path/to/mineclonia \
    --server /path/to/luantiserver
```

The runner creates a disposable singlenode world, starts an ordinary
Luanti server, checks the actual materials with Godot's dummy renderer,
and stops both processes. It checks both portal routes, server texture
animation, player-scoped shader globals, frame-contact data and blank side
faces. `--pack /path/to/textures` repeats it with a replacement pack. No GPU
or desktop window is used.

The offline visual study uses synthetic tiles and separate node quads:

```sh
tools/goanna-headless gpu-free
tools/goanna-headless fixture res://portal_study.tscn --size 1280x800
```

It captures both materials, a moved camera, a zero-depth End comparison,
a foreground object, the Nether rim with the grid disabled, the clock
wrap, source alpha extremes, transparent objects behind the membrane and
both sheets under water. Images go to `/tmp/goanna-portal-review`, or
`GOANNA_PORTAL_OUT` when
passed through the launcher's `--env` option. The study checks rendered
changes from animation and parallax, rim continuity without the grid, and
the clock wrap. It also checks transparency behind the Nether sheet in air
and under water, clear and opaque source coverage, and stronger red than
blue absorption for both materials. These are offline images, not a
live-server capture.

## Recorded result

On 2026-10-05, Godot 4.5.1 on an RTX 3090, the initial offline study passed
four image checks: animation, End parallax, the Nether rim with its grid
disabled and the 60-second clock wrap. The foreground bar was inspected
visually. [Captures](perf/portals-2026-10-05/README.md) are from that initial
offline study with synthetic textures, before the absorption and alpha
blending fixes, not from a live game.

The expanded study adds seven checks for source coverage, transparent
objects, underwater colour absorption and avoiding repeated absorption of
transmitted light. It parses with Godot 4.5.1. Rendering these checks is
pending; the shared GPU was occupied during this revision.

A local Luanti 5.17.0 server running Mineclonia (game release 38561) passed
the material-routing test using Godot 4.5.1's dummy renderer, both without
a pack and with `pbr_packs/mineclonia/textures` (3859 native replacements).
Both portal shaders reached real node meshes, animated their source
textures, used player-scoped globals and left blank sides alone. The Nether
mesh carried frame-contact bits without a lamp grid. Visual appearance
against the live server has not been captured.
The pack-enabled routing check also passed after the absorption and alpha
blending fixes.

## Limits

Nether refraction uses the opaque screen buffer. Other transparent objects
remain visible but undistorted, subject to Godot's usual transparent
sorting. Refraction near the screen boundary is clamped. Frame contacts
recognise full opaque cubes, not partial shapes. The End starfield is
procedural; a pack still supplies coverage, but does not replace the stars.
