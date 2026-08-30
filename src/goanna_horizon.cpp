// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_horizon.h"

#include <algorithm>
#include <cmath>

namespace goanna {

namespace {

// The far field is known to leak floating stale boxes (a block or two,
// nowhere near the ground), and a snapshot column made from one paints a
// tall pale slab across the sky when the march treats it as a spire. A
// column with no neighbouring column at all is such a leak, or the very
// corner of the frontier, and is dropped; one that stands far above every
// neighbour it has is clamped to the tallest of them plus a grace. A real
// mesa is wide, so its interior columns keep each other tall.
std::unordered_map<uint32_t, HorizonSnapshot::Column> despiked(
        const std::unordered_map<uint32_t, HorizonSnapshot::Column> &in) {
    constexpr int kGrace = 48;
    std::unordered_map<uint32_t, HorizonSnapshot::Column> out;
    out.reserve(in.size());
    for (const auto &kv : in) {
        const int bx = (int)(kv.first >> 16) - 32768;
        const int bz = (int)(kv.first & 0xffff) - 32768;
        int best = -32768;
        int neighbours = 0;
        const int nx[4] = {1, -1, 0, 0};
        const int nz[4] = {0, 0, 1, -1};
        for (int i = 0; i < 4; ++i) {
            auto it = in.find(HorizonSnapshot::key(bx + nx[i], bz + nz[i]));
            if (it == in.end())
                continue;
            ++neighbours;
            best = std::max(best, (int)it->second.top_y);
        }
        if (neighbours == 0)
            continue;
        HorizonSnapshot::Column c = kv.second;
        if ((int)c.top_y > best + kGrace)
            c.top_y = (int16_t)(best + kGrace);
        out.emplace(kv.first, c);
    }
    return out;
}

} // namespace

HorizonResult buildHorizonPanorama(const HorizonSnapshot &snap) {
    HorizonResult out;
    out.width = snap.width;
    out.height = snap.height;
    out.albedo.assign((size_t)snap.width * snap.height * 4, 0);
    out.distance.assign((size_t)snap.width * snap.height, 0.0f);
    out.origin_x = snap.origin_x;
    out.origin_y = snap.origin_y;
    out.origin_z = snap.origin_z;
    out.r0 = snap.r0;
    out.r1 = snap.r1;
    out.y_min = snap.y_min;
    out.y_max = snap.y_max;
    const auto columns = despiked(snap.columns);
    const float tau = 6.28318530718f;
    const float span = snap.y_max - snap.y_min;
    for (int i = 0; i < snap.width; ++i) {
        // Column i is centred on u = (i + 0.5) / width; the shader samples
        // u = fract(atan(dir.x, -dir.z) / tau), so theta 0 faces Godot -Z.
        const float theta = ((float)i + 0.5f) / (float)snap.width * tau;
        const float dxn = std::sin(theta);        // Luanti X
        const float dzn = std::cos(theta);        // Luanti Z (Godot -Z)
        float max_sin = -1.0f;
        // Walk outward; a nearer surface can only be occluded by painting
        // strictly above the running silhouette, which is the whole of the
        // hidden-surface problem for a heightfield seen from one point.
        float r = snap.r0;
        int last_bx = INT32_MIN, last_bz = INT32_MIN;
        while (r < snap.r1 && max_sin < snap.y_max) {
            const float lx = snap.origin_x + dxn * r;
            const float lz = snap.origin_z + dzn * r;
            const int bx = (int)std::floor(lx / 16.0f);
            const int bz = (int)std::floor(lz / 16.0f);
            // The radial step tracks the angular footprint of one pixel
            // column, so near terrain is sampled finely and the far edge
            // coarsely, but never finer than one visit per block column.
            const float dr = std::clamp(r / 64.0f, 8.0f, 48.0f);
            r += dr;
            if (bx == last_bx && bz == last_bz)
                continue;
            last_bx = bx;
            last_bz = bz;
            auto it = columns.find(HorizonSnapshot::key(bx, bz));
            if (it == columns.end())
                continue;
            const float top = (float)it->second.top_y + 1.0f;
            const float dy = top - snap.origin_y;
            const float s = dy / std::sqrt(r * r + dy * dy);
            if (s <= max_sin)
                continue;
            const float lo = std::max(max_sin, snap.y_min);
            const float hi = std::min(s, snap.y_max);
            max_sin = s;
            if (hi <= lo)
                continue;
            int row0 = (int)std::floor((lo - snap.y_min) / span * (float)snap.height);
            int row1 = (int)std::ceil((hi - snap.y_min) / span * (float)snap.height);
            row0 = std::clamp(row0, 0, snap.height - 1);
            row1 = std::clamp(row1, row0 + 1, snap.height);
            const uint32_t c = it->second.colour;
            for (int row = row0; row < row1; ++row) {
                const size_t px = ((size_t)row * snap.width + i);
                uint8_t *a = &out.albedo[px * 4];
                a[0] = (uint8_t)((c >> 16) & 0xff);
                a[1] = (uint8_t)((c >> 8) & 0xff);
                a[2] = (uint8_t)(c & 0xff);
                a[3] = 255;
                out.distance[px] = r;
            }
        }
    }
    return out;
}

} // namespace goanna
