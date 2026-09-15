# Forest previews for baked terrain

Unvisited TDL terrain carries a separate forest layer. The near preview replays
surface schematic decorations using the game's placement rules, biome palette,
world seed, rotations and schematic voxels. Ground and tree roots share
`tdl_column.lua` with the mapgen. This reads the bake without emerging or writing
mapblocks.

The geometric preview uses the same 1, 2, 4 progression as the retained voxel
renderer. Its horizontal distance bands are:

| Tree cell | Terrain sample | Outer reach (nodes) |
| --- | --- | --- |
| 1 | 4 | 512 |
| 2 | 8 | 1,024 |
| 4 | 16 | 2,048 |
| Statistical canopy | 64 | 4,096 |
| Statistical canopy | 128 | Server/client horizon |

These reaches are capped by the negotiated horizon. With detailed server data
available, retained world geometry uses the same bands as a minimum quality;
projected-size tiers can keep it finer. The extra eight-node terrain
rung avoids the previous four-to-sixteen jump. Overview tiles load first; geometric
refinement proceeds near to far across the three forest rungs. Cold geometric
coverage can still take minutes in a large dense forest; the canopy approximation
remains visible during refinement.

Chunk caches retain all three tree reductions. The mesher removes interior faces
between vertical runs, including mixed-resolution neighbours, and merges coplanar
rectangles without filling crown openings. Coarse samples carry foliage material,
crown height and coverage from the game's schematic/density definitions. They are
floating crowns above independently rendered ground, rather than solid columns
from the ground to the canopy.

Actual summaries discover available mapblocks, then a separate detailed stream
supplies their nodes for the one- and two-node rungs. Coarse four-node summaries
remain discovery data while a finer preview is visible. The client builds the
same compact voxel boundaries used by retained world geometry, preserving
trunks, crown openings, node colours and lighting.

Published world geometry removes its corresponding prediction. Synthetic ground
summaries only replace the ground and cannot erase the forest. Provider revisions
invalidate synthetic server summaries while retaining summaries of actual world
data. Prediction removal is three-dimensional: a ground block cannot erase a
crown above it, and a known empty block can remove a chopped tree. Replacement
meshes become visible in the same publication as the preview mask. The mask uses
immutable published inputs and the actual ground resolution, including one-node
ledges. LOD ground coverage comes from emitted top faces. A buried block or a
column ceded to another tier cannot claim coverage merely because its occupancy
chain contains ground; that previously opened permanent sky gaps at the boundary.

TDL recalculates lighting after placing decorations. This fixes zero-light leaves
in newly generated chunks; existing chunks retain their saved lighting until the
server recalculates it (for example with its `fixlight` command).

Revision identities include the bake, settings, biome/decorations, schematic
files and preview/mapgen source.

The prediction currently covers schematic trees with leaf/tree node groups;
L-system trees and arbitrary mapgen callbacks are not reproduced. Exterior
placement skips cave floors. Probabilistic schematic nodes use a deterministic
preview RNG rather than the engine's global schematic RNG, so individual random
leaves can differ when generated terrain replaces the prediction.

## Transport

`surface_tiles=2` adds compressed forest runs to surface tiles; version-one
requests still receive their original terrain-only layout. Supported sample steps
are 4, 8, 16, 64 and 128. The v2 decoded payload starts with the original 256
seven-byte terrain samples, followed by twelve-byte forest records:

| Field | Encoding |
| --- | --- |
| Local X, Z | Two big-endian unsigned 16-bit integers |
| Bottom Y, exclusive top Y | Two big-endian signed 16-bit integers |
| Material palette index, param2 | One byte each |
| Horizontal cell size, coverage | One byte each |

The payload is deflate-compressed and base64-encoded after the shared material
palette. Dense tiles use `surface_part` messages of at most 60,000 body bytes;
the client assembles only requested revision/key pairs, with bounded part counts
and memory, before publishing a complete tile. Geometry is never coarsened to fit
a packet. The client also bounds decoded sizes, coordinates, material indices
and cell sizes. Server work yields cooperatively against a two-millisecond tick
budget, with bounded pending requests and caches.

`far_fine=1` advertises the detailed block stream. Requests contain a version,
request token and mapblock position. Replies carry a name palette and compressed
runs of node count, palette index, param1 and param2. Unknown blocks are explicitly
unavailable, distinct from 4,096 known air nodes. Reads never generate terrain.
Queues, wire sizes, decompression, coordinates and the negotiated range are bounded.
Dig/place notifications trigger refreshes; polling also observes bulk/ABM edits.
Identical replies do not rebuild geometry. Near meshes take precedence over remote replies, and a newer live block revision
invalidates an outstanding read. Retained blocks outside the near field also
refresh: having an old block in memory does not make it current server data.

## Verification

- `build/goanna_surface_test`: protocol validation, signed coordinates, bounded
  decompression, partial terrain refinement, crown openings, separate canopy
  volume, actual fine-block decoding, known-empty crown removal, fine ground
  coverage and synthetic-ground versus actual-world handoff.
- `build/goanna_lod_test`: projected-size voxel tiers, compact one-node ground,
  tree outlines and mixed-resolution face culling.
- `luajit tools/test-fine-server.lua`: actual voxel runs, light/colour preservation,
  unavailable versus empty replies, grant bounds and edit invalidation.
- `luajit tools/test-forest-preview.lua`: placement/rotation parity on a flat
  world, biome exclusion, asymmetric schematic outlines and 1/2/4 reductions.
- `luajit tools/test-tdl-columns.lua`: 2,304 point-sampled roots agree with batched
  mapgen across dry, shore and channel cases. An optional previous mapgen file
  also compares the complete generated node arrays; the extraction passed this
  comparison against the pre-change implementation.
- `luajit tools/test-surface-server.lua`: grants, versions, bounded cooperative
  work, cold/warm caching and backward compatibility.
- `res://tests/local_server_terrain_diffusion.gd`: deployment includes every TDL
  and Goanna Lua module.

`tools/forest-review/run.py` creates an isolated Mineclonia world from an existing
bake. It records loading stats and screenshots without visiting the user's world.
The September 15 review used a cherry grove, seed 1234, a 1,024-node horizon and
1280×720 on an RTX 3090, without PBR. One complete 545-tile run reported about
156 fps. This is a spot measurement, not a general performance guarantee. The
cache-migration run replaced 500 old summary areas with revision-tagged entries
and retained detailed distant crowns without the bare ground-only ring.
