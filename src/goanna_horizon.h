// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// The horizon bake: a cylindrical panorama of the terrain the client knows
// about beyond the drawn far field, built from the LOD chains' coarsest
// level on the CPU and composited by the sky shader as the false horizon
// (docs/sky-orchestration.md, "The fog wall"). The bake carries albedo and
// distance, not light: the sky shader relights it every frame from the
// same beam and air authorities the live terrain uses, so the panorama
// rides through dawn, dusk and biome fades without being re-rendered.
//
// The snapshot is extracted on the main thread (the chains are main-thread
// state) with every colour already resolved, so the worker that marches
// the rays touches nothing but its own copy.

#pragma once

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace goanna {

struct HorizonSnapshot {
    // One entry per block column that holds any filled terrain: the top
    // surface's node Y and its resolved tile colour (0xRRGGBB).
    struct Column {
        int16_t top_y = -32768;
        uint32_t colour = 0;
    };
    // Key: (block X + 32768) << 16 | (block Z + 32768), Luanti block space.
    std::unordered_map<uint32_t, Column> columns;
    // Bake origin in Luanti node space (X, Y, Z with Luanti's Z sign).
    float origin_x = 0.0f, origin_y = 0.0f, origin_z = 0.0f;
    float r0 = 256.0f; // where the march starts: about the drawn edge
    float r1 = 4096.0f; // where it gives up
    int width = 1024;  // azimuth columns
    int height = 192;  // elevation rows
    // The vertical window, in sin(elevation) units like sun_direction.y.
    float y_min = -0.08f;
    float y_max = 0.35f;

    static uint32_t key(int bx, int bz) {
        return ((uint32_t)(bx + 32768) << 16) | (uint32_t)(bz + 32768);
    }
};

struct HorizonResult {
    int width = 0, height = 0;
    // RGBA8, row-major, V=0 at y_min. Alpha 255 where terrain covers the
    // direction, 0 where the sky shows through.
    std::vector<uint8_t> albedo;
    // One float per pixel: horizontal distance to the surface, in nodes,
    // 0 where uncovered.
    std::vector<float> distance;
    float origin_x = 0.0f, origin_y = 0.0f, origin_z = 0.0f;
    float r0 = 0.0f, r1 = 0.0f;
    float y_min = 0.0f, y_max = 0.0f;
};

// March the snapshot into a panorama. Pure function of its input; safe on
// any thread.
HorizonResult buildHorizonPanorama(const HorizonSnapshot &snap);

} // namespace goanna
