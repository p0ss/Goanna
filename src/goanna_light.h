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
// docs/systems/mesh-attributes.md is the contract this fills. The occupancy field and
// the cone tracer below are deliberately parameterised on cell size, because
// the far tiers in docs/systems/far-rendering.md trace the same shapes against a
// coarser field and there should be one tracer, not two.
//
// Threads: BlockLightField::build reads the map, so it runs on the main
// thread under the session's mapLock() (GoannaClient::nearSubmit, and
// EntityRenderer for a wall plate's light). The finished field is a plain copy
// with no tie to the map, so a NearBlockJob carries it to a mesh worker and
// samples it there. Main types: VertexLight, BlockLightField.

#include <algorithm>
#include <cstdint>
#include <vector>

#include "goanna_occlusion.h"
#include "light.h"
#include "irrlichttypes_bloated.h"

class MapBlock;
class NodeDefManager;

namespace goanna {

class GoannaSession;

// What one vertex carries, before it is packed into CUSTOM0.
struct VertexLight {
    uint8_t block = 255; // torches, lava: Luanti's night bank
    uint8_t sky = 255;   // daylight reaching here: Luanti's day bank
    uint8_t ao = 255;    // combined traced and corner occlusion, for native materials
    uint8_t corner = 255; // corner occlusion alone, for imported shader packs
    uint8_t pack_block = 255, pack_sky = 255; // linear pack coordinates, scaled to 0..255
};

// Map raw Luanti levels to linear block/sky coordinates. When daytime
// light equals block light, the protocol cannot distinguish hidden skylight
// from lamp light; use zero sky conservatively. Native lighting is unchanged.
inline v2f shaderPackLight(float block, float day) {
    block = std::clamp(block, 0.0f, (float)LIGHT_SUN);
    day = std::clamp(day, 0.0f, (float)LIGHT_SUN);
    return v2f(block / LIGHT_SUN, day > block + 0.001f ? day / LIGHT_SUN : 0.0f);
}
// Inverse of the immutable Luanti decode table, for stored coarse brightness.
// Quantised or averaged brightness yields an approximation to a raw level.
inline float lightLevelFromBrightness(uint8_t brightness) {
    if (brightness == 0) return 0.0f;
    for (int level = 1; level <= LIGHT_SUN; ++level) {
        const int hi = decode_light(level), lo = decode_light(level - 1);
        if (brightness <= hi && hi > lo)
            return level - 1 + (brightness - lo) / (float)(hi - lo);
    }
    return (float)LIGHT_SUN;
}

// The light and occupancy of one mapblock's 3x3x3 neighbourhood, built once
// per meshing pass and then sampled per vertex. Positions passed in are Luanti
// node coordinates, absolute, not Godot space: the caller mirrors z.
// build() needs the map lock; once built the field is independent of the
// map and may be moved to, and sampled on, any one thread.
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
        uint8_t day_level = 15, night_level = 0;
    };
    enum : uint8_t { kLit = 1, kSolid = 2, kKnown = 4, kPackShade = 8 };
    const Cell &at(int x, int y, int z) const;
    Cell cellAtNode(const v3f &p) const;

    OccupancyField m_occ;
    std::vector<Cell> m_cells;
    v3s16 m_origin{0, 0, 0};
    int m_side = 0;
    bool m_valid = false;
};

} // namespace goanna
