// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_mesher.h"

#include "goanna_luanti_client.h"
#include "goanna_session.h"
#include "mapblock.h"
#include "client/mapblock_mesh.h"

namespace goanna {

std::unique_ptr<MapBlockMesh> meshBlock(GoannaSession &session, MapBlock *block) {
    if (!block)
        return nullptr;
    const v3s16 bp = block->getPos();
    MeshGrid grid{1};
    MeshMakeData data(session.nodeDefs(), MAP_BLOCKSIZE, grid);
    data.fillBlockDataBegin(bp);
    for (s16 z = -1; z <= 1; ++z)
        for (s16 y = -1; y <= 1; ++y)
            for (s16 x = -1; x <= 1; ++x) {
                MapBlock *b = session.getBlock(bp + v3s16(x, y, z));
                if (b)
                    b->copyTo(data.m_vmanip);
            }
    data.m_generate_minimap = false;
    data.m_smooth_lighting = false;
    const auto &is = session.interactState();
    bool has_crack = is.crack_level >= 0 && getNodeBlockPos(is.crack_pos) == bp;
    if (has_crack)
        data.setCrack(is.crack_level, is.crack_pos);
    auto mesh = std::make_unique<MapBlockMesh>(session.meshClient(), &data);
    // Stamp the crack level into the crack materials' MaterialTypeParam
    // (MapBlockMesh::animate's crack pass); the Godot side reads it back and
    // composites the crack frame over the base texture through the DSL.
    if (has_crack)
        mesh->animate(false, 0.0f, is.crack_level, 1000);
    return mesh;
}

} // namespace goanna
