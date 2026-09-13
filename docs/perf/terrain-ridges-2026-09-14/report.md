# Stepped ridge revision

The sloped reconstruction at checkpoint `6765c73` changed voxel ridges
into diagonal ramps. Ground tops now stay horizontal, with vertical faces
between different heights. The storage worker, projected-size selection
and delayed near/far handoffs remain in place.

## Live ridge views

The [ramp view](ramp-before.png) and [stepped view](steps-after.png) use a
disposable copy of the Asuna Terrain Diffusion world `fdsea`, Luanti
5.17.0 and Godot 4.5.1. The camera is at
`(643.0611, 530.8826, -31.1183)`, pitch -20 and yaw 310.49, with 1600 by
900 output and approximately 110 degree diagonal FOV. These are live
client captures. The user selected the above-ground viewpoint.

Camera and noon lighting match across the client restart. Clouds and
loaded coverage evolved, so this is a geometry comparison, not a grading
comparison. The stepped view shows horizontal ledges and vertical rock
faces where the previous view had diagonal facets. Large steps and the
near/far detail change remain conspicuous. No claim of a finished terrain
transition is made.

At the stepped capture, the server grant was 4096 nodes, storage processing
errors were zero and region dirty/building counts were zero. Visible
primitives were 302,311 and retained LOD quads were 73,418. These are a
single static observation, not a before/after performance benchmark. The
earlier ridge flight timings do not measure this geometry revision.

## Boundary correction

The stepped mixed-resolution test exposed a second culling problem: a
coarse region inspected its fine neighbour at the coarse resolution,
mistook their heights for equal, and omitted the joining face. Boundary
construction now reads the neighbour at its displayed resolution. Where
multiple finer columns meet a coarse face, the lowest known height keeps
the step closed. Exact near-neighbour aprons remain in place.

## Flat horizon investigation

The separate sky panorama read the ceiling of the chain's 16-node cell
as its surface. Its solid-envelope logic also overlooked liquid-only
columns and their separate water heights. It now reads exact retained
boundary records or the finest available summary data, preserving the
water height and material. Extraction has a two millisecond slice budget.

Native regressions check that one-node shores stay one node high, liquid
surfaces retain their height and material, mixed seabed cells do not
become walls, elevated land remains visible and air invents no surface.
This establishes the height-extraction bug and its correction. The
original reported flat-horizon screenshot has not been reproduced at an
identical viewpoint, so this report does not claim that every element of
that screenshot is explained or fixed. The underground diagnostic view
was invalid and is excluded from the comparison.

## Local-server defaults

The normal launcher wrote the distant-rendering grant but omitted
`enable_mod_channels = true`, which its capability exchange needs. It now
writes both. Enabling that transport and reconnecting the disposable
Asuna client changed its empty server-options response into the expected
4096-node grant and terrain-summary capability. External servers still
control their own grant.

`project/tests/local_server_rendering.gd` exercises generated settings
with a harmless `/bin/true` process stub and temporary data directory.
It passes without launching Luanti or changing user worlds. Native LOD,
horizon and storage tests, repository style and diff checks also pass.
