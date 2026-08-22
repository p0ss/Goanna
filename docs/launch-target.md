# The launch target

One experience, stated so it can be tested: a player opens the menu, starts
a new local world, and within a few minutes is looking at terrain all the
way to the horizon, at PBR textures up close, under a shader pack whose
effects hold across that whole depth. Nothing set in a settings panel,
nothing set in an environment variable, no file copied by hand.

`docs/roadmap.md` keeps the dependency order for the project as a whole.
This file is narrower: it is the order of work for that one experience,
broken into tasks small enough to hand to a focused agent, each with what
done looks like. When a task lands, record it here with the date and what
was measured, as the other plan files do.

## What a fresh install gets today, 2026-08-22

Read from the code, not assumed. "Fresh" means no `user://goanna.cfg`, so
every value is the code's default.

| Piece | Default | Where it is decided | State |
| --- | --- | --- | --- |
| Server mod installed into the world | yes | `project/local_server.gd`, `_install_server_mod` | on |
| Far rendering granted, 1024 nodes | yes | `local_server.gd`, `far_distance` | on |
| Pregeneration around the player | yes | `local_server.gd` writes `goanna_far_pregenerate = true` | on |
| Send distance 32 blocks | yes | `local_server.gd`, `send_distance` | on |
| Far tiers, store and summaries drawn | yes since 2026-08-22 | `m_lod_distance` in `src/goanna_client.h`, was 0, is 12 | on, not yet run on a fresh profile |
| Far distance cap, stale strength | 512 nodes, 0.6 | `GOANNA_FAR_DISTANCE`, the `stale` channel; no settings entry | on, not reachable from the panel |
| Material classifier and auto bump | always, 0.35 | `GoannaClient` constructor | on |
| Texture map for the classifier's block column | per game since 2026-08-22 | `GOANNA_GAME` from the menu, `project/texture_maps/<game>.csv` | on for Mineclonia only, the one map bundled |
| Baked PBR pack | none | `settings/texture_pack`, a local path | off; the pack is 139 MB, gitignored, Mineclonia only |
| Shader pack | none | `GOANNA_SHADERPACK` only | off; only the proof pack exists |
| Lighting values | `main.gd` constants | `light_*` in `project/main.gd` | on, but not the values the chart settled |

So the server side of the target is met and the client side is half met: a
fresh install now draws to the horizon once the world has generated, but
sees the game's own 16 pixel art, flat, under lighting values nobody has
judged against the PBR look. The rest of this file is the other half.

## The tasks, in order

Each task names where the code is, what instrument says it is done, and
which model tier it suits. A task marked opus has a design decision in it;
one marked sonnet is bounded and measured. Every task ends with
`tools/check-style.sh` clean, the relevant plan file updated, and no claim
in `README.md` moved to "Working" without the run that proves it.

### 1. The acceptance harness

Nothing else here can be called done without this. A script,
`tools/test-launch-target.sh`, that: starts the client against an empty
settings file without touching the player's own (add a `GOANNA_CFG=<path>`
override in `main.gd` and `ui/game_ui.gd` if there is no cleaner way; the
`GOANNA_LOCAL_TEST` guard in `menu.gd` is the precedent); starts a new local
world through the menu path, not a hand started server; waits on the
control channel (`docs/control-channel.md`) for `render_stats().far_remote`
to pass a threshold rather than on a wall clock; takes one shot at the
horizon and one at a wall two nodes away; writes both beside a JSON of the
settings in force. `tools/shotcheck.py` gets a `--launch-target` check that
reads them: far cells above a count, a normal map response in the close
shot, a non identity final pass in the frame when a pack is on.

Done when the script passes on this machine from a fresh profile and its
output is the evidence the rest of this file cites. Sonnet. No dependencies.

### 2. Far horizon defaults, the rest of it

`m_lod_distance` is now 12. Left: settings entries for the far distance cap
and the stale strength, which are environment variables today
(`GOANNA_FAR_DISTANCE`, the `stale` material channel); a line in the HUD or
the chat while the horizon is still filling, driven by `far_remote` rising,
so the first minute of a new world does not read as broken; and the
measurement, on a fresh profile through task 1, of what 12 costs at the
default view range on this machine and at a 1024 node grant. If 12 is wrong
the number changes, with the measurement recorded in `far-rendering.md`.

Done when task 1's horizon shot shows far cells with no setting touched, and
the two new entries round trip through the panel. Sonnet. Depends on 1.

### 3. The PBR pack, distributed

The look up close is `baked/pack-mineclonia-v2`: 3069 files, 139 MB, baked
by `tools/pbr_bake.py` from Mineclonia's own art and therefore CC BY-SA 4.0
with the attribution `ATTRIBUTION.md` carries (`docs/materials.md`, "Licence
of the source art"). It cannot go in the repository and it is Mineclonia
only.

The decision in this task: where it lives and how it arrives. The
recommended shape is a release asset, one archive per game, fetched by the
client into `user://packs/<game>/` from the menu with a progress bar and a
checksum, and selected automatically when a local world of that game is
started or when a server's game can be recognised from its node names. The
alternative, installing it as a worldmod through `tools/pbr_deploy.py` so
the server serves it, keeps the client vanilla but makes every join a
139 MB media transfer and makes the world's texture set the mod's. Pick the
first unless the design turns up a reason not to, and say why either way.

Pieces: `tools/package-pbr-pack.sh` (archive, checksum, attribution inside);
the menu button and download; the per game selection in `main.gd` beside
the texture map; a visible attribution line in the menu, because a
share-alike licence requires it where the work is distributed. Opus for the
decision and the selection logic, sonnet for the packaging and the download.
Depends on nothing; task 1 measures it.

### 4. Lighting defaults, judged with the pack on

`project/main.gd` starts at sun 1.0, ambient 1.0, bounced light 1.4, corner
shading 4.0, exposure 0.46, sky fill 0.4. The values that have actually been
looked at with the baked pack on are different (sun 0.5, ambient 0.5,
bounced light 0, corner shading 7.75, bounced light grain 7.75). Neither
set was settled by the chart in `project/lighting_chart.tscn` with the pack
on, which is the condition the target runs under.

Run the chart with and without the pack, settle the defaults, and record
the values and the frames in `pbr-plan.md` step 3. If the answer differs
with and without a pack, the defaults follow the pack's presence. Sonnet
with the chart; opus if the two conditions want different exposure
pipelines rather than different numbers. Depends on 3, or on the pack
being present locally, which it is on this machine.

### 5. A shader pack of our own, on by default

Rung 1 of `iris-compat.md` proved that a pack's screen space chain runs.
No third party pack is licensed for us to ship, and none has been run. So
the default is ours: `project/shaderpacks/goanna/`, LGPL-2.1-or-later like
the rest of the repository, written in the GLSL 120 dialect the translator
already handles, doing what packs do that Godot's environment does not:
depth fog tied to the far distance so near and far tiers sit in one
atmosphere, bloom, a tonemap, and whatever else earns its place. It must
read `depthtex0` and the colour buffer only, so it works over the far tiers
exactly as over live blocks, which is what "across near and far scales"
means in practice.

The design decision inside it: who owns fog and tonemap when a pack is on.
`main.gd` already switches Godot's tonemap to linear when a pack has a
`final`; fog needs the same rule, or the far tiers are fogged twice, once by
the environment and once by the pack. Write the rule down in
`iris-compat.md` and apply it to every pack, not only ours.

Also in this task: a `shader_pack` settings entry (path, or `default`, or
`off`), `main.gd` reading it where it reads `GOANNA_SHADERPACK` today, and a
toggle in the pause menu so a player on a weak machine can turn it off
without a relaunch if the effect can be removed and re-added live.

Done when task 1's two shots, taken with no setting touched, show the
pack's final pass in both, and `tools/shaderpack_check.py` says so. Opus.
Depends on nothing; pairs with 4 because the pack's tonemap is the
exposure's last stage.

### 6. Real Iris packs

`iris-compat.md` rungs 2 to 4: the `shaders.properties` option `#define`s
and custom uniforms, `depthtex1` and `depthtex2`, a real `shadowtex`
fallback, and then two or three real packs run locally, not shipped, to
find the long tail of the dialect. Done when one real pack's composite
chain renders without a translator edit specific to that pack. Opus; the
preprocessor is the hard part and the document says so. Independent of 5,
but 5's fog and tonemap rule is what makes a real pack look right here.

### 7. The audit

`pbr-plan.md` step 4: per game and per node, the class assigned, whether
authored data exists, a rendered swatch, generated over every registered
node (`tools/goanna_pbr_gallery.lua` is the start of it). Done when a row
can be pointed at rather than a screenshot. Sonnet. Independent; it is the
gate the Iris translator rungs 5 to 7 wait behind, not this target, so it
comes after 5 and 6 here.

### 8. Far rendering at scale

No rungs left, only cost: a worker thread for region meshing (cross thread
rules in `CLAUDE.md` apply, everything through `GoannaSession`'s mutexes),
the chain thresholds calibrated against task 1's measurements, and an index
over stored regions before the scan is asked to cover 4000 nodes. Opus for
the thread, sonnet for the rest. Depends on 2 for the numbers.

### 9. Launcher polish

The worldmod copy of `goanna_server_mod` goes stale when the checkout moves
on (copy it every start, or compare a version line); the other games need
their texture maps bundled and, when baked, their packs (VoxeLibre, Asuna,
Minetest Game, in that order of players); a player who lands in an old
world made before the privilege change has no fly and no clear reason why.
Sonnet. Independent.

## What this file is not

It is not the roadmap. Connected textures, entity and node animation,
Iris rungs 5 to 7, source movement and VR are all real and all absent here,
because none of them is between a fresh install and the experience at the
top of this page. They stay in `roadmap.md` in their order.
