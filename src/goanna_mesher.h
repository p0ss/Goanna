// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Block meshing on top of Luanti's own MapBlockMesh (content_mapblock: all
// drawtypes, texture tiles, tile colours). Output is Irrlicht CPU meshes
// (SMesh/SMeshBuffer, header-only types) which GoannaClient converts to
// Godot arrays; vertex lighting is bypassed (see goanna_mesh_flags.h).

#include <memory>
#include <vector>

#include "irrlichttypes_bloated.h"

class MapBlock;
class MapBlockMesh;

namespace goanna {

class GoannaSession;

// Meshes one block with its 3x3x3 neighbourhood. Caller holds session.mapLock().
// Returns nullptr if the block or its data are unavailable.
std::unique_ptr<MapBlockMesh> meshBlock(GoannaSession &session, MapBlock *block);

// A distant block, merged into cubes of `cell` nodes and flat-coloured from
// each node's average tile colour. Far terrain does not need texels, it needs
// to be cheap: one material for every LOD block means one draw call each,
// where a full block costs one per tile material. Positions are in Godot
// space (nodes, z mirrored) and world-absolute. Caller holds session.mapLock().
struct LodMesh {
    std::vector<v3f> pos;
    std::vector<v3f> nrm;
    std::vector<u32> col; // 0xAARRGGBB
    std::vector<u32> idx;
    bool empty() const { return idx.empty(); }
};
LodMesh meshBlockLod(GoannaSession &session, MapBlock *block, v3s16 bp, int cell);

} // namespace goanna
