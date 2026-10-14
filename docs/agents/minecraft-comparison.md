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
