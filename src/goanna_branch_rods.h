// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Tree branches drawn as round rods from per node data, in place of the
// baked node box a stock client draws.
//
// The contract is DorfCraft's (mods/kindred/world/crops/forms.lua, its
// branch section, 1 November 2026), and is plain data a server sends every
// client: a node in the item group `kindred_branch` is a branch whose rod
// width, in sixteenths of a node, is the group's value; its node metadata
// integer `kindred_arms` is a bitmask over the radial form kernel's 26 plane
// directions (bit i for the i-th entry of Kythen's `M.PLANES`: six faces,
// then eight corners, then twelve edges, the order goanna_radial_form.h
// documents). Each set bit is an arm: a round rod of radius width/32 from
// the node centre towards that neighbour, ending where the ray leaves the
// node (a face centre, an edge midpoint or a corner), and a ball of the same
// radius joins them at the centre. The arms are already in world
// orientation; the node's name and facedir only choose the stock client's
// baked piece and are ignored here. A branch without the field is drawn as
// its node box, as any other client draws it.
//
// Presentation only. Collision, selection and the node box itself are the
// definition's, read and used as before.
//
// Threads: `branchRodMesh` and the direction tables are pure. A snapshot of
// the arms around one block is taken on the main thread under the map lock
// (gatherMeshData, goanna_mesher.cpp) and read by content_mapblock through
// `g_goanna_branch_block` on whichever thread meshes that block.

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace goanna {

constexpr const char *kBranchGroup = "kindred_branch";
constexpr const char *kBranchArmsField = "kindred_arms";
constexpr int kBranchArmCount = 26;
constexpr uint32_t kBranchArmsMask = (1u << kBranchArmCount) - 1;

// The neighbour arm i points at, as an integer offset; its unit direction is
// this normalised.
struct BranchOffset {
    int x, y, z;
};
BranchOffset branchArmOffset(int arm);
// The arm pointing the other way, which a neighbour's matching arm is.
int branchArmOpposite(int arm);

// The field's value as Luanti stores an int (a decimal string); 0 when it is
// empty, not a number or has no arm set.
uint32_t parseBranchArms(const std::string &value);

// Arms of the branches in and one node around one block, keyed by position
// relative to the block's corner node.
struct BranchSnapshot {
    std::unordered_map<uint64_t, uint32_t> arms;
    static uint64_t key(int x, int y, int z) {
        return (uint64_t)(uint16_t)x | ((uint64_t)(uint16_t)y << 16) |
                ((uint64_t)(uint16_t)z << 32);
    }
    void set(int x, int y, int z, uint32_t mask) { arms[key(x, y, z)] = mask; }
    uint32_t find(int x, int y, int z) const {
        auto it = arms.find(key(x, y, z));
        return it == arms.end() ? 0 : it->second;
    }
};

// Set while one block is meshed; nullptr when it holds no branch.
extern thread_local const BranchSnapshot *g_goanna_branch_block;

struct RodVertex {
    float pos[3];    // node local, the node centre at 0, one node = 1
    float normal[3];
    float uv[2];     // texture units, one tile = 1 node
};

struct RodMesh {
    std::vector<RodVertex> vertices;
    std::vector<uint16_t> indices; // triangles, outward faces wound as a node box's
};

// Sides of each rod and of the joint ball's rings.
constexpr int kRodSides = 8;

// The rods for `arms` at `radius` (node units). `capped` names the arms whose
// far end is open to view and gets a flat cap; the rest meet a neighbour's
// rod or a solid face. The ball is left out when two arms are opposite, since
// their rods already hold all of it.
RodMesh branchRodMesh(uint32_t arms, float radius, uint32_t capped);

} // namespace goanna
