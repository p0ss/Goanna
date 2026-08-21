// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Per vertex light and ambient occlusion, sampled from map data by Goanna's
// own code rather than by Luanti's mesher.
//
// Luanti bakes light into the vertex colour and then multiplies the tile tint
// into the same channel. Goanna cannot use that, because Godot lights the
// world: multiplying baked light into albedo and then lighting the result
// applies it twice. So g_goanna_no_light stays set, the vertex colour keeps
// the tint alone, and the light values are read here from the same nodes
// Luanti would have read, into their own vertex attribute.
//
// docs/mesh-attributes.md is the contract this fills. The occupancy field and
// the cone tracer below are deliberately parameterised on cell size, because
// the far tiers in docs/far-rendering.md trace the same shapes against a
// coarser field and there should be one tracer, not two.

#include <cstdint>
#include <vector>

#include "goanna_occlusion.h"
#include "irrlichttypes_bloated.h"

class MapBlock;
class NodeDefManager;

namespace goanna {

class GoannaSession;

// What one vertex carries, before it is packed into CUSTOM0.
struct VertexLight {
    uint8_t block = 255; // torches, lava: Luanti's night bank
    uint8_t sky = 255;   // daylight reaching here: Luanti's day bank
    uint8_t ao = 255;    // 255 is unoccluded
};

// The light and occupancy of one mapblock's 3x3x3 neighbourhood, built once
// per meshing pass and then sampled per vertex. Positions passed in are Luanti
// node coordinates, absolute, not Godot space: the caller mirrors z.
class BlockLightField {
public:
    // Caller holds session.mapLock(). Returns false if the centre block is
    // missing, in which case sample() still works and returns neutral values.
    bool build(GoannaSession &session, v3s16 bp);

    // `p` is the vertex, `n` its normal, both in Luanti node coordinates.
    VertexLight sample(const v3f &p, const v3f &n) const;

    // Occlusion alone, for callers that have no light to gather (the LOD
    // tiers, which take light per cell instead).
    float occlusion(const v3f &p, const v3f &n) const;

    const OccupancyField &occupancy() const { return m_occ; }
    bool valid() const { return m_valid; }

private:
    // Light and flags per node in the neighbourhood, indexed like m_occ.
    struct Cell {
        uint8_t day = 255, night = 0, flags = 0;
    };
    enum : uint8_t { kLit = 1, kSolid = 2, kKnown = 4 };
    const Cell &at(int x, int y, int z) const;
    Cell cellAtNode(const v3f &p) const;

    OccupancyField m_occ;
    std::vector<Cell> m_cells;
    v3s16 m_origin{0, 0, 0};
    int m_side = 0;
    bool m_valid = false;
};

} // namespace goanna
