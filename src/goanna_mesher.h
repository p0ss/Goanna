// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Block meshing on top of Luanti's own MapBlockMesh (content_mapblock: all
// drawtypes, texture tiles, tile colours). Output is Irrlicht CPU meshes
// (SMesh/SMeshBuffer, header-only types) which GoannaClient converts to
// Godot arrays; vertex lighting is bypassed (see goanna_mesh_flags.h).

#include <memory>

#include "irrlichttypes_bloated.h"
#include "client/mapblock_mesh.h"

class MapBlock;

namespace goanna {

class GoannaSession;

// Meshes one block with its 3x3x3 neighbourhood. Caller holds session.mapLock().
// Returns nullptr if the block or its data are unavailable.
std::unique_ptr<MapBlockMesh> meshBlock(GoannaSession &session, MapBlock *block);

// The two halves of meshBlock, so the expensive one can run on a mesh worker
// (goanna_mesh_pool.h).
//
// gatherMeshData copies the block and its 3x3x3 neighbourhood into `out`,
// which is what makes the rest independent of the map. It reads the map, so
// the caller holds session.mapLock() and it must run on the thread that owns
// the session's map.
//
// meshGathered turns that copy into geometry and touches nothing else, so it
// runs anywhere. The one exception is a block with a dig crack in it: that
// path asks the texture source for the crack overlay
// (transplant/client/mapblock_mesh.cpp), which is not thread safe here, so
// gatherMeshData reports it and the caller meshes that block inline. It is
// one block, the one under the player's cursor, and it re-meshes every crack
// step anyway.
bool gatherMeshData(GoannaSession &session, MapBlock *block, MeshMakeData &out, bool &has_crack);
std::unique_ptr<MapBlockMesh> meshGathered(GoannaSession &session, MeshMakeData &data);

// Far blocks are not meshed here: goanna_lod.h derives a coarse chain per
// block and meshes whole regions of them per tier.

} // namespace goanna
