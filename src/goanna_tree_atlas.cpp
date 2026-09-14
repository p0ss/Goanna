// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_tree_atlas.h"

#include <algorithm>
#include <cmath>

namespace goanna {

namespace {

// FNV-1a over the shape and its colours. Two oaks grown from the same
// schematic hash the same and share one slot, which is what makes a forest of
// one species cost one slot rather than four hundred.
uint64_t hashVolume(const v3s16 &size, const std::vector<uint32_t> &voxel) {
    uint64_t h = 1469598103934665603ull;
    auto mix = [&h](uint64_t v) {
        for (int i = 0; i < 8; ++i) {
            h ^= (v >> (i * 8)) & 0xff;
            h *= 1099511628211ull;
        }
    };
    mix((uint64_t)size.X);
    mix((uint64_t)size.Y);
    mix((uint64_t)size.Z);
    for (uint32_t v : voxel)
        mix(v);
    return h;
}

} // namespace

uint64_t treePrototypeKey(content_t trunk, content_t leaves, int variant) {
    uint64_t h = 1469598103934665603ull;
    for (uint64_t part : {(uint64_t)trunk, (uint64_t)leaves, (uint64_t)variant})
        for (int i = 0; i < 4; ++i) {
            h ^= (part >> (i * 8)) & 0xff;
            h *= 1099511628211ull;
        }
    // Never zero: add() reads an empty volume as nothing to store, and a key
    // of zero would be indistinguishable from one never set.
    return h ? h : 1;
}

TreeVolume buildTreeVolume(const TreeMask &mask, const TreeColourFn &colour) {
    TreeVolume out;
    out.size = mask.size;
    const size_t n = (size_t)mask.size.X * mask.size.Y * mask.size.Z;
    if (n == 0 || mask.content.size() != n)
        return out;
    out.voxel.assign(n, 0);
    for (size_t i = 0; i < n; ++i) {
        const content_t c = mask.content[i];
        if (c == CONTENT_AIR)
            continue;
        uint32_t rgba = colour ? colour(c) : 0xff00ff00u;
        // A colour that came back transparent would punch a hole in the
        // silhouette, which is the one thing an impostor must get right.
        if ((rgba >> 24) == 0)
            rgba |= 0xff000000u;
        out.voxel[i] = rgba;
    }
    out.key = hashVolume(out.size, out.voxel);
    return out;
}

TreeAtlas::TreeAtlas(v3s16 slot, int columns, int rows)
        : m_slot(slot), m_columns(std::max(1, columns)), m_rows(std::max(1, rows)) {
    m_slot.X = std::max<s16>(1, m_slot.X);
    m_slot.Y = std::max<s16>(1, m_slot.Y);
    m_slot.Z = std::max<s16>(1, m_slot.Z);
    const v3s16 s = size();
    m_voxels.assign((size_t)s.X * s.Y * s.Z, 0);
}

v3s16 TreeAtlas::slotOrigin(int slot) const {
    if (slot < 0 || slot >= capacity())
        return v3s16(0, 0, 0);
    return v3s16((slot % m_columns) * m_slot.X, 0, (slot / m_columns) * m_slot.Z);
}

int TreeAtlas::slotOf(uint64_t key) const {
    auto it = m_by_key.find(key);
    return it == m_by_key.end() ? -1 : it->second;
}

int TreeAtlas::add(const TreeVolume &volume) {
    if (volume.voxel.empty())
        return -1;
    const int existing = slotOf(volume.key);
    if (existing >= 0)
        return existing;
    if ((int)m_slots.size() >= capacity())
        return -1;

    const int slot = (int)m_slots.size();
    m_slots.push_back(volume.key);
    m_by_key.emplace(volume.key, slot);

    const v3s16 at = slotOrigin(slot);
    const v3s16 atlas = size();

    // A volume is resampled to fill its slot, up as well as down, because the
    // instance carries the real height and crown and the shader scales the
    // march to them. The slot is therefore a unit tree, and using all of it is
    // free resolution: leaving a small tree sitting in one corner spent 24 by
    // 40 by 24 voxels to store 7 by 11 by 7 of tree, which measured as 2% of
    // the atlas carrying anything.
    //
    // Nearest neighbour, and any occupied source voxel keeps the target
    // occupied. Averaging loses the thin parts of a crown, and a crown without
    // its thin parts is a lollipop.
    const float sx = (float)volume.size.X / (float)m_slot.X;
    const float sy = (float)volume.size.Y / (float)m_slot.Y;
    const float sz = (float)volume.size.Z / (float)m_slot.Z;

    for (int z = 0; z < m_slot.Z; ++z)
        for (int y = 0; y < m_slot.Y; ++y)
            for (int x = 0; x < m_slot.X; ++x) {
                const int x0 = (int)(x * sx), x1 = std::max(x0 + 1, (int)((x + 1) * sx));
                const int y0 = (int)(y * sy), y1 = std::max(y0 + 1, (int)((y + 1) * sy));
                const int z0 = (int)(z * sz), z1 = std::max(z0 + 1, (int)((z + 1) * sz));
                uint32_t chosen = 0;
                for (int zz = z0; zz < z1 && zz < volume.size.Z && !chosen; ++zz)
                    for (int yy = y0; yy < y1 && yy < volume.size.Y && !chosen; ++yy)
                        for (int xx = x0; xx < x1 && xx < volume.size.X && !chosen; ++xx) {
                            const uint32_t v = volume.voxel[
                                    ((size_t)zz * volume.size.Y + yy) * volume.size.X + xx];
                            if (v >> 24)
                                chosen = v;
                        }
                if (!chosen)
                    continue;
                const size_t di = ((size_t)(at.Z + z) * atlas.Y + (at.Y + y)) * atlas.X +
                        (at.X + x);
                m_voxels[di] = chosen;
            }

    return slot;
}

float TreeAtlas::occupancy() const {
    if (m_voxels.empty())
        return 0.0f;
    size_t filled = 0;
    for (uint32_t v : m_voxels)
        if (v >> 24)
            ++filled;
    return (float)filled / (float)m_voxels.size();
}

} // namespace goanna
