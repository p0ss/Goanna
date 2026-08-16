// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Block meshing on top of Luanti's own MapBlockMesh (content_mapblock: all
// drawtypes, texture tiles, tile colours). Output is Irrlicht CPU meshes
// (SMesh/SMeshBuffer, header-only types) which GoannaClient converts to
// Godot arrays; vertex lighting is bypassed (see goanna_mesh_flags.h).

#include <memory>

#include "irrlichttypes_bloated.h"

class MapBlock;
class MapBlockMesh;

namespace goanna {

class GoannaSession;

// Meshes one block with its 3x3x3 neighbourhood. Caller holds session.mapLock().
// Returns nullptr if the block or its data are unavailable.
std::unique_ptr<MapBlockMesh> meshBlock(GoannaSession &session, MapBlock *block);

} // namespace goanna
