# Vertex occlusion on direct light, 2026-10-11

How much the traced corner occlusion touches direct light
(`vertex_ao_light`), as play had it and as it was meant to be.

## What was wrong

The shader's own default for `vertex_ao_light_strength` has been 0.3 since
2026-08-24 (commit 6f0c8b7c, "Darken the corners, carry the torch, honour
SDFGI at zero"), because at 0 the corner term vanished under the sun and the
world read flat at noon. That commit changed the shader but not
`kMatStrengthDefaults` (then in `src/goanna_client.cpp`, now in
`src/goanna_client_materials.cpp`), which still said 0 from
when the channel was added (62636856, 2026-08-21). The client sets every
`_strength` uniform from that table on every material it builds, so the
shader's 0.3 never reached play. No graphics profile, setting or render
feature switch sets the channel, so every tier, Lowest to Ultra, ran at 0.
No recorded measurement chose 0 for play; the one measurement of the
channel (`docs/systems/mesh-attributes.md`) predates the 0.3 decision.

The table now says 0.3, matching the shader. All tiers take it: it costs
one uniform, and Lowest, which has no SSAO, has no other corner term in
direct light at all.

## How it was shot

The render service (`tools/goanna-render`), on the GPU: RTX 3090, Godot
4.5.1-stable (official), Luanti 5.17.0 server, Mineclonia release 38561, the
client built from this branch at 97c16b68 with the change uncommitted,
1280 by 720, headless gamescope through the launcher, the default
Mineclonia PBR pack, time 0.5 (noon), weather clear. Tiers High and
Lowest, from `high-job.json` and `lowest-job.json`. The change was then
rebased onto 976b238f, which had moved the table to its own file; the value
is the same, and the frames were not shot again.

Each job shoots two variants on one service: `ao_light_0` launches with
`GOANNA_MAT=vertex_ao_light=0`, which is what play had, and
`ao_light_default` takes the new default, 0.3. The channel is not a
profile key, so the variants are two launches, not a live switch; the
stage is rebuilt the same way for both. Poses, on the service's stone
stage: `corner` (an inside corner of stonebrick walls with a cobble step in
it), `overhang` (a plank roof two nodes up, with a back and side wall),
`cave` (a tunnel into a stone mound) and `grass_wall` (a grass floor and
step against a cobble wall).

The full frames and sidecars are under
`~/.local/share/goanna-pbr-audit/vertex-ao-2026-10-11/`.

## What it shows

`contact.jpg`: columns High at 0, High at 0.3, Lowest at 0, Lowest at 0.3;
rows corner, overhang, cave, grass wall. `crops.jpg`: full resolution
crops, 0 on the left and 0.3 on the right, of the corner (High, then
Lowest) and the cave mouth (High, then Lowest).

Share of pixels whose luma moved by more than 3 of 255, and the frame mean
before and after:

| Pose | High | High mean | Lowest | Lowest mean |
| --- | --- | --- | --- | --- |
| corner | 20.4% | 85.7 to 82.5 | 19.8% | 63.6 to 61.1 |
| overhang | 10.1% | 106.6 to 105.3 | 11.5% | 83.2 to 81.8 |
| cave | 14.5% | 110.6 to 108.8 | 18.9% | 87.7 to 85.8 |
| grass_wall | 13.9% | 66.4 to 65.3 | 19.2% | 66.3 to 64.3 |

Looked at by eye: at 0.3 the floor darkens in a soft band along the foot of
each wall, the cobble step in the corner gets a contact shadow along its
base and its sunlit top edge stays bright, the tunnel walls and floor
darken toward the inside edges, and the sunlit side of the plank wall
under the overhang darkens toward the ground. At 0 those sunlit junctions
are flat and the blocks look pasted onto the floor. Nothing turns black or
loses its texture; on High, where SSAO also reaches direct light, the
darkest corners deepen a little but still read as stone and wood, so there
is no visible double darkening at these poses. On `grass_wall` the High
tier's procedural grass hides most of the floor, and the change shows only
at the wall's foot.

Not looked at: night, a torch lit interior, real terrain, the other three
tiers, and timing (the channel is a uniform, with no extra work).
