# Baked terrain surfaces

TDL worlds can supply distant land directly from their elevation and climate
bake. The client requests two-dimensional tiles, rather than expanding each
column into a vertical stack of protocol-7 voxel summaries. No mapblocks
need to emerge for this surface to appear.

This first implementation reads the existing bake through `tdl_far.lua` and
caches the resulting surface tiles in server mod storage. It does not add a
new offline export to the TDL baker or download a second world package.
An offline surface export could later supply these same records.

## Stream and storage

The existing server grant remains authoritative. A provider with a revision
identity advertises `surface_tiles=1` and `surface_revision=<sha1>` on
`goanna:v1`. The client accepts server-authored messages only. Old providers,
old server mods and ordinary servers retain the earlier rendering path.

Requests and replies use this format:

```text
surface? 1 <revision> <step> <tile-x> <tile-z>
surface <player> 1 <revision> <step> <tile-x> <tile-z> <names-csv>|<base64>
```

Each tile contains 16 by 16 samples. Supported sample spacings are 4, 16,
64 and 128 nodes. Coordinates are in Luanti space, using floor division
across negative coordinates. Samples are taken at cell centres.

Each sample occupies seven bytes:

| Field | Representation |
| --- | --- |
| Ground node height | Big-endian signed 16-bit integer |
| Water node height | Signed 16-bit integer; -32768 means absent |
| Top material | One-byte palette index |
| Side material | One-byte palette index |
| Water material | One-byte palette index |

Palette index zero means absent. Each unencoded tile is 1,792 bytes, plus
its palette. Base64 may omit padding, as Luanti's encoder does. The client
checks payload length, version, recipient, revision, coordinates and palette
indices before admitting a requested tile. An unknown tile does not count
as complete horizon coverage.

Requests are bounded to eight per player and 32 across the server. A server
step samples at most 256 columns, stopping after approximately 2 ms, and
sends at most four completed replies. A single bake tile read can exceed
that time budget; it is not a hard limit on filesystem or decode latency.
The server keeps 128 reply tiles in memory and persists completed replies
in mod storage. The client keeps up to 512 tiles and 32 queued replies.

The persistent namespace includes the bake manifest, TDL settings, complete
game biome palette and provider/reader/classifier code. A bake replaced in
place must change its manifest identity or `tdl_surface_revision` setting.
The implementation does not hash every raster file at server startup.

## Coverage and presentation

The client first requests 128-node samples across the whole permitted view.
It then requests 64-node samples within 3,072 nodes, 16-node samples within
1,024 nodes, and 4-node samples within 384 nodes. A missing child keeps its
available parent. Refinement does not wait for neighbouring tiles.

Surfaces have horizontal tops and vertical risers. Geometry writes depth;
the old sky-painted panorama is disabled for tile-enabled worlds. Water
has its own level and uses the existing water material. Adjacent cell edges
are split where necessary to join different resolutions. Unknown outer
neighbours do not create deep rectangular curtains.

CPU meshing runs on the existing mesh workers. Uploads use small spatial
chunks and a frame budget. Only changed chunks are uploaded, hidden until
the complete replacement is ready, then swapped together. The preceding
surface stays visible throughout. Voxel meshes whose footprints were cut
out of the surface are retained until a subsequent surface publication has
observed their replacement or restored their fallback.

Synthetic voxel summary requests cover the nearby 512-node region. Actual
received and stored voxel geometry can still refine the surface throughout
its permitted range. Published membership and derived ground columns
supply the four-node coverage footprints. A tile grant can extend to 8,192
nodes; it no longer hits the earlier unconditional 4,096-node client cap.
Remote servers still choose the maximum distance. The existing local
launcher already grants the player's selected distance.

## Limits

The bake supplies ground and water only. Trees, buildings, caves and
overhangs require actual voxel data; an unexplored baked column cannot
supply them. Stored voxel geometry remains available at visited locations,
subject to the existing detail and mesh-distance settings.

Coarse steps, material boundaries and resolution changes remain visible.
Coverage footprints come from derived voxel columns, so this is not an
exact geometric seam solution for every cave mouth or edited cliff. TDL's
detail noise and surface decorations also differ from its base elevation.
The field still ends at the authorised distance; fog cannot make that an
infinite horizon, especially from very high flight.

## Verification

`goanna_surface_test` checks signed coordinates and heights, bounded requests,
wire rejection, unknown coverage, partial and out-of-order refinement,
horizontal/vertical geometry and coverage footprints. The existing LOD,
horizon and storage tests remain applicable.

`luajit tools/test-surface-server.lua` checks grants, request limits, duplicate
collapse, revision invalidation and memory/disk cache reuse. The local
launcher rendering test checks the generated server configuration.

The [live report](perf/baked-terrain-2026-09-14/report.md) records Asuna
loading, flight timings and screenshots. `tools/terrain-baked-review.py`
repeats the fixed-camera load and flight captures on that disposable fixture.
