// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_light.h"

#include "goanna_session.h"
#include "light.h"
#include "mapblock.h"
#include "nodedef.h"
#include "client/node_visuals.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace goanna {

// ---------------------------------------------------------------------------

const BlockLightField::Cell &BlockLightField::at(int x, int y, int z) const {
    static const Cell kOutside; // day 255, night 0, unknown: open and lit
    if (x < 0 || y < 0 || z < 0 || x >= m_side || y >= m_side || z >= m_side)
        return kOutside;
    return m_cells[((size_t)z * m_side + y) * m_side + x];
}

bool BlockLightField::build(GoannaSession &session, v3s16 bp) {
    const NodeDefManager *ndef = session.nodeDefs();
    m_valid = false;
    if (!ndef)
        return false;
    m_side = MAP_BLOCKSIZE * 3;
    m_origin = v3s16((bp.X - 1) * MAP_BLOCKSIZE, (bp.Y - 1) * MAP_BLOCKSIZE, (bp.Z - 1) * MAP_BLOCKSIZE);
    m_cells.assign((size_t)m_side * m_side * m_side, Cell());
    m_occ.reset(m_origin, 1, m_side, m_side, m_side);

    bool have_centre = false;
    for (int bz = -1; bz <= 1; ++bz)
        for (int by = -1; by <= 1; ++by)
            for (int bx = -1; bx <= 1; ++bx) {
                MapBlock *b = session.getBlock(bp + v3s16(bx, by, bz));
                if (!b)
                    continue;
                if (!bx && !by && !bz)
                    have_centre = true;
                const int ox = (bx + 1) * MAP_BLOCKSIZE;
                const int oy = (by + 1) * MAP_BLOCKSIZE;
                const int oz = (bz + 1) * MAP_BLOCKSIZE;
                for (int z = 0; z < MAP_BLOCKSIZE; ++z)
                    for (int y = 0; y < MAP_BLOCKSIZE; ++y)
                        for (int x = 0; x < MAP_BLOCKSIZE; ++x) {
                            MapNode n = b->getNodeNoCheck(x, y, z);
                            content_t c = n.getContent();
                            if (c == CONTENT_IGNORE)
                                continue;
                            const ContentFeatures &f = ndef->get(n);
                            const bool solid = f.visuals && f.visuals->solidness == 2;
                            const bool lit = f.param_type == CPT_LIGHT && !solid;
                            Cell &cell = m_cells[((size_t)(oz + z) * m_side + (oy + y)) * m_side + (ox + x)];
                            cell.flags = kKnown | (solid ? kSolid : 0) | (lit ? kLit : 0);
                            if (lit) {
                                ContentLightingFlags lf = f.getLightingFlags();
                                cell.day = decode_light(n.getLight(LIGHTBANK_DAY, lf));
                                cell.night = decode_light(n.getLight(LIGHTBANK_NIGHT, lf));
                            } else {
                                cell.day = 0;
                                cell.night = 0;
                            }
                            // A glowing node lights its own faces, whether or
                            // not light propagates through it.
                            if (f.light_source > 0)
                                cell.night = std::max<uint8_t>(cell.night, decode_light(f.light_source));
                            if (solid)
                                m_occ.setCell(ox + x, oy + y, oz + z);
                        }
            }
    if (getenv("GOANNA_DEBUG_LIGHT")) {
        // Separates "the map carries no light" from "the sampling is wrong",
        // which look identical from the vertex side.
        long known = 0, lit = 0, day_any = 0, night_any = 0;
        int day_max = 0;
        for (const Cell &c : m_cells) {
            if (!(c.flags & kKnown))
                continue;
            ++known;
            if (c.flags & kLit)
                ++lit;
            if (c.day > 0)
                ++day_any;
            if (c.night > 0)
                ++night_any;
            day_max = std::max(day_max, (int)c.day);
        }
        printf("LIGHTFIELD %d,%d,%d known %ld lit %ld day>0 %ld night>0 %ld daymax %d\n",
                bp.X, bp.Y, bp.Z, known, lit, day_any, night_any, day_max);
        fflush(stdout);
    }
    m_valid = have_centre;
    return m_valid;
}

float BlockLightField::occlusion(const v3f &p, const v3f &n) const {
    if (!m_valid)
        return 1.0f;
    return traceOcclusion(m_occ, p, n, occlusionRadius());
}

VertexLight BlockLightField::sample(const v3f &p, const v3f &n) const {
    VertexLight out;
    if (!m_valid)
        return out;
    v3f nn = n;
    float nl = nn.getLength();
    if (nl > 1e-4f)
        nn /= nl;
    else
        nn = v3f(0, 1, 0);
    // Just off the face, so the 2x2x2 below straddles the air in front of it
    // rather than the solid node behind.
    const v3f base = p + nn * 0.05f;
    const int lx = (int)std::floor(base.X - 0.5f) - m_origin.X;
    const int ly = (int)std::floor(base.Y - 0.5f) - m_origin.Y;
    const int lz = (int)std::floor(base.Z - 0.5f) - m_origin.Z;
    int count = 0, day = 0, night = 0;
    for (int dz = 0; dz < 2; ++dz)
        for (int dy = 0; dy < 2; ++dy)
            for (int dx = 0; dx < 2; ++dx) {
                const Cell &c = at(lx + dx, ly + dy, lz + dz);
                if (!(c.flags & kKnown)) {
                    // Outside what we were sent. Counting it as open sky would
                    // light a cellar through its own wall, so it is skipped.
                    continue;
                }
                if (!(c.flags & kLit))
                    continue;
                day += c.day;
                night += c.night;
                ++count;
            }
    if (count > 0) {
        out.sky = (uint8_t)std::clamp(day / count, 0, 255);
        out.block = (uint8_t)std::clamp(night / count, 0, 255);
    } else {
        // Every neighbour solid: an enclosed face. Take the node's own value,
        // which is what a glowing block's own faces need.
        const Cell &c = at((int)std::floor(base.X) - m_origin.X,
                (int)std::floor(base.Y) - m_origin.Y, (int)std::floor(base.Z) - m_origin.Z);
        out.sky = c.day;
        out.block = c.night;
    }
    out.ao = (uint8_t)std::lround(traceOcclusion(m_occ, p, nn, occlusionRadius()) * 255.0f);
    return out;
}

} // namespace goanna
