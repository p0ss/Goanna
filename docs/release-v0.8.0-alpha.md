# Goanna v0.8.0-alpha

Goanna 0.8.0 is about what a block looks like from a metre away. Surfaces
have depth now, not just shading, the Mineclonia pack is hand authored
rather than baked, and a block being mined is carved instead of cracked.
Under that, the mesher's normal maps were upside down and the water was
lit twice, and both are fixed. It is a smaller release than 0.7.0 in
scope, and a larger one in what the player sees.

## Relief that sits on the art

Every normal map in play was upside down along a tile's V axis. Godot's
binormal points along minus V, the way its own SurfaceTool writes it, and
the mesher wrote the sign the other way, so a bump lit from below the sun,
cobble read as inverted, and relief never sat on the colour squares it was
derived from. The offline ramp had shown the maps the right way up because
it used SurfaceTool's tangents. It now builds them the mesher's way on
request, and a probe cube with one bump and one pit tells the two
conventions apart under an afternoon sun.

The node shader now does parallax occlusion with a self shadow. Godot has
no tessellation, so the shader marches the eye ray through the height
channel of the normal map, moves the tile coordinate to where the ray
meets the surface, and climbs from that hit toward the sun through the
same field. The shadow reaches direct light by folding into ambient
occlusion. Depth is per material class, because LabPBR carries no depth
scale and one depth for everything turned sand into fur. The march fades
out over the second half of its range and hands the relief back to the
normal map. The scissor variant used by cut-outs is untouched and has no
march.

Measured on the ramp with one material filling the frame at an oblique
angle under a low sun, on an RTX 3090 at 1600 by 900, the whole march
costs under a millisecond a frame on cobble and sand. A 4 fps frame seen
in play was the far field summaries on the main thread, not the shader.

Companion maps for a composite tile are now looked up by the base image
rather than the whole tile string. The grass block's dirt side, which is
dirt with the grass overlay composited on, drew flat beside plain dirt
until this.

## The authored Mineclonia pack

The plastic look reported in 0.7.0 turned out to be structure, not
specular level. Over the Mineclonia bake the median texel tilt is six
degrees and occlusion never falls below 0.81, so at the client's relief
gain every source texel outline became a ridge and nothing read as a
surface. The material ramp gained a close-up layout that shows a cube at
three hundred pixels with the client's own gain applied, which is the
scale where relief, occlusion and roughness variation can be judged at
all.

`tools/pbr_author/` builds a height and a smoothness field per stem from
the game's own 16 px art, with metric targets a script can check without
seeing the result. One hundred and seventy seven stems rebuilt this way
now replace the bake's albedo, normal and specular files in the shipped
Mineclonia pack: the surface set, the ores, furniture, doors and cut-outs,
the four colour families, the stone variants and glowing blocks, and the
grass plants and paths. Every set was judged on the close-up ramp under
sun and lamp before it was kept, and in play by the maintainer, who asked
for it to be the default. Licence and attribution are the same as the
bake's, and the attribution note names the stems.

`docs/material-calibration.md` records the two authoring passes and what
their reviews caught, most of it scripts reaching for domes and grain
where the art wants flat faces and thin lines. Iron, gold and copper
veins are metal now, diamond and emerald carry their own reflectance,
redstone glows, and the torch, glowstone, lit furnace and jack o'lantern
use an emission field taken from the art's own bright texels.

Two limits are worth knowing. The grass block side cannot take maps,
because the game draws it as the dirt side with an overlay composited on
top. And the far look is unchanged by all of this: texel detail is under
a pixel past a few dozen nodes, and what makes a hillside read at that
range is variation between blocks, which is a shader question not yet
started.

## Mining carves the block

A block being dug is carved rather than cracked. Transient damage is kept
in compact impact vectors, the exposed subcube surfaces are extracted,
and the neighbouring blocks' now visible backing faces are published with
the cut mesh. Damage advances with dig progress and the ordinary mesh is
restored on cancellation or completion.

The wield stroke, the deformation, the sound and the chip particles are
driven from one contact cycle, so a substantial block takes several
deliberate blows, and the remaining subcube volume is fitted to the
remaining health. This was validated with the native form and mining
cycle tests and an eight contact Mineclonia capture with volume and pose
assertions, plus live cancellation and completion checks at block
interiors and chunk boundaries.

The carved faces keep the source tile's PBR material. A composited crack
tile used to force the 2D material fallback, which dropped the normal and
material maps on the very first mining frame; the cut now shares its
tile's material and the review fixture asserts that it does.

Selection and collision still use the original cube, and a visible hole
does not yet retarget the block behind it.

## Water and materials calibrated

Two offline fixtures now measure what the renderer makes of a given
roughness, metalness and water depth under the world's own lighting
recipe, rather than guessing from screenshots.

The material ramp settled that the pack's terrain shows almost no
specular in daylight, that spreading its roughness maps changes nothing
by more than a count in the sun, and that no surface can show a mirror
because only the sky is there to be reflected. Those ruled the maps out
as the cause of the plastic look and pointed at structure instead.

The water ramp found a real defect: the bed seen through the water went
out through albedo and was lit a second time, so deep water sat at seven
tenths of the dry sand's brightness and read as a painted floor. The
transmitted bed now goes out as emission and only a dim scatter term is
lit. Deep water falls to a third to a half of the sand's brightness from
thirty degrees and converges on the reflected sky from twelve. This was
a fixture result; no server was run for it.

A scatter of smooth dust texels on sand each threw a pinpoint sun glint,
and seen through water at a grazing sun those came out as coloured specks
across the whole sea. Ordinary texels now stay within a quarter of their
class level; metal, gems and the glassy classes keep what the script gave
them. The bed sample is also bounded on the way out, because the speckle
seen in play was never reproduced on the water ramp and is bounded rather
than trusted.

## Distant forests and the fine scheduler

Authoritative fine blocks now stream alongside the predicted forests of a
Terrain Diffusion world, canopy shapes are preserved across detail bands,
and surface coverage is coordinated with the geometry actually published.
Baked terrain worlds can also serve compact two dimensional surface tiles
so the coarse horizon fills before the local shape refines, without
expanding the bake into mapblock summaries; `docs/baked-terrain.md` has
the protocol and its limits, which are that the bake supplies ground and
water only.

The fine candidate scan that came with this did not scale. An ordinary
Mineclonia world the maintainer had been playing fell to 1.7 fps with a
median frame of 580 ms. On disposable copies of that world at the saved
position, Godot 4.5.1 debug, RTX 3090, 1590 by 890, the fix brought the
same load to 66 fps and a 15 ms median, with the scan spread across frames
and bounded at 512 candidates a sweep. The two runs are not frame for
frame identical workloads and the report in
`docs/perf/forest-handoff-2026-09-15/` says so. Loading hitches during
fast travel remain and are documented rather than solved.

## Worlds and games

The six Terrain Diffusion worlds are republished as `worlds-2026.09.2`
with their hydrology recomputed against the corrected stream routing. It
is a rehydration, not a re-bake: the elevation and climate bytes are
untouched, verified byte for byte across all 150 tiles, and only the water
planes changed. The change is smaller than hoped, because a river needs
8 km2 of catchment and five of the six regions never reach it in a 77 km
window, so only the default world moved, in 7 of its 25 tiles. All six
download from their published URLs and verify against the recorded
hashes.

The world previews now draw the rivers. The drainage plane holds a
logarithm and the preview renderer compared it against a linear
threshold, so it drew trunk rivers and nothing else. The mapgen always
decoded the field correctly, so this changes nothing that ships.

Start Game and the Content screen name a game by the title in its
`game.conf` rather than its directory. VoxeLibre still lives in a
directory called mineclone2 so that old worlds keep loading, and a player
who had installed it from ContentDB reported it missing. The directory
name is still what the server is given.

## Not finished, and not claimed

The authored pack is judged on a ramp and in the maintainer's own play,
under sun and lamp, on Mineclonia. No other game has an authored pack.
Minetest Game still uses its bake, and there are still no companion maps
for Asuna.

Parallax occlusion's cost is measured on the ramp for one material at a
time. It has not been measured across a whole scene in play.

Carving is visual only. The server still sees a whole block until it is
gone, and Goanna asks it for nothing it did not ask for before.

## Still alpha

Goanna remains an alpha-quality Linux project targeting Godot 4.5 and a
Vulkan-capable GPU. Mineclonia is still the most thoroughly tested game,
and the Luanti client remains the compatibility reference. A Windows
package is exported alongside the Linux one from this release, but no
Windows export has ever been launched by anyone; a report either way
would be useful. macOS is not built.
