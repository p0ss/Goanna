# Minecraft comparison captures

`tools/goanna-render minecraft` captures Minecraft Java and Goanna from the
same local Minecraft server.
[BridgeTest](https://github.com/l-koehler/bridgetest) translates the connection
into the ordinary Luanti protocol for Goanna. `--native` also captures the
native Luanti client through the same bridge, sequentially.

This gives shader investigations a shared world, textures, camera position
and field of view. It does not require a Mineclonia world import. Importing
existing worlds and a block-state fidelity backlog remain separate work.

## Pinned environment

| Component | Version or revision |
| --- | --- |
| Minecraft Java client and server | 26.2, protocol 776 |
| Java | 25 |
| Fabric Loader | 0.19.5 |
| Iris | 1.11.4+26.2-fabric |
| Sodium | mc26.2-0.9.2-fabric |
| BridgeTest | `093807327ea75fbaff91ee3f5dc56c83dbe2efdd` |
| Rust toolchain | nightly-2026-10-14 |
| minecraft-data | `46b78398b6f351958e02fbd266424f0ee0ab138b` |

The installer downloads the official client, server, libraries and assets,
plus the pinned Fabric, Iris and Sodium components. It verifies published
checksums where supplied and records downloaded library hashes. Generated
files and downloaded game assets stay in ignored `build/minecraft/`.

The bridge build uses a separate checkout under `build/minecraft/sources/`.
Its locked `minecraft-data-rs` dependency supplies old item data. Without
an alias from `minecraft:scute` to `minecraft:turtle_scute`, the bridge panics
while preparing definitions. The helper applies that alias to the build
copy, records it in `bridge-build.json`, and leaves the owner's clone alone.
This fixes the observed join failure; it does not establish modern inventory
or item-ID compatibility.

The build also replaces three placeholder node base colours, RGB
`100, 70, 85`, with white. Node colour multiplies the texture independently
of explicit tile and biome tints. The placeholders made both Luanti clients
darker and purple. Explicit tints and underwater post-effect colours remain
intact. The build manifest records the corrected base colour.

BridgeTest reserves node ID 120 for `bridgetest:glowing_air`. The build adds
the ordinary node group `goanna_sky_mirror_x` to that definition. Goanna
checks its name and group after content becomes ready, then reflects the
sun and moon across X to match the bridge's world transform. Unmarked
servers keep their original orbit. This uses normal node metadata over the
unmodified Luanti protocol; the Luanti engine is not patched. Native Luanti
does not interpret this group, so its celestial direction remains different.

During a capture the service sets `GOANNA_COMPARISON_CAMERA=1`. This grants
the native Luanti client `fly` and `noclip`, so it can hold the spectator
camera position. All comparison players use spectator mode in the local
comparison world. These privileges are recorded
in the build manifest and belong to this test installation.
It retains Minecraft server teleports but disables periodic position
reconciliation from Azalea's simulated player, which otherwise pulls the
native camera towards the ground even while the world is frozen. This bridge
mode is a camera instrument for the local stage. Without that environment
variable the bridge retains its upstream privileges and reconciliation.
The flag also disables clock extrapolation and advertises zero time speed,
matching the comparison world's frozen clock. Ordinary launches keep the
bridge's upstream clock behaviour.

## Setup

Use a Java 25 JDK, including `javac`, and Rust installed through rustup. The
bridge also needs the normal native Rust build dependencies, including a C
compiler, OpenSSL development libraries and pkg-config.

```sh
python tools/minecraft/setup.py --java /path/to/jdk-25/bin/java --accept-eula
python tools/minecraft/build_helper.py
rustup toolchain install nightly-2026-10-14 --profile minimal
python tools/minecraft/build_bridge.py
```

Pass `--accept-eula` only after accepting the
[Minecraft EULA](https://www.minecraft.net/eula). The isolated server uses
local test identities, binds to `127.0.0.1:25585`, and disables online
authentication. BridgeTest binds to `127.0.0.1:30985`. The launcher does not
read the owner's Minecraft account tokens or alter their launcher profiles.

All three setup helpers accept `--root DIR`. `build_bridge.py` also accepts
`--cargo PATH` and `--jobs N`. The installed JDK for the initial run is at
`build/minecraft/jdk/jdk-25.0.4.1+1/`.

## Capture

```sh
tools/goanna-render minecraft tools/minecraft/calibration.json
```

The output directory must be empty. Pass `--out DIR`, or copy the job and
change `out`, for each run. Add `--native` for the native Luanti reference,
or use `--only minecraft`, `--only goanna` or `--only vanilla` to capture one
client. The native client
uses the existing Flatpak launcher. Its poses must share one FOV.

The service starts its own local server, builds a small calibration stage
in the dedicated comparison world, freezes world ticks, and runs
one GPU client at a time. It takes the GPU lock and checks for other clients
throughout the run. The clients stay inside headless gamescope. Minecraft's
small Fabric helper handles camera positioning and screenshots inside its
own client; Goanna uses its existing control channel. The native client is
framed by server teleport commands and photographed through gamescope.
Each Goanna run has a fresh user directory and disables its terrain store,
so cached terrain from earlier bridge definitions cannot enter a comparison.
The native client retains its HUD, including bridge inventory warnings.
`time_ticks` selects the Minecraft clock phase, from 0 to 23999. Its default
is 6000, noon; dusk is 12000 and midnight is 18000. The stage disables clock
advancement before briefly unfreezing to deliver camera and clock packets.
Minecraft's helper records the actual clock and sun angle; Goanna records
its sky and shader lighting state. Mismatched capture clocks are rejected.

The stage contains coloured pillars, stone, wood, glass, leaves, water, an
emissive node, an oriented log, stairs and a slab. The stage commands clear
and rebuild their area in this dedicated world. Do not point this server
installation at an existing world that you want to preserve.

Camera `pos` is the Minecraft eye position in block units. `look_at`, or
Minecraft `yaw` and `pitch`, sets its direction. `fov` is the vertical FOV.
BridgeTest mirrors X and offsets cube centres by half a block; Goanna also
mirrors Z when moving into Godot coordinates. The service applies both
transforms. `size` sets image dimensions and `settle_seconds` records a fixed
wait before capture, rather than claiming streaming has completed.

```json
{
  "out": "build/minecraft/my-comparison",
  "size": [1280, 720],
  "settle_seconds": 20,
  "time_ticks": 6000,
  "shader_pack": "/path/to/shaderpack.zip",
  "shader_options": {"SSAO_ENABLED": false},
  "resource_pack": "/path/to/texturepack.zip",
  "poses": [
    {"name": "calibration", "pos": [8.5, 106, 24.5],
     "look_at": [8.5, 101.5, 6.5], "fov": 70}
  ]
}
```

Omit the pack fields for a default-texture, shader-free baseline. Packs can
be directories or zip archives. Shader options use the pack's actual option
names. The profile copies one shader source and the same explicit options
into both Iris paths. The native Luanti client supplies an engine reference;
it does not run the Minecraft shader pack.

`--build /path/to/checkout` selects the Goanna build and records that
checkout's commit and dirty state. It needs a matching compiled extension.
The default remains the main checkout.

Texture profiles overlay the same Minecraft texture names into the bridge's
media and Goanna's texture override path. Normal and specular maps are also
copied. Resource packs need `pack.mcmeta` at their root. Packs which alter
`models/` or `blockstates/` are rejected because BridgeTest's geometry mapping
is built into its binary. High resolution animation, custom models and
resource pack extensions have not been verified. The initial texture test
uses ordinary 16-pixel textures.

The comparison profile resets Minecraft to four mipmap levels and texture
filtering `NONE`. Imported shader-pack terrain samples nearest texels with
blended mipmap levels and no anisotropy, matching this baseline. Native
Goanna terrain retains its anisotropic sampler. The Minecraft sidecar records
its live filtering option, mipmap count and block-atlas sampler. Anisotropic
Minecraft profiles and exact mipmap generation equivalence are not supported
by this baseline.

Each run writes PNGs, frame JSON sidecars, server and bridge logs,
`result.json` and an `index.html` gallery. The result records component and
pack hashes, options, camera transforms, observed client state, shader
translation reports, the Goanna commit and whether its checkout was dirty.
Disconnected Minecraft captures and Goanna captures with no meshed terrain
are rejected. Failed runs record `ok: false` and an error. The service stops
its own processes on success, failure or interruption.

## Qualify the Minecraft reference

An active shader flag and a small image difference establish that clients
agree with a shader's output. They do not establish that the reference
output is correct. Before treating appearance as a calibration target,
capture shader-free noon and midnight controls with the same camera and
check the recorded clocks. Inspect the pack's source, configuration and
advertised game versions when the shader result looks implausible.

Keep diagnostic edits in separate pack copies, record the exact change and
source hashes, and use the same copy in both clients. A diagnostic can
isolate a broken input without qualifying the whole third-party pack.
Retain the original captures as evidence and label suspect references
explicitly in comparison galleries and reports.

## Lighting input probe

The authored diagnostic pack writes four inputs before lighting or
post-processing: raw texture RGB, vertex colour, light coordinates and
encoded view-space sun direction. Its sun path rotation is -40 degrees,
matching the Eclipse pack used in the initial comparison. The same pack
source runs in both clients.

```sh
tools/goanna-render minecraft tools/minecraft/light-inputs.json
python tools/minecraft/light_metrics.py build/minecraft/light-inputs \
  --inputs --out build/minecraft/light-inputs/metrics.json
```

Minecraft's upper row shows texture and vertex colour; its lower row shows
light coordinates and sun direction. Goanna's current screen-space UV
convention swaps those rows. The measurement script pairs the same buffers
explicitly. This is a recorded compatibility difference, not an input
colour correction.

The geometry programs retain explicit biome tints. They disable old face
lighting, so a neutral block should have white vertex colour. Light channels
encode block and sky coordinates directly. Sun RGB encodes its normalised
view-space direction as `direction * 0.5 + 0.5`.

For Eclipse captures, omit `--inputs` to measure the stage's floor, wood,
red, blue, gold and glass surfaces, the sky and the wood's right side. The
side sample detects opposite sunlight directions which front-facing samples
can miss.
The script requires Pillow and the standard 1280x720 calibration camera.
The input probe samples both near and distant floor albedo. RGB standard
deviation records local texture contrast, so equal mean colours cannot hide
an overly sharp distant texture.
It records mean RGB differences and pixel RGB mean absolute error without
altering screenshots. Mean colour agreement in these areas does not establish
whole-frame equivalence. Animated gold and emissive effects, geometry edges,
sky, water and foliage need separate inspection.

Goanna applies a pack's `sunPathRotation` to terrain, shadows, sky and
screen-space uniforms together. `sunAngle` follows the celestial orbit;
`worldTime` retains the server's clock. Luanti's orbit curve approximates
Minecraft's curve between the matched noon and midnight positions.

## Observed runs

On 14 October 2026, Minecraft Java 26.2's unmodified dedicated server served
the calibration world to Minecraft and Goanna through the pinned BridgeTest
build. Goanna used the pinned Luanti 5.17.0 client code and Godot 4.5.1 on the
GPU in headless gamescope. This was a live Minecraft world, with no Luanti
game installed behind the proxy.

The default-texture stage aligned visually between the two cameras. With
Eclipse loaded from the same archive, Minecraft reported an active Iris
shader pack, and Goanna reported translated terrain and water programs plus
three compiled post-processing passes. Goanna drew substantially darker
terrain; sky, water, foliage and animated emissive textures differed. These
captures are evidence for shader debugging, not a claim of renderer parity.

The final shader-free texture gallery is in `build/minecraft/texture-final/`.
Minecraft, native Luanti 5.17.0 and Goanna showed the calibration stage with
the same stone-brick, diamond and birch texture substitutions. Native Luanti
held the camera with the comparison flag enabled. Its HUD and inventory
warning remain visible; its colour and lighting differ from Minecraft's.
Goanna's terrain store had to be disabled to keep earlier bridge terrain
out of the frame.

The Eclipse gallery is in `build/minecraft/eclipse-final/`; the local repeat
job is `build/minecraft/eclipse-job.json`. Capture records include the dirty
checkout used for each run. Headless frame rates are relative observations
only. Software rendering, normal play, Microsoft authentication,
inventory equivalence, entities and arbitrary existing worlds were not
tested by this workflow.

### Lighting corrections

Further live captures on the same server and GPU, using Godot 4.5.1 and the
dirty checkout based on `a83278e1` and `39fc90f7`, isolated the bridge's base
colour and the shader's sun direction. The dusk input probe measured:

| Input | Maximum mean RGB channel difference, out of 255 |
| --- | --- |
| Raw stone texture | 0.50 |
| Neutral vertex colour | 0.00 |
| Block and sky light coordinates | 0.06 |
| Encoded view-space sun direction | 1.00 |

These corrections remove the broad darkening and purple tint. Unmodified
Eclipse, with its default effects enabled, gave the following maximum mean
channel differences over the floor, wood, red, blue and wood-side samples:

| Clock phase | Maximum sampled difference |
| --- | --- |
| Noon | 6.31 |
| Dusk | 2.70 |
| Midnight | 1.16 |

At noon, disabling `SSAO_ENABLED` and `SOFT_SHADOWS` in both clients reduced
the floor's maximum mean channel difference from 6.31 to 1.68. Other
surface samples differed by up to 4.59 with those options disabled, so this
does not establish full lighting equivalence. The dusk side sample confirms
that sunlight now reaches the same side of the wood in both clients.
Both clients' recorded clock phases matched the job exactly.

The gold sample differed by up to 9.17 at dusk. Emissive animation and shader
animation timers are not synchronised by freezing world ticks. Sky, glass,
water, foliage, ambient occlusion and shadow details remain visibly
different. The input probe's row orientation also remains different.

The galleries and numerical reports are under
`build/minecraft/lighting-parity/`: `inputs-dusk-fixed/`, `final-day/`,
`final-dusk/`, `final-night/` and `final-no-occlusion/`. Each directory has
its original screenshots, capture sidecars and `metrics.json`.
The shader contracts, clock and tint checks, native light and shadow checks,
and strict documentation build passed. A joining-time crash during an
earlier capture also led to guarding node-name queries until content is
ready; its local UDP regression test and subsequent captures passed.

Further captures based on `99827bb7` identified an unbound `cloudTex`
sampler in Eclipse's basic sky program. The diagnostic copy sampled that
texture directly: Minecraft's resulting sky was near white, while Goanna's
was black. GLSL initialises unassigned samplers to texture unit zero
([GLSL specification](https://registry.khronos.org/OpenGL/specs/gl/GLSLangSpec.4.60.html)).
The observed Iris basic sky path binds white there. Goanna now uses white
for otherwise unbound 2D samplers on that basic sky path, including samplers
passed through helper functions. Assigned colortex bindings remain intact.
Custom sky texture bindings and non-2D fallback behaviour were not verified.

With the original Eclipse pack restored, the sampled sky's maximum mean
channel difference fell to 4.94. Minecraft's cloud geometry is still absent
from Goanna's pack sky. Blended glass had been using Goanna's native material
instead of the pack's translucent program. Routing blended glass and ice
through that program, with their own block IDs, reduced the glass sample's
maximum mean channel difference from 77.16 to 21.47. Glass remains different;
ice was not present in the live stage. The latest gallery is
`build/minecraft/lighting-parity/sky-glass-corrected/`, and the combined
interactive comparison is `build/minecraft/lighting-parity/index.html`.
Sky sampler regression checks and shader contracts passed. The earlier
lighting and joining changes were also rebuilt from the clean committed
checkout, reusing unchanged dependency objects after source verification;
the clean checkout's shader and joining regressions passed.

### Audit the white sky reference

The earlier white-sky match was agreement with a suspect reference, not
evidence of a correct sky. On 14 October 2026, the captured Eclipse source
was verified against the author's SHA-512-checked
[Eclipse 1.0 release](https://modrinth.com/shader/eclipseshaders/version/1.0).
Both source trees had fingerprint
`eadf7fcb8c856e478b7dd4f19f77227f6c06229686f3ce9d918db52064b4f65d`.
That release advertises support through Minecraft 1.21.8, without 26.2 in
its compatibility list.

Its basic sky shader mixes in `cloudTex` at 80% of the sample's alpha.
The published archive contains no `shaders.properties` binding for that
sampler or definitions for its cloud animation uniforms. The observed
white sample therefore washes out the sky through day and night on this
capture stack. Goanna's white fallback reproduces the observed Iris
binding; that compatibility behaviour does not qualify Eclipse's sky
appearance as a calibration target.

Live shader-free controls on the same unmodified Minecraft Java 26.2
dedicated server produced a blue daytime sky and a dark midnight sky.
A disposable Eclipse copy omitted only this line:

```glsl
skyCol = mix(skyCol, cloudSample.rgb, cloudSample.a * 0.8);
```

Both clients then produced a blue day and a darker blue night, with no
exposure change. Terrain lighting, the sun rotation and post-processing
remained intact. A fixed near-horizon sample measured these Minecraft RGB
means, out of 255:

| Reference | Noon | Midnight |
| --- | --- | --- |
| Shader-free control | 178, 206, 254 | 9, 11, 17 |
| Published Eclipse 1.0 | 241, 246, 250 | 215, 216, 219 |
| Diagnostic without cloud blend | 200, 232, 250 | 70, 84, 104 |

Goanna's diagnostic sample was `201, 235, 255` at noon and `74, 90, 111`
at midnight. The earlier opaque surface measurements were unchanged by
removing this sky blend. The tint, light-coordinate, clock and celestial
direction probes remain evidence for those inputs, independently of the
suspect sky reference.

These new captures used the dirty checkout based on `e219204b`, Goanna's
Luanti 5.17.0 core, BridgeTest protocol 52, no Luanti game, Godot 4.5.1 and
RTX 3090 in headless gamescope. Both clocks matched the requested phase.
The side-by-side audit, source provenance, exact diagnostic change and
measurement report are in `build/minecraft/sky-reference-audit/`.
The earlier comparison viewer now labels original Eclipse captures as
suspect and offers the explicitly modified diagnostic views.

This isolates the washout on the 26.2 stack. It is not an official Eclipse
repair or proof of correct rendering for the whole pack. An Eclipse run
on its advertised supported game version and an alternative supported
third-party shader reference were not tested. Foliage, glass, cloud
geometry, ambient occlusion, shadows and animation remain open comparisons.

Run the camera, capture rejection and profile isolation checks with:

```sh
python tools/test/test-minecraft-comparison.py
```

## Terrain filtering and colour controls

On 15 October 2026, paired raw-texture captures identified anisotropy in
Goanna's imported terrain sampler as a source of excess distant detail.
Minecraft reported filtering `NONE`, four mipmap levels and a nearest
block-atlas sampler with maximum anisotropy 1. Removing anisotropy from the
imported albedo array reduced distant floor pixel error from 4.52 to 2.39 RGB
levels. Raw texture contrast, measured as standard deviation, changed from
11.33 to 8.50 against Minecraft's 8.02. The near-floor input was unchanged.
Both raw floor inputs remained neutral grey; the residual distant mean
albedo difference was 0.75 levels. Mipmap generation differs between the
engines and was not changed.

The lit comparison used the same diagnostic Eclipse copy described above,
with only its suspect unbound cloud blend omitted. Matching terrain filtering
did not remove the sampled floor's blue colour discrepancy. Disabling SSAO
alone left the floor difference at 6.31 levels but reduced the glass sample's
maximum mean channel difference from 21.57 to 2.65. Disabling soft shadows
alone reduced the floor difference to 1.68; glass still differed by 18.27.
These controls isolate the dominant floor error to soft-shadow sampling and
the dominant glass error to the AO path. They do not establish the underlying
causes or justify tint, exposure or shadow-strength adjustments.

Runs used the dirty checkout based on `a9044c80`, the unmodified Minecraft
Java 26.2 dedicated server, BridgeTest protocol 52, no Luanti game, Goanna's
Luanti 5.17.0 core, Godot 4.5.1 and RTX 3090 in headless gamescope. Captured
clocks were 6000. The captures, filtering metadata, input metrics and
interactive before/after gallery are under `build/minecraft/filtering-audit/`.
Foliage transparency, mipmap alpha coverage, soft-shadow depth and noise,
glass AO inputs and baseline cloud geometry remain to be investigated.

## CPU foliage mipmap probe

The paired screenshots alone cannot distinguish a different alpha threshold
from different mipmap pixels. Run both engines' image generators without a
renderer to inspect that input first:

```sh
python tools/minecraft/mipmap_probe.py \
  build/minecraft/data/bridgetest/textures/block/oak_leaves.png \
  --out build/minecraft/leaf-mipmap-probe
```

The probe calls the installed Minecraft 26.2 client's public
`MipmapGenerator.generateMipLevels` API. It reads `mipmap_strategy` and
`alpha_cutoff_bias` from the adjacent `.png.mcmeta`, then exports Godot's
ordinary `Image.generate_mipmaps` result from an isolated dummy-renderer
project. It neither starts a game client nor uses the GPU. The output
contains PNGs at each mip level, logs and `report.json`, with source hashes,
engine versions, alpha means, coverage at 0.1 and 0.5, and visible RGB means.
Pass `--name minecraft:item/NAME` for an item: the default sprite identifier
is `minecraft:block/` followed by the filename stem. `--strategy` overrides
the metadata for a diagnostic control. Use a fresh output directory.

On 18 October 2026, the installed oak-leaf texture's metadata selected
`dark_cutout`. The CPU probe against Minecraft 26.2 and Godot 4.5.1 measured:

| Input | Minecraft | Godot |
| --- | --- | --- |
| Leaf base level, mean alpha | 171.33 | 171.33 |
| Leaf mip 2, mean alpha | 136.13 | 171.50 |
| Leaf mip 2, mean visible red | 121.63 | 97.06 |
| Leaf mip 2, coverage at alpha 0.5 | 68.75% | 100% |
| Stone mip 2, mean red | 159.88 | 159.00 |

Visible base-level leaf RGB matched exactly. Minecraft also changed RGB in
fully transparent base texels. Goanna's terrain array builder currently
generates ordinary Godot mipmaps without this metadata. This is a measured
input mismatch, not proof that it explains the live foliage difference:
shader alpha thresholds, atlas coordinates, face culling and shadow sampling
still need paired captures. At alpha 0.1, both engines retained every leaf
texel at mip 2, so coverage at 0.5 must not be treated as the pack's actual
discard behaviour.

Reports are in `build/minecraft/shadows-foliage-20261018/leaf-mips-final/`
and `stone-mips-final/`. No server or rendered frame was used for this probe.
The first new paired capture was refused because an existing Godot process
held the GPU. At that CPU-only checkpoint, no renderer correction had been
validated.

The same investigation prepared disposable Eclipse controls for a constant
shadow-noise angle and base-level texture sampling, plus hard-shadow and
normal-bias option controls. The first two passed the headless Godot 4.5.1
geometry front end. Their exact changes, source hashes and pending capture
jobs are recorded in
`build/minecraft/shadows-foliage-20261018/prepared-jobs.json`.

For the subsequent sky and broader pack comparisons, the Modrinth release
metadata explicitly lists Minecraft 26.2 for Mellow 3.4.1a (`jIbGxrnZ`),
Complementary Reimagined r5.9.3 (`Bqen1mJX`) and MakeUp Ultra Fast 9.5g
(`pgb0JjoN`). Downloaded archives were verified against the published SHA-512
hashes; metadata and day, dusk and night jobs are saved beside that manifest.
At that checkpoint these qualified version selection only. The prepared
jobs had not been rendered and did not establish a correct sky reference.
The subsequent GPU follow-up below records their live evidence.

## Shadow, foliage and supported sky follow-up, 2026-10-18

The GPU became available after the CPU investigation above. Paired captures
used the unmodified Minecraft Java 26.2 dedicated server, BridgeTest
protocol 52, no Luanti game, Goanna's Luanti 5.17.0 core, Godot 4.5.1 and
RTX 3090 in headless gamescope. The checkout was dirty, based on
`48cbb9d6`, with unrelated Overseer edits. These are visual calibration
runs, not performance measurements or a full game compatibility test.

The diagnostic Eclipse copy still omits only the suspect unbound cloud
blend. A constant shadow-noise angle did not remove the floor discrepancy.
Disabling normal bias did. An authored shader encoded the actual shadow
uniform matrices into RGB, establishing that Iris puts the 100-node eye
offset in `shadowProjection`, while Goanna put it in `shadowModelView`.
Eclipse projects normals with `w = 1` in its bias calculation, so an
otherwise equivalent matrix product does not preserve that calculation.
The helper's `shadow_state.projection` records Iris's native 0 to 1 depth
projection; it is not the OpenGL projection exposed to shader uniforms.
Use the encoded shader probe when checking that convention.
The corrected matrix split reduces the sampled floor's maximum mean
channel error from 6.31 to 0.19 levels on the 0 to 255 scale. This corrects
the inputs rather than reducing the pack's shadow strength.

Separate raw-input captures found a leaf discard threshold of 0.5 in Iris,
against Goanna's former global 0.1, and missing leaf corner occlusion.
Alpha references are now per material, including supported
`alphaTest.<program>` overrides. Imported corner shading averages the four
adjacent shade values, including leaf interiors; native corner and traced
AO retain their existing calculation. A raw leaf vertex-colour sample's
maximum mean channel error fell from 37.18 to 0.36 levels. The final lit
Eclipse calibration samples differ by 0.33 levels for foliage, 0.19 for the
floor and 0.08 for wood. These are fixed-region means, not whole-frame
pixel errors. Animation, distant mipmaps and partial node shapes remain
limitations. The CPU mipmap mismatch above has not been corrected.

The calibration biome is now explicitly plains because BridgeTest's tint
table uses plains colours. Its liquid-definition path now uses the same
existing tint lookup as its other tiles. Minecraft sidecars record the
actual water and foliage tints. This makes the fixture's inputs comparable;
it does not add general biome tint transport to BridgeTest. A new bridge
binary and changed fixture require a fresh Minecraft reference.

Mellow 3.4.1a provides an unmodified, explicitly supported Minecraft 26.2
sky reference. Day and night have distinct, plausible sky output. Its
cloud-noise images specify `texture.blur = true` in `.png.mcmeta`; honouring
this metadata removes Goanna's blocky sampling of its procedural clouds.
The custom image loader now honours both `blur` and `clamp`. An authored
four-sampler GPU proof verifies nearest/linear and repeat/clamp separately;
see [shader pack testing](../develop/shaderpack-testing.md).

A separate Mellow `CLOUD_STYLE=0` control makes Minecraft's effective cloud
setting `FANCY`. Minecraft draws native cloud geometry; Goanna draws none.
Mellow's default procedural clouds do not establish native cloud support.
The bridge also reports cloud height 196 against Minecraft's 192.33 for
this world. Neither native cloud geometry nor that height mismatch is
corrected here. Glass AO remains visibly different in the Eclipse control.

The broader matrix captured Mellow at day, dusk and night, and
Complementary Reimagined and MakeUp Ultra Fast at day and night, with
calibration, close foliage and sky cameras. With the Eclipse and native
cloud controls, this produces 25 paired views. All enabled chain passes
compile: Eclipse 3, Mellow 9, Complementary 9 and MakeUp 6, including its
`prepare` entry. No Goanna script or shader errors were reported. The
[pack status](../develop/shaderpack-status.md) records the visible gaps,
including MakeUp's absent lamp and the native emissive material path that
still bypasses imported geometry shading. These captures do not establish
correct general pass ordering or full pack compatibility.

Final paired captures, metrics and the comparison gallery are under
`build/minecraft/iris-fidelity-20261018/`. Earlier isolation probes and the
sampler proof are under `build/minecraft/shadows-foliage-20261018/`.
The rejected `shadow-projection-fixed` diagnostic has unusable scene
coverage and is excluded from reported improvements. The temporary
`shadow-alpha-fixed` diagnostic had a water alpha reference of zero and
black glass interiors; its glass metric is also excluded. Production water
retains its 0.1 fallback.

Capture validation now rejects missing calibration landmarks and failed or
inactive shader chains. A Goanna-only rerun can reuse a reference:

```sh
python tools/minecraft/light_metrics.py /path/to/goanna-rerun \
  --reference /path/to/paired-reference --out /tmp/comparison-metrics.json
```

Reference reuse requires matching Minecraft and render-mod versions,
bridge binary, fixture commands, shader and resource pack content hashes,
clock, shader options and calibration camera. It is a convenience for
controlled renderer changes, not permission to compare different inputs.

## Face culling and shader block IDs, 2026-10-18

The glass double frame was a material culling error. Imported
single-texture cut-out and translucent programs disabled raster culling to
share one shader across plants and cubes. They did not preserve each
material's back-face flag. The bridge sends `cull=true` for oak leaves and
glass, and `cull=false` for cross-shaped saplings. A per-material
`single_sided` discard now preserves that distinction in colour and
secondary outputs. Native waving leaves use the same flag. Imported
shadow programs keep their separate culling policy.

Culling-only Goanna reruns reuse the matched Minecraft references above.
No bridge, fixture, pack, clock or camera input changed. The duplicate
glass frame disappears in Eclipse, Complementary, Mellow and MakeUp. The
fixed calibration glass sample's maximum mean channel differences are:

| Pack | Before | Culling corrected |
| --- | --- | --- |
| Diagnostic Eclipse | 20.80 | 9.93 |
| Complementary Reimagined | 12.31 | 8.71 |
| Mellow | 26.53 | 6.84 |
| MakeUp Ultra Fast | 26.07 | 12.80 |

Remaining glass shading is not established as AO alone. Pass selection,
material buffers and refraction inputs still differ. The culling change
also ran with Goanna's native shaders on the same comparison server,
without client script or shader errors. These are Minecraft Java 26.2
through BridgeTest protocol 52, no Luanti game, Goanna's Luanti 5.17.0
core, Godot 4.5.1 and RTX 3090 in headless gamescope. Runs began on the
dirty checkout based on `7c5ef8b8`, including unrelated Overseer changes.
The culling correction is committed as `b6dbb4dc`.

A separate authored shader renders leaves as green cut-outs, with all
lighting and shadows removed. It identifies foliage by the verified
plains vertex tint. In the close foliage camera, top-region visible
coverage is 95.11% in Minecraft and 95.92% in Goanna. Forcing mip level
zero changes those to 95.12% and 95.92%. The front region differs by less
than 0.2 percentage points. This measures the union of visible leaf
fragments, not individual faces, layer depth or more distant foliage.
It does not justify a global leaf opacity adjustment. The CPU mipmap
input mismatch remains real but is not isolated as the dominant cause at
this close camera.

The first coverage control selected leaves by `mc_Entity` and failed to
identify any Goanna leaves. Those frames are excluded from the opacity
comparison. That failure exposed a separate setup bug: comparison
profiles left `GOANNA_TEXTURE_MAP` empty. Media loaded under BridgeTest's
flat names, but the semantic material table had no texture-to-block map.
Pack block IDs therefore did not reach the geometry's `mc_Entity` input.

Profiles now generate a map from `block-oak_leaves.png` to
`block/oak_leaves.png`, and corresponding entries for the installed block
textures, even without a resource pack. The profile records the map's
entry count and SHA-256 and rejects missing block textures. This
installation generates 1269 entries. The original ID-based probe now
selects the leaves correctly: its fixed top region changes from 0% green
to 95.92%, matching the tint-based Goanna control. This establishes ID
transport; it does not establish every pack's leaf lighting as correct.
Texture-derived IDs still approximate block states and non-cube shapes;
the existing 512-slot shader table remains a limit.

Culling-only, mapped, native and raw coverage captures are separate under
`build/minecraft/face-culling-20261018/`. Its labelled side-by-side or
divider gallery can select Minecraft, original Goanna or the culling-only
control as the left image.
The `*-mapped` runs add the ID correction. Correct IDs enable pack-specific
leaf effects and can expose further rendering differences: Complementary's
fixed foliage sample grows from 1.52 to 35.30 levels with IDs restored,
while its floor improves from 2.52 to 0.64. The earlier numerical agreement
was not proof that its leaf material inputs were complete. Do not suppress
those IDs to recover that accidental agreement.

MakeUp's fixed foliage sample improves from 14.29 in the culling-only run
to 6.37 with IDs restored. The final glass samples remain 9.93 for Eclipse,
8.78 for Complementary, 6.85 for Mellow and 12.64 for MakeUp. This is not
complete visual parity: Complementary's leaf material response, emissive
material coverage, glass pass inputs and distant leaf mipmaps remain open.
All fourteen follow-up captures, including the excluded ID controls,
reported no Goanna client script or shader errors. The gallery audits all
eight pack/pose entries and their image links. The native shader contract
and twelve comparison-tool tests pass. These are visual and input tests,
not performance measurements. The clients exited and the GPU was released.

### Glass pass and foliage input follow-up, 2026-10-18

The mapped control is intentionally retained: enabling correct block IDs
reveals pack effects which the culling-only control never exercised. A
second follow-up separates geometry, lightmap and AO inputs from the
pack's lighting response. Captures use the same unmodified Minecraft Java
26.2 server through BridgeTest protocol 52, no Luanti game, Luanti 5.17.0
core, Godot 4.5.1 and RTX 3090 in headless gamescope. The checkout is dirty,
based on `d5a20e76`, including unrelated Overseer changes.

An authored probe outputs lightmap UVs directly. Goanna's mean encoded
skylight is about five levels lower than Minecraft's in the sampled leaf
regions, not higher. These are image channel values, not integer light
levels. They do not support excess skylight as the explanation for the
bright Complementary leaves. A second probe requests `separateAo=true`
and outputs vertex alpha as grey. Using the intersection of the earlier
flat leaf masks, top means are 220.71 in Minecraft and 219.83 in Goanna;
front means are 192.68 and 193.59; rear-top means are 233.20 and 231.59.
These close-camera averages do not establish per-vertex or distant parity.
A control-channel audit also finds mesh vertex alpha intact at 1.0; the
shell supplies separate corner AO. An initial read-only audit snippet had
an indentation parse error; the corrected audit ran successfully. That
injected error is not a renderer failure.

Clear glass now uses the pack's translucent `gbuffers_water` program,
retaining its glass ID. Routing alone did not remove MakeUp's black
panels. Legacy translucent shaders also need their alpha test: without
it, fully invisible fragments can still write depth and hide later sky
or geometry. Apply the material threshold before all colour and secondary
writes. Modern output declarations keep their authored discard policy.
Corrected MakeUp calibration and close-foliage frames have clear glass
again. The fixed calibration glass region's maximum mean channel error
falls from 12.64 in the previous mapped control to 10.03. This regional
average understates the black-panel change visible in the close view.

Captures and probe metrics are under
`build/minecraft/glass-leaf-inputs-20261018/`. The side-by-side gallery
labels both engines and allows the previous mapped Goanna frame as a
control. Glass top edges, Complementary leaf lighting, emissive coverage
and distant mipmaps remain open; this is not full shader parity or a
performance measurement.

The final correction was captured at calibration and close-foliage poses
for Eclipse, Complementary Reimagined, Mellow and MakeUp. All four runs
succeeded without client script or shader errors. The eight-view gallery
checks every source image and report link, and its JavaScript passes a
syntax check. Translator regression tests, twelve comparison-tool checks,
style and strict documentation validation pass. All clients exited and
the GPU is free. The separate authored AO probe retains the audit parse
error described above; it is excluded from the error-free pack-run claim.

## Emissive material coverage, 2026-10-20

These runs used the unmodified Minecraft Java 26.2 dedicated server
through BridgeTest protocol 52, no Luanti game, Goanna's Luanti 5.17.0
core, Godot 4.5.1 and RTX 3090 in headless gamescope. Goanna-only reruns
reuse the matched `iris-fidelity-20261018` references; no bridge, fixture,
pack, clock or calibration camera changed. The "before" runs used a clean
checkout at `820ead32`. The "after" runs used `d6299921`, with only the
lamp sample below added to `light_metrics.py` uncommitted. These are
visual input tests, not performance measurements.

An authored probe pack wrote the texture, lightmap, block ID and a constant
marker from its gbuffers programs into four targets, with
`block.properties` numbering the sea lantern, gold and smooth stone. A
copy of the pack and its job are kept as `lamp-probe-pack/` and
`lamp-probe-job.json` beside the frames listed at the end. The Goanna
"before" probe ran from the clean `820ead32` build while the uncompiled
fix sat in the working tree, so its `result.json` reports a dirty
checkout. Minecraft's lantern carried the marker, ID 10 and full block
and sky light. Goanna's showed in the colour target only, drawn by its
native emissive `StandardMaterial3D`, and had no marker, ID or lightmap
in any second output. Two causes followed from the code:

- emissive tiles, and single texture tiles with no native special shader,
  took a `StandardMaterial3D` in `materialFor`, bypassing the pack;
- glowing faces were drawn on `GLOW_LAYER` alone. The cameras drawing a
  pack's second outputs see only `NODE_SURFACE_LAYER`, and the glow mesh
  had no pack shadow copy.

The fix routes those tiles to the pack's terrain, cut-out or translucent
program, as Iris sorts them, through a new single texture opaque surface
(`SURFACE_SINGLE`, translated from `gbuffers_terrain`). Glowing faces now
carry `NODE_SURFACE_LAYER` and a shadow copy. Node lights leave that layer
out of their shadow caster mask, so a lamp still does not shadow its own
light; terrain still casts from layer 1. After the fix, the probe's
lantern carries the marker and ID 10 in Goanna too. Its encoded lightmap
reads 218.82 and 247 for block and sky light, against Minecraft's 247 and
247: the face's block light is lower in Goanna.

Fixed calibration samples, maximum mean channel error in levels against
the Minecraft reference:

| Pack and phase | Lamp before | Lamp after | Floor before | Floor after |
| --- | --- | --- | --- | --- |
| MakeUp Ultra Fast, night | 232.37 | 70.59 | 13.54 | 13.48 |
| MakeUp Ultra Fast, day | 74.52 | 47.29 | 7.12 | 7.13 |
| Complementary Reimagined, night | 1.04 | 1.06 | 17.74 | 17.76 |
| Complementary Reimagined, day | 2.04 | 2.03 | 0.63 | 0.63 |
| Mellow 3.4.1a, day | 8.92 | 8.92 | 4.75 | 4.75 |
| Diagnostic Eclipse, day | 42.51 | 24.51 | 0.19 | 0.19 |

The lamp sample is the lantern's front face, `(628, 300, 652, 328)`, now
part of `light_metrics.py`. Complementary's lantern saturates that sample
in both engines; its earlier native emission happened to match, and the
pack's own emission now produces it. A sample of the light pool just in
front of the pillar is unchanged by the fix: MakeUp's night pool reads
RGB 121.01, 95.90, 77.19 against Minecraft's 143.25, 116.15, 94.69, and
Complementary's 122.10, 106.22, 115.37 against 106.82, 91.08, 97.68. The
night floor and pool differences of both packs are therefore not caused by
the missing pack lamp; they remain open.

The lantern still looks different. BridgeTest sends the five-frame
`sea_lantern.png` strip with no animation, so Goanna draws all five frames
squashed onto each face, where Minecraft shows one. MakeUp's halo around
the lamp is also absent in Goanna. Mellow's lantern pixels were identical
before and after; why its chain hides the material change was not
investigated. Mellow's water sample moved from 13.13 to 41.28, but the
"before" run was the outlier: the earlier Goanna Mellow runs read red
channel means of 92.4 to 101.7 there, like the "after" run's 99.3. Water
reflections vary between runs and were not changed here.

Goanna's native shaders, with no pack, drew the lamp identically before
and after: the lantern regions of the calibration and close lamp poses
have equal means at day and night, and whole-frame mean differences stay
under 1.6 levels, from cloud and foliage motion. Translator tests,
`goanna_iris_shadow_test` and the Godot front-end check of the bundled
pack, MakeUp, Complementary and Mellow pass. All eighteen captures
reported no Goanna script or shader errors. Torch flames, ice and lava
keep their native materials under a pack and are not covered by this fix.

Frames and metrics are under
`build/minecraft/emissive-coverage-20261020/`, in `before/`, `after/`,
`probe-before/` and `probe-after/`.

## Native clouds through the pack, 2026-10-20

The 2026-10-18 Mellow `CLOUD_STYLE=0` control showed Minecraft's `FANCY`
clouds and none in Goanna. Goanna's own clouds are marched in its sky
shader, which a pack's sky program replaces and no pack program can run
on. Goanna now builds Luanti's cloud deck as geometry while a pack draws
the sky, and draws it with the pack's `gbuffers_clouds`, falling back to
`gbuffers_textured` and `gbuffers_basic`. Shaders.properties `clouds=off`
translates no cloud program; `fast` gives a flat deck. `cloudHeight` was
already supplied from the server's cloud height; a translator test now
also checks that the cloud program reads it.

Captures used the unmodified Minecraft Java 26.2 dedicated server through
BridgeTest protocol 52 (binary `15dac257`, unchanged since 2026-10-18), no
Luanti game, Goanna's Luanti 5.17.0 core, Godot 4.5.1 and RTX 3090 in
headless gamescope. The Goanna build was a worktree based on `820ead32`
with the change uncommitted. Mellow, Complementary and MakeUp were
Goanna-only reruns against the 2026-10-18 Minecraft references in
`build/minecraft/iris-fidelity-20261018/`; `light_metrics.py` accepted
each reference as matched. Eclipse was captured paired, with the sky pose
added to its job. No performance was measured.

Every rerun reported its chain active and no Goanna client script or
shader errors. The geometry report records the cloud program and the
pack's `clouds` value:

| Run | `clouds` | Cloud program | Floor | Sky sample |
| --- | --- | --- | --- | --- |
| Mellow, `CLOUD_STYLE=0` | unset | `gbuffers_clouds` | 4.75 | 6.00 |
| Mellow default | `off` | none | 4.75 | 5.78 |
| Complementary Reimagined | `off` | none | 0.64 | 1.22 |
| MakeUp Ultra Fast | `off` | none | 7.03 | 7.21 |
| Diagnostic Eclipse, paired | unset | `gbuffers_textured` | 0.19 | 4.00 |

Floor and sky columns are the calibration pose's maximum mean channel
errors, in levels of 255. Against the previous Goanna frames they moved
by at most 0.3 levels, apart from MakeUp's sky sample, which improved by
0.8. Eclipse's wood, foliage and glass samples stay at 0.08, 0.33 and
9.93. Mellow's `alphaTest.gbuffers_clouds` (`GREATER 0.005`) is applied.

In the Mellow control's sky pose, the share of low-saturation pixels above
the horizon band was 0.0002 before, 0.41 now and 0.16 in Minecraft. The
mean colour of those pixels is RGB 125.6, 140.5, 173.9 in Goanna and
139.5, 162.4, 191.4 in Minecraft. Mellow's default sky frame is identical
to its 2026-10-18 frame. Complementary and MakeUp show only their own
procedural clouds, Complementary's moved on by its clock. Eclipse has no
`shaders.properties`, so both engines draw box clouds through its
`gbuffers_textured`; in its sky pose a cloud underside is RGB 153, 153,
175 in Goanna and 171, 188, 206 in Minecraft.

These frames establish that the client's clouds reach the pack, not that
they match. Luanti's deck is what a vanilla Luanti client draws: 64 node
cells against Minecraft's 12, from Goanna's noise rather than Minecraft's
cloud texture, which the protocol does not carry. Coverage therefore
differs. BridgeTest sends `height: 196.0`, a constant in `src/s2c/defs.rs`,
and thickness 4. Minecraft's base is 192.33, which is 191.83 in the bridge's
frame, shifted half a node like the camera (106 becomes 105.5). The height
difference is the bridge's, not Goanna's: Goanna reports and uses the
server's value. It was not corrected here because rebuilding the shared
bridge would change the binary every matched reference depends on.

Frames, logs and metrics are under
`build/minecraft/native-clouds-20261020/`: `mellow-clouds`, `mellow-day`,
`complementary-reimagined-day`, `makeup-ultra-fast-shaders-day` and
`eclipse-day-sky-paired`. The earlier control frame without clouds stays
in `iris-fidelity-20261018/mellow-baseline-clouds/`.

Goanna's own clouds without a pack were checked through the render
service on the Mineclonia fixture, served by the Luanti 5.17.0 Flatpak
server, at a sky pose. Main's build at the time and this worktree's build
drew the same marched clouds, with a mean pixel difference of 1.3, 0.8
and 0.5 levels per channel from the clouds' drift between captures and
no shader errors in either. The frames are under
`build/native-clouds-20261020-nopack/`. Main's checkout carried
unrelated Overseer edits.
