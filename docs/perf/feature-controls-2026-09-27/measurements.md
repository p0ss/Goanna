<!-- SPDX-License-Identifier: LGPL-2.1-or-later -->
# Individual recordings, 2026-09-27

Derived from the final [raw archive](raw-validation.tar.gz). See the
[report](report.md) for controls, interpretation and limitations. All times
are milliseconds except duration in seconds. FPS is frames/duration.
CPU is the renderer CPU timer, not total CPU work. GPU sums active views.
Each row uses the recorded phase summary, which excludes the first frame
spanning the phase boundary. Before and after mean all scene features
restored; each other stationary row disables only the named feature.

[Measurements CSV](measurements.csv) retains unrounded summary values,
archive paths, sampled draw calls and sampled memory ranges. Its
`low1_ms` field is the mean of the slowest 1% of frames, in milliseconds.
The short durations make tail statistics particularly unstable.

| Scene | Players | Variant | Frames | Seconds | Mean FPS | Frame median | Renderer CPU median | GPU median | Frame p99 | Frame maximum |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| dusk | 1 | control-before | 1227 | 3.071 | 399.6 | 2.405 | 0.414 | 2.290 | 3.598 | 3.968 |
| dusk | 1 | without-shafts | 1285 | 3.070 | 418.5 | 2.313 | 0.407 | 2.039 | 3.323 | 4.122 |
| dusk | 1 | control-after | 1222 | 3.069 | 398.1 | 2.409 | 0.411 | 2.302 | 3.585 | 4.301 |
| underwater | 1 | control-before | 1318 | 3.071 | 429.1 | 2.281 | 0.401 | 1.696 | 2.886 | 4.141 |
| underwater | 1 | without-underwater_volume | 1320 | 3.067 | 430.3 | 2.279 | 0.390 | 1.424 | 2.946 | 4.328 |
| underwater | 1 | control-after | 1310 | 3.069 | 426.8 | 2.301 | 0.401 | 1.693 | 2.986 | 4.222 |
| wet | 1 | control-before | 1131 | 3.070 | 368.4 | 2.614 | 0.500 | 2.473 | 3.796 | 5.263 |
| wet | 1 | without-wet_surfaces | 1134 | 3.069 | 369.4 | 2.607 | 0.499 | 2.466 | 3.706 | 4.135 |
| wet | 1 | without-water_reflections | 1124 | 3.070 | 366.2 | 2.623 | 0.499 | 2.495 | 3.900 | 5.235 |
| wet | 1 | without-water_waves | 1129 | 3.069 | 367.9 | 2.623 | 0.497 | 2.482 | 3.915 | 4.347 |
| wet | 1 | control-after | 1125 | 3.068 | 366.7 | 2.640 | 0.497 | 2.495 | 3.835 | 4.721 |
| night | 4 | control-before | 165 | 3.059 | 53.9 | 18.309 | 6.156 | 10.241 | 22.954 | 24.793 |
| night | 4 | without-dynamic_lights | 293 | 3.062 | 95.7 | 10.239 | 2.022 | 4.862 | 12.835 | 14.802 |
| night | 4 | without-carried_light | 170 | 3.057 | 55.6 | 17.794 | 5.980 | 10.072 | 21.127 | 21.932 |
| night | 4 | control-after | 167 | 3.066 | 54.5 | 18.187 | 6.111 | 10.122 | 20.970 | 21.950 |
| foliage | 1 | control-before | 1207 | 3.068 | 393.4 | 2.491 | 0.437 | 2.043 | 3.149 | 3.518 |
| foliage | 1 | without-foliage_wind | 1198 | 3.068 | 390.5 | 2.498 | 0.436 | 2.093 | 3.322 | 4.220 |
| foliage | 1 | control-after | 1061 | 3.066 | 346.1 | 2.704 | 0.448 | 2.058 | 4.253 | 5.481 |
| grass | 4 | control-before | 51 | 3.048 | 16.7 | 59.635 | 2.154 | 59.578 | 64.777 | 64.777 |
| grass | 4 | without-grass_interaction | 119 | 3.055 | 39.0 | 25.707 | 2.044 | 25.626 | 31.196 | 31.800 |
| grass | 4 | control-after | 58 | 3.039 | 19.1 | 52.209 | 2.294 | 52.629 | 56.111 | 58.074 |
| ice | 1 | control-before | 869 | 3.069 | 283.1 | 3.382 | 0.681 | 3.271 | 5.030 | 5.782 |
| ice | 1 | without-ice_detail | 1043 | 3.069 | 339.9 | 2.890 | 0.628 | 2.274 | 3.781 | 5.864 |
| ice | 1 | without-ice_transmission | 1126 | 3.069 | 366.8 | 2.614 | 0.461 | 2.462 | 3.702 | 4.542 |
| ice | 1 | control-after | 955 | 3.071 | 311.0 | 3.120 | 0.617 | 3.016 | 4.349 | 4.798 |
| magma | 1 | control-before | 896 | 3.068 | 292.0 | 3.380 | 0.465 | 3.284 | 4.086 | 5.040 |
| magma | 1 | without-lava_detail | 936 | 3.069 | 305.0 | 3.227 | 0.463 | 3.125 | 3.861 | 4.564 |
| magma | 1 | control-after | 896 | 3.066 | 292.2 | 3.386 | 0.464 | 3.290 | 4.028 | 4.768 |
| circle | 4 | apart | 378 | 3.071 | 123.1 | 7.916 | 1.711 | 5.413 | 11.721 | 17.482 |
| circle | 4 | streaming | 261 | 3.066 | 85.1 | 9.584 | 1.895 | 5.258 | 38.280 | 62.167 |
