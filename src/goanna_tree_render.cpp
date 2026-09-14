// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_tree_render.h"

#include "mapblock.h"
#include "nodedef.h"

#include <algorithm>
#include <cmath>

namespace goanna {

namespace {

// Which level to read. Four nodes is what a summary can honestly fill, and a
// chain built from live nodes has it too, so one level serves both sources and
// a tile does not change shape when a block is replaced by a better record.
constexpr int kCell = 4;

// A stable angle per tree. One prototype serves a species, and a stand of the
// same picture all facing the same way is what gives an impostor away.
float yawFor(const v3f &at) {
    uint32_t h = (uint32_t)((int)at.X * 73856093) ^ (uint32_t)((int)at.Z * 19349663) ^
            (uint32_t)((int)at.Y * 83492791);
    h ^= h >> 13;
    h *= 1274126177u;
    h ^= h >> 16;
    return (float)(h % 6283) / 1000.0f;
}

} // namespace

void TreeLayer::clear() {
    m_tiles.clear();
    m_draw.clear();
}

bool TreeLayer::buildTile(const std::map<v3s16, std::shared_ptr<const BlockLodChain>> &chains,
        const NodeDefManager *ndef, v3s16 tile, Tile &out) {
    const int level = BlockLodChain::levelForCell(kCell);
    const int per_block = MAP_BLOCKSIZE / kCell;          // voxels per block per axis
    const int edge = kTileBlocks * per_block;              // voxels per tile per axis

    TreeField field;
    field.cell = kCell;
    field.size = v3s16(edge, edge, edge);
    field.origin = v3s16(tile.X * kTileBlocks * MAP_BLOCKSIZE,
            tile.Y * kTileBlocks * MAP_BLOCKSIZE,
            tile.Z * kTileBlocks * MAP_BLOCKSIZE);
    field.resize();
    field.resizeLight();

    size_t signature = 0;
    bool any = false;
    for (int bz = 0; bz < kTileBlocks; ++bz)
        for (int by = 0; by < kTileBlocks; ++by)
            for (int bx = 0; bx < kTileBlocks; ++bx) {
                const v3s16 bp(tile.X * kTileBlocks + bx, tile.Y * kTileBlocks + by,
                        tile.Z * kTileBlocks + bz);
                auto it = chains.find(bp);
                if (it == chains.end() || !it->second)
                    continue;
                const BlockLodChain &ch = *it->second;
                const LodLevel &lv = ch.level[level];
                if (!lv.built())
                    continue;
                // Cheap identity: which chains went in, so an unchanged tile is
                // not rebuilt and a changed one is.
                signature = signature * 1099511628211ull +
                        (size_t)(uintptr_t)it->second.get();

                for (int z = 0; z < lv.n; ++z)
                    for (int y = 0; y < lv.n; ++y)
                        for (int x = 0; x < lv.n; ++x) {
                            const LodLevel::Cell &c = lv.at(x, y, z);
                            if (!(c.flags & LodLevel::kKnown))
                                continue;
                            const int fx = bx * per_block + x;
                            const int fy = by * per_block + y;
                            const int fz = bz * per_block + z;
                            const size_t i = field.index(fx, fy, fz);
                            if (c.flags & LodLevel::kLit) {
                                field.day[i] = c.day;
                                field.night[i] = c.night;
                            }
                            if (!(c.flags & LodLevel::kFilled))
                                continue;
                            const content_t content = c.face[0];
                            if (!lodIsVegetation(ndef, content))
                                continue;
                            field.content[i] = content;
                            field.canopy[i] = 1;
                            // Wood against foliage, by whether the node is a
                            // full opaque cube. Not by the group "tree": that
                            // group is not carried by every game's trunks.
                            field.trunk[i] = (c.flags & LodLevel::kOccludes) ? 1 : 0;
                            any = true;
                        }
            }

    if (out.signature == signature && !out.trees.empty())
        return false;   // same chains, same trees
    if (!any) {
        const bool had = !out.trees.empty();
        out.trees.clear();
        out.signature = signature;
        return had;
    }

    // Four node voxels: only a tree standing clear of its neighbours can be
    // told from the stand around it, so only those are drawn. A closed canopy
    // belongs to the aggregate tier.
    TreeDetectOptions opt;
    opt.isolated_only = true;
    std::vector<TreeMask> masks;
    std::vector<TreeInstance> found = detectTrees(field, opt, &masks);

    out.trees.clear();
    out.signature = signature;
    for (size_t i = 0; i < found.size(); ++i) {
        TreeVolume vol = buildTreeVolume(masks[i], m_colour);
        vol.key = treePrototypeKey(found[i].trunk, found[i].leaves,
                (int)(yawFor(found[i].base) * 4.0f) % 4);
        int slot = m_atlas.slotOf(vol.key);
        if (slot < 0) {
            slot = m_atlas.add(vol);
            if (slot < 0)
                continue;   // atlas full: better no tree than the wrong tree
            m_atlas_changed = true;
        }
        TreeDraw d;
        d.base = found[i].base;
        d.height = found[i].height;
        d.radius = found[i].radius;
        d.yaw = yawFor(found[i].base);
        d.slot = slot;
        d.day_base = found[i].day_base;
        d.day_top = found[i].day_top;
        d.night_base = found[i].night_base;
        d.night_top = found[i].night_top;
        out.trees.push_back(d);
    }
    return true;
}

bool TreeLayer::update(const std::map<v3s16, std::shared_ptr<const BlockLodChain>> &chains,
        const NodeDefManager *ndef, v3s16 centre_block, int radius_blocks) {
    if (!ndef)
        return false;
    const int reach = std::max(1, radius_blocks / kTileBlocks);
    const v3s16 centre(
            (s16)std::floor((float)centre_block.X / kTileBlocks),
            (s16)std::floor((float)centre_block.Y / kTileBlocks),
            (s16)std::floor((float)centre_block.Z / kTileBlocks));

    bool changed = false;
    std::map<v3s16, Tile> kept;
    for (int tz = -reach; tz <= reach; ++tz)
        for (int ty = -reach; ty <= reach; ++ty)
            for (int tx = -reach; tx <= reach; ++tx) {
                const v3s16 tile(centre.X + tx, centre.Y + ty, centre.Z + tz);
                auto it = m_tiles.find(tile);
                Tile t;
                if (it != m_tiles.end())
                    t = std::move(it->second);
                if (buildTile(chains, ndef, tile, t))
                    changed = true;
                if (!t.trees.empty() || t.signature != 0)
                    kept.emplace(tile, std::move(t));
            }

    // Anything outside the reach is dropped, which is what stops the set
    // growing without bound as a player crosses a world.
    if (kept.size() != m_tiles.size())
        changed = true;
    m_tiles = std::move(kept);

    if (changed) {
        m_draw.clear();
        for (const auto &kv : m_tiles)
            m_draw.insert(m_draw.end(), kv.second.trees.begin(), kv.second.trees.end());
    }
    return changed;
}

} // namespace goanna
