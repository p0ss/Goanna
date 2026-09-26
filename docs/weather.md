# Shader weather

Rain and snow drawn by shader instead of by the server's particle spawners,
with splashes on open ground and rings on open water. Presentation only: the
spawners arrive exactly as before, nothing sent to the server changes, and
everything here is built from data the client already holds.

**Status: seen once, and it did not work.** The first live check (Godot
4.5.1, Mineclonia, the warm beach at Godot (515, 4, 447), noon, `/weather
rain`) showed no rain at all at the defaults, and bright curved arcs once
the opacity was raised tenfold by hand. "First live check" below says what
was changed for it. The changed version has been tested headless only;
nothing else in this file has been observed.

## Where weather comes from

Luanti has no weather in the protocol. A game that rains attaches particle
spawners to the player. Mineclonia's `mcl_weather` loops over two raindrop
textures (`weather_pack_rain_raindrop_1.png` and `_2.png`) and two flake
textures (`weather_pack_snow_snowflake1.png` and `2.png`), but its
`add_spawner_player` deletes every spawner the player has before adding one
under a new id, so one is running at a time: 500 a second for rain, 900 in a
thunderstorm, 100 for snow. The live check saw one rain spawner of 500.

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
  most one drop per 1.8 nodes of height (0.55 of the cells carry one at
  intensity 1), a random length of 0.45 to 0.85,
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
- Lit by the scene's own lights, with a light grey albedo and a share of
  the terrain's sky fill as emission, so a drop is as bright as its
  surroundings by day and dark at night, whatever the exposure. The light
  function has no facing: a drop takes 0.45 of a light from any side and up
  to all of it with the light behind it. Fogged, receiving and casting no
  shadow, outside global illumination.
- Peak streak opacity, before the taper, at 1080 lines and 70 degrees: 0.68
  on the nearest layer and 0.34 on the farthest. Opacity does not fall with
  intensity; density does. The layers fade out over their last 6 nodes top
  and bottom, and where the wall is seen edge on (looking steeply up or
  down).
- Nothing is drawn while the eye is underwater.

Intensity comes from the spawners' rate (amount a second for an endless
spawner, amount over time for a timed one), summed per kind and divided by
Mineclonia's own rates, 500 for rain and 100 for snow. It is clamped to
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
water normal on open water within 22 nodes, on top of the waves.

Rings for both come from `goanna_rain_rings` in
`project/shaders/weather_common.gdshaderinc`, which evaluates each cell alone,
so a ring is kept inside its cell: its largest radius is the distance from
its drop to the nearest cell edge, less the ring's width, and what is left of
its envelope fades out before the edge.

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

The control channel's `status` carries `weather`
(`weather.gd`'s `debug_state()`): the eased intensities, the spawner count,
whether a map is up and its area, and over the eye the cover height, whether
the eye is open, and `open_share`, the share of the map's columns open at
eye height. On an open beach that share should be near 1; if it is near 0
there, the map is what is hiding the rain.

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
  within about 22 nodes, and the same per water pixel within 22.
- The rain is lit now, so each streak pixel runs the light loop (the sun
  and any lamps in its cluster). Pixels with no streak are discarded before
  that.
- Against that, the particle path it replaces was up to 1500 GPU particles
  per spawner.

## First live check

Godot 4.5.1, Mineclonia, the warm beach at Godot (515, 4, 447), noon,
`/weather rain`. The weather node's state was right (intensity 0.5, the mesh
at the camera, one rain spawner), and nothing could be seen. Only with the
streak opacity raised tenfold, the intensity at 2 and the cover map switched
off together did faint streaks appear, with bright curved arcs on the right
of the frame. What was changed, headless:

- Opacity. Peak streak opacity had been 0.17 on the nearest layer, drawn
  unshaded in the sky gradient's colour, which is small beside sunlit sand
  once the exposure is applied. The rain is now lit by the scene's own
  lights, peaks at 0.68 near and 0.34 far, and is denser; the constants live
  in `weather.gd`, reach the material from there, and a test holds the peak
  to at least 0.5 near and 0.25 far.
- Intensity. The references assumed two Mineclonia spawners; there is one,
  so ordinary rain was drawn at half strength. Rain is now 1 and thunder 1.8.
- Arcs. The rain rings on water and ground were evaluated one cell at a time
  but could grow past their cell, so each was cut off by a straight line;
  with the sun in the water those cut rings are bright partial circles.
  Rings now stay inside their cells, and water rings stop at 22 nodes rather
  than 30. This is the likeliest source; it has not been confirmed on
  screen. The cylinders also fade out toward their rims and where seen edge
  on, in case an edge was the cause instead.
- The cover map. No fault was found in the lookup on reading, and a test now
  reads the uploaded texture back the way the shader does over an open beach
  and finds every point a layer draws at open, while an empty or part
  scanned map withdraws its area so the shader treats everything as open.
  The C++ scan against a real map is still untested; `open_share` in the
  status is the way to check it live.

## What is untested

Everything visual. In particular, the owner's visual check should look at:

- Whether rain can now be seen at all at the defaults, at noon on the beach,
  and whether it is too strong at night or in thunder. The constants are
  still guesses, now with a floor.
- Whether the arcs are gone, and if not, whether they move with the water
  (rings) or with the camera (cylinders).
- `open_share` in the status at the beach.
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
rain, thunder and snow, switching the setting both ways mid storm). It also
reads the cover texture back the way the shader does over an open beach and
checks no rain layer is covered there, that an empty or part scanned map
hides nothing, and that a roof does cover; and it prints the peak streak
opacity and fails if it is under 0.5 on the nearest layer or 0.25 on the
farthest, checking the material carries those constants. It renders nothing.
