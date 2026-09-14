// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Finding individual trees in voxel occupancy, so the far field can draw a
// picture of a tree where a tree is rather than a box where some leaves are.
//
// The far tiers hold an occupancy field and nothing in it knows what a tree is:
// a crown is some occupied cells, and at cell 16 it draws as a solid cube.
// Thinning that cube by how full it is (LodLevel::Cell::coverage) is the right
// answer for a closed canopy at range, where no individual tree is separable
// and none needs to be. It is the wrong answer for the case that actually looks
// wrong, a single tree standing on a hill, which wants its own silhouette at
// its own size in its own place.
//
// This file is the half that finds them. Detection runs on voxels the client
// already holds, never on anything asked of the server, so it works against an
// unmodified one and gives a Goanna player no reach a vanilla client lacks.

#pragma once

#include "irrlichttypes_bloated.h"
#include "mapnode.h"

#include <cstdint>
#include <vector>

namespace goanna {

// One tree, as something to draw rather than to mesh.
struct TreeInstance {
    // World position of the foot of the trunk, centred in its voxel. The
    // impostor stands on this, so an error here is a tree floating or sunk.
    v3f base;
    float height = 0;   // nodes, trunk foot to the top of the crown
    float radius = 0;   // nodes, crown half width
    content_t trunk = CONTENT_AIR;
    content_t leaves = CONTENT_AIR;
    int voxels = 0;     // how much canopy was assigned to it

    // Where the tree came from. A better source replaces a worse one for the
    // same tree, the rule BlockLodChain::summary already uses for chains: a
    // summary is a guess at 4 nodes, real nodes are exact, and a generator
    // that placed the tree knows without anyone having been there.
    enum Source : uint8_t {
        kFromSummary = 0,
        kFromNodes = 1,
        kAuthored = 2,
    };
    uint8_t source = kFromSummary;
    uint8_t cell = 1;   // node size of the voxels it was found in

    // Luanti's stored light where the tree stands, so an impostor is as dark
    // as the geometry it stands in for. Without this a tree under a cliff or
    // at dusk lights only from the scene and changes brightness the moment it
    // crosses into the meshed range, which is the pop a continuous field
    // cannot have.
    //
    // Two heights rather than one, because a crown in the sun above a trunk in
    // shade is the normal case and a single value has to be wrong for one of
    // them. The shader reads between them by height.
    uint8_t day_base = 255, day_top = 255;
    uint8_t night_base = 0, night_top = 0;
};

// A box of voxels, already classed. The detector takes this rather than a
// BlockLodChain so that summaries, live nodes and a generator's own tree list
// can all feed one implementation, and so it can be tested without a node
// definition manager.
struct TreeField {
    v3s16 origin;          // world node position of voxel (0, 0, 0)
    v3s16 size;            // voxels per axis
    int cell = 1;          // nodes per voxel
    std::vector<content_t> content;  // CONTENT_AIR where nothing stands
    std::vector<uint8_t> canopy;     // 1 where the content is part of a plant
    // 1 where the voxel is wood rather than foliage. This is a question of
    // whether the node is a full opaque cube, not of whether it carries the
    // group "tree": measured against Asuna, the commonest tree in the test
    // forest was dorwinion, whose trunk node is in no such group, so keying on
    // the group found none of them and threw every dorwinion crown away as
    // stemless. Solidness is what the far tiers already classify by.
    std::vector<uint8_t> trunk;
    // Optional, and empty means unknown rather than dark: a field built from a
    // source that carries no light should not make every tree black.
    std::vector<uint8_t> day;
    std::vector<uint8_t> night;

    size_t index(int x, int y, int z) const {
        return ((size_t)z * size.Y + y) * size.X + x;
    }
    bool inside(int x, int y, int z) const {
        return x >= 0 && y >= 0 && z >= 0 && x < size.X && y < size.Y && z < size.Z;
    }
    void resize() {
        const size_t n = (size_t)size.X * size.Y * size.Z;
        content.assign(n, CONTENT_AIR);
        canopy.assign(n, 0);
        trunk.assign(n, 0);
    }
    void resizeLight() {
        const size_t n = (size_t)size.X * size.Y * size.Z;
        day.assign(n, 255);
        night.assign(n, 0);
    }
};

struct TreeDetectOptions {
    // Below this a component is a bush, a vine or one stray leaf, and drawing
    // a tree for it would put trees in a meadow.
    int min_voxels = 3;
    // A crown wider than this around one trunk is a closed canopy that merged,
    // not a tree. Those are left to the aggregate tier rather than drawn as one
    // enormous tree. In nodes, so it means the same at every cell size.
    float max_radius = 14.0f;
    // A trunk this short is a log, a stump or a piece of somebody's house, and
    // an impostor of it would be a bush drawn as a tree.
    float min_height = 4.0f;
    // Only trees standing clear of their neighbours. Four node voxels cannot
    // separate trees inside a closed canopy: measured over a real Asuna wood,
    // 146 trees at node resolution came out as 2 at cell 4, and those 2 were
    // merged blobs of half the stand rather than trees. Drawing those is worse
    // than drawing nothing, because a wood has hundreds of trees in it and two
    // enormous lumps is not a reading of it.
    //
    // So a component carrying more than one stem is left to the aggregate
    // tier, which is what LodLevel::Cell::coverage exists for, and what comes
    // out here is the case this can actually answer: the tree standing on its
    // own. Splitting a stand between its trunks is right at node resolution
    // and guesswork at four, so this is off by default and set by the callers
    // that read coarse voxels.
    bool isolated_only = false;
    // A component carrying no trunk at all is a crown whose stem is outside the
    // field, or a hedge. Off by default: guessing a trunk position under
    // floating leaves is what puts a tree in the wrong place.
    bool allow_trunkless = false;
};

// The voxels one tree was actually made of, in its own local box. This is what
// an impostor is built from, and it is taken from the assignment the detector
// already did rather than from a box around the trunk, so a tree standing in a
// stand carries its own crown and not its neighbour's.
struct TreeMask {
    v3s16 size;                      // voxels
    v3s16 origin;                    // world node position of local (0, 0, 0)
    int cell = 1;
    std::vector<content_t> content;  // CONTENT_AIR where empty
    size_t index(int x, int y, int z) const {
        return ((size_t)z * size.Y + y) * size.X + x;
    }
};

// Every tree in the field. A component with several trunks is split between
// them, because a stand of trees touching at the leaves is still a stand of
// trees and drawing it as one is the fault this exists to fix.
//
// When `masks` is given it receives one entry per returned tree, in the same
// order.
std::vector<TreeInstance> detectTrees(const TreeField &field, const TreeDetectOptions &opt = {},
        std::vector<TreeMask> *masks = nullptr);

} // namespace goanna
