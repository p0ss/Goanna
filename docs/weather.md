# Shader weather

Rain and snow drawn by shader instead of by the server's particle spawners,
with splashes and puddles on open ground, rings on open water, and
lightning drawn from the server's strike. Presentation only: the spawners
arrive exactly as before, nothing sent to the server changes, and
everything here is built from data the client already holds.

**Status: seen three times, not right yet.** The first two live checks
were Godot 4.5.1, Mineclonia, the warm beach at Godot (515, 4, 447), noon,
`/weather rain`. The first showed no rain at the defaults; the second showed
streaks at the defaults, but gathered in one narrow band, with the sky
speckled and bright arcs, all turning with yaw. The third, by the owner in
play at night on sand, found the rain good at a distance, leaning and
dense, with a clear circle round the player looking down, no splashes or
puddles to be seen, and lightning drawn poorly. "Live checks" below says
what was changed after each. The version after the third has been tested
headless only; nothing added since has been observed.

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

**Falling rain and snow** (`project/shaders/precipitation.gdshader`). Six
open cylinders nested round the camera, in one mesh surface: one draw call
for all of the weather. The mesh moves with the camera each frame. The
pattern on each cylinder is laid out in world units, so a far layer packs
more and thinner streaks into the same angle than a near one, and the
nesting is what gives depth. Layers are drawn outermost first and fade with
distance.

- Four full layers, radii 3, 6.5, 12 and 22 nodes, from 26 below to 34
  above the eye. These are the rain seen ahead and round about.
- Two low layers, radii 0.45 and 1 node, which exist only below the eye:
  the 1 node layer fades in from 16 to 24 degrees below level, the 0.45
  layer from 40 to 50, and both fade out from 80 to 88 degrees down, where
  their columns converge on the nadir. Their meshes run only over that
  band, so they cost fragments only where they draw. They are the rain
  close by when looking down, which the full layers cannot be: with the
  nearest wall at 3 nodes, a ray more than 28 degrees down meets the
  ground before any rain (the third live check's clear circle). Being low
  only, they are never in front of a level or raised view, and where they
  are drawn they are about 0.6 nodes or more from the eye along the ray.

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
  on the 3 node layer and 0.34 on the farthest, and fainter on the low
  layers, 0.34 at 0.45 nodes and 0.42 at 1 node, since a drop that close is
  a faint blur and a heavy line there reads as a mark on the screen. Streak
  half width is 0.0015 nodes plus 0.00075 per node of radius (it was 0.003
  plus 0.0006, which is six pixels wide half a node away). Opacity does not
  fall with intensity; density does. The full layers fade out over their
  last 6 nodes top and bottom, and between 45 and 60 degrees above or below
  the eye, where the wall is seen edge on.
- The wind's shear is taken at a height held to 1.73 radii either side of
  the eye (60 degrees), so the low layers, drawn to 88 degrees down, cannot
  fold. Below that height a streak in wind is upright, which on the low
  layers is at or under the ground.
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
rain is falling: each drop is a bright fleck for a moment, and where the
ground is wet (`goanna_wetness`) it throws a small ring carried only in the
normal, so it shows in the sheen. At intensity 1 there are about four drops
a square node a second, each fleck about a fifth of a node across for about
a tenth of a second, and a fleck carries a share of the sky fill as its own
light, as the falling streaks do, so it can be seen at night. The first
version's fleck was a twelfth of a node across for a few hundredths of a
second at a pale grey albedo, and on wet sand at night was not seen at all.
The scissor variant (leaves and plants) does not splash.

**Puddles** (the same block). On flat, open, up facing ground, patches a
node or three across where standing water collects: darker, near mirror
smooth, the texture's relief drowned, and the rain's rings at full strength
in them. Where they are is a smooth noise on the world grid
(`goanna_puddle` in `weather_common.gdshaderinc`), so a puddle stays put.
How much of the ground they cover follows `goanna_wetness`, not
`goanna_rain`: none below a wetness of about 0.4, a few per cent at 0.6 and
about a fifth at 1, so they spread through a long shower and shrink as the
world dries after it. The near mesh only; the far tiers do not puddle.

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

## Lightning

Luanti has no lightning in the protocol either. Mineclonia's
`mcl_lightning.strike_func` sends, per strike: one particle spawner
(texture `lightning_lightning_N.png`, N 1 to 3, amount 1, time 0.2,
vertical, glow `LIGHT_MAX`, size 1000, which is 100 nodes, centred 50.5
nodes over the struck node so that the quad's bottom edge meets its top
face); a white sky colour layer through `mcl_weather.skycolor` with the
day night ratio overridden to 1, removed about a tenth of a second later;
and a thunder sound.

**The bolt** (`project/ui/lightning.gd`, `project/shaders/lightning.gdshader`).
With shader weather on, particles.gd recognises the spawner by its texture
name, as it does rain (the name contains `lightning` and the amount is 4 or
less), and hands it to lightning.gd instead of building an emitter. That
draws the server's own texture on a quad of the spawner's size, turned
about its upright axis to face the camera as a vertical particle is,
additive, unshaded and six times white so it blooms; with no texture, a
jagged line with one branch is drawn instead, meeting the ground at the
same point. It flickers through a first stroke and up to two weaker return
strokes over the spawner's time, then dies away over a quarter second.

**The light.** An OmniLight3D a few nodes over the strike point, range 48,
energy 16 at the stroke's peak, following the same flicker. No shadow: an
omni shadow is six more passes over everything in range for a light that
lives a fifth of a second, so a strike beside a house lights its inside.

**The flash** (`main.gd`, `_take_lightning`). The server's white sky could
not reach the screen: `_apply_sky` eases every sky colour set over four
seconds so a biome border does not flip the dome, and a tenth of a second
of white moved it about 2 per cent of the way, then took seconds to ease
back. A sky set white through day, dawn and night is now held out of the
easing and becomes a flash: 1 while the server's white lasts, dying away
over a few hundredths of a second after it. A white sky that lasts longer
than 0.6 seconds is taken as the game's real sky. lightning.gd's own flash
(each strike's flicker, weighed by distance: full within 50 nodes, down to
0.3 of it at 225 and beyond) covers a game that strikes without whitening
the sky; the two together are one flash, not two. The flash whitens the
dome and horizon, and so the fog, lights the cloud deck and its undersides,
raises the day night ratio the ambient, background and haze follow, and
adds to the sky fill, which lights whatever is open to the sky and nothing
under a roof.

With shader weather off, the strike keeps the particle path, as before, and
the server's flash still reaches the sky. The particle path's culling box
now includes the particle's own size: it was a node round the emitter, 50
nodes up the bolt, so the bolt vanished whenever its middle left the view.

## The setting

**Shader weather** in the Video tab (`shader_weather`, on by default, shown
without opening Advanced), declared in `game_ui.gd` beside **Player effect
particles** and listed in `LOCAL_KEYS`. Off, weather spawners get their
particle emitters as before and the shader draws nothing, so there are no
splashes or rings either, and a lightning strike is a textured particle
with no light. Puddles follow the wetness, which does not depend on the
setting. Changing it mid storm rebuilds the running storm
the other way at once, from the spawners as they arrived.

## Expected cost

Not measured. What the code does:

- One extra draw call while weather is falling: 384 triangles, a
  transparent pass over whatever part of the screen the cylinders cover,
  with a handful of hashes per pixel and one texture read of the cover map.
  The overdraw is four layers deep across most of the view, and up to six
  deep below about 16 degrees down, where the low layers are, which is the
  part to watch on a weak GPU.
- Puddles: on flat up facing pixels once the world is wet, four hashes and
  a cover map read, in and for minutes after rain.
- A lightning strike: one quad and one unshadowed omni light for under half
  a second.
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

### Third

The owner, in play, at night on sand (the screenshot is sand lit by a
torch, wet and glossy). Rain looked good at a distance, leaning and dense.
Three faults:

- "Like I have an umbrella": no rain within a node or two of the player,
  plain looking down at about 30 degrees. The nearest layer was 3 nodes
  out, so a ray more than 28 degrees down met the ground first, and the
  edge on fade removed everything past 45 degrees anyway. The two low
  layers above are the fix; the test finds 178 of 359 quarter degree steps
  of depression clear under the old layout and none under the new, down to
  a clear circle of half a node.
- No splashes or puddles visible. The flecks were too small, too brief and
  too grey (above), and there were no puddles.
- Lightning. The strike went down the particle path as a flat unshaded
  quad, culled whenever the middle of the bolt left the view, and the
  server's white sky was eased away before it could be seen (above).

## What is untested

Everything visual. In particular, the owner's visual check should look at:

- Looking down at 30 to 60 degrees in rain: rain should fall right round
  the player and in front of the camera, with a clear patch at the feet no
  wider than half a node. Whether the close streaks read as rain or as
  marks on the screen, and whether 0.34 and 0.42 are the right strength
  for them. Walking forwards, the close rain moves with the player.
- Standing under a roof edge or in a doorway looking down and out: the low
  layers must stop at the roof line like the others.
- Splash flecks on open ground at intensity 1, by day and by night, and
  none under a roof. Puddles after a minute of rain on flat ground: where
  they are, how many, whether they read as water (darker, mirror, rings),
  and that they stay put as the player moves and shrink after the rain.
- Lightning, by `/lightning` (needs maphack) near and far, by day and by
  night: the bolt (the server's texture, bright, blooming, flickering), the
  light on the ground round the strike, and the flash across sky, clouds,
  fog and open ground, gone within about a third of a second, with nothing
  left white after it. A strike beside a house will light its inside
  briefly (no shadow).

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
columns are not minified away at 1080 lines.

It checks the near field: for eye heights of 1.3, 1.5, 1.625 and 2.1 over
level ground, at every depression from a quarter degree to 90 in quarter
degrees (which covers a camera pitched 30 to 60 degrees down with a 70
degree field), a ray that meets the ground more than half a node out
horizontally must first cross a layer drawn at half strength or more, by
each layer's fades and mesh span as the shader has them; the layout the
owner saw fails this at 178 of 359 depressions. Nothing is drawn nearer the
eye than 0.55 nodes along the ray, no low layer is drawn at or above eye
level, and the low layers' peak opacity is no more than 0.45. The column
rate check covers every height each layer's mesh reaches, with the shear
held as the shader holds it.

It checks the ground terms, as nodes_array computes them and tied to its
source by text, with the puddle noise mirrored: splash and puddle are both
over 0.5 on an open, flat, up facing point at intensity 1 and full wetness,
both zero on a wall and under the roof of the stand in map; puddles cover
under 1 per cent of open ground at wetness 0.3, 3 per cent at 0.6 and 21
per cent at 1 (a tenth to two fifths required); and there are at least
three splashes a square node a second.

It checks lightning: a synthetic spawner as Mineclonia sends it, with
`lightning_lightning_2.png`, builds no emitter, one bolt 100 nodes tall and
one light a few nodes over the strike point, lit, flashes the sky, and all
of it is gone after the spawner's time and the tail; with shader weather
off it is an emitter whose culling box holds the whole quad; a stream of 40
is not a strike; and the flash sky test tells Mineclonia's white layer from
a storm sky. It renders nothing.
