// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_mesher.h"

#include "goanna_luanti_client.h"
#include "goanna_session.h"
#include "goanna_textures.h"
#include "nodedef.h"
#include "client/node_visuals.h"
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
    // Off, and it has to stay off until the vertex light path is revived.
    // content_mapblock.cpp does implement smooth lighting fully, per vertex
    // light blended across neighbours plus an ambient occlusion term from
    // counting solid ones, but every value it computes leaves through
    // encode_light(), and mapblock_mesh.cpp's g_goanna_no_light makes that
    // return opaque white for every vertex, because Godot lights the world
    // instead. So the flag cannot change a single vertex colour.
    //
    // Measured rather than reasoned, because turning it on looked plausible:
    // GOANNA_DEBUG_VCOL=1 (goanna_client.cpp) prints the spread of per vertex
    // green inside each mesh buffer, and against Mineclonia on Luanti 5.16.1
    // the output is byte identical with the flag true and false, buffer for
    // buffer, most buffers reading one distinct value. A three view A/B in
    // the same jungle at the same fixed camera positions agreed: 0.4 to 2.9
    // per cent of pixels differed by more than 4 of 255, and the diff was
    // concentrated in the far chunks that streamed differently between runs,
    // not in the shaded faces the change was supposed to help.
    //
    // Turning it on before g_goanna_no_light goes is not harmless either: it
    // costs the extra per corner light gathering for a result that is
    // discarded.
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
