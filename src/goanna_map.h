// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Goanna's world container: Luanti's own Map, with sectors created on
// demand as blocks arrive (what ClientMap does, minus the scene node).

#include "map.h"
#include "mapsector.h"

#include <algorithm>
#include <utility>
#include <vector>

namespace goanna {

class GoannaMap final : public Map {
public:
    explicit GoannaMap(IGameDef *gamedef) : Map(gamedef) {}

    MapSector *emergeSector(v2s16 p) override {
        MapSector *sector = getSectorNoGenerate(p);
        if (sector)
            return sector;
        sector = new MapSector(this, p, m_gamedef);
        m_sectors[p] = sector;
        return sector;
    }

    // How many mapblocks are resident. Unbounded residency is what makes a
    // long session grow without limit, so the session prunes against this.
    size_t residentBlocks() const {
        size_t n = 0;
        for (const auto &kv : m_sectors) {
            const MapSector *sec = kv.second;
            n += sec->getBlocks().size();
        }
        return n;
    }

    // Blocks further than `radius` mapblocks from `centre`, furthest first.
    std::vector<v3s16> blocksBeyond(v3s16 centre, int radius) const {
        std::vector<std::pair<int, v3s16>> far;
        for (const auto &kv : m_sectors) {
            const MapSector *sec = kv.second;
            for (const auto &bkv : sec->getBlocks()) {
                v3s16 bp(kv.first.X, bkv.first, kv.first.Y);
                v3s16 d = bp - centre;
                int dist2 = d.X * d.X + d.Y * d.Y + d.Z * d.Z;
                if (dist2 > radius * radius)
                    far.emplace_back(dist2, bp);
            }
        }
        std::sort(far.begin(), far.end(),
                [](const auto &a, const auto &b) { return a.first > b.first; });
        std::vector<v3s16> out;
        out.reserve(far.size());
        for (auto &f : far)
            out.push_back(f.second);
        return out;
    }

    void dropBlock(v3s16 bp) {
        MapSector *sector = getSectorNoGenerate(v2s16(bp.X, bp.Z));
        if (!sector)
            return;
        if (MapBlock *b = sector->getBlockNoCreateNoEx(bp.Y))
            sector->deleteBlock(b);
    }
};

} // namespace goanna
