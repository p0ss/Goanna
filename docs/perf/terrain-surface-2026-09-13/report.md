# Terrain surface and handoff validation

Recorded on 13 and 14 September 2026. The repeated ridge flight draws less
geometry and spends less time processing distant terrain. Two near/far
gap causes were corrected: premature removal of detailed blocks and edge
faces ending above the neighbouring detailed ground. Visible coarse
facets and abrupt changes in detail remain; this is not a finished
continuous horizon renderer.

## Setup and comparison limits

Live Godot 4.5.1, RTX 3090, Luanti 5.17.0, Mineclonia and the
terrain-diffusion provider, using the disposable `tdl_showcase` copy and
isolated client profile. Output is 1600 by 900, with approximately 110
degree diagonal FOV, noon and clear weather. Server summary reach is
4096 nodes.

`tools/terrain-storage-flight.py` repeats the previous ridge route: 40
seconds out, 40 seconds back, then a 30 second hold. The comparison is the
[previous storage warm run](../terrain-storage-2026-09-13/report.md).
Camera route and lighting match, but server coverage and cache state
evolved. The server was also restarted with provider provenance support.
These are repeat-route observations, not a controlled speedup measurement
or pixel-matched before/after comparison.

Current native binary SHA-256:

```text
1854fbfd15846b84e252f85f6c4b8781fde2cdeaeb42fbb2c189aba9f3163af8
```

## Ridge flight

| Measurement while moving | Previous storage warm | Current |
| --- | ---: | ---: |
| Median frame time | 13.05 ms | 5.40 ms |
| p99 frame time | 44.54 ms | 26.92 ms |
| Maximum frame time | 68.60 ms | 45.08 ms |
| Median sampled visible primitives | 207,744 | 73,116 |
| Maximum sampled visible primitives | 716,532 | 171,752 |
| Median sampled full-detail block meshes | 545 | 0 |
| Maximum sampled full-detail block meshes | 931 | 14 |
| Median sampled terrain poll time | 7.87 ms | 2.52 ms |

The new screen-size rule permits far geometry directly below the camera
at flight altitude. Sparse capture then avoids scanning large empty
volumes for those coarser regions. Both changes contribute to the result.
These mesh counts do not imply that full-detail terrain is absent when
walking; the descent below exercises its return.

Storage processing errors stayed at zero. Storage queues drained at the
final observation, while 12 regions remained dirty. Maximum sampled
camera/server probe separation was 9.29 nodes. This is not evidence of a
fully settled horizon. The hold maximum of 214.19 ms includes screenshot
encoding; it must not be presented as a gameplay hitch. The recorder now
stops timing before PNG capture for future runs.

[Previous held view](../terrain-storage-2026-09-13/warm/held.png) and
[current held view](flight/held.png) show the same return viewpoint with
different loaded coverage. Angular distant cliff strips and differences
between the coarse ground and actual voxel terrain remain visible.

## Near/far handoff exercise

`tools/terrain-surface-descent.py` moves vertically at eight nodes per
second from `(-4000, 572, -4000)` to height 465 and back, with pitch -35
and yaw 180. Each leg records 15 seconds; the lower view has an additional
ten second hold. PNG encoding occurs outside the timing recordings.

| Measurement | Descent | Ascent |
| --- | ---: | ---: |
| Median frame time | 3.58 ms | 3.49 ms |
| p99 frame time | 13.09 ms | 10.01 ms |
| Maximum frame time | 62.24 ms | 67.03 ms |

Full-detail block meshes grew to 212 on descent. Pending far-to-near
handoffs reached 14 in the sampled observations and returned to zero at
the lower endpoint. Ascent reduced full-detail meshes to 21 by its final
observation. Storage errors remained zero.

The [lower held view](descent/low-held.png) shows detailed voxel ground
meeting the distant representation without a broad open-sky moat in this
view. The [descent endpoint](descent/descent.png) and
[ascent endpoint](descent/ascent.png) document different heights, not
before/after variants. Dark step faces and abrupt resolution changes
remain. Endpoint images and one-second counters cannot prove that no
transient hole appeared between samples.

## Checks and implementation

Native LOD and storage tests pass. Added checks cover altitude and output
resolution, sparse capture bounds, shared and mixed-resolution edges,
preserved ridge heights, shallow water, floating rock, provider shell
classification, exact-height boundary faces and provenance persistence.
Both server-mod copies pass Lua syntax checking and are identical. The
live client and server logs contain no reported errors.

The provider audit in `provider-flags.json` found 147,064 marked provider
records and zero marked real voxel records in its sampled stored areas.
Unvisited older provider records remain eligible for lazy upgrade.

See [the implementation and remaining limits](../../terrain-surface.md).
Raw flight data is in `flight/`; descent/ascent timing and observations
are in `descent/`. The averaged blanket prototype is not the implementation
tested here.
