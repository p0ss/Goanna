// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Turning the far field's occupancy into a set of trees to draw.
//
// This is the join between goanna_trees.h, which finds trees in a box of
// voxels, and the renderer, which wants one atlas and one instance buffer. It
// deliberately does not go through the far region machinery: a region is a
// mesh of the ground and rebuilding one is expensive, while trees are sparse,
// change rarely, and want to be one draw call for the whole view rather than
// one per region.
//
// Work happens in tiles of blocks rather than per block, because a tree at a
// mapblock boundary belongs to both and detecting per block would cut it in
// half and then draw both halves as separate trees.

#pragma once

#include "goanna_lod.h"
#include "goanna_tree_atlas.h"
#include "goanna_trees.h"

#include <map>
#include <memory>
#include <vector>

namespace goanna {

// One tree ready to draw: where it stands, how big, which slot, and the light
// it was standing in.
struct TreeDraw {
    v3f base;
    float height = 0;
    float radius = 0;
    float yaw = 0;
    int slot = 0;
    uint8_t day_base = 255, day_top = 255;
    uint8_t night_base = 0, night_top = 0;
};

class TreeLayer {
public:
    // Blocks per tile per axis. Four is 64 nodes, wide enough that a tree at a
    // mapblock seam is whole and small enough that one changed block does not
    // rebuild the county.
    static constexpr int kTileBlocks = 4;

    // Rebuild from the chains covering a box of tiles around `centre_block`.
    // Pure computation: no Godot objects are touched, so this can run wherever
    // it is convenient. Returns true when anything changed.
    bool update(const std::map<v3s16, std::shared_ptr<const BlockLodChain>> &chains,
            const NodeDefManager *ndef, v3s16 centre_block, int radius_blocks);

    const std::vector<TreeDraw> &trees() const { return m_draw; }
    const TreeAtlas &atlas() const { return m_atlas; }
    bool atlasChanged() const { return m_atlas_changed; }
    void clearAtlasChanged() { m_atlas_changed = false; }

    // Set before update() to resolve a node's colour. Without one the atlas is
    // built in flat grey, which is visible and therefore honest.
    void setColourFn(TreeColourFn fn) { m_colour = std::move(fn); }

    void clear();

private:
    struct Tile {
        std::vector<TreeDraw> trees;
        size_t signature = 0;   // which chains it was built from
    };

    bool buildTile(const std::map<v3s16, std::shared_ptr<const BlockLodChain>> &chains,
            const NodeDefManager *ndef, v3s16 tile, Tile &out);

    std::map<v3s16, Tile> m_tiles;
    std::vector<TreeDraw> m_draw;
    TreeAtlas m_atlas;
    TreeColourFn m_colour;
    bool m_atlas_changed = false;
};

} // namespace goanna
