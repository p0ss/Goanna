# Terrain flight investigation, 13 September 2026

The current renderer still stutters and leaves incomplete distant terrain
during flight. This is a diagnostic baseline, not a visual improvement
comparison. A local-server movement configuration defect was corrected;
the terrain renderer itself has not been changed in this investigation.

## Fixture and validity

The test used a disposable copy of `tdl_showcase`, Mineclonia on Luanti
5.17.0, Godot 4.5.1 Forward+, and an RTX 3090. The client ran at 1600x900
with the copied Ultra graphics configuration, view range 16 mapblocks,
detail distance 32 mapblocks, and a 4096-node far grant. Actual camera FOV
was approximately 110 degrees. Time was held at noon with clear weather.
Clouds can still appear below these high viewpoints.

Both routes travelled at 40 nodes per second, facing forward and down
18 degrees. Each recording contains 110 seconds outbound, 110 seconds
returning, and a 60-second stationary hold. The coastal route went from
Godot `(0,550,0)` to `(0,650,-4096)`. The mountain route followed
[these ridge points](ridge-route.json), about 140 nodes above the baked
surface, after a 25-second wait at its starting point. Each round trip
covered approximately eight kilometres. Client caches were already warm;
these are not cold-start throughput measurements.

Screenshots labelled `outbound-110` show the outbound endpoint, and
`returned-held` shows the starting position after returning and waiting.
Neither label claims that streaming finished. They are different moments
in the same renderer, not before/after results.

An earlier coastal flight is excluded: the server rejected the camera's
movement and continued streaming around spawn. It also had verbose
`GOANNA_PERF` instrumentation enabled. The retained runs have that
instrumentation disabled and use the existing frame recorder. The ordinary
performance overlay is separate from verbose instrumentation.

A temporary server mod sampled the actual player's position every
0.25 seconds. The retained observations compare it with the camera every
10 seconds, correcting the Luanti/Godot Z-axis sign. The control endpoint's
`server_position` is a cached teleport/correction value, so it cannot prove
that the server follows a flight. No movement rejection appears in the
server log during these retained runs.

## Evidence

The [measurements](measurements.json) contain phase summaries, sampled
counter maxima and camera/server agreement. Each route directory contains
per-frame timings, one-second render samples, ten-second server checks,
the binary hash, and the test server configuration.

- Coastal: [timings and geometry](coastal/telemetry.png),
  [outbound endpoint](coastal/outbound-110.png),
  [returned and held](coastal/returned-held.png).
- Ridge: [timings and geometry](ridge/telemetry.png),
  [starting view](ridge/outbound-0.png),
  [outbound endpoint](ridge/outbound-110.png),
  [returned and held](ridge/returned-held.png).

The coastal flight reached a moving-frame 99th percentile of 82.3 ms
while median GPU time was 3.05 ms. It had no full-detail block meshes at
the sampled positions: that flight demonstrates stutter in the distant
terrain path even without a large near field. The sampled terrain polling
time was substantial. Its internal timing counters are smoothed values,
not individual frame traces, so they do not identify one responsible
function.

The ridge route brings detailed terrain and its shadow geometry into
range. Its moving-frame 99th percentile was 78.9 ms, median GPU time
2.90 ms, and worst frame 309.3 ms. The sampled total primitive count
peaked at 962,890. Camera/server disagreement stayed below 14 nodes on
both routes. After the ridge hold, the dirty-region count reached zero,
but detached distant patches and small triangular seam artefacts remained
visible. Draining the current mesh queue does not prove complete coverage.

The pass counters are retained separately: the total primitive
counter includes multiple rendering passes and is not a count of unique
terrain triangles. These short routes do not establish the maximum
geometry growth of a long exploration session. Low triangle counts in
views with missing ground are not evidence of efficient complete coverage.

## Confirmed local-server defect

`project/local_server.gd` intended to disable movement checking for its
local player using `anticheat_flags = digging,interaction`. Luanti's
`Settings::getFlagStr` inherits omitted flags from the parent settings, so
movement checking remained enabled. The generated configuration now uses
`digging,interaction,nomovement` explicitly. This preserves the existing
local launcher's intention; public server configuration is separate.

The corrected configuration was tested after restarting the disposable
server, using direct player-position samples throughout both flights.
Godot's headless import and the repository style check passed. Correct
streaming position did not remove the rendering stalls or missing terrain.

## What the current code actually does

- `GoannaClient::lodTierFor` selects resolution from horizontal distance.
  Height above or below the camera does not make geometry coarser.
- `buildLodTerrainSurface` is called for both live and summary data. It
  recognises solid runs rooted at each mapblock's floor. Other occupied
  cells remain voxel geometry. Contrary to some older comments, the
  surface path is active.
- `meshLodRegion` gives each land quad four equal corner heights, retaining
  terraces and vertical risers. It does not currently form a smooth,
  continuous outer landscape from shared height samples.
- The terrain provider has surface heights, but `synthesise_area` encodes
  them into a four-node occupancy shell. Omitted buried cells are air in
  that representation. This loses information that would help distinguish
  a terrain skin from disconnected solid structures.
- Mesh workers exist, but region capture still walks a three-dimensional
  neighbourhood on the main thread. Array conversion, tangent generation
  and publication also run there. Publication is capped at four regional
  results per collection, not at a measured time or vertex limit.
- Existing handoffs retain old meshes while replacements build, with an
  eight-second freeze escape. Any replacement design must preserve the
  coverage that these mechanisms already protect.

These are source observations and investigation targets. They do not
prove that one of them explains every hole, overlap pattern or hitch.

## Recommended next implementation

Start with the terrain data and storage contract before implementing a new
outer mesher. The client BlockStore persists full serialised mapblocks;
stored terrain is read and deserialised before deriving its LOD chain on
the main thread. Reads and session-thread writes share one store mutex.
The server also persists summary areas, so storage already exists, but
these paths do not provide a client cache of directly loadable terrain at
several resolutions. The flights did not isolate disk latency or prove it
is the dominant cost.

Define persistent coarse records, coverage and source revision metadata,
then bounded asynchronous reads, decoding, derivation and memory residency.
Validate cold loads, revisits and edits with a simple mesh consumer before
investing in its final appearance. Keep source block storage where useful;
the evidence does not yet justify replacing its file format wholesale.

Build the bounded outer terrain surface on that foundation. For the existing
server-authorised terrain provider, preserve surface heights and material
information at several scales, with shared samples along tile edges.
Publish coarse coverage first; replace it only when a complete finer
replacement and its boundary are ready. Choose detail using projected
size, including camera altitude, with explicit geometry and upload costs.

Keep nearby voxel geometry for actual caves, overhangs, structures and
edits. A distant surface must not bridge real nearby cave entrances or
invent terrain where the server supplied no information. The provider
path is an opt-in extension; ordinary servers still need the existing
received-data fallback.

First separate and measure capture, array preparation and publication
costs on this repeatable flight. Then test a single outer surface ring
against the current renderer with matched positions and elapsed times.
Acceptance requires continuous ground during travel, compatible tile
edges, a bounded triangle count, and improved frame-time tails together.
A completed stationary screenshot alone would not satisfy it.
