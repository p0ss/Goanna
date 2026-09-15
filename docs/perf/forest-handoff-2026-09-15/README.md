# Forest handoff performance investigation

Measured the current uncommitted forest/handoff build on 2026-09-15 after a
report of worse performance during regular play. This is a current-build
diagnostic, **not a before/after regression measurement**. Earlier stationary
FPS spot checks did not validate movement or the cost after exploring.

Fixture: `tools/forest-review/run.py`, `/tmp/goanna-forest-review4`, Mineclonia
TDL seed 1234, Godot 4.5.1 debug, RTX 3090, 1280×720, PBR disabled by the
harness, view range 6, far distance 1024, time 0.4. The world and client cache
were already partly warm; surface tiles were still arriving. These settings
do not establish performance in the user's regular play configuration.

Attached the existing `project/bench.gd` recorder through the control channel;
it disables vsync and enables GPU timestamps. Recorded a fly route at 20
nodes/second, looping through (Godot coordinates):
`[1600,800,1500]`, `[1856,800,1500]`, `[1856,800,1756]`,
`[1600,800,1756]`, `[1600,800,1500]`, pitch -20, yaw 0. The regular fly branch
sends player poses to the server, but server position was not independently
recorded. Then stopped the route and returned to the first pose for the
stationary measurement. No rendering configuration changed between samples.

| Measurement | Moving | Stationary after movement |
|---|---:|---:|
| Duration | 75.3 s | 162.6 s |
| Average FPS | 72.1 | 92.3 |
| Median frame time | 12.0 ms | 10.0 ms |
| Mean slowest 1% frame time | 50.7 ms | 25.9 ms |
| 99th percentile frame time | 39.4 ms | 21.4 ms |
| Worst frame | 249.4 ms | 78.8 ms |
| Median GPU render time | 4.04 ms | 3.08 ms |

The stationary phase name in the recorder is `steady`, but the scene **did
not settle**. Its chain-build counter rose from 66,157 at the first sample to
303,367 at 160.9 seconds. Chain queues repeatedly contained thousands of
entries, and surface handoffs kept retiring and staging meshes. During the
movement sample, up to 728 retired surface-handoff meshes were retained.
These are symptoms, not yet proof of which source invalidates those chains.

GPU median timing is well below the frame period; sampled CPU counters and
persistent queues point toward main-thread/streaming work. No isolated
profile or previous-build comparison has yet apportioned the cost among
fine-block refresh, source replacement, retiering, publication, or surface
rebuilding. Do not interpret the moving/stationary difference as the cost of
the changes themselves.

Full frame CSVs are in `/tmp/goanna-forest-performance/{moving,after-motion}`.
Summary and one-second counter samples are retained alongside this report.
The next investigation should trace why unchanged terrain repeatedly builds,
then repeat an identical route with controlled world/cache snapshots before
changing the visual detail bands.
