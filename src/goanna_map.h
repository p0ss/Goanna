// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Goanna's world container: Luanti's own Map, with sectors created on
// demand as blocks arrive (what ClientMap does, minus the scene node).

#include "map.h"
#include "mapsector.h"

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
};

} // namespace goanna
