# Ice rendering

Ice keeps its side faces beside water. The old mesher workaround removed
both sides of that interface to hide transparency sorting errors, leaving
an open block when the camera went underwater. Water still gives up its
coplanar face; ice owns the boundary.

Transparent ice-group nodes use `ice.gdshader`. The body colour now comes
from procedural internal structure. The surface retains the accepted normal
and roughness maps, tile-derived facets and backlighting. The old tile no
longer paints the ice's colour or internal inclusions. Relief changes
shading, not the block silhouette. Packed and blue ice retain their opaque
node materials.

## Procedural interior

Two shared, deterministic 3D noise textures describe fractures and cloudy
inclusions. They are generated once by Godot's
[NoiseTexture3D](https://docs.godotengine.org/en/4.5/classes/class_noisetexture3d.html),
using cellular distance differences and Perlin noise respectively. The
fracture volume is 128 cubed; the cloud volume is 64 cubed. Their world-space
periods differ (12 and 11 nodes), with a slow warp and uneven visibility to
break up regular cell outlines. Adjacent nodes sample the same field.

The shader takes 24 samples along a refracted ray through a bounded optical
layer. Fractures, cloudy regions and sparse ellipsoidal air pockets scatter
light at different depths. Their positions therefore shift relative to the
surface as the camera moves. Frost broadens the surface highlights, and
coloured absorption removes more red from transmitted light. Fine bubbles
fade as their projected size becomes too small.

This remains a material approximation: the sampled layer is 1.15 nodes deep
along the face normal, adjusted for refraction angle. It neither traces the
actual connected ice volume nor detects its exit face. A one-node lake sheet
and a thick formation therefore do not yet have physically distinct optical
thicknesses. The retained surface facets also still repeat with the tile.

## Transmission and water ordering

Ice writes ordinary opaque depth. `ice_transmission.gd` renders a half-width,
half-height HDR background view with the translucent ice meshes excluded
on layer 3. The ice material samples that view as transmitted light. Water
therefore finds ice in both its opaque colour and depth buffers, rather
than losing it when it samples a scene that excludes transparent objects.

This avoids relying on mapblock alpha sorting or a fixed render priority.
The discarded alpha-hash trial produced obvious grain; it is not used.
Godot documents the relevant limitation in its
[screen-reading shader reference](https://docs.godotengine.org/en/4.5/tutorials/shaders/screen-reading_shaders.html).

The capture omits the final grade, bloom, screen-space effects and fog.
The main view applies the grade and the fog between the camera and the ice.
Capture activation uses the visible ice meshes' bounds and camera frustum.
The background is disabled when no ice bounds intersect that frustum, or
when Solid ice is enabled. The capture excludes the final light-shaft quad.

Solid ice remains available in Video settings. The new default is off;
existing saved preferences are respected, so an older profile may still
need that toggle switched off to enable transmission.

## Limits

This is a softened, screen-aligned background approximation, not nested
refraction through multiple ice volumes. All near translucent ice is
excluded from the background, and transmission uses the bounded procedural layer,
not a traced thickness through an iceberg. The background omits
fog beyond the ice. Distant ice retains its existing coarse representation.
The capture has a real graphics cost and needs wider landscape assessment.
At y=79.49/79.51 the camera near plane clips the water surface, leaving a
bright horizontal band. The sweep records that remaining waterline artifact;
the geometry assertions do not claim to fix it.

## Procedural material review

See the [material comparison](perf/ice-study-2026-09-13/index.html) for the
procedural pass against the previously accepted rough ice. Six pairs swap
only the shader in the same frozen scene. Camera, sky, lighting and grading
are held still within each pair; water animation continues. The review also
has a nine-view orbit and separate captures from a fresh launch. These use
the same disposable Mineclonia pool, not a natural landscape.

The first edge-view sample at 1600x900 on an RTX 3090 measured median frame
times of 8.73 ms for the accepted material and 8.82 ms for the procedural
material. Main-view GPU times were 6.25 and 6.42 ms. Each sample contains 120
uncapped frames after 45 warm-up frames, with transmission enabled in both.
Capture GPU times varied between samples; these numbers do not isolate an
exact shader cost or predict performance on other hardware.

## Earlier geometry review and verification

See the [ice comparison](perf/ice-2026-09-13/index.html). These are live
Mineclonia captures from a disposable pool on Luanti 5.17.0, rendered with
Godot 4.5.1 Forward+. They are geometry and material diagnostics, not a
natural frozen-lake showcase. Paired views share camera and server time;
clouds were allowed to evolve between captures, so these are not grading
comparisons. The two close-ups show only the revised material.

The submerged sheet edge has 66 triangles spanning its 33-node width.
The waterline sweep checks cameras at y=78.8, 79.3, 79.49, 79.51, 79.8 and
80.2 around the surface at y=79.5. It also verifies that facing away disables
the background. Native build, Godot import and style checks passed.

In the fixed pool edge view at 1600x900 on an RTX 3090, a 90-frame uncapped
sample measured median frame time of 5.5 ms with transmission disabled and
7.8 ms enabled. The extra 800x450 viewport measured about 2.2 ms GPU time.
These are fixture measurements, not a frame-rate guarantee for landscapes.

The disposable server fixture and capture script are in `tools/ice-review`.
Copy that directory into a test world's `worldmods/goanna_ice_review`, start
Mineclonia and connect a client with `GOANNA_CONTROL=30862`. The fixture
command requires the server privilege and replaces its pool coordinates;
use a disposable world. Then run:

```sh
python3 tools/ice-review/capture.py before --create-fixture
# Rebuild and relaunch the changed client against the same test world.
python3 tools/ice-review/capture.py after
```

The fixture occupies x/z=-17..17 and y=72..89. Baseline and revised clients
must use the same texture pack, appearance, weather and camera settings.
