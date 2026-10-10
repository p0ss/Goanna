# Fire material review, 2026-10-05

The review of the [fire material](../../systems/fire-material.md). The
fixture here was never run; the reviews of 2026-10-06 and 2026-10-10 below
used the render service's stage.

## What it does

`run.py` holds one Luanti server on a private copy of `test_world`
(Mineclonia) with `fixture/` installed as a worldmod, and one headless
client at a tier's resolution with a fresh profile written for that tier.
`--attach TIER --frames` photographs each pose old against new, by day
(time 0.5) and at night (time 0.0), with the node animation clock pinned
so the game's frame and the flicker match between variants. Each frame has
a `.settings.json` beside it with the profile values and the flame state
the client held. `--attach TIER --timing` times the field pose with the
back to back `force_draw` method of the
[occlusion review](../low-tier-occlusion-2026-10-05/run.py), variants in
rotation.

Old and new are one client switched live with
`GoannaClient.set_flame_material`, which rebuilds the materials and remeshes
the near blocks.

The fixture, at Luanti (-40, 90, 420), floating in open sky:

| Pose | What |
| --- | --- |
| `campfire` | Mineclonia campfire, a culled mesh flame |
| `netherrack` | eternal fire on netherrack |
| `soul` | soul fire on soul soil |
| `candle` | four lit candles |
| `zombie` | a held zombie kept burning (`mcl_burning`), the upright sprite flame |
| `water` | a fire in front of a 5 by 3 water pool |
| `glass` | a fire behind a glass wall and one beside it |
| `field` | nine by nine fires on netherrack filling the near frame, the timing pose |

Variants: `old` (the emissive cut-out), `new_flat` (the flame material with
`render_fire_shimmer` off, as Lowest and Low draw it) and `new` (shimmer
on). Low times `old` against `new_flat`; Medium all three.

## How to run it

```sh
OUT=~/.local/share/goanna-pbr-audit/fire-shader-2026-10-05/run
flock /tmp/claude-1000/goanna-gpu.lock \
    python3 run.py $OUT --hold medium &
python3 run.py $OUT --attach medium --frames --variants old,new_flat,new
python3 run.py $OUT --attach medium --timing --rounds 12 --burst 600
touch $OUT/stop
```

The world copy is `goanna_fire_1005` under the flatpak's worlds, made from
`goanna_occl_1005` with its fixture swapped for this one.

## What happened

On 2026-10-05 and 06 the hold waited about two hours under the GPU lock.
In that time `tools/goanna-headless gpu-free` never reported free for
long enough to start a client: other agents' clients (portal studies,
headless and later software rendered clients under gamescope) were on the
GPU throughout, often two at once. Three starts were refused by the
launcher when a client arrived during the server's start. The hold was
then stopped. No frame was taken and nothing was timed.

## First GPU frames and the fix, 2026-10-06

The fixture above was never run. The material was first drawn by the
render service (`tools/goanna-render`, docs/agent-interfaces.md) on its own
stage: RTX 3090, NVIDIA driver, Godot 4.5.1, Luanti 5.17.0 server,
Mineclonia release 38561, tier High, 1280 by 720. That job and the review
of it are in
[render-backlog-2026-10-06](../render-backlog-2026-10-06/README.md). It
showed two defects with the flame material on, by day and at night: a band
of dark, noisy pixels in the air above a fire on netherrack and above the
fire in front of water, and cyan and green speckle over the far rows of the
nine by nine field.

### Cause

Both came from the heat shimmer, then part of `flame_glow.gdshader`. A job
with `render_fire_shimmer` on and off, on the same unfixed build, showed
both defects with it on and neither with it off, day and night.

The shimmer adds the difference between the opaque screen at a displaced
point and at the pixel, `bent - here`, with additive blending. That is right
once. But every flame quad added its own: Luanti draws a firelike node as
six quads (four sides and two diagonals), all stretched 0.6 nodes up for
the shimmer, and the field stacks dozens of quads behind each far pixel.
With n layers the pixel became `here + n * (bent - here)`, each with its
own waves. Where the scene behind was bright and the bent read was dark
(the edges of the wall and the pool), that went below black: the dark band.
Where only the red channel fell (netherrack against sky and stone), red
went under while green and blue rose: the cyan and green speckle.

### Fix

The shimmer is its own pass now, `flame_shimmer.gdshader`, the next pass of
the halo pass. It uses the stencil buffer (`stencil_mode read, write,
compare_not_equal, 7`): a pixel takes the shimmer of the first layer drawn
there and no other, and fragments the shimmer does not reach are discarded
before they claim the stencil. The halo stays in `flame_glow.gdshader`,
unstretched; it is never negative, so overlapping halos only add. With the
shimmer off, the shimmer quads collapse to a point in the vertex shader.

### Soul fire and the burning zombie

- **Soul fire** never stayed placed because Mineclonia's own
  `mcl_blackstone:soul_fire` `on_construct` turns itself into air when the
  node under it is in group `soul_block`, which soul soil is: a soul fire
  set on soul soil with `set_node` removes itself. The job places it with
  `swap: true`, so no constructor runs, and it stayed for the whole job.
- **The burning zombie** was burning all along. A probe in the job logged
  the held zombie's `burn_time` at 1000000 and one `mcl_burning:fire`
  entity attached to it every two seconds. The flame was drawn, but inside
  the zombie's legs: Goanna did not scale an attached object by its
  parent's `visual_size`, where upstream parents the child's scene node to
  the parent's mesh node and so scales both the offset and the child.
  `mcl_burning` divides the flame's size by the zombie's `visual_size` of 3
  to allow for that, so in Goanna it was a third of its height. Goanna now
  scales the offset and the child by a mesh parent's `visual_size` for an
  attachment without a bone, as upstream does. The flame now stands the
  zombie's height. It is one plane through the zombie's middle, as upstream
  draws it, so from the front the body hides most of it and it shows beside
  the legs and above the head.

### Frames

`fixed-job.json` is the job. Each row of the sheets is one pose; the
columns are the old flame (`GOANNA_FLAME_MATERIAL=0`), the flame material
before the fix (the branch's first commit, built in its own worktree) and
after it. The burning zombie's flame shows only in the old and fixed
columns, because the entity fix is not in the unfixed build.

- [fixed-day.jpg](fixed-day.jpg), time 0.5
- [fixed-night.jpg](fixed-night.jpg), time 0.0

Full frames: `~/.local/share/goanna-pbr-audit/fire-fix-2026-10-06/2-fixed/`
on the owner's machine, and the on and off diagnosis in `1-diag/` beside
it. Neither job logged a shader error.

### Timing

Back to back `force_draw` bursts of 600 draws, 6 rounds, median of per draw
GPU time, milliseconds, with the range of the round medians:

| Variant | field | row |
| --- | --- | --- |
| old flame, day | 4.89 (4.87 to 5.01) | 4.91 (4.82 to 4.95) |
| old flame, night | 4.88 (4.87 to 5.02) | 4.85 (4.80 to 4.91) |
| unfixed, day | 5.56 (5.51 to 5.69) | 4.89 (4.87 to 4.91) |
| unfixed, night | 5.52 (5.51 to 5.59) | 4.86 (4.85 to 4.89) |
| fixed, day | 5.54 (5.45 to 5.62) | 4.86 (4.84 to 5.00) |
| fixed, night | 5.51 (5.44 to 5.58) | 4.84 (4.83 to 5.00) |
| fixed, day, shimmer off | 5.42 (5.37 to 5.58) | 4.85 (4.81 to 4.92) |

The fix does not change the cost: the field still costs about 0.6 ms more
than the old flame, fixed or not, and the ranges overlap. Turning the
shimmer off saves about 0.1 ms of it; the rest is the blended flame and
halo passes over 81 fires. On the row pose the three are within noise.

## Second look, 2026-10-10

The branch rebased on main at 37b417f7, drawn by the render service:
RTX 3090, NVIDIA driver, Godot 4.5.1-stable, Luanti 5.17.0 server,
Mineclonia release 38561, 1280 by 720, a fresh profile per launch read
back from the client. Tier High for the old and new flame, by day (time
0.5) and at night (0.0), and tier Low for the new flame by day, where
`render_fire_shimmer` is 0. The build was the branch at 9f1d59f4 (the
sheet fix), not dirty; the seam job had the shimmer limit as its one
dirty file, which is the next commit unchanged. No job logged a shader
error.

- [landing-day.jpg](landing-day.jpg): old, new and Low by day.
- [landing-night.jpg](landing-night.jpg): old and new at night.
- [landing-flicker.jpg](landing-flicker.jpg): one close pose three times,
  ten seconds apart, day and night. The frames differ in 16 to 20 percent
  of their pixels (more than 16 of 255): the flames animate.
- [landing-zombie.jpg](landing-zombie.jpg): the burning zombie from the
  front, at 45 degrees and from behind; columns old by day, new by day,
  new at night.
- [landing-seams.jpg](landing-seams.jpg): the netherrack fire close up,
  before and after the shimmer limit.

`landing-job.json`, `landing-zombie-job.json` and `landing-seams-job.json`
are the jobs. Full frames are under
`~/.local/share/goanna-pbr-audit/fire-landing-2026-10-10/` on the owner's
machine (`run-2`, `run-3-zombie`, `run-4-seam`, and `probe-live` for the
control channel shots with the zombie's body hidden).

What it found and what changed:

- The first run's Low variant was refused: the profile said a view range
  of 6 and the client held 12. The client dropped a view range set before
  the session existed, which is when the settings are applied, so every
  tier asked the server for 12. Fixed in the client; the second run read
  back 6 on Low.
- The burning zombie's flame drew nothing of its own with the material on.
  The flame passes read the sprite cell rectangle as origin and size where
  it is min and max corners, and the halo's coarse read reached the frame
  above in the sheet and drew a flat box over the head. With both fixed
  the flame shows beside the legs and over the head, as the old flame
  does; with the body hidden the whole flame shows.
- Close up the shimmer cut thin black cracks into the flame over the
  netherrack's joints, absent on Low. Holding the shimmer's difference to
  0.08 a channel removed them; the bend over water still shows.
- The fixture's burn is unreliable: in the full run after the fixes no
  variant had a flame on the zombie, old or new.

Not timed after these fixes.
