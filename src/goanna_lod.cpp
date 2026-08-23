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
enum : uint8_t { nSolid = 1, nFilled = 2, nLit = 4, nKnown = 8, nVeg = 16 };

struct ContentClass {
    uint8_t flags = 0;
    uint8_t glow = 0; // decoded light_source
    ContentLightingFlags lf;
};

} // namespace

bool lodIsVegetation(const NodeDefManager *ndef, content_t c) {
    // Mirrors VEG_GROUPS in goanna_server_mod/init.lua. Keep the two lists
    // the same, or a stored block and the summary beside it disagree on
    // where the ground is and the surface steps at the seam.
    static const char *const kGroups[] = {"tree", "leaves", "cactus", "bamboo", "plant", "flora",
            "sapling", "flower", "mushroom", "fruit", "vines"};
    if (!ndef)
        return false;
    const ContentFeatures &f = ndef->get(c);
    for (const char *g : kGroups)
        if (itemgroup_get(f.groups, g) > 0)
            return true;
    return false;
}

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
        const bool veg = filled && lodIsVegetation(ndef, c);
        cc.flags = nKnown | (solid ? nSolid : 0) | (filled ? nFilled : 0) | (lit ? nLit : 0) |
                (veg ? nVeg : 0);
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
        // The ground per column: the highest filled node that is not
        // vegetation, over the cell's footprint, so a tree stands on the
        // surface rather than being part of it. Cells in the run from the
        // floor up to it are flagged terrain below, once they are known to
        // be filled.
        lv.terrain.assign((size_t)n * n, 0);
        // The content seen on the ground per column, the commonest top
        // terrain node over the footprint, kept so the surface cell's top
        // face can be set after the cells are built: that cell may hold too
        // few nodes to count as filled, and then has no faces of its own,
        // but the surface still needs to know what it is made of.
        std::vector<content_t> ground_c((size_t)n * n, CONTENT_AIR);
        std::vector<uint8_t> ground_p2((size_t)n * n, 0);
        for (int cz = 0; cz < n; ++cz)
            for (int cx = 0; cx < n; ++cx) {
                int h = 0;
                struct Top {
                    content_t c;
                    uint8_t p2;
                    int count;
                };
                Top tops[16];
                int ntops = 0;
                for (int z = cz * cell; z < (cz + 1) * cell; ++z)
                    for (int x = cx * cell; x < (cx + 1) * cell; ++x)
                        for (int y = N - 1; y >= 0; --y) {
                            const NodeInfo &ni = info[((size_t)z * N + y) * N + x];
                            if ((ni.flags & nFilled) && !(ni.flags & nVeg)) {
                                h = std::max(h, y + 1);
                                int t = 0;
                                for (; t < ntops; ++t)
                                    if (tops[t].c == ni.c && tops[t].p2 == ni.p2) {
                                        ++tops[t].count;
                                        break;
                                    }
                                if (t == ntops && ntops < 16)
                                    tops[ntops++] = Top{ni.c, ni.p2, 1};
                                break;
                            }
                        }
                lv.terrain[(size_t)cz * n + cx] = (uint8_t)h;
                int best = -1;
                for (int t = 0; t < ntops; ++t)
                    if (best < 0 || tops[t].count > tops[best].count)
                        best = t;
                if (best >= 0) {
                    ground_c[(size_t)cz * n + cx] = tops[best].c;
                    ground_p2[(size_t)cz * n + cx] = tops[best].p2;
                }
            }
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
                    int solid = 0, filled = 0, lit = 0, known = 0, top = 0;
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
                                if (ni.flags & nFilled) {
                                    ++filled;
                                    top = std::max(top, y - y0 + 1);
                                }
                                if (ni.flags & nLit) {
                                    ++lit;
                                    day += ni.day;
                                    night += ni.night;
                                }
                            }
                    if (!known)
                        continue;
                    const bool is_filled = filled >= fill_at;
                    out_cell.top = (uint8_t)top;
                    const bool in_ground = is_filled && y0 < (int)lv.terrain[(size_t)cz * n + cx];
                    out_cell.flags = LodLevel::kKnown | (is_filled ? LodLevel::kFilled : 0) |
                            (solid >= occlude_at ? LodLevel::kOccludes : 0) | (lit ? LodLevel::kLit : 0) |
                            (in_ground ? LodLevel::kTerrain : 0);
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
        // The surface cell of every column with ground: its top face is the
        // ground's own content, and its sides take it too where the tally
        // above found nothing, so the surface pass and its skirts have
        // something to draw whatever the cell's fill count.
        for (int cz = 0; cz < n; ++cz)
            for (int cx = 0; cx < n; ++cx) {
                const int h = lv.terrain[(size_t)cz * n + cx];
                const content_t gc = ground_c[(size_t)cz * n + cx];
                if (h <= 0 || gc == CONTENT_AIR)
                    continue;
                LodLevel::Cell &top_cell = lv.cells[((size_t)cz * n + (h - 1) / cell) * n + cx];
                top_cell.face[0] = gc;
                top_cell.param2[0] = ground_p2[(size_t)cz * n + cx];
                for (int d = 1; d < 6; ++d)
                    if (top_cell.face[d] == CONTENT_AIR) {
                        top_cell.face[d] = gc;
                        top_cell.param2[d] = ground_p2[(size_t)cz * n + cx];
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
    if (f.visuals && tsrc && f.isLiquid()) {
        // The water shader wants the tile's 2D image; an animated tile's
        // first frame, or the tile itself. A flowing liquid draws from its
        // special tiles (top, then side), its ordinary tiles being blank.
        const TileLayer &l = f.drawtype == NDT_FLOWINGLIQUID
                ? f.visuals->special_tiles[side == 0 ? 0 : 1].layers[0]
                : f.visuals->tiles[side].layers[0];
        u32 tid = l.texture_id;
        if (l.frames && !l.frames->empty())
            tid = (*l.frames)[0].texture_id;
        GoannaTexture *gt = tsrc->goannaTexture(tid);
        if (gt && !gt->isArray()) {
            e.liquid = true;
            e.texture_id = tid;
            e.tile_has_color = l.has_color;
            e.tint = l.has_color ? (l.color.color | 0xff000000) : 0xffffffff;
            return cache.entries.emplace(key, e).first->second;
        }
    }
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
    bool liquid = false;
    // The vertical span of the face within its cell, in nodes: from the
    // height the neighbour reaches to the height this cell reaches. A cell
    // is not a full cube unless its content fills it, so a hill drawn at
    // cell 16 follows its own surface rather than snapping to the cell.
    uint8_t lo = 0, hi = 16;
    // Which row of cells a partial height side face belongs to, plus one; 0
    // for a full height face. Two partial faces in different rows are not
    // one rectangle (each sits at its own height inside its own cell), so
    // this keeps the greedy merge from joining them, while full height faces
    // merge as freely as before.
    uint16_t row = 0;
    bool valid = false;
    bool operator==(const FaceKey &o) const {
        return texture_id == o.texture_id && layer == o.layer && block_id == o.block_id && colour == o.colour &&
                day == o.day && night == o.night && ao == o.ao && fresh == o.fresh && liquid == o.liquid &&
                lo == o.lo && hi == o.hi && row == o.row;
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
    // The level one tier coarser, for stitching this tier's edge onto a
    // coarser neighbour; null where there is no coarser tier.
    const int cell2 = cell * 2 <= MAP_BLOCKSIZE ? cell * 2 : 0;
    std::vector<const LodLevel *> levels2((size_t)B * B * B, nullptr);
    std::vector<uint8_t> member((size_t)B * B * B, 0);
    std::vector<uint8_t> stored((size_t)B * B * B, 0);
    std::vector<int> drawn((size_t)B * B * B, -1);
    for (int bz = 0; bz < B; ++bz)
        for (int by = 0; by < B; ++by)
            for (int bx = 0; bx < B; ++bx) {
                v3s16 bp = spec.origin + v3s16(bx - mb, by - mb, bz - mb);
                const BlockLodChain *ch = spec.chain(bp);
                const size_t i = ((size_t)bz * B + by) * B + bx;
                levels[i] = ch ? ch->forCell(cell) : nullptr;
                levels2[i] = ch && cell2 ? ch->forCell(cell2) : nullptr;
                stored[i] = ch && ch->stored ? 1 : 0;
                const bool inside = bx >= mb && by >= mb && bz >= mb &&
                        bx < mb + spec.blocks && by < mb + spec.blocks && bz < mb + spec.blocks;
                member[i] = inside && spec.member && spec.member(bp) ? 1 : 0;
                if (member[i])
                    drawn[i] = cell;
                else if (spec.drawn_cell)
                    drawn[i] = spec.drawn_cell(bp);
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
    std::map<uint64_t, size_t> surface_of; // texture id (and liquid bit) -> index into out.surfaces
    auto surfaceFor = [&](u32 texture_id, bool liquid) -> LodSurface & {
        const uint64_t k = (uint64_t)texture_id | (liquid ? (1ull << 40) : 0);
        auto it = surface_of.find(k);
        if (it != surface_of.end())
            return out.surfaces[it->second];
        out.surfaces.emplace_back();
        out.surfaces.back().texture_id = texture_id;
        out.surfaces.back().liquid = liquid;
        surface_of[k] = out.surfaces.size() - 1;
        return out.surfaces.back();
    };

    // Per block and per column of cells in it: the block holds ground here
    // with air under it, an overhang, a bridge, a floating island, so it is
    // not the column's surface and its cells are drawn as boxes by the box
    // pass below. Indexed [block][lz * cpb + lx]; filled by the surface pass.
    std::vector<uint8_t> floating((size_t)B * B * B * cpb * cpb, 0);
    auto floatAt = [&](size_t bi, int lx, int lz) -> uint8_t & {
        return floating[bi * (size_t)cpb * cpb + (size_t)lz * cpb + lx];
    };
    // Region columns (with margin) whose surface is a forest canopy, filled
    // by the surface pass; the box pass leaves their vegetation alone.
    const int canopy_margin = mb * cpb;
    const int canopy_w = n + 2 * canopy_margin;
    std::vector<uint8_t> canopy_cols((size_t)canopy_w * canopy_w, 0);
    auto canopyAt = [&](int gx, int gz) -> bool {
        const int ix = gx + canopy_margin, iz = gz + canopy_margin;
        if (ix < 0 || iz < 0 || ix >= canopy_w || iz >= canopy_w)
            return false;
        return canopy_cols[(size_t)iz * canopy_w + ix] != 0;
    };

    // -----------------------------------------------------------------------
    // The ground as one surface.
    //
    // Every column of cells has, in the chains, a terrain height per block:
    // the highest filled node that is not vegetation. The highest block in the
    // column that holds one carries the column's surface, and this region
    // draws that surface for every column whose surface block is a member,
    // as one quad per cell over the heights at the cell's four corners. A
    // corner's height is the mean of the surfaces of the columns around it
    // that are drawn at this same cell size and are not water; water keeps
    // its own level, so a sea is flat to the shore. Both regions either side
    // of a boundary compute a shared corner from the same columns, since each
    // reads a block of margin, so the surface is seamless across regions of
    // one tier without either knowing about the other.
    //
    // Where a cell's edge does not meet a neighbour that agrees with it, at a
    // hole, the shore, a block drawn at another tier or at full detail, or
    // the edge of what is known, a skirt drops from the edge so nothing is
    // seen under the surface. The ground cells themselves emit no box faces
    // below; the box pass draws only what is not ground, which is the
    // vegetation and anything else the chain could not class as terrain.
    //
    // This replaces the staircase a heightfield costs when it is drawn as
    // boxes (docs/far-rendering.md, "Strips, and what the merge can and
    // cannot do"): a slope is two triangles a cell, there are no risers to
    // merge, and the normals follow the ground.
    {
        const int margin = mb * cpb; // cells of margin each side, horizontally
        const int W = n + 2 * margin;
        struct Column {
            bool has = false;     // a surface was found within the blocks read
            bool same = false;    // and its block is drawn at this cell
            bool own = false;     // and that block is a member of this region
            bool water = false;
            bool canopy = false;  // the surface is a forest roof, not ground
            int drawn_at = -1;    // cell size the surface block is drawn at
            float h = 0.0f;       // absolute node height of the surface
            int gy = 0;           // region cell y of the surface cell
            const LodLevel::Cell *top = nullptr; // the surface cell
            const LodLevel::Cell *above = nullptr;
            bool is_stored = false;
        };
        std::vector<Column> cols((size_t)W * W);
        auto colAt = [&](int gx, int gz) -> Column * {
            const int ix = gx + margin, iz = gz + margin;
            if (ix < 0 || iz < 0 || ix >= W || iz >= W)
                return nullptr;
            return &cols[(size_t)iz * W + ix];
        };
        for (int gz = -margin; gz < n + margin; ++gz)
            for (int gx = -margin; gx < n + margin; ++gx) {
                Column &col = *colAt(gx, gz);
                const int bx = (gx + margin) / cpb, bz = (gz + margin) / cpb;
                const int lx = (gx + margin) % cpb, lz = (gz + margin) % cpb;
                for (int by = B - 1; by >= 0 && !col.has; --by) {
                    const size_t bi = ((size_t)bz * B + by) * B + bx;
                    const LodLevel *lv = levels[bi];
                    if (!lv)
                        continue;
                    int th = lv->terrainAt(lx, lz);
                    // At the coarser tiers a forest is its roof: the highest
                    // vegetation cell in the column, if it stands above the
                    // ground, is the surface, with the canopy's colour. A
                    // forest seen from a few hundred nodes is a green roof
                    // rolling with the land, not a pile of cubes, which is
                    // what boxes at 8 and 16 nodes made of it. At the finest
                    // far tier the trees stay boxes, since there they are
                    // still individual trees.
                    bool canopy = false;
                    if (cell >= 8) {
                        for (int ty = cpb - 1; ty >= 0 && ty * cell + 1 > th; --ty) {
                            const LodLevel::Cell &vc = lv->at(lx, ty, lz);
                            if ((vc.flags & LodLevel::kFilled) && !(vc.flags & LodLevel::kTerrain)) {
                                const int vh = ty * cell + (vc.top > 0 && vc.top < cell ? vc.top : cell);
                                if (vh > th) {
                                    th = vh;
                                    canopy = true;
                                }
                                break;
                            }
                        }
                    }
                    if (th <= 0)
                        continue;
                    // The highest block with ground is the surface only if
                    // the ground is under it: the block below filled to its
                    // ceiling, or this block filled to its own. A run with
                    // air beneath it is an overhang or a floating island,
                    // and taking its top as the surface draped the
                    // heightfield from its rim down to the real ground as a
                    // cone (reported as a sky island "rendering weirdly").
                    // Such a run is left to the box pass, and the search
                    // goes on down. A block below that is not known keeps
                    // the old answer rather than punching a hole at the
                    // frontier.
                    if (!canopy && th < MAP_BLOCKSIZE && by > 0) {
                        const size_t below = ((size_t)bz * B + (by - 1)) * B + bx;
                        const LodLevel *lb = levels[below];
                        if (lb && lb->terrainAt(lx, lz) < MAP_BLOCKSIZE) {
                            floatAt(bi, lx, lz) = 1;
                            continue;
                        }
                    }
                    col.has = true;
                    col.canopy = canopy;
                    if (canopy)
                        canopy_cols[(size_t)(gz + canopy_margin) * canopy_w + (gx + canopy_margin)] = 1;
                    col.same = drawn[bi] == cell;
                    col.drawn_at = drawn[bi];
                    col.own = member[bi] != 0;
                    col.is_stored = stored[bi] != 0;
                    col.h = (float)(origin_nodes.Y + (by - mb) * MAP_BLOCKSIZE + th);
                    const int ty = (th - 1) / cell;
                    col.gy = (by - mb) * cpb + ty;
                    col.top = &lv->at(lx, ty, lz);
                    col.above = cellAt(gx, col.gy + 1, gz);
                    const content_t tc = col.top->face[0];
                    if (tc != CONTENT_AIR && tc != CONTENT_IGNORE) {
                        const ContentFeatures &f = ndef->get(tc);
                        col.water = !canopy && f.isLiquid();
                    }
                }
            }
        // Corner height: mean of the same tier, non water columns around it;
        // a water cell asks for its own level instead.
        auto cornerLand = [&](int cx, int cz, float &h) -> bool {
            float sum = 0.0f;
            int k = 0;
            for (int dz = -1; dz <= 0; ++dz)
                for (int dx = -1; dx <= 0; ++dx) {
                    const Column *c = colAt(cx + dx, cz + dz);
                    if (c && c->has && c->same && !c->water) {
                        sum += c->h;
                        ++k;
                    }
                }
            if (!k)
                return false;
            h = sum / (float)k;
            return true;
        };
        // -------------------------------------------------------------------
        // Stitching onto a coarser tier. Where this tier meets the next one
        // out, the two compute their shared edge from different cell sizes
        // and the edge reads as a step, a ring at a fixed distance from the
        // camera that both sides skirt. So the finer side adopts the coarser
        // side's heights along that edge: at a corner that is also a corner
        // of the coarse grid, what the coarse region computes there (the
        // mean of the coarse columns around it that are drawn at the coarse
        // cell, which excludes this side); halfway along a coarse edge, the
        // midpoint of its two ends, which is what the coarse quad's straight
        // edge passes through. The coarse side keeps its skirt, which then
        // hangs under this surface unseen, and this side drops its own.
        //
        // The coarse columns are read from the same chains at the coarser
        // level, so both sides see the same data, and this region's margin
        // of one block reaches one coarse cell past its edge, which is all a
        // boundary corner needs.
        struct Column2 {
            bool done = false, has = false, same = false, water = false;
            float h = 0.0f;
        };
        const int cpb2 = cell2 ? MAP_BLOCKSIZE / cell2 : 0;
        const int margin2 = mb * cpb2;
        const int n2 = cell2 ? n / 2 : 0;
        const int W2 = n2 + 2 * margin2;
        std::vector<Column2> cols2((size_t)std::max(1, W2 * W2));
        auto col2At = [&](int cx2, int cz2) -> const Column2 * {
            if (!cell2)
                return nullptr;
            const int ix = cx2 + margin2, iz = cz2 + margin2;
            if (ix < 0 || iz < 0 || ix >= W2 || iz >= W2)
                return nullptr;
            Column2 &col = cols2[(size_t)iz * W2 + ix];
            if (col.done)
                return &col;
            col.done = true;
            const int bx = ix / cpb2, bz = iz / cpb2;
            const int lx = ix % cpb2, lz = iz % cpb2;
            for (int by = B - 1; by >= 0; --by) {
                const size_t bi = ((size_t)bz * B + by) * B + bx;
                const LodLevel *lv = levels2[bi];
                if (!lv)
                    continue;
                const int th = lv->terrainAt(lx, lz);
                if (th <= 0)
                    continue;
                col.has = true;
                col.same = drawn[bi] == cell2;
                col.h = (float)(origin_nodes.Y + (by - mb) * MAP_BLOCKSIZE + th);
                const LodLevel::Cell &top = lv->at(lx, (th - 1) / cell2, lz);
                const content_t tc = top.face[0];
                if (tc != CONTENT_AIR && tc != CONTENT_IGNORE)
                    col.water = ndef->get(tc).isLiquid();
                break;
            }
            return &col;
        };
        // What the coarse region computes at one of its corners.
        auto cornerCoarse = [&](int cx2, int cz2, float &h) -> bool {
            float sum = 0.0f;
            int k = 0;
            for (int dz = -1; dz <= 0; ++dz)
                for (int dx = -1; dx <= 0; ++dx) {
                    const Column2 *c = col2At(cx2 + dx, cz2 + dz);
                    if (c && c->has && c->same && !c->water) {
                        sum += c->h;
                        ++k;
                    }
                }
            if (!k)
                return false;
            h = sum / (float)k;
            return true;
        };
        // A fine corner lies on the boundary with the coarser tier when any
        // of the four fine columns around it is drawn at the coarser cell.
        auto onCoarseEdge = [&](int cx, int cz) -> bool {
            if (!cell2)
                return false;
            for (int dz = -1; dz <= 0; ++dz)
                for (int dx = -1; dx <= 0; ++dx) {
                    const Column *c = colAt(cx + dx, cz + dz);
                    if (c && c->has && c->drawn_at == cell2)
                        return true;
                }
            return false;
        };
        // The coarse side's height at a fine corner on the boundary: the
        // coarse corner where the grids coincide, else the midpoint of the
        // coarse edge, else (inside a coarse cell) the mean of its corners.
        auto stitchedHeight = [&](int cx, int cz, float &h) -> bool {
            auto fdiv2 = [](int v) { return v >= 0 ? v / 2 : -((-v + 1) / 2); };
            const int ex = cx % 2 == 0, ez = cz % 2 == 0;
            const int bx = fdiv2(cx), bz = fdiv2(cz);
            if (ex && ez)
                return cornerCoarse(bx, bz, h);
            float ha, hb, hc, hd;
            if (ex) {
                if (!cornerCoarse(bx, bz, ha) || !cornerCoarse(bx, bz + 1, hb))
                    return false;
                h = 0.5f * (ha + hb);
                return true;
            }
            if (ez) {
                if (!cornerCoarse(bx, bz, ha) || !cornerCoarse(bx + 1, bz, hb))
                    return false;
                h = 0.5f * (ha + hb);
                return true;
            }
            if (!cornerCoarse(bx, bz, ha) || !cornerCoarse(bx + 1, bz, hb) ||
                    !cornerCoarse(bx, bz + 1, hc) || !cornerCoarse(bx + 1, bz + 1, hd))
                return false;
            h = 0.25f * (ha + hb + hc + hd);
            return true;
        };
        // The four corner heights of a cell's quad, (gx,gz), (gx+1,gz),
        // (gx+1,gz+1), (gx,gz+1). False if the cell has no surface. A land
        // cell's corners on the coarse boundary take the coarse side's
        // heights, above.
        auto quadHeights = [&](int gx, int gz, float out[4]) -> bool {
            const Column *c = colAt(gx, gz);
            if (!c || !c->has || !c->same)
                return false;
            if (c->water || spec.terrace) {
                out[0] = out[1] = out[2] = out[3] = c->h;
                return true;
            }
            const int cx[4] = {gx, gx + 1, gx + 1, gx};
            const int cz[4] = {gz, gz, gz + 1, gz + 1};
            for (int i = 0; i < 4; ++i) {
                if (onCoarseEdge(cx[i], cz[i]) && stitchedHeight(cx[i], cz[i], out[i]))
                    continue;
                if (!cornerLand(cx[i], cz[i], out[i]))
                    out[i] = c->h; // cannot happen: the cell itself counts
            }
            return true;
        };
        // The coarse neighbour's surface along the edge of a fine cell: true
        // when that neighbour is land drawn at the coarser cell, with its
        // heights at the two shared corners, which are what this side
        // stitched to. A water neighbour keeps its own level and is compared
        // as such.
        auto coarseEdgeAgrees = [&](int ngx, int ngz, int cax, int caz, int cbx, int cbz,
                float ha, float hb) -> bool {
            const Column *nc = colAt(ngx, ngz);
            if (!nc || !nc->has || nc->drawn_at != cell2)
                return false;
            if (nc->water)
                return std::fabs(nc->h - ha) < 0.01f && std::fabs(nc->h - hb) < 0.01f;
            float sa, sb;
            if (!stitchedHeight(cax, caz, sa) || !stitchedHeight(cbx, cbz, sb))
                return false;
            return std::fabs(sa - ha) < 0.01f && std::fabs(sb - hb) < 0.01f;
        };
        // Normal at a corner from the heights of the columns around it.
        auto cornerNormal = [&](int cx, int cz) -> v3f {
            auto hAt = [&](int x, int z, float fallback) -> float {
                float h;
                return cornerLand(x, z, h) ? h : fallback;
            };
            float h0;
            if (!cornerLand(cx, cz, h0))
                return v3f(0, 1, 0);
            const float hx0 = hAt(cx - 1, cz, h0), hx1 = hAt(cx + 1, cz, h0);
            const float hz0 = hAt(cx, cz - 1, h0), hz1 = hAt(cx, cz + 1, h0);
            v3f nrm((hx0 - hx1) / (2.0f * cell), 1.0f, (hz0 - hz1) / (2.0f * cell));
            nrm.normalize();
            return nrm;
        };
        // How far a skirt drops: to the lowest corner of the neighbour it
        // does not agree with, plus a little, so it covers the step and no
        // more. Three cells of skirt at the coarsest tier were 48 node
        // plates standing on every mountainside (reported as distant hills
        // that "look like dominoes"). Where the neighbour is unknown, one
        // cell, which hides the underside at the frontier from most angles.
        const float skirt_min = 0.5f * (float)cell;
        const float skirt_unknown = (float)cell;
        auto lightOf = [&](const Column &c, uint8_t &day, uint8_t &night) {
            if (c.above && (c.above->flags & LodLevel::kLit)) {
                day = quant16(c.above->day);
                night = quant16(c.above->night);
            } else if (c.top->flags & LodLevel::kLit) {
                day = quant16(c.top->day);
                night = quant16(c.top->night);
            } else {
                day = 255;
                night = 0;
            }
        };
        auto tintOf = [&](const LodTileCache::Entry &te, content_t content, uint8_t p2) -> u32 {
            u32 tint = 0xffffffff;
            if (te.tile_has_color) {
                tint = te.tint;
            } else {
                const ContentFeatures &f = ndef->get(content);
                if (f.visuals) {
                    video::SColor col;
                    f.visuals->getColor(p2, &col);
                    tint = col.color | 0xff000000;
                }
            }
            return te.texture_id ? tint : mulColour(te.fallback, tint);
        };
        const float ox = (float)origin_nodes.X, oy = (float)origin_nodes.Y, oz = (float)origin_nodes.Z;
        for (int gz = 0; gz < n; ++gz)
            for (int gx = 0; gx < n; ++gx) {
                const Column &col = *colAt(gx, gz);
                if (!col.has || !col.own)
                    continue;
                float hs[4];
                if (!quadHeights(gx, gz, hs))
                    continue;
                const content_t content = col.top->face[0];
                if (content == CONTENT_AIR || content == CONTENT_IGNORE)
                    continue;
                const LodTileCache::Entry &te = tileFor(tiles, ndef, tsrc, materials, content, 0);
                const u32 colour = tintOf(te, content, col.top->param2[0]);
                uint8_t day, night;
                lightOf(col, day, night);
                const uint8_t fresh = col.is_stored ? 96 : 255;
                // Corners in Luanti coordinates relative to the region.
                const float lx0 = (float)(gx * cell), lx1 = lx0 + cell;
                const float lz0 = (float)(gz * cell), lz1 = lz0 + cell;
                const float cxs[4] = {lx0, lx1, lx1, lx0};
                const float czs[4] = {lz0, lz0, lz1, lz1};
                const int cix[4] = {gx, gx + 1, gx + 1, gx};
                const int ciz[4] = {gz, gz, gz + 1, gz + 1};
                LodSurface &sf = surfaceFor(te.texture_id, te.liquid);
                const u32 base = (u32)sf.pos.size();
                for (int i = 0; i < 4; ++i) {
                    // Godot space: z mirrored.
                    const v3f p(ox + cxs[i], hs[i], -(oz + czs[i]));
                    v3f nrm = col.water || spec.terrace ? v3f(0, 1, 0) : cornerNormal(cix[i], ciz[i]);
                    nrm.Z = -nrm.Z;
                    uint8_t ao = 255;
                    if (trace)
                        ao = quant16((int)std::lround(traceOcclusion(occ,
                                v3f(ox + cxs[i], hs[i], oz + czs[i]), v3f(nrm.X, nrm.Y, -nrm.Z),
                                spec.ao_radius) * 255.0f));
                    sf.pos.push_back(p);
                    sf.nrm.push_back(nrm);
                    sf.uv.push_back(v2f(cxs[i], -czs[i]));
                    sf.uv2.push_back(v2f((float)te.layer, (float)te.block_id));
                    sf.col.push_back(colour);
                    sf.custom0.push_back(night);
                    sf.custom0.push_back(day);
                    sf.custom0.push_back(ao);
                    sf.custom0.push_back(fresh);
                }
                // Split along the diagonal whose ends are nearer in height,
                // so a ridge or a gully keeps its line. Clockwise seen from
                // above, Godot's front face.
                if (std::fabs(hs[0] - hs[2]) <= std::fabs(hs[1] - hs[3])) {
                    for (u32 i : {0u, 2u, 1u, 0u, 3u, 2u})
                        sf.idx.push_back(base + i);
                } else {
                    for (u32 i : {0u, 3u, 1u, 1u, 3u, 2u})
                        sf.idx.push_back(base + i);
                }
                ++out.surface_cells;
                ++out.faces;
                ++out.quads;
                out.max_span = std::max(out.max_span, cell);
                // Skirts: one per edge whose neighbour does not share this
                // edge's heights. Sides in DIRS order +X, -X, +Z, -Z, as face
                // indices 2 to 5, so the UV and winding tables below match the
                // box pass.
                const int ndx[4] = {1, -1, 0, 0};
                const int ndz[4] = {0, 0, 1, -1};
                // Corner indices (into hs) at the near end and far end of
                // each edge, and where the neighbour's matching corners are.
                const int ea[4] = {1, 0, 3, 0};
                const int eb[4] = {2, 3, 2, 1};
                for (int e = 0; e < 4; ++e) {
                    const int ngx = gx + ndx[e], ngz = gz + ndz[e];
                    float nh[4];
                    bool agree = false;
                    // Water skirts only toward a hole. Against land, live
                    // water or another tier's water its skirt would hang
                    // under a surface that is there, and at the live edge it
                    // showed as a stepped wall around the lake the server was
                    // sending.
                    if (col.water) {
                        const Column *nc = colAt(ngx, ngz);
                        if (nc && nc->has)
                            agree = true;
                    }
                    if (!agree && quadHeights(ngx, ngz, nh)) {
                        // The neighbour's corners on our shared edge: +X
                        // edge of ours is its -X edge, and so on.
                        const int na[4] = {0, 1, 0, 3};
                        const int nb[4] = {3, 2, 1, 2};
                        agree = std::fabs(nh[na[e]] - hs[ea[e]]) < 0.01f &&
                                std::fabs(nh[nb[e]] - hs[eb[e]]) < 0.01f;
                    }
                    if (!agree && !col.water) {
                        // Stitched onto a coarser neighbour: no skirt where
                        // the two edges coincide.
                        const int cix2[4] = {gx, gx + 1, gx + 1, gx};
                        const int ciz2[4] = {gz, gz, gz + 1, gz + 1};
                        agree = coarseEdgeAgrees(ngx, ngz, cix2[ea[e]], ciz2[ea[e]], cix2[eb[e]],
                                ciz2[eb[e]], hs[ea[e]], hs[eb[e]]);
                    }
                    if (agree)
                        continue;
                    const int d = 2 + e;
                    const content_t sc = col.top->face[d] != CONTENT_AIR ? col.top->face[d] : content;
                    const LodTileCache::Entry &se = tileFor(tiles, ndef, tsrc, materials, sc, d);
                    const u32 scol = tintOf(se, sc, col.top->param2[d]);
                    LodSurface &ss = surfaceFor(se.texture_id, se.liquid);
                    const u32 sbase = (u32)ss.pos.size();
                    // Top edge from corner ea to eb, bottom edge below the
                    // neighbour's lowest corner on that edge. Ordered so the
                    // face looks outward.
                    const float ax = cxs[ea[e]], az = czs[ea[e]], ah = hs[ea[e]];
                    const float bxv = cxs[eb[e]], bz = czs[eb[e]], bh = hs[eb[e]];
                    float bottom = std::min(ah, bh) - skirt_unknown;
                    {
                        float nq[4];
                        if (quadHeights(ngx, ngz, nq)) {
                            const float nlow = std::min(std::min(nq[0], nq[1]), std::min(nq[2], nq[3]));
                            bottom = std::min(std::min(ah, bh) - skirt_min, nlow - 1.0f);
                        }
                    }
                    v3f q[4] = {
                        v3f(ox + ax, bottom, -(oz + az)),
                        v3f(ox + bxv, bottom, -(oz + bz)),
                        v3f(ox + bxv, bh, -(oz + bz)),
                        v3f(ox + ax, ah, -(oz + az)),
                    };
                    const v3f gn((float)DIRS[d][0], 0.0f, -(float)DIRS[d][2]);
                    for (int i = 0; i < 4; ++i) {
                        const float lx = q[i].X - ox, ly = q[i].Y - oy, lz = -q[i].Z - oz;
                        v2f uv;
                        switch (d) {
                        case 2: uv = v2f(lz, -ly); break;
                        case 3: uv = v2f(-lz, -ly); break;
                        case 4: uv = v2f(-lx, -ly); break;
                        default: uv = v2f(lx, -ly); break;
                        }
                        ss.pos.push_back(q[i]);
                        ss.nrm.push_back(gn);
                        ss.uv.push_back(uv);
                        ss.uv2.push_back(v2f((float)se.layer, (float)se.block_id));
                        ss.col.push_back(scol);
                        ss.custom0.push_back(night);
                        ss.custom0.push_back(day);
                        ss.custom0.push_back(255);
                        ss.custom0.push_back(fresh);
                    }
                    // Winding per side, matching the box pass: the quad here
                    // is (bottom a, bottom b, top b, top a), which for +X and
                    // +Z reads clockwise from outside as 0,2,1 0,3,2 and for
                    // -X and -Z the other way.
                    if (e == 0 || e == 2) {
                        for (u32 i : {0u, 2u, 1u, 0u, 3u, 2u})
                            ss.idx.push_back(sbase + i);
                    } else {
                        for (u32 i : {0u, 1u, 2u, 0u, 2u, 3u})
                            ss.idx.push_back(sbase + i);
                    }
                    ++out.skirts;
                }
            }
    }

    std::vector<FaceKey> mask((size_t)n * n);
    for (int d = 0; d < 6; ++d) {
        const int axis = DIRS[d][0] ? 0 : (DIRS[d][1] ? 1 : 2);
        const int sign = DIRS[d][0] + DIRS[d][1] + DIRS[d][2];
        // In plane axes: u is the first of the other two, v the second.
        const int ua = axis == 0 ? 1 : 0;
        const int va = axis == 2 ? 1 : 2;
        // Which of the two in plane axes is the vertical one, for a side
        // face: u for an x facing quad, v for a z facing one.
        const bool u_is_vertical = ua == 1;
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
                    // Ground is drawn by the surface pass above, never as
                    // boxes: its side faces would cut through the slopes.
                    // Except a run with air under it, an overhang or an
                    // island, which the surface pass left for here.
                    if (c->flags & LodLevel::kTerrain) {
                        const int bx = g[0] / cpb + mb, by = g[1] / cpb + mb, bz = g[2] / cpb + mb;
                        const size_t bi = ((size_t)bz * B + by) * B + bx;
                        if (!floatAt(bi, g[0] % cpb, g[2] % cpb))
                            continue;
                    } else if (canopyAt(g[0], g[2])) {
                        // Vegetation under a canopy surface is inside the
                        // roof the surface pass drew.
                        continue;
                    }
                    const int fx = g[0] + DIRS[d][0], fy = g[1] + DIRS[d][1], fz = g[2] + DIRS[d][2];
                    const LodLevel::Cell *front_cell = cellAt(fx, fy, fz);
                    const bool front_filled = front_cell && (front_cell->flags & LodLevel::kFilled);
                    // How high the content actually reaches in each cell.
                    auto height_of = [&](const LodLevel::Cell *cc, bool is_filled) -> int {
                        if (!is_filled)
                            return 0;
                        return cc->top > 0 && cc->top < cell ? (int)cc->top : cell;
                    };
                    const int h_self = height_of(c, true);
                    const int h_front = height_of(front_cell, front_filled);
                    if (axis == 1) {
                        // A top or bottom face exists only where the cell
                        // beyond is empty, and unknown is not empty here
                        // either. What saves the far field from going
                        // invisible from above, which is what a blanket
                        // version of this rule did, is that the face only
                        // leans on the neighbour when it has to: a cell whose
                        // content stops inside it carries its own surface,
                        // known from this cell alone, so its top face is
                        // drawn whatever is above. Only a cell filled right
                        // to its ceiling depends on the cell above, and a
                        // bottom face always depends on the cell below,
                        // because the chain fills a cell from its floor.
                        //
                        // Left leaning on nothing, a solid column whose
                        // neighbour above was never sent grew a lid, and a
                        // mapgen chunk is five blocks tall against a summary
                        // area's eight, so a generated chunk under an
                        // ungenerated one put a flat plate across the whole
                        // area at the chunk boundary: the panels seen hanging
                        // in the sky (docs/far-rendering.md, "Lids, layers
                        // and the vertical walk").
                        if (front_filled)
                            continue;
                        const bool leans_on_front = sign < 0 || h_self >= cell;
                        if (leans_on_front && (!front_cell || !(front_cell->flags & LodLevel::kKnown)))
                            continue;
                        fk.lo = 0;
                        fk.hi = (uint8_t)h_self;
                    } else {
                        // A side face spans from where the neighbour's
                        // content stops to where this cell's stops: nothing
                        // where the neighbour is as tall, a step where it is
                        // shorter, the whole cell where it is empty.
                        //
                        // Empty, though, means known to be empty. Unknown is
                        // not air, and at the frontier of what the store and
                        // the summaries have filled it used to read as air:
                        // every filled cell along that frontier grew a side
                        // face, so the far field ended in free standing walls
                        // of terrain, pitch black wherever what stood behind
                        // them was underground and unlit. Nothing is drawn
                        // there now, which is the honest answer and is the
                        // same rule as never inventing terrain: we do not
                        // know that surface exists. The haze closes at that
                        // frontier anyway (docs/far-rendering.md,
                        // "Background, overlay, foreground"), so what is left
                        // is air rather than a hole.
                        //
                        // Top and bottom faces now follow the same rule,
                        // guarded so that a cell carrying its own surface
                        // keeps its top face. See the axis 1 branch above.
                        if (!front_cell || !(front_cell->flags & LodLevel::kKnown))
                            continue;
                        if (h_front >= h_self)
                            continue;
                        fk.lo = (uint8_t)h_front;
                        fk.hi = (uint8_t)h_self;
                        if (fk.lo != 0 || fk.hi != cell)
                            fk.row = (uint16_t)(1 + (u_is_vertical ? u : v));
                    }
                    const content_t content = c->face[d];
                    if (content == CONTENT_AIR || content == CONTENT_IGNORE)
                        continue;
                    const LodTileCache::Entry &te = tileFor(tiles, ndef, tsrc, materials, content, d);
                    fk.texture_id = te.texture_id;
                    fk.layer = te.layer;
                    fk.block_id = te.block_id;
                    fk.liquid = te.liquid;
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
                    const LodLevel::Cell *front = front_cell;
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
                    if (fk.row)
                        ++out.partial;
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

                    // w and h are cells; nodes is what the UV switch below
                    // repeats the tile in, so this is the repeat count a
                    // panel drawn from this quad actually shows.
                    out.max_span = std::max(out.max_span, std::max(w, h) * cell);

                    // The quad, Luanti node coordinates relative to the region
                    // origin: the face plane along the axis, u and v spans.
                    int lo[3], hi[3];
                    lo[axis] = hi[axis] = (sign > 0 ? s + 1 : s) * cell;
                    lo[ua] = u * cell;
                    hi[ua] = (u + w) * cell;
                    lo[va] = v * cell;
                    hi[va] = (v + h) * cell;
                    // The vertical span the face keys carry: a top face sits
                    // at the height the content reaches, a side face spans
                    // from the neighbour's height to this cell's. A full
                    // height face keeps the merged extent it was given.
                    if (axis == 1) {
                        if (sign > 0)
                            lo[1] = hi[1] = s * cell + key.hi;
                    } else if (key.lo != 0 || key.hi != cell) {
                        const int vax = u_is_vertical ? ua : va;
                        const int vcell = u_is_vertical ? u : v;
                        lo[vax] = vcell * cell + key.lo;
                        hi[vax] = vcell * cell + key.hi;
                    }
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
                    LodSurface &sf = surfaceFor(key.texture_id, key.liquid);
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
