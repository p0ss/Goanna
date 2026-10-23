// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_light_volume.h"

#include <algorithm>

namespace goanna {

void floodColouredLight(const LightVolumeGrid &grid, std::vector<uint8_t> &level, std::vector<uint8_t> &colour) {
    const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
    const size_t cells = (size_t)nx * ny * nz;
    level.assign(cells, 0);
    // Colours are carried as floats so repeated averaging does not round
    // towards black.
    std::vector<float> rgb(cells * 3, 0.0f);
    const int64_t step[6] = {1, -1, nx, -nx, (int64_t)nx * ny, -(int64_t)nx * ny};
    // One bucket per level. A cell is queued at the level it reached; a
    // later, brighter arrival queues it again and the stale entry is skipped
    // when its level no longer matches.
    std::vector<uint32_t> bucket[15];
    // How many arrivals at its current level a cell's colour averages.
    std::vector<uint8_t> arrivals(cells, 0);
    for (size_t i = 0; i < cells; ++i) {
        const uint8_t e = std::min<uint8_t>(grid.emit[i], 14);
        if (e == 0) continue;
        level[i] = e;
        arrivals[i] = 1;
        for (int c = 0; c < 3; ++c) rgb[i * 3 + c] = grid.colour[i * 3 + c];
        if (e > 1) bucket[e].push_back((uint32_t)i);
    }
    for (int l = 14; l >= 2; --l) {
        // The bucket grows while it is walked only for l - 1, never l.
        for (size_t k = 0; k < bucket[l].size(); ++k) {
            const uint32_t i = bucket[l][k];
            if (level[i] != l) continue;
            const int x = (int)(i % nx), y = (int)((i / nx) % ny), z = (int)(i / ((size_t)nx * ny));
            const bool inside[6] = {x + 1 < nx, x > 0, y + 1 < ny, y > 0, z + 1 < nz, z > 0};
            for (int d = 0; d < 6; ++d) {
                if (!inside[d]) continue;
                const size_t n = (size_t)((int64_t)i + step[d]);
                if (!grid.pass[n]) continue;
                if (level[n] < l - 1) {
                    level[n] = (uint8_t)(l - 1);
                    arrivals[n] = 1;
                    for (int c = 0; c < 3; ++c) rgb[n * 3 + c] = rgb[(size_t)i * 3 + c];
                    bucket[l - 1].push_back((uint32_t)n);
                } else if (level[n] == l - 1 && arrivals[n] < 255) {
                    // Another arrival at the same level: a running average.
                    const float w = 1.0f / (float)(++arrivals[n]);
                    for (int c = 0; c < 3; ++c)
                        rgb[n * 3 + c] += (rgb[(size_t)i * 3 + c] - rgb[n * 3 + c]) * w;
                }
            }
        }
    }
    // Solid cells read their brightest passing neighbour. Done after the
    // flood so it does not carry light through a wall.
    std::vector<uint8_t> solid_level(level);
    std::vector<float> solid_rgb(rgb);
    for (int z = 0; z < nz; ++z)
        for (int y = 0; y < ny; ++y)
            for (int x = 0; x < nx; ++x) {
                const size_t i = grid.index(x, y, z);
                if (grid.pass[i]) continue;
                const bool inside[6] = {x + 1 < nx, x > 0, y + 1 < ny, y > 0, z + 1 < nz, z > 0};
                for (int d = 0; d < 6; ++d) {
                    if (!inside[d]) continue;
                    const size_t n = (size_t)((int64_t)i + step[d]);
                    if (!grid.pass[n] || level[n] <= solid_level[i]) continue;
                    solid_level[i] = level[n];
                    for (int c = 0; c < 3; ++c) solid_rgb[i * 3 + c] = rgb[n * 3 + c];
                }
            }
    level.swap(solid_level);
    colour.resize(cells * 3);
    for (size_t k = 0; k < cells * 3; ++k)
        colour[k] = (uint8_t)std::clamp((int)(solid_rgb[k] + 0.5f), 0, 255);
}

} // namespace goanna
