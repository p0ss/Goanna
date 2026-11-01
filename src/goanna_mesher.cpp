// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Near block meshing through Luanti's MapBlockMesh: the gather half (main
// thread, under mapLock()), the mesh half (any thread) and the inline path
// that does both. goanna_mesher.h says which caller runs which, and why the
// block with a dig crack is meshed inline.

#include "goanna_mesher.h"

#include "goanna_branch_rods.h"
#include "goanna_radial_form.h"

#include "goanna_luanti_client.h"
#include "goanna_session.h"
#include "goanna_textures.h"
#include "itemgroup.h"
#include "nodedef.h"
#include "nodemetadata.h"
#include "client/node_visuals.h"
#include "mapblock.h"
#include "client/mapblock_mesh.h"

namespace goanna {

namespace {

// The arms of every branch in this block and one node around it (a rod's cap
// depends on its neighbour's arms), from the node metadata the map holds.
// Map lock held. See goanna_branch_rods.h for the contract.
void gatherBranches(GoannaSession &session, const v3s16 bp, BranchSnapshot &out) {
    out.arms.clear();
    const NodeDefManager *ndef = session.nodeDefs();
    const v3s16 corner = bp * MAP_BLOCKSIZE;
    for (s16 z = -1; z <= 1; ++z)
        for (s16 y = -1; y <= 1; ++y)
            for (s16 x = -1; x <= 1; ++x) {
                MapBlock *b = session.getBlock(bp + v3s16(x, y, z));
                if (!b || b->m_node_metadata.size() == 0)
                    continue;
                const v3s16 offset = (bp + v3s16(x, y, z)) * MAP_BLOCKSIZE - corner;
                for (const auto &entry : b->m_node_metadata) {
                    const v3s16 rel = entry.first;
                    const v3s16 at = offset + rel;
                    if (at.X < -1 || at.Y < -1 || at.Z < -1 || at.X > MAP_BLOCKSIZE ||
                            at.Y > MAP_BLOCKSIZE || at.Z > MAP_BLOCKSIZE)
                        continue;
                    const NodeMetadata *meta = entry.second;
                    if (!meta)
                        continue;
                    const uint32_t arms = parseBranchArms(meta->getString(kBranchArmsField));
                    if (!arms)
                        continue;
                    if (itemgroup_get(ndef->get(b->getNodeNoCheck(rel)).groups, kBranchGroup) <= 0)
                        continue;
                    out.set(at.X, at.Y, at.Z, arms);
                }
            }
}

} // namespace

bool gatherMeshData(GoannaSession &session, MapBlock *block, MeshMakeData &data,
        bool &has_crack, BranchSnapshot &branches) {
    has_crack = false;
    if (!block)
        return false;
    const v3s16 bp = block->getPos();
    data.fillBlockDataBegin(bp);
    for (s16 z = -1; z <= 1; ++z)
        for (s16 y = -1; y <= 1; ++y)
            for (s16 x = -1; x <= 1; ++x) {
                MapBlock *b = session.getBlock(bp + v3s16(x, y, z));
                if (b)
                    b->copyTo(data.m_vmanip);
            }
    gatherBranches(session, bp, branches);
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
    // GOANNA_DEBUG_VCOL=1 (goanna_client_near.cpp) prints the spread of per
    // vertex green inside each mesh buffer, and against Mineclonia on Luanti
    // 5.16.1 the output is byte identical with the flag true and false, buffer
    // for buffer, most buffers reading one distinct value. A three view A/B in
    // the same jungle at the same fixed camera positions agreed: 0.4 to 2.9 per
    // cent of pixels differed by more than 4 of 255, and the diff was
    // concentrated in the far chunks that streamed differently between runs,
    // not in the shaded faces the change was supposed to help.
    //
    // Turning it on before g_goanna_no_light goes is not harmless either: it
    // costs the extra per corner light gathering for a result that is
    // discarded.
    data.m_smooth_lighting = false;
    const auto &is = session.interactState();
    has_crack = is.crack_level >= 0 && getNodeBlockPos(is.crack_pos) == bp;
    if (has_crack)
        data.setCrack(is.crack_level, is.crack_pos);
    return true;
}

std::unique_ptr<MapBlockMesh> meshGathered(GoannaSession &session, MeshMakeData &data,
        const BranchSnapshot &branches) {
    // The carves the server has told us about for this block, snapshotted so
    // content_mapblock can read them without touching the shared store: this
    // runs on a mesh worker and several of them are live at once.
    CarveSnapshot carves;
    const v3s16 corner = data.m_blockpos * MAP_BLOCKSIZE;
    session.carves().snapshot(corner.X, corner.Y, corner.Z, carves);
    goanna::g_goanna_carve_block = carves.entries.empty() ? nullptr : &carves;
    goanna::g_goanna_branch_block = branches.arms.empty() ? nullptr : &branches;
    struct Clear {
        ~Clear() {
            goanna::g_goanna_carve_block = nullptr;
            goanna::g_goanna_branch_block = nullptr;
        }
    } clear_on_exit;
    return std::make_unique<MapBlockMesh>(session.meshClient(), &data);
}

std::unique_ptr<MapBlockMesh> meshBlock(GoannaSession &session, MapBlock *block) {
    if (!block)
        return nullptr;
    MeshGrid grid{1};
    MeshMakeData data(session.nodeDefs(), MAP_BLOCKSIZE, grid);
    bool has_crack = false;
    BranchSnapshot branches;
    if (!gatherMeshData(session, block, data, has_crack, branches))
        return nullptr;
    auto mesh = meshGathered(session, data, branches);
    // Stamp the crack level into the crack materials' MaterialTypeParam
    // (MapBlockMesh::animate's crack pass); the Godot side reads it back and
    // composites the crack frame over the base texture through the DSL.
    if (has_crack) {
        const auto &is = session.interactState();
        mesh->animate(false, 0.0f, is.crack_level, 1000);
    }
    return mesh;
}

} // namespace goanna
