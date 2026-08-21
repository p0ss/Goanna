// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_lod.h"

#include "goanna_materials.h"
#include "goanna_occlusion.h"
#include "goanna_textures.h"
#include "light.h"
#include "mapblock.h"
#include "nodedef.h"
#include "client/node_visuals.h"

#include <algorithm>
#include <cmath>
#include <unordered_map>

namespace goanna {

// Luanti's tile order, which is also the face order here: +Y, -Y, +X, -X,
// +Z, -Z. Luanti coordinates; the z mirror happens when a vertex is emitted.
static const int DIRS[6][3] = {{0, 1, 0}, {0, -1, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}};

int BlockLodChain::levelForCell(int cell) {
    switch (cell) {
    case 2: return 0;
    case 4: return 1;
    case 8: return 2;
    case 16: return 3;
    default: return -1;
    }
}

// ---------------------------------------------------------------------------
// The chain

namespace {

struct NodeInfo {
    content_t c = CONTENT_AIR;
    uint8_t p2 = 0, day = 0, night = 0, flags = 0;
};
enum : uint8_t { nSolid = 1, nFilled = 2, nLit = 4, nKnown = 8 };

struct ContentClass {
    uint8_t flags = 0;
    uint8_t glow = 0; // decoded light_source
    ContentLightingFlags lf;
};

} // namespace

void buildLodChain(const NodeDefManager *ndef, MapBlock *block, BlockLodChain &out, int min_level) {
    const int N = MAP_BLOCKSIZE;
    for (LodLevel &lv : out.level)
        lv = LodLevel();
    if (!ndef || !block)
        return;
    min_level = std::clamp(min_level, 0, BlockLodChain::kLevels - 1);

    // One pass over the nodes, classifying each once per content id.
    std::vector<NodeInfo> info((size_t)N * N * N);
    std::unordered_map<content_t, ContentClass> classes;
    auto classify = [&](content_t c) -> const ContentClass & {
        auto it = classes.find(c);
        if (it != classes.end())
            return it->second;
        const ContentFeatures &f = ndef->get(c);
        ContentClass cc;
        const bool solid = f.visuals && f.visuals->solidness == 2;
        // Filled is what draws: a full solid node, anything that looks like a
        // cube (leaves, glass, allfaces: solidness 0, visual_solidness 1, the
        // way node_visuals.cpp classes them) and a liquid, so the sea is a
        // surface and not a hole. Leaves matter more than anything: a forest
        // at range is its canopy, and without them a jungle meshed as the log
        // tops the trunks were standing on. Only solid blocks light, the same
        // rule as the near field in goanna_light.cpp.
        const bool filled = solid || (f.visuals && f.visuals->visual_solidness >= 1) || f.isLiquid();
        const bool lit = f.param_type == CPT_LIGHT && !solid;
        cc.flags = nKnown | (solid ? nSolid : 0) | (filled ? nFilled : 0) | (lit ? nLit : 0);
        cc.glow = f.light_source > 0 ? decode_light(f.light_source) : 0;
        cc.lf = f.getLightingFlags();
        return classes.emplace(c, cc).first->second;
    };
    for (int z = 0; z < N; ++z)
        for (int y = 0; y < N; ++y)
            for (int x = 0; x < N; ++x) {
                MapNode n = block->getNodeNoCheck(x, y, z);
                NodeInfo &ni = info[((size_t)z * N + y) * N + x];
                ni.c = n.getContent();
                ni.p2 = n.getParam2();
                if (ni.c == CONTENT_IGNORE)
                    continue;
                const ContentClass &cc = classify(ni.c);
                ni.flags = cc.flags;
                if (cc.flags & nLit) {
                    ni.day = decode_light(n.getLight(LIGHTBANK_DAY, cc.lf));
                    ni.night = decode_light(n.getLight(LIGHTBANK_NIGHT, cc.lf));
                }
                if (cc.glow)
                    ni.night = std::max(ni.night, cc.glow);
            }

    for (int l = min_level; l < BlockLodChain::kLevels; ++l) {
        LodLevel &lv = out.level[l];
        lv.cell = BlockLodChain::cellForLevel(l);
        lv.n = N / lv.cell;
        const int cell = lv.cell, n = lv.n;
        lv.cells.assign((size_t)n * n * n, LodLevel::Cell());
        // A cell draws as a full cube, so what counts as filled decides how
        // the world simplifies. Any node at all is wrong: a single leaf turns
        // a 16 node cell into a cliff, and a jungle canopy at the coarsest
        // tier became a wall of cubes in the first run. Half a layer's worth
        // keeps a floor and a canopy and a 2 by 2 trunk, and drops a post
        // and a stray branch, which is roughly what a tree is at that range.
        // Blocking light takes a full layer, so a one node floor occludes and
        // a lone post does not. docs/far-rendering.md says to calibrate both
        // on the chart before trusting the look; these are the knobs.
        const int fill_at = std::max(1, cell * cell / 2);
        const int occlude_at = cell * cell;
        struct Tally {
            content_t c;
            uint8_t p2;
            int count;
        };
        Tally tally[16];
        for (int cz = 0; cz < n; ++cz)
            for (int cy = 0; cy < n; ++cy)
                for (int cx = 0; cx < n; ++cx) {
                    LodLevel::Cell &out_cell = lv.cells[((size_t)cz * n + cy) * n + cx];
                    int solid = 0, filled = 0, lit = 0, known = 0;
                    long day = 0, night = 0;
                    const int x0 = cx * cell, y0 = cy * cell, z0 = cz * cell;
                    for (int z = z0; z < z0 + cell; ++z)
                        for (int y = y0; y < y0 + cell; ++y)
                            for (int x = x0; x < x0 + cell; ++x) {
                                const NodeInfo &ni = info[((size_t)z * N + y) * N + x];
                                if (!(ni.flags & nKnown))
                                    continue;
                                ++known;
                                if (ni.flags & nSolid)
                                    ++solid;
                                if (ni.flags & nFilled)
                                    ++filled;
                                if (ni.flags & nLit) {
                                    ++lit;
                                    day += ni.day;
                                    night += ni.night;
                                }
                            }
                    if (!known)
                        continue;
                    const bool is_filled = filled >= fill_at;
                    out_cell.flags = LodLevel::kKnown | (is_filled ? LodLevel::kFilled : 0) |
                            (solid >= occlude_at ? LodLevel::kOccludes : 0) | (lit ? LodLevel::kLit : 0);
                    if (lit) {
                        out_cell.day = (uint8_t)(day / lit);
                        out_cell.night = (uint8_t)(night / lit);
                    }
                    if (!is_filled)
                        continue;
                    // What each side sees: the first filled node down every
                    // column, by majority. Grass on top of a hill, dirt on
                    // its cut side, stone deeper, as the near mesh shows it.
                    for (int d = 0; d < 6; ++d) {
                        const int axis = DIRS[d][0] ? 0 : (DIRS[d][1] ? 1 : 2);
                        const int sign = DIRS[d][0] + DIRS[d][1] + DIRS[d][2];
                        int ntally = 0;
                        for (int i = 0; i < cell; ++i)
                            for (int j = 0; j < cell; ++j)
                                for (int k = 0; k < cell; ++k) {
                                    // k runs from the outer face inward
                                    const int along = sign > 0 ? cell - 1 - k : k;
                                    int x, y, z;
                                    if (axis == 0) { x = x0 + along; y = y0 + i; z = z0 + j; }
                                    else if (axis == 1) { x = x0 + i; y = y0 + along; z = z0 + j; }
                                    else { x = x0 + i; y = y0 + j; z = z0 + along; }
                                    const NodeInfo &ni = info[((size_t)z * N + y) * N + x];
                                    if (!(ni.flags & nFilled))
                                        continue;
                                    int t = 0;
                                    for (; t < ntally; ++t)
                                        if (tally[t].c == ni.c && tally[t].p2 == ni.p2) {
                                            ++tally[t].count;
                                            break;
                                        }
                                    if (t == ntally && ntally < 16)
                                        tally[ntally++] = Tally{ni.c, ni.p2, 1};
                                    break;
                                }
                        int best = -1;
                        for (int t = 0; t < ntally; ++t)
                            if (best < 0 || tally[t].count > tally[best].count)
                                best = t;
                        if (best >= 0) {
                            out_cell.face[d] = tally[best].c;
                            out_cell.param2[d] = tally[best].p2;
                        }
                    }
                }
    }
}

// ---------------------------------------------------------------------------
// The region mesher

namespace {

// The tile behind (content, side), resolved once.
const LodTileCache::Entry &tileFor(LodTileCache &cache, const NodeDefManager *ndef,
        GoannaTextureSource *tsrc, const MaterialTable *materials, content_t c, int side) {
    const u32 key = (u32)c * 6 + side;
    auto it = cache.entries.find(key);
    if (it != cache.entries.end())
        return it->second;
    LodTileCache::Entry e;
    if (materials)
        e.block_id = materials->blockOf(c);
    const ContentFeatures &f = ndef->get(c);
    if (f.visuals && tsrc) {
        const TileLayer &l = f.visuals->tiles[side].layers[0];
        e.tile_has_color = l.has_color;
        e.tint = l.has_color ? (l.color.color | 0xff000000) : 0xffffffff;
        std::string name;
        if (l.texture_id) {
            GoannaTexture *gt = tsrc->goannaTexture(l.texture_id);
            if (gt && gt->isArray()) {
                e.texture_id = l.texture_id;
                e.layer = l.texture_layer_idx;
                const auto &names = gt->layerNames();
                if (l.texture_layer_idx < names.size())
                    name = names[l.texture_layer_idx];
            } else if (gt) {
                name = tsrc->getTextureName(l.texture_id);
            }
        }
        if (!name.empty()) {
            video::SColor avg = tsrc->getTextureAverageColor(name);
            e.fallback = avg.color | 0xff000000;
        }
    }
    return cache.entries.emplace(key, e).first->second;
}

inline u32 mulColour(u32 a, u32 b) {
    const u32 r = ((a >> 16) & 0xff) * ((b >> 16) & 0xff) / 255;
    const u32 g = ((a >> 8) & 0xff) * ((b >> 8) & 0xff) / 255;
    const u32 bl = (a & 0xff) * (b & 0xff) / 255;
    return 0xff000000 | (r << 16) | (g << 8) | bl;
}

// What one cell face is, for merging: two faces merge only when every field
// agrees. Light and occlusion are quantised to sixteen levels first, so a
// plain stays a few quads while a valley still breaks where it darkens.
struct FaceKey {
    u32 texture_id = 0;
    u16 layer = 0;
    u16 block_id = 0;
    u32 colour = 0; // tint, or the fallback colour
    uint8_t day = 255, night = 0, ao = 255;
    // CUSTOM0.a: 255 for a live block, lower for one drawn from the store,
    // which the shader marks as stale.
    uint8_t fresh = 255;
    bool valid = false;
    bool operator==(const FaceKey &o) const {
        return texture_id == o.texture_id && layer == o.layer && block_id == o.block_id && colour == o.colour &&
                day == o.day && night == o.night && ao == o.ao && fresh == o.fresh;
    }
};

inline uint8_t quant16(int v) {
    int q = (v * 15 + 127) / 255;
    return (uint8_t)(q * 17);
}

} // namespace

LodRegionMesh meshLodRegion(const LodRegionSpec &spec, const NodeDefManager *ndef,
        GoannaTextureSource *tsrc, const MaterialTable *materials, LodTileCache &tiles) {
    LodRegionMesh out;
    const int level = BlockLodChain::levelForCell(spec.cell);
    if (level < 0 || !ndef || spec.blocks < 1 || !spec.chain)
        return out;
    const int cell = spec.cell;
    const int cpb = MAP_BLOCKSIZE / cell; // cells per block
    const int n = spec.blocks * cpb;      // cells per axis in the region

    // Every block the mesh reads: the region, plus a margin wide enough for
    // the occlusion radius, and never less than one block so faces on the
    // region's skin are culled against the neighbour.
    const int margin_cells = spec.ao_radius > 0.0f ? (int)std::ceil(spec.ao_radius / cell) : 0;
    const int mb = std::max(1, (margin_cells + cpb - 1) / cpb);
    const int B = spec.blocks + 2 * mb;
    std::vector<const LodLevel *> levels((size_t)B * B * B, nullptr);
    std::vector<uint8_t> member((size_t)B * B * B, 0);
    std::vector<uint8_t> stored((size_t)B * B * B, 0);
    for (int bz = 0; bz < B; ++bz)
        for (int by = 0; by < B; ++by)
            for (int bx = 0; bx < B; ++bx) {
                v3s16 bp = spec.origin + v3s16(bx - mb, by - mb, bz - mb);
                const BlockLodChain *ch = spec.chain(bp);
                const size_t i = ((size_t)bz * B + by) * B + bx;
                levels[i] = ch ? ch->forCell(cell) : nullptr;
                stored[i] = ch && ch->stored ? 1 : 0;
                const bool inside = bx >= mb && by >= mb && bz >= mb &&
                        bx < mb + spec.blocks && by < mb + spec.blocks && bz < mb + spec.blocks;
                member[i] = inside && spec.member && spec.member(bp) ? 1 : 0;
            }
    // Region cell coordinates, which may run up to mb blocks outside it.
    auto cellAt = [&](int gx, int gy, int gz) -> const LodLevel::Cell * {
        const int bx = (gx + mb * cpb) / cpb, by = (gy + mb * cpb) / cpb, bz = (gz + mb * cpb) / cpb;
        if (bx < 0 || by < 0 || bz < 0 || bx >= B || by >= B || bz >= B)
            return nullptr;
        const LodLevel *lv = levels[((size_t)bz * B + by) * B + bx];
        if (!lv)
            return nullptr;
        const int lx = (gx + mb * cpb) % cpb, ly = (gy + mb * cpb) % cpb, lz = (gz + mb * cpb) % cpb;
        return &lv->at(lx, ly, lz);
    };
    auto isMember = [&](int gx, int gy, int gz) -> bool {
        const int bx = gx / cpb + mb, by = gy / cpb + mb, bz = gz / cpb + mb;
        return member[((size_t)bz * B + by) * B + bx] != 0;
    };
    auto isStored = [&](int gx, int gy, int gz) -> bool {
        const int bx = gx / cpb + mb, by = gy / cpb + mb, bz = gz / cpb + mb;
        return stored[((size_t)bz * B + by) * B + bx] != 0;
    };
    auto filled = [&](int gx, int gy, int gz) -> bool {
        const LodLevel::Cell *c = cellAt(gx, gy, gz);
        return c && (c->flags & LodLevel::kFilled);
    };

    // The far field occlusion: the same tracer as the near field, over a field
    // at this tier's cell size, covering the whole neighbourhood read above.
    OccupancyField occ;
    const bool trace = spec.ao_radius > 0.0f;
    if (trace) {
        const int fc = B * cpb; // field cells per axis
        occ.reset((spec.origin - v3s16(mb, mb, mb)) * MAP_BLOCKSIZE, cell, fc, fc, fc);
        for (int bz = 0; bz < B; ++bz)
            for (int by = 0; by < B; ++by)
                for (int bx = 0; bx < B; ++bx) {
                    const LodLevel *lv = levels[((size_t)bz * B + by) * B + bx];
                    if (!lv)
                        continue;
                    for (int z = 0; z < cpb; ++z)
                        for (int y = 0; y < cpb; ++y)
                            for (int x = 0; x < cpb; ++x)
                                if (lv->at(x, y, z).flags & LodLevel::kOccludes)
                                    occ.setCell(bx * cpb + x, by * cpb + y, bz * cpb + z);
                }
    }

    const v3s16 origin_nodes = spec.origin * MAP_BLOCKSIZE;
    std::map<u32, size_t> surface_of; // texture id -> index into out.surfaces
    auto surfaceFor = [&](u32 texture_id) -> LodSurface & {
        auto it = surface_of.find(texture_id);
        if (it != surface_of.end())
            return out.surfaces[it->second];
        out.surfaces.emplace_back();
        out.surfaces.back().texture_id = texture_id;
        surface_of[texture_id] = out.surfaces.size() - 1;
        return out.surfaces.back();
    };

    std::vector<FaceKey> mask((size_t)n * n);
    for (int d = 0; d < 6; ++d) {
        const int axis = DIRS[d][0] ? 0 : (DIRS[d][1] ? 1 : 2);
        const int sign = DIRS[d][0] + DIRS[d][1] + DIRS[d][2];
        // In plane axes: u is the first of the other two, v the second.
        const int ua = axis == 0 ? 1 : 0;
        const int va = axis == 2 ? 1 : 2;
        const v3f normal((float)DIRS[d][0], (float)DIRS[d][1], (float)DIRS[d][2]);
        for (int s = 0; s < n; ++s) {
            // Gather the slab's faces.
            bool any = false;
            for (int v = 0; v < n; ++v)
                for (int u = 0; u < n; ++u) {
                    FaceKey &fk = mask[(size_t)v * n + u];
                    fk = FaceKey();
                    int g[3];
                    g[axis] = s;
                    g[ua] = u;
                    g[va] = v;
                    if (!isMember(g[0], g[1], g[2]))
                        continue;
                    const LodLevel::Cell *c = cellAt(g[0], g[1], g[2]);
                    if (!c || !(c->flags & LodLevel::kFilled))
                        continue;
                    const int fx = g[0] + DIRS[d][0], fy = g[1] + DIRS[d][1], fz = g[2] + DIRS[d][2];
                    if (filled(fx, fy, fz))
                        continue;
                    const content_t content = c->face[d];
                    if (content == CONTENT_AIR || content == CONTENT_IGNORE)
                        continue;
                    const LodTileCache::Entry &te = tileFor(tiles, ndef, tsrc, materials, content, d);
                    fk.texture_id = te.texture_id;
                    fk.layer = te.layer;
                    fk.block_id = te.block_id;
                    u32 tint = 0xffffffff;
                    if (te.tile_has_color) {
                        tint = te.tint;
                    } else {
                        const ContentFeatures &f = ndef->get(content);
                        if (f.visuals) {
                            video::SColor col;
                            f.visuals->getColor(c->param2[d], &col);
                            tint = col.color | 0xff000000;
                        }
                    }
                    fk.colour = te.texture_id ? tint : mulColour(te.fallback, tint);
                    // Light: the air in front of the face, else the cell's
                    // own, else unlit sky and no block light. Block light's
                    // neutral is 0 rather than 255 here, because the far
                    // tiers add it as emission and 255 would glow.
                    const LodLevel::Cell *front = cellAt(fx, fy, fz);
                    if (front && (front->flags & LodLevel::kLit)) {
                        fk.day = quant16(front->day);
                        fk.night = quant16(front->night);
                    } else if (c->flags & LodLevel::kLit) {
                        fk.day = quant16(c->day);
                        fk.night = quant16(c->night);
                    } else {
                        fk.day = 255;
                        fk.night = 0;
                    }
                    if (trace) {
                        // Face centre, Luanti node coordinates.
                        v3f p((float)(origin_nodes.X + g[0] * cell) + cell * 0.5f,
                                (float)(origin_nodes.Y + g[1] * cell) + cell * 0.5f,
                                (float)(origin_nodes.Z + g[2] * cell) + cell * 0.5f);
                        if (axis == 0) p.X += sign * cell * 0.5f;
                        else if (axis == 1) p.Y += sign * cell * 0.5f;
                        else p.Z += sign * cell * 0.5f;
                        const float ao = traceOcclusion(occ, p, normal, spec.ao_radius);
                        fk.ao = quant16((int)std::lround(ao * 255.0f));
                    }
                    fk.fresh = isStored(g[0], g[1], g[2]) ? 96 : 255;
                    fk.valid = true;
                    any = true;
                    ++out.faces;
                }
            if (!any)
                continue;
            // Greedy merge: widen along u, then grow along v while every
            // cell of the next row matches.
            for (int v = 0; v < n; ++v)
                for (int u = 0; u < n;) {
                    FaceKey &fk = mask[(size_t)v * n + u];
                    if (!fk.valid) {
                        ++u;
                        continue;
                    }
                    const FaceKey key = fk;
                    int w = 1;
                    while (u + w < n && mask[(size_t)v * n + u + w].valid && mask[(size_t)v * n + u + w] == key)
                        ++w;
                    int h = 1;
                    for (; v + h < n; ++h) {
                        bool row_ok = true;
                        for (int k = 0; k < w && row_ok; ++k) {
                            const FaceKey &o = mask[(size_t)(v + h) * n + u + k];
                            row_ok = o.valid && o == key;
                        }
                        if (!row_ok)
                            break;
                    }
                    for (int dv = 0; dv < h; ++dv)
                        for (int du = 0; du < w; ++du)
                            mask[(size_t)(v + dv) * n + u + du].valid = false;

                    // The quad, Luanti node coordinates relative to the region
                    // origin: the face plane along the axis, u and v spans.
                    int lo[3], hi[3];
                    lo[axis] = hi[axis] = (sign > 0 ? s + 1 : s) * cell;
                    lo[ua] = u * cell;
                    hi[ua] = (u + w) * cell;
                    lo[va] = v * cell;
                    hi[va] = (v + h) * cell;
                    const float ox = (float)origin_nodes.X, oy = (float)origin_nodes.Y, oz = (float)origin_nodes.Z;
                    // Godot space: x0 < x1, y0 < y1, z1 <= z0 (z mirrored).
                    const float x0 = ox + lo[0], x1 = ox + hi[0];
                    const float y0 = oy + lo[1], y1 = oy + hi[1];
                    const float z0 = -(oz + lo[2]), z1 = -(oz + hi[2]);
                    v3f a, b, c2, d2;
                    switch (d) {
                    case 0: a = {x0, y1, z0}; b = {x1, y1, z0}; c2 = {x1, y1, z1}; d2 = {x0, y1, z1}; break;
                    case 1: a = {x0, y0, z1}; b = {x1, y0, z1}; c2 = {x1, y0, z0}; d2 = {x0, y0, z0}; break;
                    case 2: a = {x1, y0, z0}; b = {x1, y0, z1}; c2 = {x1, y1, z1}; d2 = {x1, y1, z0}; break;
                    case 3: a = {x0, y0, z1}; b = {x0, y0, z0}; c2 = {x0, y1, z0}; d2 = {x0, y1, z1}; break;
                    case 4: a = {x0, y0, z1}; b = {x1, y0, z1}; c2 = {x1, y1, z1}; d2 = {x0, y1, z1}; break;
                    default: a = {x1, y0, z0}; b = {x0, y0, z0}; c2 = {x0, y1, z0}; d2 = {x1, y1, z0}; break;
                    }
                    const v3f gn((float)DIRS[d][0], (float)DIRS[d][1], -(float)DIRS[d][2]);
                    LodSurface &sf = surfaceFor(key.texture_id);
                    const u32 base = (u32)sf.pos.size();
                    for (const v3f &p : {a, b, c2, d2}) {
                        // Back to Luanti coordinates relative to the region
                        // origin for the tile UV, per the face's orientation
                        // in content_mapblock.cpp's cuboid table, so a far
                        // tile lies the same way as the near one. Texture
                        // repeats per node; the region relative origin keeps
                        // the numbers small enough for float.
                        const float lx = p.X - ox, ly = p.Y - oy, lz = -p.Z - oz;
                        v2f uv;
                        switch (d) {
                        case 0: uv = v2f(lx, -lz); break;
                        case 1: uv = v2f(lx, lz); break;
                        case 2: uv = v2f(lz, -ly); break;
                        case 3: uv = v2f(-lz, -ly); break;
                        case 4: uv = v2f(-lx, -ly); break;
                        default: uv = v2f(lx, -ly); break;
                        }
                        sf.pos.push_back(p);
                        sf.nrm.push_back(gn);
                        sf.uv.push_back(uv);
                        sf.uv2.push_back(v2f((float)key.layer, (float)key.block_id));
                        sf.col.push_back(key.colour);
                        sf.custom0.push_back(key.night);
                        sf.custom0.push_back(key.day);
                        sf.custom0.push_back(key.ao);
                        sf.custom0.push_back(key.fresh);
                    }
                    // Clockwise seen from outside, which is Godot's front
                    // face. The old single tier wound these the other way and
                    // drew every cell inside out; flat colour hid it, the
                    // array shader did not.
                    for (u32 i : {0u, 2u, 1u, 0u, 3u, 2u})
                        sf.idx.push_back(base + i);
                    ++out.quads;
                    u += w;
                }
        }
    }
    return out;
}

} // namespace goanna
