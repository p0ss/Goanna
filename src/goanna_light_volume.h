// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Coloured block light by Luanti's own rules, for the light volume around
// the camera (docs/systems/light-volume.md).
//
// Luanti spreads a node's light_source outwards one level per node, through
// nodes whose light_propagates is set, and keeps the brightest arrival in
// each node. floodColouredLight does exactly that for the level, so every
// node gets the light level Luanti gives it, and carries the colour of the
// light that set it along with it. Where two lights arrive at the same
// level their colours are averaged, so the boundary between a red and a
// blue lamp is a blend rather than a seam. A light keeps its hue as it
// dims: spreading the three channels separately instead would leave the
// far fringe of a warm torch pure red, as its weaker green and blue ran out
// first.
//
// Pure data, no Godot or Luanti: the grid is filled by the caller
// (GoannaClient::updateLightVolume) and the result decoded and uploaded
// there.
#pragma once

#include <cstdint>
#include <vector>

namespace goanna {

struct LightVolumeGrid {
    int nx = 0, ny = 0, nz = 0;
    // Per cell, x fastest then y then z: 1 where light passes.
    std::vector<uint8_t> pass;
    // Per cell: the light level it emits, 0 to 14, and its colour (red,
    // green, blue bytes; the brightest channel is usually 255).
    std::vector<uint8_t> emit;
    std::vector<uint8_t> colour;

    void resize(int x, int y, int z) {
        nx = x;
        ny = y;
        nz = z;
        pass.assign((size_t)x * y * z, 0);
        emit.assign((size_t)x * y * z, 0);
        colour.assign((size_t)x * y * z * 3, 0);
    }
    size_t index(int x, int y, int z) const { return ((size_t)z * ny + y) * nx + x; }
};

// Fills `level` (one byte per cell, 0 to 14) with the light level that
// reaches each cell and `colour` (three bytes per cell) with its colour. A
// cell light does not pass then takes its brightest passing neighbour's
// level and colour, so a texture sample that blends across a wall's face
// reads the light in front of it rather than darkness; nothing propagates
// out of such a cell.
void floodColouredLight(const LightVolumeGrid &grid, std::vector<uint8_t> &level, std::vector<uint8_t> &colour);

} // namespace goanna
