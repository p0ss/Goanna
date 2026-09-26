# Shader weather

Rain and snow drawn by shader instead of by the server's particle spawners,
with splashes on open ground and rings on open water. Presentation only: the
spawners arrive exactly as before, nothing sent to the server changes, and
everything here is built from data the client already holds.

**Status: nothing in this file has been seen on screen.** It was written and
tested headless only (shaders compile, scripts parse, the logic has unit
tests). Every visual claim below is what the code is meant to do, not what
has been observed. See "What is untested" at the end.

## Where weather comes from

Luanti has no weather in the protocol. A game that rains attaches particle
spawners to the player: Mineclonia's `mcl_weather` sends two rain spawners
(`weather_pack_rain_raindrop_1.png` and `_2.png`) of 500 a second each, 900
each in a thunderstorm, and two snow spawners
(`weather_pack_snow_snowflake1.png` and `2.png`) of 100 a second each.

`project/ui/particles.gd` already recognised these by texture name (the
`is_weather` test: the name contains `rain` or `snow`) for `precipitation()`,
which drives wet ground (`goanna_wetness`) and the storm sky in `main.gd`.

With shader weather on, a weather spawner that follows the player (attached,
or given in player relative coordinates) is handed to `project/ui/weather.gd`
and no `GPUParticles3D` is built for it. Everything else keeps the particle
path, including a spawner with a rain texture fixed somewhere in the world,
since the shader only draws round the camera. `precipitation()` reports the
same either way, so wetness and the sky do not change with the setting.

## What it draws

**Falling rain and snow** (`project/shaders/precipitation.gdshader`). Four
open cylinders nested round the camera, radii 3, 6.5, 12 and 22 nodes, from
26 below to 34 above the eye, in one mesh surface: one draw call for all of
the weather. The mesh moves with the camera each frame. The pattern on each
cylinder is laid out in world units, so a far layer packs more and thinner
streaks into the same angle than a near one, and the nesting is what gives
depth. Layers are drawn outermost first and fade with distance.

- Rain: thin streaks in columns about 0.16 nodes apart, each column with at
  most one drop per 2.4 nodes of height, a random length of 0.45 to 0.85,
  falling at the spawners' own speed (Mineclonia's is 17.5 nodes a second)
  with a per column variation. Lines thinner than a pixel are drawn a pixel
  wide at their true coverage, so far layers do not sparkle.
- Snow: round flakes in cells about 0.55 nodes across, falling at the snow
  spawners' speed (2.5 for Mineclonia) with a slow sideways sway.
- Both lean with the wind. There is no wind in the protocol either; main.gd
  derives one for the grass from the cloud drift and the storm cover
  (`grass_wind`, strength 0.25 to 1), and the weather uses the same air,
  scaled so 1 is 7 nodes a second. On a main.gd without `grass_wind` the
  same rule is worked out in weather.gd from `cloud_speed` and
  `storm_cover`.
- Colour is the sky's (`goanna_sky_top` and `goanna_sky_horizon`), so rain at
  night is dark rather than white lines. Drawn unshaded, fogged, casting no
  shadow and outside global illumination.
- Nothing is drawn while the eye is underwater.

Intensity comes from the spawners' rate (amount a second for an endless
spawner, amount over time for a timed one), summed per kind and divided by
Mineclonia's own totals, 1000 for rain and 200 for snow. It is clamped to
0.3 to 2, so any running weather spawner is visible and a thunderstorm (1.8)
is heavier than rain (1). It eases over 2.5 seconds, so a storm starting,
stopping or turning to thunder (Mineclonia replaces its spawners then) does
not pop.

**Splashes** (`project/shaders/nodes_array.gdshader`, after the wetness
block). On up facing, open ground within about 22 nodes of the eye, while
rain is falling: each drop is a pale fleck for a moment, and where the ground
is wet (`goanna_wetness`) it throws a small ring carried only in the normal,
so it shows in the sheen. The scissor variant (leaves and plants) does not
splash.

**Rings on water** (`project/shaders/water.gdshader`). Expanding rings in the
water normal on open water within 30 nodes, on top of the waves.

Splashes and rings follow `goanna_rain` (what is falling now), not
`goanna_wetness` (which lingers for minutes after rain), so they stop with
the rain.

## Occlusion: the rain cover map

`project/ui/rain_cover.gd` keeps a 64 by 64 map, one texel per node column,
centred on the player: the top face of the highest node in the column that
would stop rain. The precipitation shader draws a drop only above it; the
splash and ripple terms apply only at or above it (with a margin of 0.55 for
a liquid surface, which sits a little below its node's top). So there is no
rain indoors, under a roof or under a canopy, while rain still falls past
the window of a house you are standing in, because the outer layers are
over open ground. The depth buffer hides any layer behind a wall.

The sky light the mesh carries already answers "is this under a roof", but
only at the faces of solid nodes. Rain falls through air, where there is no
face to ask, so the shader needs a height to compare a drop against.

What stops rain is decided in `GoannaClient::rain_cover_rows`: any walkable
node (roofs, glass, and leaves in every game checked), any liquid (its
surface is where rain lands), and allfaces_optional leaves in a game that
makes them walk through. Plants, torches and other walk through, see through
nodes do not, so rain reaches the ground in a meadow. Unloaded blocks are
skipped, never treated as solid.

Each column is scanned from 48 above the player to 32 below. A roof higher
than that (a cave ceiling far overhead) does not shelter, and a column with
nothing in the way reads as open to the scan floor.

The scan runs on the main thread, 8 rows (512 columns) a frame, into a
pending buffer that replaces the live map only when it is whole, so a half
old, half new map never draws a line of rain through a roof. A full map takes
8 frames. It rescans once a second while weather is falling, and at once
when the player has moved 6 nodes sideways or 10 up or down from the map's
centre. In fair weather nothing is scanned and the map is withdrawn.

The map reaches the shaders as three global uniforms, registered in
`project.godot`: `goanna_rain_cover` (the RF texture), `goanna_rain_cover_area`
(its world corner, size, and 1 once published) and `goanna_rain`. Off the
map, the precipitation shader and the water treat a point as open, and the
ground splash falls back to the sky light channel; both splashes and rings
fade out before the map's edge.

## The setting

**Shader weather** in the Video tab (`shader_weather`, on by default, shown
without opening Advanced), declared in `game_ui.gd` beside **Player effect
particles** and listed in `LOCAL_KEYS`. Off, weather spawners get their
particle emitters as before and the shader draws nothing, so there are no
splashes or rings either. Changing it mid storm rebuilds the running storm
the other way at once, from the spawners as they arrived.

## Expected cost

Not measured. What the code does:

- One extra draw call while weather is falling: 256 triangles, a
  transparent pass over whatever part of the screen the cylinders cover,
  with a handful of hashes per pixel and one texture read of the cover map.
  The overdraw is four layers deep across most of the view, which is the
  part to watch on a weak GPU.
- The occlusion scan: at most 512 columns a frame for 8 frames each second,
  each column read block by block under the map lock until it hits something.
  Open ground stops a few nodes down; the worst case is flying high over
  empty air, 80 nodes a column.
- On terrain and water: a uniform branch that costs nothing in fair weather;
  in rain, one texture read and two ring evaluations per up facing pixel
  within about 22 nodes, and the same per water pixel within 30.
- Against that, the particle path it replaces was up to 1500 GPU particles
  per spawner, and Mineclonia runs two.

## What is untested

Everything visual. In particular, the owner's visual check should look at:

- Rain density and streak look at Mineclonia's rain and thunder rates, in
  daylight and at night. The constants (column spacing, period, alpha, layer
  radii) are first guesses.
- Whether the layers read as depth or as sheets, and whether the pattern
  sliding with the player when walking forward is noticeable (only sideways
  motion is compensated).
- A roof edge from inside and outside, a doorway, a window, and tree canopy:
  rain should stop at the node boundary above, not at the camera.
- Looking straight up (the cylinders are edge on, so rain thins overhead) and
  straight down from a height (the layers end 26 nodes below the eye).
- The wind lean direction against the grass and clouds: the sign of the wind
  vector in world space has not been checked against a real frame.
- Snow: flake size, sway and drift.
- Splashes on open ground and their absence under roofs and trees, and the
  rings on a lake (the warm beach scene is a good place).
- Toggling the setting mid storm, and a thunderstorm starting.
- Frame time with and without shader weather.

Not done: a settling snow look on the ground, splashes on leaves and plants,
drops sliding down walls, and a lamp lighting nearby rain.

## Tests

`project/tests/weather.gd`, headless:

```sh
godot --headless --path project --script res://tests/weather.gd
```

It checks that the precipitation, water and nodes_array shaders compile with
the uniforms the scripts set, that the globals are registered, the rain
cover map against a stand in for `rain_cover_rows` (banding, whole map
publishing, texel placement matching the shader's lookup, recentring,
clearing), `GoannaClient.rain_cover_rows`'s binding with no world loaded, the
mesh, and the routing in particles.gd (rain and snow to the shader, other
spawners and world fixed rain to particles, intensities for Mineclonia's
rain, thunder and snow, switching the setting both ways mid storm). It
renders nothing.
