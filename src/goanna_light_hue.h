// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The colour of block light, for the baked block light the node meshes
// already carry (docs/systems/light-colour.md).
//
// A mesh's block light is Luanti's own level at the vertex: right in
// brightness and occlusion, but white. buildLightHue gives it a colour: a
// coarse grid of cells round the camera, each holding the colour of the
// lights within reach of it, every light weighted by the square of the
// light it would still give there (its level less the distance, as
// Luanti's light falls off), so the nearest and brightest light decides
// and two equal lights blend. Cells no light reaches are white, which
// leaves the baked light as it was. Brightness stays the mesh's, so the
// grid ignores walls: only the colour of light a wall already lets through
// can come from beyond it.
//
// Each cell also records how near it is to a glowing liquid. The lamp pool
// stands a few point lamps over a lava pool, and a point lamp lights a flat
// bank level with it at a grazing angle, which is barely at all; the
// shaders use the baked light, Luanti's own level, in full beside the
// liquid. It is measured from the nearest liquid cell alone, so a wide
// pool's many cells do not reach further than one.
//
// Pure data, no Godot or Luanti: the caller (GoannaClient::updateLightHue)
// collects the lights and uploads the grid.
#pragma once

#include <cstdint>
#include <vector>

namespace goanna {

struct HueLight {
    float x, y, z; // world position, nodes
    float level;   // light_source, 0 to 14
    float r, g, b; // colour, brightest channel 1
    bool liquid = false;
};

struct HueGrid {
    float ox = 0, oy = 0, oz = 0; // world position of cell (0, 0, 0)'s low corner
    float cell = 4.0f;            // nodes per cell
    int nx = 0, ny = 0, nz = 0;
};

// Fills `rgba` (four bytes per cell, x fastest then y then z) with each
// cell's light colour, its brightest channel 255 (white where no light
// reaches), and in alpha how near the nearest glowing liquid is: 255 within
// two nodes, falling to 0 six nodes out (for a level 14 liquid; a dimmer
// one reaches less far).
void buildLightHue(const HueGrid &grid, const std::vector<HueLight> &lights, std::vector<uint8_t> &rgba);

} // namespace goanna
