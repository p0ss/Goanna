# Fire material review, 2026-10-05

The review of the [fire material](../../fire-material.md). Not yet run:
see "What happened" below.

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
