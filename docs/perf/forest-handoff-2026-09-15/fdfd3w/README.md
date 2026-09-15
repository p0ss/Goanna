# Reproducing the regular-world slowdown

The user identified `fdfd3w`, an ordinary Mineclonia world, as running at about
4 FPS after previously running well. Tests used separate disposable copies
of this world and its saved Goanna settings, at the saved player position.
The original world and settings were not modified.

Both runs used 1590×890, RTX 3090, Godot 4.5.1 debug, authored Mineclonia PBR
textures, procedural grass, view range 40, LOD distance 32 and far distance
2176. Camera position was (-175.004, 4.12, -602.264), pitch/yaw 0. Each run
started with a fresh client cache and a fresh copy of the original world.
Server time was frozen at the saved time. Weather and entities remained
ordinary game simulation. These are loading/stationary samples, not fully
settled or frame-for-frame identical workloads. Recording started later in
the first load; candidate counts overlap substantially between the runs.

| Stationary measurement | Before scan fix | After scan fix |
|---|---:|---:|
| Recorded duration | 96.1 s | 139.7 s |
| Average FPS | 1.68 | 66.08 |
| Median frame | 579.5 ms | 15.0 ms |
| Mean slowest 1% | 880.1 ms | 52.8 ms |
| Worst frame | 880.1 ms | 94.1 ms |
| Median sampled summary/fine update EMA | 332.95 ms | 0.63 ms |
| Median sampled statistics-call EMA | 86.96 ms | 0.36 ms |
| Maximum candidate count | 562,621 | 566,351 |
| Maximum sampled fine scan | unbounded | 512 candidates / 0.77 ms |

This isolates the newly added fine scheduler's scalability failure much
better than the earlier small TDL fixture. It is not a comparison against
the historical version the user remembers. Streaming is asynchronous, and
the slow first run serviced less fine detail: fine-ready counts ended at
1,167 versus 4,666 in the corrected run. The diagnostic now reports readiness
from its last completed sweep rather than rescanning on every HUD call.

## Fixes

1. Consume a near-worker result when its block has already moved into LOD
   range. Previously it stayed in `m_near_ready` and re-entered `fresh` every
   frame, erasing/rebuilding its LOD chain indefinitely. Also discard a
   finished result if its live block has already been pruned.
2. Replace the fine scheduler's full-world scan and sort every quarter-second
   with a persistent cursor, at most 512 candidates and a 1 ms scan budget
   per frame. Keep the 16 in-flight requests in their own bounded set for
   timeout handling. The budget bounds the scan; it is not a hard real-time
   limit on the entire update, including reply decoding and requests.
3. Accumulate diagnostic readiness counts during that sweep; the statistics
   call no longer walks hundreds of thousands of candidates independently.

The first fix was already in the "before scan fix" binary. That run still
reproduced the severe slowdown, establishing that the queue loop was not
the whole problem. No quality distances or graphics settings were reduced.

Native `goanna_lod_test` and `goanna_surface_test` passed. The companion
`tools/forest-review/profile.py` exercises moving through the near/LOD
boundary and holding still, recording per-frame timings and sampling the
512-candidate and 16-request limits. Compressed raw frame and counter records
and their summaries accompany this report.

Loading hitches remain; the result should not be described as stutter-free.

## Follow-up: scheduling after exploration

The first flight after the bounded-scan fix still averaged 19.32 FPS moving
and 25.53 FPS during its stationary phase. The near-ready queue drained, but
`poll_lod_ms` had a sampled median of 20.11 ms while stationary. Region
prioritisation was repeatedly comparing unchanged member sets against their
published member sets. Cached this comparison, invalidating it when a region
is dirtied or publishes. This preserves coverage classification and scheduling
priority rather than skipping regions or reducing their detail.

After rebuilding and restarting the disposable client/server, the original
standing-view sample averaged 73.77 FPS over 56.6 seconds. Repeating the
same 1,024-node square flight at 20 nodes/second then produced:

| Phase | Before priority cache | Final build |
|---|---:|---:|
| Moving average FPS | 19.32 | 25.28 |
| Stationary average FPS after flight | 25.53 | 46.38 |
| Moving worst frame | 244.8 ms | 239.9 ms |
| Stationary slowest-1% mean | 84.8 ms | 57.8 ms |

These repeat flights use the same route/settings, but the later server copy
contains the earlier exploration, and streaming/rendered geometry is not
identical between the runs. They demonstrate the remaining performance
limits; they are not a clean historical-version comparison. In particular,
the approximately 240 ms movement pauses remain unresolved.

The final profile sampled up to 701,354 fine candidates, with no scan above
512 entries or request window above 16. The largest sampled scan was 0.73 ms.
The ready and chain queues were zero at the final observation. The chain-build
counter also held constant over several consecutive observations after
movement, unlike the earlier continuous rebuild loop. Sampled `poll_lod_ms`
had a median near 2 ms across the repeat flight/hold, rather than the 20 ms
stationary cost seen before caching. Native LOD/surface tests passed again.
The test script's scheduler-limit assertions passed; `validation.json` records
the final native binary hash and queue/scan checks.
