<!-- SPDX-License-Identifier: LGPL-2.1-or-later -->
# Cloud layers, 2026-09-29

All three cloud styles now draw low, middle and high layers. Block cells
have deterministic base-height variation as well as different crown
heights. Fluffy clouds retain their rounded square bodies. Volumetric
cloud bases vary with their weather envelope.

The server's cloud height anchors the low layer. The middle and high bases
are at least 480 and 1100 nodes above the existing smoothed regional ground
reference. Thick clouds increase the spacing to keep their bounds apart.
This reference follows known terrain slowly and holds its last answer when
the terrain scan fails. It is not the camera's altitude. Regional changes
can therefore move the upper decks gradually; these are not a global
meteorological simulation or an endless stack of clouds.

Each layer has separate noise placement and drift. Overcast and the existing
precipitation signal strengthen middle clouds and reduce the high layer's
coverage. The high layer has lower optical density. Server-hidden clouds
still suppress every layer. Mist retains its existing ground reference.

The local atmosphere and camera-opacity calculation share layer bounds,
block occupancy, crown heights and weather-driven base displacement. Local
fog remains an approximation of the sky's texture-based cloud density.
Terrain shadows use the first layer above the regional ground, with the
existing single-field approximation. Cloud lighting still shares the low
deck's beam and server palette; layers do not shadow one another.

Slabs composite from near to far in both viewing directions. Opaque nearby
clouds end the traversal, and local fog rejects empty heights before noise
sampling. Clear sightlines can march three layers instead of one. This
change has not had a calibrated performance comparison or handheld test.

## Validation

- Godot 4.5.1 Forward+, local Luanti 5.17.0, devtest, a disposable platform
  at 2500 nodes. [Fluffy](live-fluffy.png) and
  [volumetric](live-volume.png) clouds appeared above the platform. These
  live captures used software rendering because another client had the GPU.
- Live layer bases were 128, 2980 and 3600 nodes. Moving the camera from
  2502 to [4000 nodes](live-above.png) retained those heights. The fog
  material received the same layer descriptors as the sky.
- An offline production-shader study ran on an RTX 3090 at 960 by 540:
  [below](study-fluffy.png), [between](study-between.png) and
  [above](study-above.png) the layers. It covered all three styles, fair
  weather, overcast and a 2500-node ground reference. Hidden clouds and zero
  coverage produced identical images. These study images precede the
  equivalent change to compositing from near to far.
- `project/tests/cloud_layers.gd` passed: high terrain, extreme server
  thickness, disjoint jitter bounds, weather responses, hidden clouds and
  local fog inside and outside every layer.
- Graphics-profile transitions and render-feature tests passed. Shader
  parsing and repository style checks passed.

The offline study is `project/tests/cloud_layer_study.gd`. Add an instance
inside a headless control client and await its `capture(directory)` method.
It owns a viewport and does not connect to a server.
