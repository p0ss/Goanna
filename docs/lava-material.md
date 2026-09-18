# Lava material

The lava renderer uses the selected pack's source artwork for a whole liquid
family, including its flowing blocks. It recognises real liquids with a
node light level of at least 6. Water and solid nodes retain their materials.
The source and special flowing texture IDs resolve to one shared surface
texture, including Luanti's extracted first frame for animated tiles.

## Surface and flow

`src/goanna_lava.cpp` subdivides nearby lava at eight segments per node and
samples a continuous velocity field from neighbouring liquid levels. The
velocity is interpolated in world space, including across mapblock borders.
The lava shader uses world position for texture coordinates. Its single
oblique projection stays continuous around top/side corners, without
rotating the artwork independently on each block. Two overlapping advection
cycles bound stretching over time.

Dark texels become rough crust rising up to 0.14 nodes above the melt.
Height, darkening and emission suppression share a mesh-filtered luminance
mask. Saturated red detail can form crust even when its red channel is as
bright as the yellow melt. Normals follow the same mesh-filtered height
field, using central differences to smooth the individual triangles while
keeping the raised regions aligned with the dark crust.
Emission uses the inverse of that same animated crust mask, squared, with
no independent glow pulse. The dark raised regions and bright low regions
therefore travel together across tile boundaries.
Every face samples the same height and displacement direction at a shared
world position. The direction follows the liquid occupancy gradient, so
crust protrudes from vertical falls as well as flat pools. Geometry fades
out between 32 and 80 nodes; distant lava uses the same artwork and glow,
without subdivision. The source texture supplies the colours and shapes;
a uniformly bright texture remains molten instead of acquiring extra rock.

Native material setup measures the selected source artwork in linear colour.
The shared mask uses its 20th to 80th luminance percentiles, rather than a
fixed range tuned to one game. Nearly uniform or wholly bright artwork
reduces crust strength. This calibration is shared by near and distant
materials; Mineclonia's darker orange tile therefore stays visibly molten.

Raised crust settles smoothly to zero height over the last 0.6 nodes of
the liquid footprint. Coverage comes from neighbouring liquid occupancy,
including the layer below at waterfalls, rather than individual tile UVs.
The normal follows the taper too, so a flat flow edge does not retain the
lighting of a tall rock. Internal block edges keep their relief.
Descending liquid is exempt from shoreline taper, so the exposed sides of
a waterfall retain their crust.

Lava meshes stay outside regional batching. Their UV attribute carries the
projected flow vector; the dedicated shader does not need tangent data.
Vertex colour alpha carries shoreline coverage; RGB keeps the pack's tint.
`CUSTOM1` carries the shared world-space displacement direction as RGB floats.
Other node attributes retain their meanings. No screen texture or additional
render pass is required.

## Surrounding light

Exposed liquid lamps sit above the emitting surface rather than buried at
the node centre, below the bank's top. Covered liquid cells do not consume
lamp slots unless they have an exposed side. Nearby liquid lamps are spaced
at least 3.5 nodes apart so the shadow budget covers more of the shoreline.
The existing shadowed pool and fading behaviour are retained. Flowing liquid
light colour comes from its special tile rather than its unused inventory
tile.

Surface emission is 4.8 times the squared normalised node light level.
Spaced liquid lamps receive 2.5 times ordinary lamp energy at the same level,
and exposed top lamps sit 1.15 nodes above their cell centre. This lifts the
glowing surface and the light on flat banks independently. Torch energy,
light range, attenuation and the shadow budget are unchanged.

Liquid light spacing uses world-key order before camera ranking, with a
two-node improvement required to replace one liquid lamp with another inside
the retention window. This avoids small camera movements reshuffling a
waterfall's emitters. Liquid lamps have no point-light specular component:
those sharp moving reflections misrepresented the broad emitting surface.
The lava material itself is rougher, with roughness 0.72 to 0.96.

## Review

Run with a graphics device:

```sh
../Godot_v4.5.1-stable_linux.x86_64 --path project \
    --script res://tests/lava_material.gd
../Godot_v4.5.1-stable_linux.x86_64 --path project \
    --script res://tests/lava_continuity.gd
```

The material fixture compares rocky and mostly molten control textures with
an authored tile over a pool, slope and fall. `GOANNA_LAVA_TEXTURE` accepts
an external tile or vertical animation strip for the third lane.
`GOANNA_LAVA_TEST_OUT` sets the capture directory. `GOANNA_LAVA_PLAYBACK=1`
compares frames three real seconds apart instead of setting a fixed time.

The continuity fixture compares one surface with four independently drawn
meshes split at world X=16, then compares the raised silhouette with zero
height. Zero shoreline coverage must also match the flat surface's geometry
and normals. Captures go to `/tmp/goanna-lava-continuity`.

`tools/lava-review/capture.py` captures an isolated live server fixture,
including lava lamps on/off with the camera light unchanged. It restores
animation and lamp energy even on failure. Its default control port is
30879; use this only with the disposable test client.

The [sealed cave review](perf/lava-cave-2026-09-17/README.md) compares a
spreading source with a torch, and records the brightness on exposed floor
tiles beyond the flow. `tools/lava-review/cave.lua` builds its disposable
world fixture; `cave_capture.py` captures the two rooms on control port 30880.

The [waterfall review](perf/lava-fall-2026-09-18/README.md) checks camera
sidesteps, native corner continuity and raised dark crust. Run
`project/tests/lava_coupling.gd` to compare emitted brightness with actual
displaced height at two animation times over adjacent tile meshes.

The [Mineclonia review](perf/lava-mineclonia-2026-09-18/README.md) reproduces
the in-game dark-fall report with the selected authored texture pack,
validates texture-relative calibration over four flow phases, and compares
the supplied stylised material through the native falling-liquid renderer.

Verified on 17 September 2026 with Godot 4.5.1, Forward+, RTX 3090:

- Native extension build and shader compilation passed.
- Splitting the displaced surface produced zero changed pixels; raising the
  crust added 7,783 pixels to the silhouette.
- Three-second playback checks passed with Pixel Perfection, Everness and
  AOM textures. Screenshots retain Everness's darker islands; AOM's nearly
  uniform glowing tile remains almost flat. These are texture checks, not
  full integration tests of all three games.
- A real Minetest Game source spread over a raised platform. Source and
  flowing surfaces shared the shader and artwork. The live fixture contained
  239,850 lava vertices over 25 surfaces in the final lighting capture.
- With only the lava lamps disabled, an exposed rock patch fell from mean
  RGB (79,39,24) to (3,6,19), confirming warm local illumination independently
  of the camera light. Lighting remains limited by the shadow lamp budget.

## Limits

Brightness is a heat estimate, not an authored material mask. Bright grey
rock can be treated as melt and unusually dark magma as crust. Other glowing
liquids can also enter this material; lava with light level below 6 will not.
The shader animates the source frame itself rather than playing the full
pack animation strip. A pack's separate flowing artwork is deliberately
replaced by the source artwork to keep the surface connected.

The flow field moves texture features rather than tracking individual
physical rocks. Fine features can blend during the advection cycle. Dense
lava adds geometry and mesh preparation cost; subdivision is limited to the
near renderer, but large nearby lava lakes still need performance review.
