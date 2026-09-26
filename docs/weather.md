# Shader weather

Rain and snow drawn by shader instead of by the server's particle spawners,
with splashes on open ground and rings on open water. Presentation only: the
spawners arrive exactly as before, nothing sent to the server changes, and
everything here is built from data the client already holds.

**Status: seen twice, not right yet.** Both live checks were Godot 4.5.1,
Mineclonia, the warm beach at Godot (515, 4, 447), noon, `/weather rain`.
The first showed no rain at the defaults; the second showed streaks at the
defaults, but gathered in one narrow band, with the sky speckled and bright
arcs, all turning with yaw. "Live checks" below says what was changed after
each. The version after the second has been tested headless only; nothing
else in this file has been observed.

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

- The pattern is fixed to the layer, which turns with the camera: walking
  sideways takes the rain with you rather than past you (see "Live checks"
  for why nothing tries to hold it still).
- Rain: thin streaks in columns about 0.16 nodes apart, each column with at
  most one drop per 1.8 nodes of height (0.55 of the cells carry one at
  intensity 1), a random length of 0.45 to 0.85,
  falling at the spawners' own speed (Mineclonia's is 17.5 nodes a second)
  with a per column variation. Lines thinner than a pixel are drawn a pixel
  wide at their true coverage, and columns under 5 pixels apart or streaks
  under 8 pixels long fade out, so far layers thin out rather than
  sparkle. At 1080 lines the farthest layer's columns are 5.6 pixels apart.
- Snow: round flakes in cells about 0.55 nodes across, falling at the snow
  spawners' speed (2.5 for Mineclonia) with a slow sideways sway.
- Both lean with the wind. There is no wind in the protocol either; main.gd
  derives one for the grass from the cloud drift and the storm cover
  (`grass_wind`, strength 0.25 to 1), and the weather uses the same air,
  scaled so 1 is 7 nodes a second. On a main.gd without `grass_wind` the
  same rule is worked out in weather.gd from `cloud_speed` and
  `storm_cover`. The lean, drift per node of fall, is held to 0.35 so the
  shear it puts on the pattern can never fold it (`lean_along` in the
  shader); rain in the strongest wind would lean 0.41, and snow in any real
  wind is held well short of its true drift.
- Lit by the scene's own lights, with a light grey albedo and a share of
  the terrain's sky fill as emission, so a drop is as bright as its
  surroundings by day and dark at night, whatever the exposure. The light
  function has no facing: a drop takes 0.45 of a light from any side and up
  to all of it with the light behind it. Fogged, receiving and casting no
  shadow, outside global illumination.
- Peak streak opacity, before the taper, at 1080 lines and 70 degrees: 0.68
  on the nearest layer and 0.34 on the farthest. Opacity does not fall with
  intensity; density does. The layers fade out over their last 6 nodes top
  and bottom, and between 45 and 60 degrees above or below the eye, where
  the wall is seen edge on.
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

## Live checks

### First

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
  than 30. That was a real fault, but not the arcs: the second check found
  them in open air (below).
- The cover map. No fault was found in the lookup on reading, and a test now
  reads the uploaded texture back the way the shader does over an open beach
  and finds every point a layer draws at open, while an empty or part
  scanned map withdraws its area so the shader treats everything as open.
  The C++ scan against a real map is still untested; `open_share` in the
  status is the way to check it live.

### Second

Same place and time. Status: rain 1.0, `eye_open` true, `open_share` 0.87,
cover over the eye 2.5, so the map was not hiding anything. Streaks were
visible at the defaults, over sky and sand, but three faults remained, all
turning with yaw: the rain gathered into one narrow bright band (straight
ahead at yaw 60), the rest of the sky was speckled with sub pixel white
dots like stars, and bright curved arcs hung in open air (upper right at
yaw 0, which is the same direction as the band).

All three were one fault. To keep the rain still in the world when the
player walked sideways, the column coordinate carried the camera's world
position along each layer's tangent. That term changes round the turn at a
rate of the camera's distance from world zero, about 680 nodes at the
beach, against layer radii of 3 to 22. In most directions it squeezed a
layer's columns far below a pixel (the stars); in the two directions square
to the camera's position it spread them back to their proper size (the
band); and between, where it cancelled the arc length exactly, one column
was smeared across the view (the arcs). The wind's shear had the same
fault, smaller, measured from world zero instead of the eye. What changed:

- The column coordinate is arc length alone. No shift keeps the pattern
  still in every direction at once on a cylinder round a moving camera, so
  there is none, and the rain moves with you sideways.
- The shear is measured from the eye, the lean is held to 0.35, and the
  edge on fade now ends at 60 degrees, so the column coordinate advances at
  no less than 0.39 of its calm rate anywhere a layer is drawn.
- Minification, for the specks the far layers could still make at low
  resolution: columns under 5 pixels apart fade, and so do streaks under 8
  pixels long (flakes likewise by their cell size).

## What is untested

Everything visual. In particular, the owner's visual check should look at:

- Whether rain now fills the view evenly at every yaw, with no band, no
  specks in the sky and no arcs.
- Whether it is too strong at night or in thunder. The constants are still
  guesses, with a floor.
- Whether the layers read as depth or as sheets, and whether rain moving
  with the player, sideways and forwards, is noticeable. For snow it may be.
- A roof edge from inside and outside, a doorway, a window, and tree canopy:
  rain should stop at the node boundary above, not at the camera.
- Looking up or down past 45 degrees (the rain fades out by 60) and straight
  down from a height (the layers end 26 nodes below the eye).
- The wind lean direction against the grass and clouds: the sign of the wind
  vector in world space has not been checked against a real frame.
- Snow: flake size, sway and drift.
- Splashes on open ground and their absence under roofs and trees, and the
  rings on a lake (the warm beach scene is a good place).
- Toggling the setting mid storm, and a thunderstorm starting.
- Frame time with and without shader weather.

Not done: a settling snow look on the ground, splashes on leaves and plants,
drops sliding down walls, and holding the pattern still as the player walks.
Lamps do light nearby rain now that it is lit, which is also untested.

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
farthest, checking the material carries those constants. It checks the
column coordinate, copied from the shader and tied to it by text: evenly
spaced round the turn in calm air, never slower than 0.3 of that rate
under any wind, speed and height a layer is drawn at, with the shader's
lean bound and fade end read from its source; and that the first version's
formula fails the same check at the beach. It checks the farthest layer's
columns are not minified away at 1080 lines. It renders nothing.
