// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_mesher.h"

#include "goanna_luanti_client.h"
#include "goanna_session.h"
#include "goanna_textures.h"
#include "nodedef.h"
#include "client/node_visuals.h"
#include <map>
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

// Average colour of a node's top tile, cached per content id. Tiles may be
// array textures, whose name is not a real image, so resolve the layer first.
static u32 lodColour(GoannaSession &session, content_t c, const ContentFeatures &f) {
    static std::map<content_t, u32> cache;
    auto it = cache.find(c);
    if (it != cache.end())
        return it->second;
    u32 argb = 0xff808080;
    if (f.visuals) {
        const TileLayer &l = f.visuals->tiles[0].layers[0];
        std::string name;
        if (l.texture_id) {
            GoannaTexture *gt = session.tsrc()->goannaTexture(l.texture_id);
            if (gt && gt->isArray()) {
                const auto &names = gt->layerNames();
                if (l.texture_layer_idx < names.size())
                    name = names[l.texture_layer_idx];
            } else if (gt) {
                name = session.tsrc()->getTextureName(l.texture_id);
            }
        }
        if (!name.empty()) {
            video::SColor avg = session.tsrc()->getTextureAverageColor(name);
            if (l.has_color)
                avg.set(255, avg.getRed() * l.color.getRed() / 255,
                        avg.getGreen() * l.color.getGreen() / 255,
                        avg.getBlue() * l.color.getBlue() / 255);
            argb = avg.color | 0xff000000;
        }
    }
    cache[c] = argb;
    return argb;
}

LodMesh meshBlockLod(GoannaSession &session, MapBlock *block, v3s16 bp, int cell) {
    LodMesh out;
    if (!block || cell < 1)
        return out;
    const NodeDefManager *ndef = session.nodeDefs();
    const int n = MAP_BLOCKSIZE / cell; // cells per axis
    // Occupancy and colour per cell: a cell is filled if any node in it is
    // solid or liquid, and takes the colour of the first such node.
    std::vector<u32> colour(n * n * n, 0);
    auto at = [&](int x, int y, int z) { return colour[(z * n + y) * n + x]; };
    for (int cz = 0; cz < n; ++cz)
    for (int cy = 0; cy < n; ++cy)
    for (int cx = 0; cx < n; ++cx) {
        u32 found = 0;
        for (int z = 0; z < cell && !found; ++z)
        for (int y = 0; y < cell && !found; ++y)
        for (int x = 0; x < cell && !found; ++x) {
            MapNode node = block->getNodeNoCheck(cx * cell + x, cy * cell + y, cz * cell + z);
            content_t c = node.getContent();
            if (c == CONTENT_AIR || c == CONTENT_IGNORE)
                continue;
            const ContentFeatures &f = ndef->get(node);
            if (f.visuals && (f.visuals->solidness == 2 || f.isLiquid()))
                found = lodColour(session, c, f);
        }
        colour[(cz * n + cy) * n + cx] = found;
    }
    // Faces of filled cells that face an empty one. Neighbouring blocks are
    // not consulted: a seam between two LOD blocks is hidden by the blocks
    // themselves, and it keeps this a pure per-block operation.
    static const int DIRS[6][3] = {{0,1,0},{0,-1,0},{1,0,0},{-1,0,0},{0,0,1},{0,0,-1}};
    const float cs = (float)cell;
    for (int cz = 0; cz < n; ++cz)
    for (int cy = 0; cy < n; ++cy)
    for (int cx = 0; cx < n; ++cx) {
        u32 col = at(cx, cy, cz);
        if (!col)
            continue;
        for (int d = 0; d < 6; ++d) {
            int nx = cx + DIRS[d][0], ny = cy + DIRS[d][1], nz = cz + DIRS[d][2];
            bool inside = nx >= 0 && ny >= 0 && nz >= 0 && nx < n && ny < n && nz < n;
            if (inside && at(nx, ny, nz))
                continue;
            // cell corner in Godot space (nodes, z mirrored), world-absolute
            float x0 = bp.X * MAP_BLOCKSIZE + cx * cs, y0 = bp.Y * MAP_BLOCKSIZE + cy * cs;
            float z0 = -(bp.Z * MAP_BLOCKSIZE + cz * cs);
            float x1 = x0 + cs, y1 = y0 + cs, z1 = z0 - cs;
            v3f a, b, c2, d2;
            switch (d) {
            case 0: a = {x0, y1, z0}; b = {x1, y1, z0}; c2 = {x1, y1, z1}; d2 = {x0, y1, z1}; break;
            case 1: a = {x0, y0, z1}; b = {x1, y0, z1}; c2 = {x1, y0, z0}; d2 = {x0, y0, z0}; break;
            case 2: a = {x1, y0, z0}; b = {x1, y0, z1}; c2 = {x1, y1, z1}; d2 = {x1, y1, z0}; break;
            case 3: a = {x0, y0, z1}; b = {x0, y0, z0}; c2 = {x0, y1, z0}; d2 = {x0, y1, z1}; break;
            case 4: a = {x0, y0, z1}; b = {x1, y0, z1}; c2 = {x1, y1, z1}; d2 = {x0, y1, z1}; break;
            default: a = {x1, y0, z0}; b = {x0, y0, z0}; c2 = {x0, y1, z0}; d2 = {x1, y1, z0}; break;
            }
            v3f nrm((float)DIRS[d][0], (float)DIRS[d][1], -(float)DIRS[d][2]);
            u32 base = (u32)out.pos.size();
            for (const v3f &p : {a, b, c2, d2}) {
                out.pos.push_back(p);
                out.nrm.push_back(nrm);
                out.col.push_back(col);
            }
            for (u32 i : {0u, 1u, 2u, 2u, 3u, 0u})
                out.idx.push_back(base + i);
        }
    }
    return out;
}

} // namespace goanna
