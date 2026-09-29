# Night-sky study

29 September 2026. Godot 4.5.1, Forward+, software Vulkan on llvmpipe
(LLVM 22.1.8). All rendering ran inside the headless launcher.

[Open the visual comparison](index.html).

## Appearance

The production sky now contains a galactic band, dark dust lanes, subdued
nebular colour, varied star temperatures and magnitudes, gentle twinkling,
three steady planet-like points and occasional meteors. The panorama
rotates with game time. Twilight adds upper-air blue/violet and a pink
anti-solar arch, while the galactic band fades before the brighter stars.

The before/after pair uses the same offline viewport, camera, palette,
exposure, star opacity and silhouette. The old image uses the previous
`sky.gdshader`; the new image uses the production shader and its include.
The fixture's star alpha is 0.4117647, matching the received server value.
The silhouette is a stand-in, not server terrain. Other fixture conditions
are specified in `project/night_sky_study.gd`.

## Checks

- The production shader compiled and rendered in Godot 4.5.1.
- Hidden stars, zero density and zero scale produced identical images.
- Full daylight was identical with the additions enabled or disabled.
- Separate night frames showed small twinkle changes without moving stars.
- A deterministic meteor capture at 111.24 seconds showed a tapered trail.
- Block clouds covered both the stars and the galactic band.
- The current `main.gd` passed Godot's headless script check.
- `tools/check-style.sh` passed.

`checks.json` contains the image equality results and renderer version.

## Server check and limits

The test client connected to the local development server at
`127.0.0.1:30561`, received 6,050 media files and rendered 103 mapblocks.
The game supplied `mcl_core` terrain, `mcl_moon` textures, 1,000 stars and
star alpha 0.4117647. The exact game release was not established.
`server-night.png` shows that received sky/weather state over loaded terrain,
with a client-only midnight override. The server shut down during the
check; this capture is from the retained scene after disconnect, not an
ongoing live session. No server clock or weather was changed.

The offline comparisons passed on software rendering. GPU frame cost,
temporal antialiasing in motion, all moon phases and extended server
day/night cycles were not measured. The new celestial panorama is omitted
from the ambient radiance cubemap, like the sun and moon discs, so that
reflection fallback does not contain it.

## Blockiness and star groupings

This treatment was rejected: the angular mosaic read as fish scales and
did not match the material relief. Its images remain for comparison.

The follow-up [style comparison](blocky.html) isolates continuous sampling,
the band with stepped patches, and the stepped band with four six-star
asterisms. Two of those groupings are visible from this camera. The
fixtures use the same palette, star alpha, camera and application clock.
The smooth silhouette is still a stand-in, not actual terrain.

The angular sampling belongs to the sky rather than the screen. Two cell
sizes break the band into broad patches and finer detail while its outer
halo stays soft. Constellations have no connecting lines; a slight thinning
of the background helps their brighter stars form recognisable shapes.
Both changes have independent shader controls for comparison.

Godot 4.5.1 rendered all variants without shader errors on llvmpipe in the
headless launcher. Visibility and daylight image equality checks passed
again with the new defaults, recorded in `blocky-checks.json`. This revision
has not had a new live-server run or GPU performance measurement.

## Relief following the cloud artwork

The [relief comparison](relief.html) replaces the angular mosaic with a
shallow heightfield. The reference is the flat texel plateaus, height
steps and narrow chamfers described in `tools/pbr_author/extrude.py` and
rendered through the height/normal channels of the node materials.

The sky's height comes from the same procedural light and dust that form
its galactic band. Neighbouring equal-height texels merge. A bounded
four-cell traversal intersects tops and sides, then exposed top edges
receive a narrow bevel. Fixed illustrative lighting gives those faces
depth while the broad emission remains diffuse. The projection stays in
the celestial frame: walking does not move distant galactic matter.

This is an artistic sky treatment, not the terrain's physical material
shader or a volumetric galaxy simulation. The comparison includes a
1280x720 full view, a 1920x1080 view and a closer 38-degree field of view.
The full views still contain the explicitly labelled stand-in horizon.
They use the existing fixture palette and exposure, not a live world.

Godot 4.5.1 rendered the final shader on llvmpipe. The hidden/zero-count/
zero-scale comparisons and unchanged-daylight check passed again; see
`relief-checks.json`. The fixture script check and repository style check
passed. GPU cost and the visual match beside actual night-time terrain
remain unverified.

## Square stars

Random and constellation stars now share an area-filtered square core.
Colour, relative brightness and twinkle remain. The core area matches the
previous Gaussian's integrated light. The final shader rendered at 1280x720
and 1920x1080 in the same offline fixture, including the closer view.
Visibility and daylight checks passed (`square-stars-checks.json`), with no
shader errors in that run. These captures remain offline style previews.

## Commit validation, 30 September

The fixture now supplies the layered cloud descriptors introduced after
this study began. The current sky and night include rendered again on
Godot 4.5.1 with llvmpipe in the headless launcher, without shader errors.
Hidden stars, zero count and zero scale still produced identical images;
full daylight was identical with the additions disabled. Results are saved
in `commit-checks.json`. The night and cloud views were inspected, and the
fixture and main script passed headless parser checks.
