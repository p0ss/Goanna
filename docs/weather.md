# Shader weather

Rain and snow drawn by shader instead of by the server's particle spawners,
with splashes and puddles on open ground, rings on open water, and
lightning drawn from the server's strike. Presentation only: the spawners
arrive exactly as before, nothing sent to the server changes, and
everything here is built from data the client already holds.

**Status: seen five times, not right yet, and rebuilt since.** The first
two live checks were Godot 4.5.1, Mineclonia, the warm beach at Godot (515,
4, 447), noon, `/weather rain`. The first showed no rain at the defaults; the
second showed streaks at the defaults, but gathered in one narrow band, with
the sky speckled and bright arcs, all turning with yaw. The third, by the
owner in play at night on sand, found the rain good at a distance, leaning
and dense, with a clear circle round the player looking down, no splashes or
puddles to be seen, and lightning drawn poorly. After changes for that, the
owner in play again found the rain still a "pillbox" looking down, with rain
rushing in underneath, radial lines round a clear circle looking up, and
still no splash or puddle on the ground, though rain rings did show on
water. "Live checks" below says what was changed after each. The falling
rain has since been rebuilt as a box of drops, and splashes and puddles now
reach the shader that draws the ground. The owner then saw the splashes, as
big bright white spots with no ring, their colour not the ground's (the
fifth check); they have been rebuilt as small rings in the ground's own
shading, and the puddles as water filling the relief. All of that has been
tested headless only, and nothing of it has been observed.

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

**Falling rain and snow** (`project/shaders/precipitation.gdshader`, placed
by `project/ui/weather.gd`). Each drop is one instance of a MultiMesh of
unit quads, one draw call per kind of weather. The shader places every drop
itself from its instance number (`skip_vertex_transform`), so the instance
transforms are identity and nothing is uploaded per frame.

- A drop has a seed, hashed from its instance number (PCG), and falls
  through a box round the eye. Its world position is the box's corner plus
  (seed times box size + velocity times time minus the corner) wrapped into
  the box. So a drop is fixed in the world, not in the view: when the eye
  moves the box moves round the drops, and a drop that leaves by one face
  comes in by the opposite one. Drops fade over their last 1.5 nodes toward
  every face, so the wrap is not seen.
- Two boxes share the instances. The far box is 24 by 16 by 24 nodes, the
  eye 10 above its bottom, about 0.3 drops a cubic node at intensity 1: the
  rain round about, falling to the ground below and toward the face from
  above. The near box is 6 nodes a side, the eye 3.5 above its bottom, about
  9 drops a cubic node: the rain falling past the face and between the eye
  and the ground looking down, where the far box alone leaves a node or two
  of air with almost nothing in it.
- Intensity picks the drops: the MultiMesh holds enough for intensity 2, and
  a drop is drawn when its own hash is under intensity / 2, so the same
  drops are drawn from frame to frame. At intensity 1 that is 5000 rain
  drops, or 2600 flakes.
- Rain: a streak along the fall, turned about its own axis to face the
  camera, 6 mm wide, as long as 0.035 seconds of fall (Mineclonia's 17.5
  nodes a second makes 0.5 to 0.7 nodes, with a per drop variation in speed
  and length). A streak narrower than a pixel and a half is drawn that wide
  at the coverage it really has, so a far drop is a faint line and not a
  sparkle. Peak opacity at 1080 lines and 70 degrees: 0.85 at 3 nodes, 0.26
  at 10.
- Snow: round flakes 5 cm across facing the camera, falling at the snow
  spawners' speed (2.5 for Mineclonia) with a slow sway of their own.
- Both lean with the wind. There is no wind in the protocol either; main.gd
  derives one for the grass from the cloud drift and the storm cover
  (`grass_wind`, strength 0.25 to 1), and the weather uses the same air,
  scaled so 1 is 7 nodes a second. Rain leans no more than 0.6 nodes of
  drift per node of fall; snow drifts at up to twice its fall speed. On a
  main.gd without `grass_wind` the same rule is worked out in weather.gd
  from `cloud_speed` and `storm_cover`.
- Nothing on the lens: a drop with any part of it within 0.3 nodes of the
  eye is not drawn, and drops fade in from 0.3 to 1.2 nodes, since a drop
  that close is out of focus, and drawn hard reads as a scratch on the
  screen.
- A drop is drawn only where the rain cover map says the sky reaches: asked
  at the top of the streak in the vertex stage (a covered drop's quad
  collapses and draws nothing) and again at each pixel, so a streak crossing
  a roof's edge stops at the edge. The cover map holds the ground too, so a
  drop that has fallen below the surface of its column is not drawn.
- Lit by the scene's own lights, with a light grey albedo and a share of
  the terrain's sky fill as emission, so a drop is as bright as its
  surroundings by day and dark at night, whatever the exposure. The light
  function has no facing: a drop takes 0.45 of a light from any side and up
  to all of it with the light behind it. Fogged, receiving and casting no
  shadow, outside global illumination.
- Nothing is drawn while the eye is underwater.

This replaced six cylinders nested round the camera, which could not work
at steep angles: a cylinder is seen edge on above and below the eye, so
looking up its streaks became radial lines round a clear circle, and
looking down the nearest wall was a ring of rain rushing in under a dry
disc. A box has no angle it looks wrong from. What was lost: rain beyond
about 12 nodes. The cylinders drew a layer 22 nodes out, which is what the
owner found good at a distance; the far box fades out from 10.5 nodes to
its sides at 12, and the storm fog and sky are left to carry the distance.

Intensity comes from the spawners' rate (amount a second for an endless
spawner, amount over time for a timed one), summed per kind and divided by
Mineclonia's own rates, 500 for rain and 100 for snow. It is clamped to
0.3 to 2, so any running weather spawner is visible and a thunderstorm (1.8)
is heavier than rain (1). It eases over 2.5 seconds, so a storm starting,
stopping or turning to thunder (Mineclonia replaces its spawners then) does
not pop.

**The ground in rain** (`weather_common.gdshaderinc`, drawn by both
`nodes_array.gdshader` and `nodes_array_scissor.gdshader`, one block in each
after the material decode). Four parts, none of which adds light or paints a
colour of its own: whatever shows is the ground's own albedo, darkened, in
the scene's own light, with a smoother surface and a bent normal to catch
the sky or a lamp.

- **The damp film.** Everything up facing with strong sky light, from
  `goanna_wetness`: darker by the porosity (soil soaks, stone sheens),
  roughness pulled toward 0.32, the normal map's relief softened by up to
  30 per cent, as a film of water fills the fine texture. It was a
  roughness of 0.13 over everything open with the relief left whole, which
  read as wet plastic. On an authored relief the crests (height over 0.75)
  drain first and take up to half as much.
- **Standing water in the relief** (`goanna_water_level`, `goanna_pool`).
  The owner's idea: the soft wet look is the dips between ridges filled
  with water. A LabPBR `_n` map carries the surface's height in its alpha,
  which the parallax march already reads; the water stands at a level on
  that height, rising with the wetness to 0.45 (none below a wetness of
  0.35, 0.15 at 0.6, 0.40 after a minute of rain from dry). Where the
  height at the texel drawn is under the level the pixel is water: the
  normal map's relief drowned, so the normal is the face's own, roughness
  0.06, SPECULAR 0.25 (water's F0 of 0.02), and the albedo darkened by 28
  to 40 per cent by porosity and up to 20 more where it is deepest. Just
  above the waterline, a quarter of the height, is a wet margin: darker,
  roughness toward 0.22, relief softened. Above that the film alone.
  After the march the texel drawn is the one the eye ray met, so the test
  is exact: a ray that met the relief under the level crossed the water's
  surface first. The height comes from the fetch the shader makes anyway,
  so it costs no read. Measured on the Mineclonia packs here, 0.45 is over
  the lowest tenth to quarter of the authored pack's dirt, sand, gravel
  and stone tops, and more of the Material Maker pack's, whose heights sit
  lower.
- **Basins** (`goanna_puddle`). The level is lifted by up to 1.2 in
  patches a node or three across, where a smooth noise on the world grid
  passes a threshold that falls with the wetness, so the patches stay put
  and spread through a shower. The lift ramps up toward a patch's middle,
  so at its rim only the hollows fill and the edge follows the texture;
  in the middle every crest is under and the tile is a puddle. None at a
  wetness of 0.3, 5 per cent of open flat ground at 0.6, 23 after a
  minute of rain and 34 at 1.
- **Splashes** (`goanna_rain_splash`, `goanna_splash_ring`). From
  `goanna_rain`, what is falling now. A cell of 0.22 nodes holds at most
  one drop each 0.6 seconds, on two grids offset by half a cell: about 31
  drops a square node a second at intensity 1. Each throws a ring for 0.36
  seconds, growing fast and then slower to between 7 and 15 centimetres
  across, its crest (1.3 centimetres half width) carried only in the
  normal and dying away as it spreads, over a wet mark that darkens and
  smooths the ground under it and fades over the same time. The ring is a
  third as strong on damp ground as in standing water. Rings are widened
  to the pixel and lowered in proportion, and faded out where a pixel is
  wider than 1.2 to 3 centimetres (about 9 to 23 nodes away at 1080 lines,
  nearer at a low angle) and past 10 to 22 nodes.

Water and its margin are drawn only on flat (normal y over 0.95), open, up
facing ground, fading out as the far tiers flatten (from `lod_flatten_near`).
Splashes need up facing (over 0.7) and open. "Open" is the rain cover map,
or the sky light where there is no map. A layer with no authored height
passes a height of 1, a crest everywhere, and so holds water only in a
basin: a missing `_n` gets a filler layer whose alpha is 0, and one
inferred from the colour has 255, neither a height, and `layer_depth` is
measured only from an authored height, so it tells them apart.

What these replaced, after the fifth check: a splash was a fleck a fifth of
a node across for a tenth of a second, its albedo mixed 80 per cent toward
white with a share of the sky fill added as light "so it can be seen at
night", with a ring 0.7 nodes across in the normal that the fleck drowned
out. In play it was a field of big white spots coming and going with no
ring, their colour nothing to do with the ground. A puddle was a patch of
the same noise with a hard edge, half the albedo and a mirror, drawn over
the relief whatever its shape.

**Splashes and puddles in play.** Neither was ever seen, through two live
checks, while the ground did go wet and rings did show on water. The terms
were only in `nodes_array.gdshader`, and in play the ground is not drawn by
it. `GoannaClient::materialFor` puts a node array on
`nodes_array_scissor.gdshader` if any of its layers has alpha, and the
arrays are upstream's bunches (`NodeVisuals::fillNodeVisuals`), which group
tiles by size alone, 256 at a time. 1160 of Mineclonia's 1841 16 pixel
textures have some alpha (counted over every 16 pixel PNG in its mods,
near enough the set its nodes use), so the chance of a bunch of 256 with
none is nil: every array is a scissor array, and sand, grass and stone are
all drawn by the scissor shader, which had the wetness block and nothing
after it. The terms now live in one function both shaders call, and the status
trace below names the shader of the ground under the eye. The same cause
kept the parallax march, which is only in `nodes_array.gdshader`, off the
ground too. That was fixed on 2026-09-27 by choosing the shader per tile,
by its own layer (`docs/materials.md`, "Which shader draws a tile"): sand,
grass tops and stone now go to `nodes_array.gdshader` on the near mesh,
while cut-outs and the far tiers stay on the scissor shader. Both still
carry the rain terms.

**Rings on water** (`project/shaders/water.gdshader`). Expanding rings in the
water normal on open water within 22 nodes, on top of the waves.

The water's rings come from `goanna_rain_rings`, the ground's splashes from
`goanna_rain_splash`, both in `project/shaders/weather_common.gdshaderinc`.
Each evaluates each cell alone, so a ring is kept inside its cell: its
largest radius is the distance from its drop to the nearest cell edge, less
the ring's width, and what is left of its envelope fades out before the
edge.

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
the window of a house you are standing in, over the open ground outside.
The depth buffer hides any drop behind a wall.

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
fade out before the map's edge. The falling drops read the map in the
vertex stage too, so the lookup names its level of detail.

The control channel's `status` carries `weather`
(`weather.gd`'s `debug_state()`): the eased intensities, the spawner count,
the drops drawn, whether a map is up and its area, and over the eye the
cover height, whether the eye is open, and `open_share`, the share of the
map's columns open at eye height. On an open beach that share should be
near 1; if it is near 0 there, the map is what is hiding the rain.

Under `weather.ground` is every gate between the weather and a splash or a
puddle on the ground below the eye, worked out by GDScript copies of the
shader's maths (`ground_trace`): the node and the shader that draws its top
face (from `GoannaClient::top_surface_at`, by the tests `materialFor`
makes), whether that shader has the terms, `goanna_rain` and
`goanna_wetness`, the facing, whether the cover map has the point open,
the distance and the pixel size taken for it (`pixel`, estimated for 1080
lines and 70 degrees), the basin noise (`basin`), the water level
(`water_level`), how much of it the ground holds (`pool`) and the splash
term (`splash`); and `failing`, the first gate that is shut, empty when all
are open. Whether water stands at the exact point under the eye depends on
the tile's relief, which the trace does not read, and on the basin noise,
so the level is reported but is not a gate.

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

## Wakes

Rings on the water round the player and the animals moving through it.
Not weather, but drawn by the same water shader beside the rain rings, so
it is described here. Presentation only: the positions are the ones the
client already draws, the water is looked up in the map it already holds,
and nothing is asked of the server. Tested headless only; nothing of it has
been observed.

**Sources** (`project/ui/wake.gd`, a child of the particles node). Ten times
a second: the local player (its walking position from `step_player`, or
1.6 nodes under the eye with the free camera) and the entities in
`GoannaClient::entity_list`, the nearest 15 of them within 32 nodes of the
eye. An entity within 0.4 nodes of the local player is taken to be its own
object and skipped. The entity list carries no collision box, so a body is
taken to span from half a node under its position to 1.7 over it, and it
touches the water when the top of a water node with no water over it lies
in that span. Water is recognised by name (`node_name_at`, the name
contains `water`), which covers Mineclonia's and Minetest Game's water and
river water, source and flowing; a game naming its water otherwise gets no
wake. Lava is left out on purpose: its own shader draws no wake.

**Points.** Each source that touches the water lays points on its path
since the last sample, each at its own place and at the time the body
passed it, into a ring buffer of 64 (x, z, birth, strength):

- Moving (0.3 nodes a second or more across): a point every 0.25 nodes, or
  every 0.12 seconds of travel at speed, whichever is further, so a boat
  or a sprint drops about eight a second and one body cannot fill the
  buffer. Strength 0.35 plus 0.2 a node a second, up to 1.
- Standing still in the water: one point of strength 0.3 every 1.2
  seconds (the bob), the first after a jittered delay so a herd in a pond
  does not pulse in step.
- Coming into the water from out of it: one point of strength 1.
- Out of the water, wholly under it, or after a jump of more than 4 nodes
  between samples (a teleport): nothing.

**Rings** (`goanna_wake` in `project/shaders/wake.gdshaderinc`). The live
points (under 2 seconds old) go to the water shader as a 64 by 1 float
texture, one texel a point, with a count, wake.gd's own clock (not `TIME`,
which rolls over) and the xz box the rings can reach. Each point grows a
ring from 0.15 nodes across, spreading at 0.6 nodes a second: a short wave
packet (wavelength 0.24 nodes, half width 0.12) whose slope is summed into
the water normal on top of the waves and the rain rings. It eases in over
a tenth of a second, fades linearly to nothing at 2 seconds, and weakens as
it spreads. A swimmer faster than 0.6 nodes a second leaves its rings on two
lines behind it, the V of a wake (half angle about 17 degrees at 2 nodes a
second); a still body bobs small rings. The crest also whitens the water a
little (up to 18 per cent, a lit albedo taken out of what comes up through
the surface), which is what is left to read at night when the sky in the
water is too dark for the bent normal to show. Drawn from below the surface
too. Faded out from 19 to 32 nodes from the eye.

**No setting.** The wake is always on, and not tied to shader weather:
rings round a swimmer are wanted in fair weather most of all. With no point
live the shader's whole term is one uniform branch, and wake.gd samples ten
times a second whatever happens.

The control channel's `status` carries `wake`: the bodies followed, how
many of them touch water, and the points live.

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

- One draw call per kind of weather falling: 10000 quads for rain (the
  instances for intensity 2), each placed by a handful of hashes and a
  cover map read in the vertex stage. A drop not drawn at this intensity,
  covered, or at the lens collapses to a point and costs no fragments.
- Fragments: each drawn drop is a thin transparent quad, lit, with one
  cover map read. The near box's drops a node or two away are the large
  ones, a few pixels wide and a few hundred long, and there are some tens
  of them in view; the far ones are a pixel and a half wide. Against the
  six cylinders this replaced, which were four to six layers of overdraw
  across the whole view, most pixels now carry no rain at all.
- Standing water: on flat up facing pixels once the world is wet, the
  basin noise (eight hashes) and a cover map read, in and for minutes
  after rain, in both array shaders. The height it fills is the alpha of
  the normal map fetch the shader makes anyway: no texture read of its
  own.
- A lightning strike: one quad and one unshadowed omni light for under half
  a second.
- The occlusion scan: at most 512 columns a frame for 8 frames each second,
  each column read block by block under the map lock until it hits something.
  Open ground stops a few nodes down; the worst case is flying high over
  empty air, 80 nodes a column.
- On terrain and water: a uniform branch that costs nothing in fair weather;
  in rain, one texture read and two splash cells (three hashes and at most
  one exponential each) per up facing pixel where a pixel is under 3
  centimetres and within 22 nodes, and two ring evaluations per water
  pixel within 22.
- Against that, the particle path it replaces was up to 1500 GPU particles
  per spawner.
- Wakes: ten times a second, `entity_list` and up to four node name
  lookups per body for 16 bodies, and a 64 texel upload while any point is
  live. On water within 32 nodes and inside the box the live rings reach,
  one texture read and a few dozen operations per live point, up to 64
  points, per water pixel; at most one exponential, a cosine and a sine for
  a point whose ring is near the pixel. Nothing when no point is live.

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

### Fourth

The owner, in play, with Godot 4.5.1 against Mineclonia. Looking down:
"it's still like a pillbox, the rain rushes in underneath". Looking up:
the streaks became radial lines round a clear circle overhead. "The ground
does get wet as the rain persists, but I've never seen a splash or a
puddle", while rain rings did show on water. What was changed, headless:

- The cylinders are gone. They are edge on above and below the eye, which
  is both faults, and no layout of them fixes that. The rain is now a box
  of drops fixed in the world (above). The test casts rays at pitches from
  80 degrees down to 80 up, at three yaws, and finds drawn drops within 12
  degrees of every one in at least six of eight moments.
- Splashes and puddles: the terms were in the one array shader that does
  not draw the ground in play (above, "Splashes and puddles in play").
  Found by reading `materialFor` and upstream's bunching, and confirmed
  against Mineclonia's textures; not by a live client, which the status
  trace is now for. Both shaders now draw them, puddles are darker and a
  little more widespread (a fifth of open flat ground after a minute of
  rain), and flecks are brighter.

### Fifth

The owner, in play at night against Mineclonia, in rain on open ground lit
by a torch (the Godot version was not recorded). The splashes were seen at
last: "bright white giant spots ... in game it just looks like hundreds of
big spots appearing and disappearing without any kind of concentric ring
effect, and their colour doesn't seem well matched to the surface". The
brightened flecks of the fourth round were the whole of what showed: a
fifth of a node of near white albedo with light of its own, over a ring
too faint beside it to read. And for puddles, the owner's idea: "it may be
possible to get the soft wet puddle look by softening the reflectivity
and normals, like those dips in between ridges are what would get filled
in by water." What was changed, headless:

- Splashes are small rings, 7 to 15 centimetres across, about 31 a square
  node a second at intensity 1, each spreading over a third of a second,
  in the normal only, over a brief wet mark that darkens and smooths the
  ground's own colour. Nothing white is mixed in and no light is added;
  the test holds rain's effect on the albedo to a factor of at most 1.
- Standing water fills the relief's hollows, by the height in the `_n`
  map's alpha, rising with the wetness; the noise puddles are kept as
  basins that raise the level until the crests drown too.
- The damp film is softer: roughness toward 0.32 rather than 0.13, and
  the relief softened rather than left whole under a gloss.

## What is untested

Everything visual. In particular, the owner's visual check should look at:

- Looking straight down and at 30 to 60 degrees down in rain: drops should
  be seen falling past the face and down to the ground all round the feet,
  with no ring of rain rushing in and no dry disc. Whether the close drops
  (the near box, 1 to 3 nodes away) read as rain or as marks on the screen,
  and whether there are too many or too few of them.
- Looking straight up: drops falling toward the face, seen nearly end on,
  with no radial lines and no clear circle.
- Walking and turning: the drops must stay put in the world (walk forward
  and pass them), and no drop should pop in or out at the box's faces,
  which are 3 nodes out for the near box and 12 for the far.
- The distance. Rain now ends about 12 nodes out; whether the storm still
  reads as heavy at the horizon, or whether a far layer is wanted back.
- The status trace, `status` then `weather.ground`, on open sand in rain:
  `shader` should be `nodes_array` (it was `nodes_array_scissor` before
  the per tile choice), `layer_alpha` false, `shader_has_terms` true and
  `failing` empty. If it is not empty, it names the gate.
- Splashes on open ground at intensity 1, by day and by night, within a
  few nodes: whether each reads as a small ring spreading and fading
  rather than a spot, whether it takes the ground's colour (a darker,
  glossier patch of the same sand or dirt, lit as the ground round it
  is), whether there are too many or too few, and that they fade out
  further off without a visible edge or shimmer. None under a roof. At
  night by a torch in particular, where the old flecks were brightest.
- Water in the relief as a shower goes on: first the joints and dips of
  an authored tile (the dirt, gravel and cobble tops show it best) going
  dark and mirror smooth with the crests damp between, then basins where
  whole tiles drown. Whether it reads as soft wet ground or as wet
  plastic; whether the water level against the pack's heights is right
  (0.45 at full wetness may be too much for the Material Maker pack,
  whose heights sit lower, or too little for the authored one); whether
  a basin's rim follows the texture; whether the water flickers or swims
  with the parallax as the view moves (it should not); and that it drains
  after the rain. A tile with no authored height (the filler, or an
  inferred normal) holds water only in basins.
- The distance: the normal map's mipmaps average the height, so far off
  the hollows blur toward the tile's mean and the relief's water thins
  out; whether that shows as a band where the near ground looks wetter.
- Standing under a roof edge or in a doorway looking out: drops should
  stop at the roof line, and none should fall indoors.
- Lightning, by `/lightning` (needs maphack) near and far, by day and by
  night: the bolt (the server's texture, bright, blooming, flickering), the
  light on the ground round the strike, and the flash across sky, clouds,
  fog and open ground, gone within about a third of a second, with nothing
  left white after it. A strike beside a house will light its inside
  briefly (no shadow).
- Whether it is too strong at night or in thunder. The constants are still
  guesses, with a floor.
- The wind lean direction against the grass and clouds: the sign of the wind
  vector in world space has not been checked against a real frame.
- Snow: flake size, sway, drift, and whether 2600 flakes is enough.
- The rings on a lake (the warm beach scene is a good place).
- Toggling the setting mid storm, and a thunderstorm starting.
- Frame time with and without shader weather.

- Wakes, on calm water by day and by night, in first person (look down
  while swimming, then turn round) and watching an animal swim: whether
  the rings read, whether a swimmer's V is visible behind it and at what
  angle, whether the bob of a body standing in shallow water is too busy
  or too faint, the whitening at the crests, and that a boat's wake does
  not fill the view. Whether bodies are found at all: `status` then
  `wake`, `in_water` should count the player while swimming and any
  animal in the water. The rings with rain falling on them too.

Not done: a settling snow look on the ground, splashes on leaves and plants,
drops sliding down walls, and splashes thrown up from the ground by the
falling drops themselves (the splashes are the ground's own, not the
drops').
Lamps light nearby rain now that it is lit, which is also untested.

## Tests

`project/tests/weather.gd`, headless:

```sh
godot --headless --path project --script res://tests/weather.gd
```

It checks that the precipitation, water and both node array shaders compile
with the uniforms the scripts set, that the globals are registered, the
rain cover map against a stand in for `rain_cover_rows` (banding, whole map
publishing, texel placement matching the shader's lookup, recentring,
clearing), `GoannaClient.rain_cover_rows`'s and `top_surface_at`'s bindings
with no world loaded, and the routing in particles.gd (rain and snow to the
shader, other spawners and world fixed rain to particles, intensities for
Mineclonia's rain, thunder and snow, switching the setting both ways mid
storm). It reads the cover texture back the way the shader does over an
open beach and checks nothing round the eye is covered there, that an
empty or part scanned map hides nothing, and that a roof does cover.

The rain box, through a GDScript copy of the shader's drop placing
(`weather.gd`'s `drop` and `drop_shown`, tied to the shader's lines by
text, with the PCG hash in 32 bit arithmetic): every drop is inside its
box; a drop inside its box stays at the same world position when the eye
moves and falls at its own velocity; intensity 1 draws half the instances;
rays from the eye at pitches of 80 and 45 degrees down, level, and 45 and
80 up, at three yaws, over level ground 1.625 below the eye, meet drawn
drops within 12 degrees in at least six of eight moments (the test prints
the drawn opacity per pitch); no drawn drop is within 0.3 nodes of the eye;
and under the roof of the stand in map no drop is drawn while beside it
many are. It prints and floors the peak opacity of a streak at 3 and 10
nodes, caps it at 0.45 for a drop 0.6 nodes away, and checks the
materials carry the constants.

The ground terms, through copies in `weather.gd` of `goanna_ground_rain`,
`goanna_water_level`, `goanna_pool`, `goanna_wet_darken` and
`goanna_splash_ring`, each tied to its source line by line and its
constants read from the shader. Both array shaders call the shared
functions, take the height only from a layer with an authored one, and
have no `EMISSION` and no mix toward a colour in their rain block;
`nodes_array.gdshader` reads the height from the fetch at the coordinate
the march moved to. On open flat ground clear of any basin at wetness
0.6, a hollow at height 0.05 is under water and a crest at 0.95 is
neither water nor margin, just above the waterline is a margin, and at
0.3 nothing stands even at height 0; a wall holds nothing; in a basin
after a minute of rain a crest is under water and splashes; under the
roof of the stand in map there is no water and no splash; and splashes
are gone where a pixel is 5 centimetres. Basins flood none of open ground
at wetness 0.3, less at 0.6 than at 1, a tenth or more after a minute and
under two fifths at 1. A splash ring's leading edge moves outward at every
tenth of its life while its slope dies to under a tenth, its mark is there
at impact and gone at the end; rings grow to between 4 and 20 centimetres
across; there are at least 20 splashes a square node a second; and over
four albedos, black to near white, and every mix of water, margin, mark
and porosity, rain scales the albedo by a factor between 0.35 and 1 and
never adds to it. The status trace, on open sand drawn by `nodes_array`,
reports every gate open, the splash term and the water held over 0.5 and
the level over 1 in a basin; with the scissor shader's text as it was,
without the terms, it names that shader as the failing gate; under a
roof it names the cover.

It checks lightning: a synthetic spawner as Mineclonia sends it, with
`lightning_lightning_2.png`, builds no emitter, one bolt 100 nodes tall and
one light a few nodes over the strike point, lit, flashes the sky, and all
of it is gone after the spawner's time and the tail; with shader weather
off it is an emitter whose culling box holds the whole quad; a stream of 40
is not a strike; and the flash sky test tells Mineclonia's white layer from
a storm sky. It renders nothing.

`project/tests/wake.gd`, headless, the wakes:

```sh
godot --headless --path project --script res://tests/wake.gd
```

It checks that the water shader compiles with the wake include and the
globals are registered, and ties wake.gd's copy of the ring (`ring`) and
its constants to the include by text. With a fake body across a fake lake
(water at and below y 0 for x 0 to 40): at 1, 2 and 4 nodes a second the
points are `spacing_for` apart, about as many as the path over the
spacing, each born when the body passed it and stronger the faster it
goes; a body standing in the water for six seconds bobs four or five times,
BOB_PERIOD apart, where it stands, and one drifting slower than STILL_SPEED
lays no trail; walking on land, deep under the water, or standing on a bank
over it lays nothing; walking in from the bank makes one splash, a
teleport lays nothing across the gap, and a source that leaves is
forgotten; published points are the live ones, the area holds them, and
none outlives MAX_AGE; the ring buffer overwrites its oldest; the nearest
sources within range are taken up to the cap. The ring: a fresh full
strength ring bends the normal (its peak slope is printed), nothing before
a point's birth, past its age or off its packet; and across a line two
nodes behind a body swimming at 2 nodes a second the slope is on both
sides of the path, more than twice what it is on the path, and none 1.6
nodes to the side (the profile is printed), and nothing beyond range.
