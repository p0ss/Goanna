# Terrain storage validation

The prepared terrain cache survives a client restart and avoids rebuilding
most stored block hierarchies on the repeated route. It does not fix the
visible terrain seams or the flight stutter. Both runs use the new storage
implementation; these are cold/warm diagnostics, not before/after images.

## Setup

Live Godot 4.5.1 client, RTX 3090, Luanti 5.17.0 server with Mineclonia and
the terrain-diffusion provider. The world is a disposable copy of
`tdl_showcase`. The client uses an isolated profile, Ultra settings,
1600 by 900 output, approximately 110 degree FOV, noon and clear weather.
The server grants 4096 nodes of summary reach.

`tools/terrain-storage-flight.py` records a ridge route from
`(-4000, 572, -4000)` through `(-4000, 654, -5000)` to
`(-4000, 693, -5500)`, then returns and holds for 30 seconds. Coordinates
are in Godot space. Each moving leg lasts 40 seconds. A server-side probe
checks player movement independently of the client's cached correction
position. Maximum sampled camera/probe differences were 6.89 nodes cold
and 14.98 nodes warm; both returned to zero at the final hold.

The cold client started with an empty prepared cache and retained raw
source blocks. The warm client restarted with that same profile. Both
loaded the same native binary, SHA-256:

```text
d2e470e48d96b0fa197abf7da45498d29f0b825c13e116b4536755c59ab47c02
```

The definition namespace was `nodes-v1-a2df9e41d8deb089`. Neither run
cleared the server's generated terrain. Source coverage and server state
therefore differ between runs, which limits performance comparisons.

## Results

Cache counters below are cumulative since connection, including startup
and the ten second wait before recording. Hits count requests, not unique
blocks. The cold flight can hit records prepared earlier in that session.

| Measurement | Cold | Restarted, warm |
| --- | ---: | ---: |
| Prepared block hits | 9,641 | 17,891 |
| Prepared block misses | 8,081 | 174 |
| Hierarchies built, including live snapshots | 9,049 | 653 |
| Cached summary hits | 8 | 2,264 |
| Summary write attempts | 4,470 | 5,382 |
| Storage processing errors | 0 | 0 |
| Maximum sampled renderer request backlog | 434 | 389 |
| Moving median frame time | 13.15 ms | 13.05 ms |
| Moving p99 frame time | 45.60 ms | 44.54 ms |
| Moving maximum frame time | 98.95 ms | 68.60 ms |
| Hold p99 frame time | 40.78 ms | 43.82 ms |
| Hold maximum frame time | 217.04 ms | 201.95 ms |
| Maximum sampled visible primitives | 709,015 | 716,532 |

The restarted run served 99.0% of its stored-source cache lookups from
prepared records. It still validates their raw source bytes on the worker.
The summary hits demonstrate reuse across sessions, while fresh server
requests continue independently.

The storage queue, completed results, active jobs, pending requests and
retry regions were all zero at the final observation in both runs. Other
terrain work was still active, so this is not a fully settled horizon.
Sampled queue maxima omit activity between samples; native tests enforce
the actual bounds. Startup backpressure was recorded separately from
processing errors. Both client logs contained no errors.

The near-identical moving p99 times show that successful cache reuse alone
has not removed flight stutter. Main-thread terrain capture/publication,
geometry size and coverage remain separate work.

## Visual evidence and next surface work

[Cold held view](cold/held.png) and [warm held view](warm/held.png) are live
diagnostic screenshots after the return leg. Camera and lighting match,
but loaded coverage differs. They are not evidence of a visual overhaul.
Stepped surfaces, triangular seams and an abrupt outer terrain edge remain.

A coarse opaque earth surface is the next useful coverage fallback where
received terrain data establishes ground. It should remain visible until
the detailed replacement is ready, with joined edges between resolutions.
That can cover missing detail without generating thousands of filler
voxels. Unknown terrain must remain distinct from confirmed ground, and
nearby known cave entrances must not be sealed. Darkening the lower sky
alone would leave holes in the silhouette and would not restore depth or
occlusion. This fallback is not implemented by the storage change.

## Checks and files

The native storage and LOD tests passed, as did the Godot headless import,
repository style check and `git diff --check`. Storage tests exercise
persistence, edits, definitions, corruption, bounded records and queues,
worker execution, shutdown, summary reuse and cold index lookups.

Each run directory contains `metadata.json`, `observations.jsonl`,
`samples.jsonl`, `frames.csv`, `summary.json`, `held.json`, `held.png` and
`client.log`. See [the storage contract](../../terrain-storage.md) for
implementation details and remaining limits.
