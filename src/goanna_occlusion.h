// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Voxel occupancy and the ambient occlusion trace over it.
//
// Deliberately free of any dependency on the session, Godot or Luanti's map:
// it is grid arithmetic, so it can be tested offline against a dense reference
// integral (goanna_light_test.cpp) and reused unchanged by the far tiers,
// which trace the same shapes against a coarser field. See
// docs/far-rendering.md, "Baked ambient occlusion", and docs/mesh-attributes.md.

#include <cstdint>
#include <vector>

#include "irrlichttypes_bloated.h"

namespace goanna {

// A bitfield of "this cell blocks light", over a cuboid of cells. Cell size 1
// is the node grid; larger cells are the coarse chain the far tiers use.
struct OccupancyField {
    v3s16 origin;   // node coordinates of the low corner of cell (0,0,0)
    int cell = 1;   // nodes per cell along each axis
    int nx = 0, ny = 0, nz = 0;
    std::vector<uint64_t> bits;

    void reset(v3s16 origin_nodes, int cell_nodes, int cells_x, int cells_y, int cells_z);
    inline size_t index(int x, int y, int z) const {
        return ((size_t)z * ny + y) * nx + x;
    }
    inline void setCell(int x, int y, int z) {
        size_t i = index(x, y, z);
        bits[i >> 6] |= (uint64_t)1 << (i & 63);
    }
    inline bool cellSolid(int x, int y, int z) const {
        if (x < 0 || y < 0 || z < 0 || x >= nx || y >= ny || z >= nz)
            return false; // outside the field is unknown, and unknown is open
        size_t i = index(x, y, z);
        return (bits[i >> 6] >> (i & 63)) & 1;
    }
    // p is in node coordinates, and need not be integral.
    bool solidAt(float x, float y, float z) const;
};

// How much of the hemisphere above `p`, facing `n`, is blocked. 1.0 is fully
// open. Node coordinates, and `n` need not be normalised. `radius` is in
// nodes, so a coarse field traces further for the same number of steps.
float traceOcclusion(const OccupancyField &f, const v3f &p, const v3f &n, float radius);


// Tracing budget, shared by every field. Twelve rays over six nodes tells a
// pit from a plain and is cheap enough to run while meshing; the numbers are
// variable so lighting_chart.tscn can sweep them against the reference.
void setOcclusionQuality(int rays, int steps, float radius);
int occlusionRays();
int occlusionSteps();
float occlusionRadius();

} // namespace goanna
