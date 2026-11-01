# Branch rods

A game can ask for tree branches to be drawn round. A stock client draws a
branch as the node box the server registered, a blocky approximation baked
from a small catalogue of shapes; Goanna draws the shape the server keeps
for that one node, as round rods. It changes the picture only: collision,
selection and digging still use the node box, exactly as a stock client
does.

## The contract

DorfCraft set it (its `mods/kindred/world/crops/forms.lua`, the branch
section). Nothing in it is DorfCraft specific beyond the names, and any
game can use it:

- A branch node is in the item group `kindred_branch`, whose value is the
  rod width in sixteenths of a node (DorfCraft uses 2, 4 and 6).
- Its node metadata integer `kindred_arms` is a bitmask over the radial
  form kernel's 26 directions, in Kythen's `M.PLANES` order: six faces (xn
  xp yn yp zn zp), eight corners (nnn to ppp), twelve edges (xnyn to ypzp).
  Bit i is the i-th direction.
- Each set bit is an arm: a round rod of radius width/32 from the node
  centre towards that neighbour, ending where its ray leaves the node: a
  face centre, an edge midpoint or a corner. A ball of the same radius
  joins the arms at the centre.
- The arms are in world orientation. The node's name and facedir only pick
  the stock client's baked piece, and Goanna ignores them.
- A branch without the field is drawn as its node box.

## How it is drawn

`gatherMeshData` (`src/goanna_mesher.cpp`) copies the arms of every branch
in the block and one node around it out of the map's node metadata, on the
main thread under the map lock, into a `BranchSnapshot`. The mesh worker
hands that to the transplanted `drawNodeboxNode` through
`g_goanna_branch_block`, which draws the rods from
`branchRodMesh` (`src/goanna_branch_rods.cpp`) in place of the boxes.

- Rods are eight sided, the ball eight round and four from pole to pole.
  A straight stem draws no ball, since its two rods already hold it.
- An arm's far end is capped only when it is open: not where the
  neighbour it points at has the matching arm back, and not on the face
  of a solid node.
- A rod and the neighbour's rod coming back along the same line share one
  frame, so their rims and texture meet point for point.
- The texture is the node's side tile, u around the rod and v along it, at
  a node box's density (one tile a node).
- Lighting is Godot's, from the vertex normals, as for every other near
  mesh; the per vertex light sampling sees rods like any other geometry.
- A change to a node's metadata re-meshes its block, as for a carve
  (`GoannaSession::takeCarveMetadata`), so a branch that grows an arm is
  redrawn.

`goanna_branch_rods_test` checks the geometry and the mesher path without
a server.

## Seen in a run

On 1 November 2026, against Luanti 5.17.0 (flatpak) with Mineclonia
(ContentDB release 39603) and DorfCraft's mods staged from its working
tree, in a disposable singlenode world built by a copy of DorfCraft's
`forms_view` test mod: Goanna (Godot 4.5.1 official binary, software
rendered under `tools/goanna-headless start --software`) drew every
catalogue shape at widths 2, 4 and 6 and a small hand-built oak as round
rods, and the stock Luanti client on the same server drew the baked
boxes. The frames are in `docs/perf/branch-rods-2026-11-01/`, Goanna's
placed with the control channel's `pose` and `look` and taken with `shot`.
In the tree the diagonal arms run on from node to node as single rods,
where the stock client's nearest pieces do not meet. Goanna's frames have
snow over the ground and the rods' upper faces and a different time of
day; that is Goanna's season cover on that world, not this feature.

## What does not work yet

- Only near blocks draw rods. Far terrain is built from coarse chains that
  carry no node metadata, so a distant branch keeps whatever the far
  mesher makes of its node box.
- A carve on a branch is drawn from the node box, not the rods.
- An edge or corner arm with no neighbour to meet runs its cap slightly
  past the node, where the rod's straight end does not follow the node's
  faces.
- The tile's rotation and world alignment are not applied along a rod.
