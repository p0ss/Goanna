# Voxel volumes for shader packs

How Goanna could feed shader packs that build a per-node voxel volume
(coloured flood fill light, voxel traced light). It follows the
[survey](shaderpack-survey.md), which put these paths out of reach, and
[Iris shader packs](iris-compat.md), which explains the pipeline. This is a
design: nothing here has run, and every pack fact below comes from reading
the packs' files (versions as in the survey, read on 24 October 2026).

## The problem

A voxel pack builds its volume as a side effect of the shadow pass. Its
shadow program, for every terrain vertex or triangle, works out which block
it belongs to and writes that block's id into a 3D image with `imageStore`
or `imageAtomic*`. Compute programs (`setup`, `begin`, `shadowcomp`,
`composite*.csh`) then flood or trace light through the volume, and the
lighting passes sample the result.

Goanna cannot run that first step the way the pack wrote it. Its shadow
pass is a Godot spatial material, which cannot write images or buffers, and
Godot's RenderingDevice has no geometry stage (its `ShaderStage` lists
vertex, fragment, the two tessellation stages and compute). Today
`imageStore` in a translated geometry program is dropped and `imageLoad`
reads zero, which is why Solas and Rethinking Voxels draw their voxel light
as black.

The compute half is not the problem. The screen chain already compiles pack
GLSL to SPIR-V on RenderingDevice, and compute passes, storage images and
storage buffers are ordinary RenderingDevice features.

## What the packs write

Nine of the 22 surveyed packs touch voxels or storage. All the voxel
writers share one shape except Rethinking Voxels.

| Pack | Default | Volume | Texel | Written from |
| --- | --- | --- | --- | --- |
| Solas | on (`VX_SUPPORT` whenever not Mac) | `voxel_img` r8ui 192 x 96 x 192 | `max(mc_Entity - 10001, 1)` | shadow vertex, `gl_VertexID % 4 == 0` |
| Complementary (both) | off (`COLORED_LIGHTING`) | `voxel_img` r16ui N x N/2 x N | its `GetVoxelIDs(mc_Entity)`, 1 for solid | shadow vertex, `% 4` |
| BSL | off (`MULTICOLORED_BLOCKLIGHT`) | `voxelimg` r8ui 256 x 256 x 256 | `mc_Entity % 100`, 99 solid | shadow vertex, `% 4` |
| Photon | off (ultra profile only) | `voxel_img` r8ui 128 cubed | `mc_Entity - 10000`, bit 7 not a full cube | shadow vertex, every vertex near a block corner |
| Bliss | off (`LPV_ENABLED`) | `imgVoxelMask` r16ui 128 cubed | `mc_Entity`, else 1 for solid | shadow vertex |
| Mellow | off (`COLORED_LIGHTS`) | `voxelImg_a/_b` rgba16 128 cubed | light colour from the atlas times emission | shadow vertex, light sources only |
| Shrimple | off (LIGHTS and RTX profiles) | `imgLocalBlockMask` r16ui 4096 squared, a 256 x 128 x 256 volume in 8 cubed bins | `mc_Entity` | shadow geometry shader, one write per triangle centroid |
| Rethinking Voxels | required | six images, 177 MB at default size | sub-block occupancy bits at up to 32 per block, summed atlas colour per triangle, a light hash map | geometry shader per triangle plus rasterised fragments |
| Noble | required | none: two small SSBOs and a compute reflection pass | exposure and sky irradiance | compute and fragment passes |

The common shape, true of the first seven:

- **One unsigned id per block**, in a 3D (or flattened 2D) image the pack
  marks `clear = true`, so it is wiped and rewritten every frame.
- **Centred on the camera and snapped to whole blocks.** The index is
  `floor(scenePos + at_midBlock / 64 + fract(cameraPosition)) + size / 2`,
  where `scenePos` is the vertex in player space. Photon and Shrimple push
  the centre ahead along the view direction (15 and 30 per cent of the
  size); Shrimple also snaps its origin to multiples of 8.
- **The id comes from `mc_Entity`**, that is from the pack's
  `block.properties`, through a small pack function. Light colour, range
  and tint are looked up from that id in tables inside the pack (often
  built once by a `setup` compute pass). None uses the light level Goanna
  knows; Mellow is the exception, taking colour from the atlas and level
  from the emission attribute.
- **Light lives in a ping-pong pair** of rgba8 or rgba16f 3D images that
  persist, alternate on frame parity, and scroll by
  `floor(cameraPosition) - floor(previousCameraPosition)`.
- **No atomics, SSBOs or geometry shaders** on the lighting path, except
  Shrimple's geometry shader (a per-triangle centroid, which the pack
  itself also does in `gbuffers_terrain.vsh` when shadows are off).
- **Every pack relies on the shadow pass reaching all terrain near the
  camera**, which is why each sets `shadow.culling = reversed`. Shrimple's
  default shadow distance (100) does not even reach the edge of its own
  volume (128).

## Three designs

**A, a fill per pack.** Goanna writes each pack's image itself, in the
pack's layout, from its own node data. Exact and cheap, but every pack
needs its texel function copied: Complementary's `GetVoxelIDs` is a
270-line table. That is copying pack code into Goanna, which most of these
licences forbid, and it breaks when a pack is updated.

**B, replay the shadow program on our geometry.** Draw near terrain through
the pack's own shadow program in a RenderingDevice raster pipeline, so its
own `imageStore` writes the volume. Faithful, but it needs a second
geometry upload (Godot exposes no mesh vertex buffers to RenderingDevice),
the full set of compatibility vertex inputs, vertex-stage stores (the
Vulkan feature `vertexPipelineStoresAndAtomics`, not checked in Godot), and
still cannot run a geometry shader.

**C, replay the shadow vertex program in compute.** Translate the pack's
shadow vertex program into a compute shader: one invocation per node,
attributes synthesised from a node buffer, `gl_Position` and the varyings
demoted to locals, `imageStore` kept. The pack's own code decides the id,
the index and the layout; Goanna only supplies inputs. No raster, no
vertex-stage stores, no copied tables.

**Recommendation: C, with A kept for what C cannot reach.** C covers the six
vertex-stage packs with no pack-specific code, and follows a pack through
its updates. Shrimple's geometry shader body is per-triangle arithmetic on
`gl_in[]`, so the same transform extends to it (one invocation per node,
three synthesised vertices, `EmitVertex` dropped). Rethinking Voxels is the
one pack neither A nor C serves well: its occupancy comes from rasterising
real triangles at up to 32 sub-voxels per block, with atlas colour summed
per triangle. It goes last, and may need B on Goanna's real mapblock meshes
with its geometry stage moved into compute.

## The pieces

### 1. Pack features in the screen chain

Needed by every design and by Noble, which has no voxels at all, so Noble
is the test for this piece alone.

- Load `.csh` programs, including `_a` to `_z` variants, at `setup` (once),
  `begin`, `shadowcomp`, `prepare`, `deferred` and `composite`, before the
  fragment pass of the same name. Parse `local_size`, `workGroups` and
  `workGroupsRender`. A `begin` pass runs at the start of the frame, which
  needs an earlier compositor callback than today's `POST_TRANSPARENT`.
- Parse `image.*` (format, clear, relative size, 1D, 2D or 3D) and
  `bufferObject.*` (size, screen-relative form) from `shaders.properties`.
  Create storage textures and buffers; clear the `clear = true` ones each
  frame.
- Translate `image*` uniforms as storage images (they are currently treated
  as samplers), `layout(std430) buffer` blocks into their own descriptor
  set, and `colorimgN` as storage views of the colortex targets, which then
  need the storage usage bit.
- Bind custom images to their sampler names (`texLpv1`) in the chain and,
  through `Texture3DRD` globals like `GoannaIrisShadow`'s `Texture2DRD`, in
  the translated gbuffers materials, which is where Mellow and Bliss read
  them.
- Define `IRIS_FEATURE_CUSTOM_IMAGES`, `IRIS_FEATURE_SSBO`,
  `IRIS_FEATURE_COMPUTE_SHADERS` and `MC_GL_EXT_shader_image_load_store`,
  and stop refusing those features.

### 2. The node provider

A camera-centred volume of the nodes near the player, kept on the GPU and
shared by every pack.

- **Exposed nodes only.** A flood fill only spreads through air, so a solid
  node with no air neighbour can never receive light, and leaving it out
  changes nothing. The shadow pass only sees those nodes too, since buried
  faces are never meshed. That cuts a 256 x 128 x 256 box (8.4 million
  nodes) to a few hundred thousand.
- **Per node record**: block position, content id, the pack's
  `mc_Entity` (content id to `MaterialTable::node_block` to the pack's
  `block_ids`, as the gbuffers shells already do), light source level,
  baked block and sky light, and a shape class (full cube, slab-like,
  plant).
- **Mapblock slots.** A storage buffer of per-mapblock slots addressed
  modulo the box, updated with partial `buffer_update` when a mapblock
  arrives or changes, so moving the camera rewrites only the new edge.
  `texture_update` on a 3D texture replaces the whole texture, which is why
  this is a buffer.
- **Built off the main thread.** The scan pattern exists in
  `updateLampOcclusion` (map lock, per-mapblock content digests, cached
  block lookups). The prototype in `c2f70c0b` scanned 128 x 64 x 128 nodes
  in 5 to 9 ms on the main thread; per-mapblock updates on a worker should
  make the steady cost close to nothing.
- **A compacted list** of the exposed nodes, rebuilt on the GPU when slots
  change, gives the replay its dispatch size.

### 3. The replay

Per frame, before the pack's `shadowcomp` passes and after the custom images
are cleared, dispatch the translated shadow program over the node list.

- Each invocation sets `gl_VertexID` to a multiple of 4, `gl_Vertex` to the
  node's lower corner (Photon's corner test then passes),
  `at_midBlock.xyz` to the centre offset times 64 and `.w` to the emission
  level, `mc_Entity`, `gl_MultiTexCoord1` from the baked light,
  `mc_midTexCoord` and `gl_MultiTexCoord0` to the node's atlas tile (Mellow
  samples it), and `renderStage` to the terrain stage that matches the
  node's draw type.
- `gl_ModelViewMatrix` and the shadow matrices are the ones the shadow
  material already gets.
- Varyings and `gl_Position` become locals and are discarded. Packs that
  test `gl_VertexID % 4` write once per node, as on real quads.
- The translator already has an unused `ProgramKind::Shadow`; this is a
  sibling kind that emits compute.

**Half-node offset.** Luanti nodes are centred on whole coordinates, while
packs assume a block spans `[p, p + 1)`. A replayed centre lands exactly
on an integer, where `floor` is decided by rounding error. Either feed the
replay node corners and centres shifted by half a node, consistently with
`cameraPosition` in that pack's chain, or confirm how the translated
gbuffers programs already handle this. To verify before the first replay.

### 4. Targets, in order

1. **Noble**, for piece 1 alone: compute passes, SSBOs, `colorimg`.
2. **Solas**, the first replay: on by default, read in the screen chain,
   r8ui volume, and today visibly black.
3. **Complementary, BSL, Photon, Bliss**, by turning their options on with
   `GOANNA_SHADERPACK_OPTIONS`; each is the same replay with no new code
   expected. Photon adds its look-ahead centre, which comes from the pack's
   own code.
4. **Mellow**, which needs the atlas tile and emission inputs, and the
   `Texture3DRD` path into gbuffers materials. It is MIT and shippable.
5. **Shrimple** in its LIGHTS profile: the geometry shader extension of the
   replay, and its 8 cubed bin layout comes from its own code.
6. **Rethinking Voxels**, last, through B on real meshes.

## Costs and risks

- **Memory.** Default volumes are 3 to 64 MB per pack; the largest options
  reach 1 to 2 GB (BSL and Complementary at 512, Photon at 512 cubed). Cap
  sizes Goanna accepts, or let the pack refuse.
- **Frame time.** The replay runs every frame because the packs clear their
  volume every frame. A few hundred thousand invocations of a short vertex
  program should cost well under a millisecond; to measure.
- **Inputs a pack reads that Goanna lacks.** The replay will surface them
  as they come, as the gbuffers translation did: `blockEntityId`, entity
  colour, item ids. Entity lights (Bliss, Complementary) are out of scope
  at first; entities are not in the node provider.
- **Iris semantics not yet confirmed**: what `voxelizeLightBlocks` and
  `voxelDistance` change in Iris, the exact meaning of
  `shadow.culling = reversed`, and the order of `_a` and `_b` compute
  variants against their base pass.
- **Licences.** Only Mellow and Noble of these may ship with Goanna; the
  rest are tested locally, as in the survey. Design C copies nothing from
  any pack.
