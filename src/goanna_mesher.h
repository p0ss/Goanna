// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Block meshing on top of Luanti's own MapBlockMesh (content_mapblock: all
// drawtypes, texture tiles, tile colours). Output is Irrlicht CPU meshes
// (SMesh/SMeshBuffer, header-only types) which GoannaClient converts to
// Godot arrays; vertex lighting is bypassed (see goanna_mesh_flags.h).
//
// Threads: gatherMeshData and meshBlock run on Godot's main thread, from
// GoannaClient::poll_blocks, with session.mapLock() held. meshGathered runs
// on a MeshPool worker (NearBlockJob in goanna_client_jobs.cpp). The session
// thread never meshes: it only queues block positions.

#include <memory>

#include "irrlichttypes_bloated.h"
#include "client/mapblock_mesh.h"

class MapBlock;

namespace goanna {

class GoannaSession;

// Meshes one block with its 3x3x3 neighbourhood, inline. Main thread, caller
// holds session.mapLock(). Used for the block with a dig crack in it and
// when the mesh pool is not running. Returns nullptr if the block or its
// data are unavailable.
std::unique_ptr<MapBlockMesh> meshBlock(GoannaSession &session, MapBlock *block);

// The two halves of meshBlock, so the expensive one can run on a mesh worker
// (goanna_mesh_pool.h).
//
// gatherMeshData copies the block and its 3x3x3 neighbourhood into `out`,
// which is what makes the rest independent of the map. It reads the map,
// which the session thread writes as packets arrive, and the interaction
// state, which stepInteract writes, so it runs on the main thread with
// session.mapLock() held.
//
// meshGathered turns that copy into geometry, reading only the copy, a
// snapshot of the block's carves (CarveStore locks itself) and the texture
// and shader sources, which lock themselves (goanna_textures.h): a crack,
// the live dig's or a stored carve's, asks for crack_anylength.png by name
// (transplant/client/mapblock_mesh.cpp). So it runs on any thread. The block
// with the live dig crack in it is still meshed inline, as gatherMeshData
// reports it: it re-meshes on every crack step, and meshBlock stamps the
// crack level from the interaction state, which is the main thread's.
bool gatherMeshData(GoannaSession &session, MapBlock *block, MeshMakeData &out, bool &has_crack);
std::unique_ptr<MapBlockMesh> meshGathered(GoannaSession &session, MeshMakeData &data);

// Far blocks are not meshed here: goanna_lod.h derives a coarse chain per
// block and meshes whole regions of them per tier.

} // namespace goanna
