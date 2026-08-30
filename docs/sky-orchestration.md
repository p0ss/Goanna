# Sky orchestration

How the sky, the fog, the clouds and the sun are kept telling one story
through dawn and dusk. The code lives in `project/sky_director.gd` (the
authorities), `_apply_sky` in `project/main.gd` (the plumbing), the ridge
probe in `src/goanna_client.cpp` (`lodUpdateFar`), and the shaders
(`sky.gdshader`, `atmosphere_volume.gdshader`, `light_shafts.gdshader`).

## The problem this replaces

Every lighting band used to be a ramp over the raw astronomical sun
elevation, each with hand tuned constants calibrated against a symptom in
isolation. Nothing asked whether the sun was actually occluded. At dawn
the sequence of events was a constants table playing out: the clouds
changed colour at one elevation, the sky at another, the fog gradient at a
third, and the fog between the camera and a ridge glowed with a beam the
ridge was blocking. The picture disagreed with itself because the layers
could not agree: the cloud undersides and the glow around the disc were
unrelated luminances.

## The two authorities

**The beam.** One function of solar altitude gives the transmitted sun's
hue and strength after its grazing path through the air
(`SkyDirector.beam_tint`, `beam_strength`). Every warm term consumes it:
the disc tint, the dome's directional haze band, the cloud undersides, the
fog's sun scatter, the sun light itself. The hue script is keyed to the
astronomical elevation, because the colour of twilight is a property of
the whole air mass; only the strength is per layer.

**Per layer horizons.** Each layer hands `beam_strength` its own altitude,
relative to the horizon that layer actually sees:

- The ground answers to the terrain ridge toward the sun's azimuth, as
  measured by the ridge probe. Sun energy, the sky fill's twilight
  carrier, `fog_sun_scatter`, the screen space shafts and the water's sun
  glow all gate on it, so the true dawn arrives at the crest, together.
- The cloud deck sees over that ridge by its own altitude
  (`SkyDirector.cloud_horizon`), so it lights first and darkens last by
  geometry: a long lead over open sea, a short one under a tall range,
  held back entirely when the range tops the deck.
- The dome's haze band is air beyond and above the ridge, so it answers
  only to the false horizon, lifted by `AIR_LIFT`: high air stays sunlit
  well after ground level is dark, which is the predawn and afterglow.
- The dome's own colour blend (day, dawn, night sky colours) stays on the
  astronomical sun. Its predawn is the false horizon dawn.

This is the two dawn pattern: over flat terrain the ridge probe reports
nothing, every ground gate sits on the false horizon, and the whole dawn
plays out as the sun crests the skybox's lower hemisphere. With a ridge
above the horizon, that skybox dawn becomes the predawn (clouds and high
air light, land waits), and the full arrival holds for the crest.

## The shadow boundary

Sun visibility is a height, not one scalar. When the sun is below the
ridge, the air between the camera and the ridge stands in the ridge's
shadow, so it must not glow: `fog_sun_scatter` and the shafts gate on the
ground's beam. The clouds stand above that shadow, so they blaze while the
land is dark. The gate also closes the oldest leak in the frame: the sun's
shadow map ends at 200 nodes, and beyond it every sun facing slope was
floodlit even with the disc behind a mountain. With the sun's energy gated
on the composite horizon that cannot happen at twilight. (By day, distant
terrain beyond the shadow map is still lit unshadowed; that is an older,
separate problem.)

## The fog wall

The dome's lower hemisphere renders as terrain wearing full fog, not as
unlit ground: the same air colour the depth fog converges to, darkened
mildly for depth, with the directional warm term running down it. Where
the far field stands proud of the horizon line it dissolves into that same
air, and where it dips below, the wall stands in as the horizon, so the
disc's edge and the dome blend through one gradient. The radiance cubemap
half of the sky shader keeps its separate lighting-only treatment.

## The ridge probe

`lodUpdateFar` measures the sine of the terrain horizon's elevation toward
the sun's azimuth: the max over drawn block tops within about 20 degrees
of the azimuth, at least 128 nodes out (nearer canopy is not a ridge
line). A max over tops needs no buried test, since a buried block's top
always sits under the surface block above it. The near set is walked
whole; the far set with a bounded cursor like the prune sweeps, publishing
each completed cycle. `sky_state()` carries the result (`ridge.sin`,
`ridge.height`, `ridge.distance`); `_update_horizons` in main.gd smooths
it over a few seconds and derives the cloud deck's horizon.
`GOANNA_RIDGE` forces the sine for an A/B without terrain.

## Fog on the fens

The valley mist exists before and independent of the light: its density
follows a diurnal cycle (thicker through night and predawn, burning off
through the morning, `mist_cycle` in main.gd), and at night the mist share
of the froxel volume carries a faint emission at the night radiance
floor's hue, so the banks are visible weather for the dawn to pierce
rather than something the dawn creates. Calibrated on the fixture:
`0.24 * night`; 0.03 was invisible, 0.9 was moonlit milk.

## The fixture

`project/dawn_sweep.tscn` renders the real shaders over a boxy stand-in
ridge, sweeping the sun through dawn twice (flat and ridge variants), with
no server. `GOANNA_SWEEP_ELEVS`, `GOANNA_SWEEP_RIDGE` and
`GOANNA_MIST_GLOW` narrow a calibration run. Judge composition there;
confirm on a server afterwards. Two traps it already caught: an
Environment left at the default `fog_sky_affect` of 1.0 repaints the whole
dome with fog colour, and the 3D cloud noise texture builds on a thread,
so early frames have no clouds.

## Not done yet

- The moon gets no ridge treatment; moonrise still uses the astronomical
  horizon.
- Daytime far terrain beyond the shadow map's 200 nodes is lit with no
  occlusion (see above).
- The probe fan is fixed at about 20 degrees; a sunrise through a narrow
  notch inside the fan reads as crested a little early.
- The night mist glow is calibrated on the fixture only; its hue on a
  live server night is unjudged. The rest of the sequence was verified on
  the test_world Mineclonia server on 2026-08-30; PLAN.md has the
  numbers.
