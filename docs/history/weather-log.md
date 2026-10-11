# Weather log

The dated record of shader weather and the water effects described with it:
what each live check found, what was changed after it, the tunings that came
before the current ones, and the status recorded when the storm work landed.
It is a log, so an entry describes the code as it was on its date. How
weather works today is in [Shader weather](../systems/weather.md).

Entries are oldest first. The first five are the live checks of the
falling rain, splashes and puddles; their dates are those of the commits
that recorded them. The passages are kept as they were written on the weather
page, so "above" and "below" in them point at that page as it was then. New
entries go at the end, under a `##` heading that ends with the date.

## First live check, 2026-09-26

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

## Second live check, 2026-09-26

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

## Third live check, 2026-09-27

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

What was changed, headless (from the commit that made the changes): two
low layers, at 0.45 and 1 node, which existed only below the eye (fading in
from 40 and 16 degrees down, out by 88), fainter and with thinner streaks,
and the wind's shear held to 1.73 radii of height so they could not fold.
The splash fleck was made larger, longer lived, denser and given a share of
the sky fill as its own light, and shallow noise puddles were added on
flat, open, up facing ground. A strike spawner was recognised by texture
and drawn by `lightning.gd` with an omni light, and `main.gd` held a white
sky out of its easing and turned it into a flash. With shader weather off,
the strike kept the particle path, and the particle path's culling box was
made to include the particle's own size: it was a node round the emitter,
50 nodes up the bolt, so the bolt vanished whenever its middle left the
view.

## Fourth live check, 2026-09-27

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

**The cylinders the box replaced.** The box replaced six cylinders nested round
the camera, which could not work at steep angles: a cylinder is seen edge on
above and below the eye, so looking up its streaks became radial lines round a
clear circle, and looking down the nearest wall was a ring of rain rushing in
under a dry disc. A box has no angle it looks wrong from. What was lost: rain
beyond about 12 nodes. The cylinders drew a layer 22 nodes out, which is what
the owner found good at a distance; the far box fades out from 10.5 nodes to its
sides at 12, and the storm fog and sky are left to carry the distance. The
cylinders were four to six layers of overdraw across the whole view; with the
box, most pixels carry no rain at all.

**Splashes and puddles in play.** Neither was ever seen, through two live
checks, while the ground did go wet and rings did show on water. The terms were
only in `nodes_array.gdshader`, and in play the ground is not drawn by it.
`GoannaClient::materialFor` puts a node array on `nodes_array_scissor.gdshader`
if any of its layers has alpha, and the arrays are upstream's bunches
(`NodeVisuals::fillNodeVisuals`), which group tiles by size alone, 256 at a
time. 1160 of Mineclonia's 1841 16 pixel textures have some alpha (counted over
every 16 pixel PNG in its mods, near enough the set its nodes use), so the
chance of a bunch of 256 with none is nil: every array is a scissor array, and
sand, grass and stone are all drawn by the scissor shader, which had the wetness
block and nothing after it. The terms now live in one function both shaders
call, and the status trace below names the shader of the ground under the eye.
The same cause kept the parallax march, which is only in `nodes_array.gdshader`,
off the ground too. That was fixed on 2026-09-27 by choosing the shader per
tile, by its own layer (`docs/systems/materials.md`, "Which shader draws a
tile"): sand, grass tops and stone now go to `nodes_array.gdshader` on the near
mesh, while cut-outs and the far tiers stay on the scissor shader. Both still
carry the rain terms.

## Fifth live check, 2026-09-27

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

What these replaced, after the fifth check: a splash was a fleck a fifth of
a node across for a tenth of a second, its albedo mixed 80 per cent toward
white with a share of the sky fill added as light "so it can be seen at
night", with a ring 0.7 nodes across in the normal that the fleck drowned
out. In play it was a field of big white spots coming and going with no
ring, their colour nothing to do with the ground. A puddle was a patch of
the same noise with a hard edge, half the albedo and a mirror, drawn over
the relief whatever its shape.

The damp film before this change was a roughness of 0.13 over everything
open with the relief left whole, which read as wet plastic.

## Other games' weather, run live, 2026-09-27

Regional Weather was run live on 2026-09-27: Minetest Game with Climate
API, Regional Weather, `lightning`, `lighting_monoid` and
`player_monoids` as world mods, and a headless client on the software
renderer. Each preset forced with `/set_weather`: rain, heavy rain, snow
and heavy snow were all taken as weather (about a dozen bursts at once)
and drew 0.52, 0.93, 0.78 and 0.70, scaled by a storm field of 0.1 to 0.2
at the spot; hail was left to its particles. Its snow and heavy snow both
reach the cap of 2 before the storm field, so the two look alike. Two
traps for anyone repeating it: Climate API skips a dead player, and a
client that spawned underground dies there; respawn and fly up before
forcing a preset. Nothing was looked at on a GPU, and the `lightning`
mod's strike (one spawner of one sprite, `lightning_lightning_N.png`, the
sky set plain white for a moment) has not been seen.

Snowdrift's particles never reached the client before 2026-09-27, when the
batched particle packet was first read
([protocol coverage](../systems/protocol-coverage.md)).

The other three were run live the same day, each alone on Minetest Game
with a headless client on the software renderer. theFox's `weather`: rain
1.18 and storm 1.13 under a weak storm field, snow 0.90, hail and sand as
particles; standing flown up at y 45 nothing came, since the mod only
rains where it finds sky light in the air above, which was not generated
yet. Mymonths: rain 1.2, storm 1.14, snow 0.88 where the ground was snowy,
hail and sandstorm as particles; its weather follows the nodes round the
player, so a spot by sand or snow changes it. Snowdrift, a test copy with
its precipitation forced on and its freeze read from a setting: rain 0.27
and snow 0.21 under a weak storm field. theFox's rain uses sprites 25
across and runs about five bursts at once, so by the drop count it is
already heavy; at a storm cell's heart its rain and its storm both reach
the cap and look alike.

Seen on 2026-09-27 on the software renderer: Regional Weather's sandstorm
browned the distance and the sky with blowing grains, its hail drew as
short white streaks. With shader weather off, 24 rain spawners took the
covered material without a shader error, but particle rain did not show
on the software renderer with the covered material or the plain one, so
whether the cover test hides the right particles has not been seen.

Seen on 2026-09-27 only on the software renderer, in a disposable
Minetest Game world with a faked snowfall: driven streaks, the far hill
greying, snow settling on sand. Not yet seen on a GPU.

## Ripple and splash tunings, 2026-09-30 to 2026-10-02

The ripple patch's body footprint is a disc whose soft edge (`kEdge`) is
centred 0.42 nodes out, just outside a player's 0.3. The first versions
centred both the shove and the push on a Gaussian under the body: the crest
it shoved up stood a fifth of a node ahead, inside the body, and the ring it
pushed out was a node across before it was steep enough to see, so the
water hard by a body lay flat whatever it did, a dead zone round the player
seen looking down.

Three tunings came before the one current on 2026-10-02. The first, on a swimmer
at 3 nodes a second, drew nothing a player could see: wading at 1 node a second
left a slope of 0.09 against the rings' 0.3. The second pressed down on the
water under every body all the time and swayed that press at a fixed 1.1 Hz,
which drew waves out of a player standing still, at a rate that had nothing to
do with what the player did, and the press, built up over half a second, left
the middle of the pattern behind a moving player. The third lifted the surface
with the body's own vertical speed, in the air as well as in the water, making
water to do it, and a player jumping up and down piled up broad mounds with no
troughs, drawn as white smoke rings by the crest whitening that went with them.
Jumping in and out for five seconds peaked at 0.27 and -0.23 with no water made
under that tuning; a gentle bob, a fifth of a node up and down, makes faint
rings (0.03), as it does in real water, where narrowing the push to sharpen them
only made them fainter. The test prints and floors the steepest slope 0.4 to 1.5
and 1.5 to 6 nodes from a swimmer. Now, for a player: nothing holding still;
moving, 0.35 to 1.2 near and 0.22 to 0.30 further out; bobbing 0.11 near and
0.024 out; 0.09 out two seconds after dropping in. Jumping in and out for five
seconds peaks at 0.08 round the body. It also checks a swimmer's crest is ahead
of it and its trough behind, centred on it.

The refraction offset through the ripple patch was at first the whole
normal times 0.006 times the ray's length through the water, which moved a
shallow bed by a pixel. Its replacement, the tilt times the depth over the
distance, was still only a subtle distortion looked down on, so caustics
were added in sunlight. Seen from high up even that was not enough, and the
rings round a body did not show at all, so shading to the sun and froth
were added on the top of the water.

The froth and shading were seen headless on software rendering: a hard kick
beside a standing player froths as clumps of rimmed bubbles of mixed sizes; the
shading did not show in those captures, where the patch steps slower than real
time and the light was dim, and neither has been looked at on a GPU.

The drips a body throws coming out of the water at first came out of a box
through the whole body, which in first person put them in front of the
lens. The droplets were at first round billboards 0.07 across, which read
as white bubbles coming out of the chest and hands.

## Status when the storm work landed, 2026-10-10

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
water. The live check entries above say what was changed after each. The falling
rain has since been rebuilt as a box of drops, and splashes and puddles now
reach the shader that draws the ground. The owner then saw the splashes, as
big bright white spots with no ring, their colour not the ground's (the
fifth check); they have been rebuilt as small rings in the ground's own
shading, and the puddles as water filling the relief. All of that has been
tested headless only, and nothing of it has been observed.

The storm work's own status, as recorded at its landing. Its section
names are those of the weather page at the time.

### Storms, other games' weather and snow: status

Landed on main on 2026-10-10, after a rebase onto weeks of other weather,
water and sky work. What it adds, each described in its own section:

- **Storm cells** (below): a drifting field of storm cells scales rain,
  snow, hail and dust from a drizzle at a cell's edge to a downpour at its
  heart, and scales the storm deck and the wetness with it.
- **Snowstorms**: snow rises further than rain at a cell's heart and
  turns into a whiteout that closes the fog in and greys it and the sky.
- **Settled snow**: snow builds `goanna_snow_cover` instead of wetting the
  ground, and the node and leaves shaders dust up facing surfaces open to
  the sky, texel by texel.
- **Wet grass droplets** (`grass_volume.gdshader`): a few tilted, mirror
  smooth droplets on wet blades where the sky reaches, gated, like the
  rest of the wet look, by the tier's wet surfaces flag.
- **Hail and blowing sand** ("Hail, blowing sand and the rest"): drawn
  by the precipitation shader as kinds of their own, with dust closing
  and browning the fog.
- **Covered particles**: weather still drawn as particles is kept out
  from under roofs by the rain cover map.
- **Other games' weather** ("Other games"): Mineclonia and VoxeLibre
  (`mcl_weather`), pmb_core (`aom_weather`), backroomtest (`br_weather`),
  Kythen, Regional Weather (Climate API), theFox's `weather`, Mymonths and
  Snowdrift.
- **`storm_override`** on the weather node: 0 to 1 pins where in a storm
  cell the viewer stands, for a test or a screenshot; below 0, the
  default, the field decides.

How it was verified, and how not:

- On 2026-09-27, before the rebase, each supported mod was run against a
  local server (Minetest Game, or Mineclonia for `mcl_weather`) with a
  headless client on the software renderer, and the recognised weather
  and its intensity were read from the client ("Other games").
- On 2026-09-28, still before the rebase, a GPU look pass in headless
  gamescope found the defects listed below.
- At the landing, on 2026-10-10, only headless checks with Godot 4.5.1's dummy
  renderer: `project/tests/weather.gd` and the native tests (`cmake --build
  build --target check`), both passing, and the other headless tests that load
  the changed scripts: `ripples`, `wake`, `water_optics`, `cloud_layers`,
  `procedural_grass`, `local_play`, `graphics_profiles` and `render_features`
  pass; `local_play_scene` (3 menu failures) and `portal_materials` (3
  failures) fail the same way on main before the landing. These draw no frame.
  The rebased code, which now sets its shader globals per view for local
  multiplayer, loads the covered particle shaders through the view's scope and
  gates the droplets on the tier flag, has not been run against a server or
  looked at on a GPU since the rebase. None of it is claimed to look right.

Known defects, open, from the 2026-09-28 GPU look pass (realistic rates,
not the fake spawner):

- **Blowing dust is invisible.** The grains (`DUST_RADIUS` 0.012, alpha
  0.5) are near invisible, and Mymonths' sandstorm at 0.67 shows nothing.
  The fog does close in and brown.
- **The sky stays sunny under a storm.** `storm_cover` reaches 0.93, but
  the sky keeps blue gaps and full sun lies on the ground.
- **Hail is sparse**: thin, sparse streaks rather than a hailstorm.
- **The fake snow spawner is far heavier than real snow.** `weather snow
  fake=true` (`particles.gd`, `inject_test_spawner`) is 400 a second over
  16 by 16 nodes, about 39 times Mineclonia's snow by density, so it sits
  at the cap of 4 and a full whiteout at any storm strength. Judge snow
  with a spawner of 100 a second over 50 by 50 (density 1) instead. Its
  rain is over the cap too. Not changed here, since `local_bench.gd`'s
  rain benchmark uses the same spawner.

Rain and snow at realistic rates did scale with the storm as intended in
that pass.
