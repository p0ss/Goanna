#pragma once

// Stage-2 mesher: culled cubes and cross-quads from a MapBlock, faces
// grouped by tile texture into surfaces, UV-mapped, tinted by node colour.
// Deliberately simple; the transplant of Luanti's own content_mapblock
// meshing (all drawtypes, texture modifiers, palettes) replaces it.

#include <cstdint>
#include <string>
#include <vector>

#include "irrlichttypes_bloated.h"
#include "nodedef.h"

class MapBlock;

namespace goanna {

struct SurfaceData {
    std::string tex;              // full tile texture string (may carry modifiers)
    TileAnimationParams animation;
    AlphaMode alpha = ALPHAMODE_OPAQUE;
    bool double_sided = false;    // cross quads
    std::vector<float> positions; // xyz, Godot space
    std::vector<float> normals;
    std::vector<float> uvs;
    std::vector<float> colors;    // rgba tint
    std::vector<int32_t> indices;
};

struct MeshData {
    std::vector<SurfaceData> surfaces;
    bool empty() const { return surfaces.empty(); }
};

class GoannaSession;

// Meshes one block. Neighbouring blocks (for cross-boundary culling) are
// looked up through the session; caller must hold session.mapLock().
MeshData meshBlock(GoannaSession &session, MapBlock *block);

} // namespace goanna
