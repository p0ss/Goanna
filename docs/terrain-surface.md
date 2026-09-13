# Terrain surfaces and detail selection

The ground pass reconstructs connected surfaces from received terrain
columns. Floating objects retain voxel geometry. Detail selection uses
projected size and altitude, so flying above the ground no longer retains
a cylinder of full-detail blocks beneath the camera.

This is an incremental change to the region renderer. Coverage gaps and
visible changes between resolutions are not fully solved. The
[flight report](perf/terrain-surface-2026-09-13/report.md) records the
current result and its limits.

## Shape and boundaries

Shared corners select a measured column height in a consistent order.
They do not average the surrounding heights: that prototype rounded
ridges into a blanket and was rejected. Fine edges interpolate the
coarser neighbour's anchors. Surface normals follow the resulting planes.
Cliffs retain vertical edge faces, and ground stays below known water.

Detailed neighbours contribute immutable occupancy data to boundary
construction without becoming members of the far mesh. Boundary faces
extend below the neighbouring exact column top. Previously they could
stop a whole height difference above it, exposing a gap.

Near-to-far transitions retain the detailed mesh until the replacement
region is published. The live-block and pruning paths previously had
early removal paths that bypassed this handoff. Region revision checks
reject obsolete worker results before publication.

## Provider summaries

Terrain-diffusion summaries describe an exterior shell and omit buried
volume. Treating that omission as ordinary voxel air classified parts of
a hillside as floating objects, producing strips and underside plates.

The optional bit 32 in protocol 7's existing 92-byte summary record marks
provider exterior shells. The server sets it only for synthesised records
and lazily upgrades stored provider records using their existing origin
metadata. Real voxel records remain unmarked. Older clients ignore the
bit; unmarked replies from older servers retain the previous behaviour.
Both distributed server-mod copies contain this change.

The client classifies occupied provider shell cells as ground without
inventing filled occupancy below them. Prepared storage schema 2 retains
the marker and rebuilds incompatible cached records. The provider fix
requires the updated server mod; detail selection and handoff changes are
client-side.

## Geometry budget and capture

The full-detail radius is capped at approximately five pixels per node,
using viewport focal length and three-dimensional distance to the nearest
point of each block's bounds. The configured distance remains an upper
limit. Larger output resolutions and narrower fields of view retain more
detail. Inward hysteresis avoids repeated switches at the threshold.

Region capture visits known entries using ordered spatial rows instead
of probing every position in a mostly empty cube. It still captures on
the main thread; meshing and prepared-data loading run on workers.

## Remaining limits

- Coarse facets, stepped cliff strips and abrupt material/detail changes
  remain visible. Boundary faces close height gaps but do not make a
  seamless transition to the near voxel surface.
- Unknown frontier terrain has no guaranteed surface. This pass does not
  establish continuous coverage all the way to the horizon.
- Summaries still use the existing four-node records and coarser levels,
  rather than a dedicated high precision heightfield protocol.
- Existing far-to-far handoff freeze timeouts remain. The live test is not
  proof that every asynchronous transition remains covered under load.
- Main-thread publication and some capture work remain, and resident
  terrain memory is not globally bounded by the prepared cache limits.
