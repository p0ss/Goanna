<!-- SPDX-License-Identifier: LGPL-2.1-or-later -->
# Fluffy block clouds, 2026-09-27

Cloud style 1 now integrates a noisy density field inside the rounded box
shape. It replaces the opaque rounded surface from the previous review.
The broad block outline remains, with eroded edges, partial transmission
and sunlight attenuated through the body. Low selects this style.

[Close view](fluffy-close.png), captured in a live headless client using
Godot 4.5.1 Forward+, an RTX 3090, local Luanti 5.17.0 and Mineclonia.
The disposable test_world copy uses the cloud fixture at noon, with clouds
at 128 nodes and the camera at 64. The source world was not changed.

The [four-player view](fluffy-four-player.png) passed at 1280x800, including
a return to plain blocks after the style sweep. The earlier native startup
allocation failure did not recur in this run; its cause remains unknown.
Both owned clients exited. [Raw recordings and logs](recordings.tar.gz)
include the settings, frame counters and screenshots.

The renderer traverses occupied grid cells and integrates 16 density samples
per cell (eight for the radiance cubemap). Three samples towards the sun
estimate attenuation inside each cell. Nearly opaque rays stop early;
translucent edges composite with cells farther along the ray. Noise erodes
within the rounded bounds, avoiding a clipped surface at cell boundaries.

Plain blocks still avoid the noise texture. Fluffy blocks allocate it
lazily and reuse it when switching to the full volumetric style in the same
view. Views currently have separate textures. Sun attenuation is local to
each cell: adjacent cells do not cast shadows into each other. The local
atmosphere volume and terrain cloud-shadow approximation are unchanged.

These are appearance checks with one-second recordings, not a calibrated
performance comparison. This style adds density and light sampling; there
is no established saving versus full volumetric clouds or validated
handheld budget.

Shader compilation, all 25 tier transitions, per-view lazy texture
allocation and reuse, feature-switch tests, preset-plan consistency and
style checks passed. The [shader change](shader.patch) is retained for
review against the preceding opaque rounded-box implementation.
