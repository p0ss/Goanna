# Prepared terrain storage

The renderer now keeps prepared LOD data on disk and loads it through a
bounded background queue. This is the storage foundation for subsequent
terrain work. The region mesher remains in place; subsequent changes to
its geometry and distance selection are described in
[terrain surfaces](terrain-surface.md).

## Source identity and records

Raw network mapblocks contain numeric node IDs. Their cache is now bound
to a fingerprint of the complete node-definition packet and protocol
version, below the existing world/server cache directory. Old unbound
files remain intact and are not interpreted using a new ID mapping.
Changing definitions starts a separate cache namespace.

Prepared full-block records retain all five LOD levels, sparse exact
occupancy, materials, palette values, light, liquid envelopes and ground
heights. Fields have explicit byte encodings, a schema version, source and
definition fingerprints, a checksum and bounded Zstandard decompression.
The source fingerprint covers the full serialised block and its format
version. A stored-source read still reads those bytes on the worker to
validate the prepared record, but a hit avoids mapblock deserialisation and
LOD construction. There is no timestamp-only freshness assumption.

The schema preserves the existing distinction between unknown cells and
known empty cells. It does not upgrade partial coverage to complete or
invent finer detail for a summary. A corrupt or incompatible prepared
record falls back to deriving the hierarchy from its source.

Prepared schema 2 also retains provider exterior-shell provenance. This
distinguishes omitted underground volume in a provider summary from real
air beneath a floating voxel object. Older prepared records are rebuilt.

Terrain-diffusion and other server summaries have a separate compressed
cache. It retains the protocol's node names, occupancy and coverage flags.
These are the server's existing four-node records, not a new terrain
heightfield. The renderer still reduces them into the coarser levels when
consuming a reply.

## Loading and handoffs

A single storage worker reads source blocks, decompresses prepared data,
derives missing hierarchies and writes prepared records. Live blocks are
copied into immutable node snapshots before worker derivation. Every load
has a ticket and a source revision; stale results are discarded after an
edit, reset or reconnect. The worker stops before its session is destroyed.

The source-store index has non-blocking, memory-only lookups. Absent source
regions need no worker job. Cold indices are primed on the worker, and the
renderer revisits them when ready rather than waiting for a complete scan
cycle. Ordinary packet-cache writes run on the session thread outside the
map lock. A block awaiting that write stays resident so pruning cannot
replace it with an older stored copy.

Cached summaries are provisional. The client always requests a fresh
server answer, and a late cache result cannot overwrite that answer.
Cached completeness never suppresses the refresh. A fresh known-empty
record removes the older summary; an unknown record cannot claim that the
terrain is empty. The server's existing grant and summary request path
still control which distant areas can be used.

A summary remains visible while an exact stored replacement loads. The
existing region publication and near/far handoffs then install the new
representation. Storage readiness is included in benchmark settling checks.

## Bounds and diagnostics

- At most 128 worker jobs, one active job and 32 completed results.
- At most 16 queued summary jobs, with a one MiB source-message limit.
- A 4096-entry renderer request backlog, with region retries when full.
- At most 16 result collections per poll, inside a two millisecond budget.
- Prepared block records have a 256 KiB decoded limit.
- The existing region-file eviction policy uses a 512 MiB prepared-cache
  target and a 128 MiB summary-cache target per definition namespace.
  Raw-block storage retains its separate configured target. These are
  eviction targets, not a combined hard cap across worlds or namespaces.

Render diagnostics expose `lod_storage_hits`, `lod_storage_misses`,
`lod_storage_built`, `lod_storage_errors`, `lod_storage_queued`,
`lod_storage_ready`, `lod_storage_pending`, `lod_storage_retry_regions`,
`lod_summary_cache_hits` and `lod_summary_cache_writes`. Queue rejection is
backpressure and is counted separately from processing errors.

## Validation and remaining work

`goanna_lod_storage_test` covers reopen hits, source edits, changed node
definitions, sparse occupancy and liquid preservation, unknown versus
empty, corrupted/truncated records, size limits, queue bounds, queued
replacement, shutdown, summary persistence and cold index lookup.
`goanna_lod_test` checks the existing terrain topology independently.

`tools/terrain-storage-flight.py` records the disposable `tdl_showcase`
ridge route. Run it, restart the client with the same profile, then run it
again to verify disk reuse across sessions. Its screenshots are diagnostic
views; neither waiting nor a cache hit proves complete horizon coverage.

The [live cold/warm report](perf/terrain-storage-2026-09-13/report.md)
records successful reuse across a client restart and the remaining flight
stutter and visible seams.

This does not yet bound all resident terrain or mesh memory, remove
main-thread region capture and mesh publication. The subsequent surface
pass reduces capture work and changes the outer geometry. Edits flushed
while pruning still use the existing synchronous
save path. Remote edits that the server never announces remain subject to
the existing summary protocol's freshness limits. A server that replaces
its world without changing its address, cache identity or definitions
still needs an explicit world identity/invalidation protocol.
