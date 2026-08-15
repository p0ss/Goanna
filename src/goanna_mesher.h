#pragma once

// Stage-2 mesher: naive culled cubes from a MapBlock, vertex-coloured by
// node type. Deliberately simple; the transplant of Luanti's own
// content_mapblock meshing (all drawtypes, real textures) replaces it.

#include <vector>

#include "irrlichttypes_bloated.h"

class MapBlock;
class NodeDefManager;

namespace goanna {

struct MeshData {
    std::vector<float> positions; // xyz triples, in Godot space (z mirrored)
    std::vector<float> normals;
    std::vector<float> colors;    // rgba
    std::vector<int32_t> indices;
    bool empty() const { return indices.empty(); }
};

class GoannaSession;

// Meshes one block. Neighbouring blocks (for cross-boundary culling) are
// looked up through the session; caller must hold session.mapLock().
MeshData meshBlock(GoannaSession &session, MapBlock *block);

} // namespace goanna
