// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_light_hue.h"

#include <algorithm>
#include <cmath>

namespace goanna {

void buildLightHue(const HueGrid &grid, const std::vector<HueLight> &lights, std::vector<uint8_t> &rgba) {
    const size_t cells = (size_t)grid.nx * grid.ny * grid.nz;
    std::vector<float> sum(cells * 5, 0.0f);
    for (const HueLight &l : lights) {
        if (l.level <= 0.0f) continue;
        // The cells whose centres lie within the light's reach.
        const float reach = l.level;
        const int x0 = std::max(0, (int)std::floor((l.x - reach - grid.ox) / grid.cell));
        const int x1 = std::min(grid.nx - 1, (int)std::floor((l.x + reach - grid.ox) / grid.cell));
        const int y0 = std::max(0, (int)std::floor((l.y - reach - grid.oy) / grid.cell));
        const int y1 = std::min(grid.ny - 1, (int)std::floor((l.y + reach - grid.oy) / grid.cell));
        const int z0 = std::max(0, (int)std::floor((l.z - reach - grid.oz) / grid.cell));
        const int z1 = std::min(grid.nz - 1, (int)std::floor((l.z + reach - grid.oz) / grid.cell));
        for (int z = z0; z <= z1; ++z)
            for (int y = y0; y <= y1; ++y)
                for (int x = x0; x <= x1; ++x) {
                    const float cx = grid.ox + (x + 0.5f) * grid.cell - l.x;
                    const float cy = grid.oy + (y + 0.5f) * grid.cell - l.y;
                    const float cz = grid.oz + (z + 0.5f) * grid.cell - l.z;
                    const float left = l.level - std::sqrt(cx * cx + cy * cy + cz * cz);
                    if (left <= 0.0f) continue;
                    const float w = left * left;
                    float *s = &sum[(((size_t)z * grid.ny + y) * grid.nx + x) * 5];
                    s[0] += w * l.r;
                    s[1] += w * l.g;
                    s[2] += w * l.b;
                    s[3] += w;
                    if (l.liquid) s[4] = std::max(s[4], left);
                }
    }
    rgba.assign(cells * 4, 0);
    for (size_t i = 0; i < cells; ++i) {
        const float *s = &sum[i * 5];
        uint8_t *o = &rgba[i * 4];
        if (s[3] <= 0.0f) {
            o[0] = o[1] = o[2] = 255;
            o[3] = 0;
            continue;
        }
        const float m = std::max(s[0], std::max(s[1], s[2]));
        for (int c = 0; c < 3; ++c) o[c] = (uint8_t)std::lround(255.0f * (m > 0.0f ? s[c] / m : 1.0f));
        // Full while the nearest liquid still gives 12 of its 14 levels,
        // nothing from 8 down.
        o[3] = (uint8_t)std::lround(255.0f * std::clamp((s[4] - 8.0f) / 4.0f, 0.0f, 1.0f));
    }
}

} // namespace goanna
