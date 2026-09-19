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

LodTopSample lodHorizonTop(const BlockLodChain &chain) {
    LodTopSample out;
    auto offer = [&](int height, content_t content, uint8_t param2) {
        if (height > out.height && content != CONTENT_AIR && content != CONTENT_IGNORE)
            out = {height, content, param2};
    };
    auto sample = [&](const LodLevel::Cell &c, int y, int cell) {
        const bool liquid = (c.flags & LodLevel::kLiquid) != 0;
        const int water_top = y * cell + (c.liquid_top > 0 ? c.liquid_top : cell);
        // A mixed summary cell can contain both seabed and water. Its solid
        // envelope is not evidence of land above the separate water surface.
        if (liquid)
            offer(water_top, c.liquid, c.liquid_param2);
        if (c.flags & LodLevel::kFilled) {
            int top = y * cell + (c.top > 0 ? c.top : cell);
            if (liquid)
                top = std::min(top, water_top);
            offer(top, c.face[0], c.param2[0]);
        }
    };
    if (chain.fine_available) {
        // Exposed tops survive boundary compaction, including liquid tops.
        for (const auto &record : chain.fine_records)
            sample(record.cell, (record.index / MAP_BLOCKSIZE) % MAP_BLOCKSIZE, 1);
        return out;
    }
    for (const LodLevel &level : chain.level) {
        if (!level.built())
            continue;
        for (int y = level.n - 1; y >= 0; --y) {
            for (int z = 0; z < level.n; ++z)
                for (int x = 0; x < level.n; ++x)
                    sample(level.at(x, y, z), y, level.cell);
            if (out.height > 0)
                break;
        }
        break;
    }
    return out;
}

float lodDetailRadius(float configured_nodes, float focal_pixels) {
    // Five pixels per node at the full-detail boundary. The first two-node
    // approximation then spans ten pixels, including its small features.
    return std::min(configured_nodes, std::max(32.0f, focal_pixels / 5.0f));
}

int lodProjectedTier(v3f relative_block_centre, int current, bool live,
        float configured_nodes, float focal_pixels) {
    if (configured_nodes <= 0.0f)
        return 0;
    // Distance to the block bounds includes altitude. Preserve full detail
    // at close boundaries even when the block centre is further away.
    const float half = 0.5f * MAP_BLOCKSIZE;
    const v3f delta(std::max(0.0f, std::fabs(relative_block_centre.X) - half),
            std::max(0.0f, std::fabs(relative_block_centre.Y) - half),
            std::max(0.0f, std::fabs(relative_block_centre.Z) - half));
    const float distance = delta.getLength();
    const float first = lodDetailRadius(configured_nodes, focal_pixels);
    // Full near meshes and cached node-detail meshes have separate ranges.
    // Keep the latter while a node is still visibly larger than a pixel;
    // the old five-pixel boundary discarded trunks and crown openings early.
    const float fine = std::max(first, std::min(configured_nodes * 2.0f,
            std::max(32.0f, focal_pixels / 1.5f)));
    auto threshold = [&](int tier) {
        return tier == 1 ? first : fine * (float)(1 << (tier - 2));
    };
    int desired = live && distance <= first ? 0 : 1;
    for (int tier = 2; tier <= BlockLodChain::kLevels; ++tier)
        if (distance > threshold(tier))
            desired = tier;
    // The return threshold is inside the outward threshold. It applies at
    // the near join too, so hovering there cannot alternate representations.
    if (current >= 1 && current <= BlockLodChain::kLevels && desired < current &&
            distance > 0.85f * threshold(current))
        return current;
    return desired;
}

// How many bits are set in a 64 bit word.
//
// __builtin_popcountll is a GCC and Clang extension and MSVC does not have
// it, which is what broke the Windows build: "error C3861:
// '__builtin_popcountll': identifier not found". std::popcount would be the
// answer but it is C++20 and this is C++17 (CMakeLists.txt). The fallback is
// the usual SWAR count rather than MSVC's __popcnt64, because that intrinsic
// needs a CPU with the POPCNT instruction and silently returns nonsense
// where there is none; this is correct everywhere and the sparse boundary
// lookup that calls it is not hot enough to care.
static inline int popcount64(uint64_t v) {
#if defined(__GNUC__) || defined(__clang__)
    return __builtin_popcountll(v);
#else
    v = v - ((v >> 1) & 0x5555555555555555ull);
    v = (v & 0x3333333333333333ull) + ((v >> 2) & 0x3333333333333333ull);
    v = (v + (v >> 4)) & 0x0f0f0f0f0f0f0f0full;
    return (int)((v * 0x0101010101010101ull) >> 56);
#endif
}

// Luanti's tile order, which is also the face order here: +Y, -Y, +X, -X,
// +Z, -Z. Luanti coordinates; the z mirror happens when a vertex is emitted.
static const int DIRS[6][3] = {{0, 1, 0}, {0, -1, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}};

// Project the occupied children onto a face. Each column votes with its
// outermost material; a buried opaque trunk must not repaint a leafy crown.
// Keep content and palette index together, and resolve equal areas in a
// stable scan order. Occupancy and lighting are reduced independently.
template <typename Sample>
static void reduceFace(int edge, int face, Sample sample,
        content_t &content, uint8_t &param2) {
    struct Vote { content_t content; uint8_t param2; int count; };
    std::array<Vote, MAP_BLOCKSIZE * MAP_BLOCKSIZE> votes;
    int count = 0;
    for (int v = 0; v < edge; ++v)
        for (int u = 0; u < edge; ++u)
            for (int depth = 0; depth < edge; ++depth) {
                const int along = face % 2 ? depth : edge - 1 - depth;
                const int x = face < 2 ? u : face < 4 ? along : u;
                const int y = face < 2 ? along : v;
                const int z = face < 2 ? v : face < 4 ? u : along;
                content_t c = CONTENT_AIR;
                uint8_t p2 = 0;
                if (!sample(x, y, z, c, p2))
                    continue;
                int i = 0;
                while (i < count && (votes[i].content != c || votes[i].param2 != p2))
                    ++i;
                if (i == count)
                    votes[count++] = {c, p2, 0};
                ++votes[i].count;
                break;
            }
    int best = 0;
    for (int i = 0; i < count; ++i)
        if (votes[i].count >= best) {
            content = votes[i].content;
            param2 = votes[i].param2;
            best = votes[i].count;
        }
}

int BlockLodChain::levelForCell(int cell) {
    switch (cell) {
    case 1: return 0;
    case 2: return 1;
    case 4: return 2;
    case 8: return 3;
    case 16: return 4;
    default: return -1;
    }
}

const LodLevel::Cell *BlockLodChain::cellAt(int cell, int x, int y, int z) const {
    if (cell != 1) {
        const LodLevel *lv = forCell(cell);
        return lv ? &lv->at(x, y, z) : nullptr;
    }
    if (!fine_available) {
        const LodLevel *lv = forCell(1);
        return lv ? &lv->at(x, y, z) : nullptr;
    }
    if (x < 0 || y < 0 || z < 0 || x >= MAP_BLOCKSIZE || y >= MAP_BLOCKSIZE ||
            z >= MAP_BLOCKSIZE)
        return nullptr;
    const uint16_t index = (uint16_t)(((size_t)z * MAP_BLOCKSIZE + y) * MAP_BLOCKSIZE + x);
    const unsigned word = index >> 6, bit = index & 63;
    const uint64_t mask = fine_record_mask[word];
    if (!(mask & (1ull << bit)))
        return nullptr;
    const uint64_t below = bit ? mask & ((1ull << bit) - 1) : 0;
    const size_t record = fine_record_base[word] + (size_t)popcount64(below);
    return record < fine_records.size() ? &fine_records[record].cell : nullptr;
}

bool BlockLodChain::filledAt(int cell, int x, int y, int z) const {
    if (cell != 1) {
        const LodLevel::Cell *c = cellAt(cell, x, y, z);
        return c && (c->flags & LodLevel::kFilled);
    }
    if (!fine_available) {
        const LodLevel::Cell *c = cellAt(1, x, y, z);
        return c && (c->flags & LodLevel::kFilled);
    }
    if (x < 0 || y < 0 || z < 0 || x >= MAP_BLOCKSIZE || y >= MAP_BLOCKSIZE ||
            z >= MAP_BLOCKSIZE)
        return false;
    const size_t index = ((size_t)z * MAP_BLOCKSIZE + y) * MAP_BLOCKSIZE + x;
    return (fine_filled[index >> 6] & (1ull << (index & 63))) != 0;
}

bool BlockLodChain::liquidAt(int cell, int x, int y, int z) const {
    const LodLevel::Cell *c = cellAt(cell, x, y, z);
    return c && (c->flags & LodLevel::kLiquid);
}

bool BlockLodChain::occludesAt(int cell, int x, int y, int z) const {
    if (cell != 1) {
        const LodLevel::Cell *c = cellAt(cell, x, y, z);
        return c && (c->flags & LodLevel::kOccludes);
    }
    if (!fine_available) {
        const LodLevel::Cell *c = cellAt(1, x, y, z);
        return c && (c->flags & LodLevel::kOccludes);
    }
    if (x < 0 || y < 0 || z < 0 || x >= MAP_BLOCKSIZE || y >= MAP_BLOCKSIZE ||
            z >= MAP_BLOCKSIZE)
        return false;
    const size_t index = ((size_t)z * MAP_BLOCKSIZE + y) * MAP_BLOCKSIZE + x;
    return (fine_occludes[index >> 6] & (1ull << (index & 63))) != 0;
}

// ---------------------------------------------------------------------------
// The chain

namespace {

struct NodeInfo {
    content_t c = CONTENT_AIR;
    uint8_t p2 = 0, day = 0, night = 0, flags = 0;
};
enum : uint8_t { nSolid = 1, nFilled = 2, nLit = 4, nKnown = 8, nLiquid = 16 };

struct ContentClass {
    uint8_t flags = 0;
    uint8_t glow = 0; // decoded light_source
    ContentLightingFlags lf;
};

} // namespace

bool lodIsVegetation(const NodeDefManager *ndef, content_t c) {
    static const char *const groups[] = {"tree", "leaves", "cactus", "bamboo", "plant", "flora",
            "sapling", "flower", "mushroom", "fruit", "vines"};
    if (!ndef || c == CONTENT_AIR || c == CONTENT_IGNORE)
        return false;
    const ContentFeatures &f = ndef->get(c);
    for (const char *group : groups)
        if (itemgroup_get(f.groups, group) > 0)
            return true;
    return false;
}

void buildLodChain(const NodeDefManager *ndef, MapBlock *block, BlockLodChain &out, int min_level) {
    const int N = MAP_BLOCKSIZE;
    for (LodLevel &lv : out.level)
        lv = LodLevel();
    out.fine_available = false;
    out.fine_filled.fill(0);
    out.fine_occludes.fill(0);
    out.fine_record_mask.fill(0);
    out.fine_record_base.fill(0);
    out.fine_records.clear();
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
        // Airlike is authoritative: technical nodes such as Mineclonia's
        // barriers may carry inventory/PBR images but never have world faces.
        const bool visible = f.drawtype != NDT_AIRLIKE;
        const bool solid = visible && f.visuals && f.visuals->solidness == 2;
        // Filled is what draws: a full solid node, anything that looks like a
        // cube (leaves, glass, allfaces: solidness 0, visual_solidness 1, the
        // way node_visuals.cpp classes them) and a liquid, so the sea is a
        // surface and not a hole. Leaves matter more than anything: a forest
        // at range is its canopy, and without them a jungle meshed as the log
        // tops the trunks were standing on. Only solid blocks light, the same
        // rule as the near field in goanna_light.cpp.
        const bool filled = visible && (solid ||
                (f.visuals && f.visuals->visual_solidness >= 1) || f.isLiquid());
        const bool lit = f.param_type == CPT_LIGHT && !solid;
        cc.flags = nKnown | (solid ? nSolid : 0) | (filled ? nFilled : 0) |
                (lit ? nLit : 0) | (f.isLiquid() ? nLiquid : 0);
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

    // Build only the finest requested level from nodes. Coarser levels are
    // recursive 2x2x2 mips of it, exactly like summary-derived chains.
    LodLevel &base = out.level[min_level];
    base.cell = BlockLodChain::cellForLevel(min_level);
    base.n = N / base.cell;
    const int cell = base.cell, n = base.n;
    base.cells.assign((size_t)n * n * n, LodLevel::Cell());
    base.terrain.clear();
    for (int cz = 0; cz < n; ++cz)
        for (int cy = 0; cy < n; ++cy)
            for (int cx = 0; cx < n; ++cx) {
                LodLevel::Cell &dst = base.cells[((size_t)cz * n + cy) * n + cx];
                const NodeInfo *chosen = nullptr, *chosen_liquid = nullptr;
                int chosen_score = -1, known = 0, lit = 0, liquid_top = 0;
                int filled = 0;
                uint8_t day = 0, night = 0;
                const int x0 = cx * cell, y0 = cy * cell, z0 = cz * cell;
                // Track opaque occupancy independently of the visible face
                // materials chosen below. A buried solid still blocks light.
                for (int z = z0; z < z0 + cell; ++z)
                    for (int y = y0; y < y0 + cell; ++y)
                        for (int x = x0; x < x0 + cell; ++x) {
                            const NodeInfo &ni = info[((size_t)z * N + y) * N + x];
                            if (!(ni.flags & nKnown))
                                continue;
                            ++known;
                            if (ni.flags & nLit) {
                                ++lit;
                                day = std::max(day, ni.day);
                                night = std::max(night, ni.night);
                            }
                            if (!(ni.flags & nFilled))
                                continue;
                            ++filled;
                            if (ni.flags & nLiquid) {
                                liquid_top = std::max(liquid_top, y - y0 + 1);
                                chosen_liquid = &ni;
                                continue;
                            }
                            const int score = (ni.flags & nSolid) ? 2 : 1;
                            if (score >= chosen_score) {
                                chosen = &ni;
                                chosen_score = score;
                            }
                        }
                if (!known)
                    continue;
                dst.flags = LodLevel::kKnown | (lit ? LodLevel::kLit : 0);
                if (lit) {
                    dst.day = day;
                    dst.night = night;
                }
                if (chosen_liquid) {
                    dst.flags |= LodLevel::kLiquid;
                    dst.liquid = chosen_liquid->c;
                    dst.liquid_param2 = chosen_liquid->p2;
                    if (liquid_top > 0 && liquid_top < cell)
                        dst.liquid_top = (uint8_t)liquid_top;
                }
                if (chosen) {
                    dst.flags |= LodLevel::kFilled;
                    if (chosen->flags & nSolid)
                        dst.flags |= LodLevel::kOccludes;
                    for (int d = 0; d < 6; ++d) {
                        if (cell == 1) {
                            dst.face[d] = chosen->c;
                            dst.param2[d] = chosen->p2;
                            continue;
                        }
                        reduceFace(cell, d, [&](int x, int y, int z, content_t &c, uint8_t &p2) {
                            const NodeInfo &ni = info[((size_t)(z0 + z) * N + y0 + y) * N + x0 + x];
                            if (!(ni.flags & nFilled) || (ni.flags & nLiquid)) return false;
                            c = ni.c;
                            p2 = ni.p2;
                            return true;
                        }, dst.face[d], dst.param2[d]);
                    }
                    // Against the cell's whole volume, not against the nodes
                    // that happened to be known: a cell half outside a loaded
                    // block is half empty as far as anything drawing it knows.
                    const int volume = cell * cell * cell;
                    dst.coverage = (uint8_t)std::min(255, (filled * 255 + volume / 2) / volume);
                }
                // Non-liquids and a liquid filling the cell keep top=0: the
                // voxel occupies its complete cell, including its lower face.
            }
    buildLodMipLevels(out, min_level);
    buildLodTerrainSurface(ndef, out, min_level);
    if (cell == 1)
        compactLodFineBoundary(out);
}

void buildLodMipLevels(BlockLodChain &out, int first_level) {
    first_level = std::clamp(first_level, 0, BlockLodChain::kLevels - 1);
    const LodLevel &material_source = out.level[first_level];
    for (int level = first_level + 1; level < BlockLodChain::kLevels; ++level) {
        const LodLevel &src = out.level[level - 1];
        if (!src.built())
            break;
        LodLevel &dst = out.level[level];
        dst.cell = src.cell * 2;
        dst.n = src.n / 2;
        dst.cells.assign((size_t)dst.n * dst.n * dst.n, LodLevel::Cell());
        dst.terrain.clear();
        for (int z = 0; z < dst.n; ++z)
            for (int y = 0; y < dst.n; ++y)
                for (int x = 0; x < dst.n; ++x) {
                    LodLevel::Cell &coarse = dst.cells[((size_t)z * dst.n + y) * dst.n + x];
                    const LodLevel::Cell *chosen = nullptr, *chosen_liquid = nullptr;
                    int chosen_score = -1, chosen_liquid_top = -1, known = 0, lit = 0;
                    int coverage_sum = 0;
                    uint8_t day = 0, night = 0;
                    for (int dz = 0; dz < 2; ++dz)
                        for (int dy = 0; dy < 2; ++dy)
                            for (int dx = 0; dx < 2; ++dx) {
                                const LodLevel::Cell &c = src.at(x * 2 + dx, y * 2 + dy, z * 2 + dz);
                                if (!(c.flags & LodLevel::kKnown))
                                    continue;
                                ++known;
                                if (c.flags & LodLevel::kLit) {
                                    ++lit;
                                    day = std::max(day, c.day);
                                    night = std::max(night, c.night);
                                }
                                if (c.flags & LodLevel::kLiquid) {
                                    const int child_top = c.liquid_top > 0 ? c.liquid_top : src.cell;
                                    const int liquid_top = dy * src.cell + child_top;
                                    if (liquid_top >= chosen_liquid_top) {
                                        chosen_liquid = &c;
                                        chosen_liquid_top = liquid_top;
                                    }
                                }
                                coverage_sum += c.coverage;
                                if (c.flags & LodLevel::kFilled) {
                                    const int score = (c.flags & LodLevel::kOccludes) ? 2 : 1;
                                    if (score >= chosen_score) {
                                        chosen = &c;
                                        chosen_score = score;
                                    }
                                }
                            }
                    if (!known)
                        continue;
                    coarse.flags = LodLevel::kKnown | (lit ? LodLevel::kLit : 0);
                    if (lit) {
                        coarse.day = day;
                        coarse.night = night;
                    }
                    if (chosen_liquid) {
                        coarse.flags |= LodLevel::kLiquid;
                        coarse.liquid = chosen_liquid->liquid;
                        coarse.liquid_param2 = chosen_liquid->liquid_param2;
                        coarse.liquid_top = chosen_liquid_top < dst.cell ?
                                (uint8_t)chosen_liquid_top : 0;
                    }
                    if (chosen) {
                        for (int d = 0; d < 6; ++d) {
                            // Vote from the finest available surface. Voting
                            // repeatedly on winners exaggerates thin borders
                            // until they consume a whole face at the last mip.
                            const int edge = dst.cell / material_source.cell;
                            reduceFace(edge, d, [&](int dx, int dy, int dz, content_t &content, uint8_t &p2) {
                                const auto &c = material_source.at(x * edge + dx, y * edge + dy, z * edge + dz);
                                if ((c.flags & (LodLevel::kKnown | LodLevel::kFilled)) !=
                                        (LodLevel::kKnown | LodLevel::kFilled)) return false;
                                content = c.face[d];
                                p2 = c.param2[d];
                                return true;
                            }, coarse.face[d], coarse.param2[d]);
                        }
                        coarse.flags |= LodLevel::kFilled;
                        if (chosen->flags & LodLevel::kOccludes)
                            coarse.flags |= LodLevel::kOccludes;
                        // Mean over the children that are known. An unknown
                        // child is not evidence of sky, so it neither fills
                        // the parent nor thins it: leaving it out of the
                        // divisor keeps a half streamed crown as dense as the
                        // half that has arrived, and it fills in as it does.
                        coarse.coverage = (uint8_t)std::min(255,
                                (coverage_sum + known / 2) / std::max(1, known));
                    }
                }
    }
}

void buildLodTerrainSurface(const NodeDefManager *ndef, BlockLodChain &out, int first_level) {
    first_level = std::clamp(first_level, 0, BlockLodChain::kLevels - 1);
    for (int level = first_level; level < BlockLodChain::kLevels; ++level) {
        LodLevel &lv = out.level[level];
        if (!lv.built())
            continue;
        // The exact cell-1 level is compacted to sparse boundary records, and
        // the surface pass needs random access to the dense level. It is also
        // already exact, so replacing it with a height surface buys nothing.
        if (lv.cell == 1) {
            lv.terrain.clear();
            continue;
        }
        for (LodLevel::Cell &c : lv.cells)
            c.flags &= ~LodLevel::kTerrain;
        lv.terrain.assign((size_t)lv.n * lv.n, 0);
        for (int z = 0; z < lv.n; ++z)
            for (int x = 0; x < lv.n; ++x) {
                int top = 0;
                for (int y = 0; y < lv.n; ++y) {
                    LodLevel::Cell &c = lv.at(x, y, z);
                    // Only a solid run rooted at the block floor is ground.
                    // Air ends the run; anything above it remains a box, so
                    // an island or bridge cannot drape a terrain sheet down
                    // to the valley below. Vegetation ends it too, keeping a
                    // trunk from raising the land to its canopy.
                    if (!(c.flags & LodLevel::kKnown) || !(c.flags & LodLevel::kFilled) ||
                            lodIsVegetation(ndef, c.face[0])) {
                        if (out.surface_shell)
                            continue;
                        break;
                    }
                    c.flags |= LodLevel::kTerrain;
                    const int within = c.top > 0 && c.top < lv.cell ? c.top : lv.cell;
                    top = y * lv.cell + within;
                }
                lv.terrain[(size_t)z * lv.n + x] = (uint8_t)top;
            }
    }
}

void compactLodFineBoundary(BlockLodChain &out) {
    LodLevel &base = out.level[BlockLodChain::levelForCell(1)];
    if (base.cell != 1 || base.n != MAP_BLOCKSIZE || base.cells.empty())
        return;
    out.fine_filled.fill(0);
    out.fine_occludes.fill(0);
    out.fine_record_mask.fill(0);
    out.fine_record_base.fill(0);
    out.fine_records.clear();
    std::array<uint8_t, MAP_BLOCKSIZE * MAP_BLOCKSIZE * MAP_BLOCKSIZE> keep{};
    auto index_of = [&](int x, int y, int z) {
        return ((size_t)z * MAP_BLOCKSIZE + y) * MAP_BLOCKSIZE + x;
    };
    for (int z = 0; z < MAP_BLOCKSIZE; ++z)
        for (int y = 0; y < MAP_BLOCKSIZE; ++y)
            for (int x = 0; x < MAP_BLOCKSIZE; ++x) {
                const size_t index = index_of(x, y, z);
                const LodLevel::Cell &c = base.cells[index];
                if (!(c.flags & (LodLevel::kFilled | LodLevel::kLiquid)))
                    continue;
                if (c.flags & LodLevel::kFilled) {
                    out.fine_filled[index >> 6] |= 1ull << (index & 63);
                    if (c.flags & LodLevel::kOccludes)
                        out.fine_occludes[index >> 6] |= 1ull << (index & 63);
                }
                bool exposed = false;
                for (const auto &dir : DIRS) {
                    const int nx = x + dir[0], ny = y + dir[1], nz = z + dir[2];
                    if (nx < 0 || ny < 0 || nz < 0 || nx >= MAP_BLOCKSIZE ||
                            ny >= MAP_BLOCKSIZE || nz >= MAP_BLOCKSIZE) {
                        exposed = true;
                        break;
                    }
                    const uint8_t neighbour = base.at(nx, ny, nz).flags;
                    if ((c.flags & LodLevel::kFilled) && !(neighbour & LodLevel::kFilled)) {
                        exposed = true;
                        break;
                    }
                    if ((c.flags & LodLevel::kLiquid) && !(neighbour & LodLevel::kLiquid)) {
                        exposed = true;
                        break;
                    }
                }
                if (!exposed)
                    continue;
                keep[index] = 1;
                for (const auto &dir : DIRS) {
                    const int nx = x + dir[0], ny = y + dir[1], nz = z + dir[2];
                    if (nx >= 0 && ny >= 0 && nz >= 0 && nx < MAP_BLOCKSIZE &&
                            ny < MAP_BLOCKSIZE && nz < MAP_BLOCKSIZE)
                        keep[index_of(nx, ny, nz)] = 1;
                }
            }
    out.fine_records.reserve((size_t)std::count(keep.begin(), keep.end(), (uint8_t)1));
    uint16_t record_count = 0;
    for (size_t i = 0; i < base.cells.size(); ++i) {
        if ((i & 63) == 0)
            out.fine_record_base[i >> 6] = record_count;
        if (keep[i]) {
            out.fine_record_mask[i >> 6] |= 1ull << (i & 63);
            out.fine_records.push_back({(uint16_t)i, base.cells[i]});
            ++record_count;
        }
    }
    out.fine_available = true;
    base.cells.clear();
    base.cells.shrink_to_fit();
}

// ---------------------------------------------------------------------------
// The region mesher

void LodRegionSnapshot::reset(v3s16 origin_, int blocks_, int margin_) {
    origin = origin_;
    blocks = std::max(1, blocks_);
    margin = std::max(0, margin_);
    const size_t e = (size_t)edge();
    entries.assign(e * e * e, Entry());
}

LodRegionSnapshot::Entry *LodRegionSnapshot::at(v3s16 bp) {
    const LodRegionSnapshot *self = this;
    return const_cast<Entry *>(self->at(bp));
}

const LodRegionSnapshot::Entry *LodRegionSnapshot::at(v3s16 bp) const {
    const int e = edge();
    const int x = bp.X - origin.X + margin;
    const int y = bp.Y - origin.Y + margin;
    const int z = bp.Z - origin.Z + margin;
    if (x < 0 || y < 0 || z < 0 || x >= e || y >= e || z >= e)
        return nullptr;
    return &entries[((size_t)z * e + y) * e + x];
}

void LodRegionSnapshot::bind(LodRegionSpec &spec) const {
    const int cell = spec.cell;
    spec.chain = [this](v3s16 bp) -> const BlockLodChain * {
        const Entry *e = at(bp);
        return e ? e->chain.get() : nullptr;
    };
    spec.drawn_cell = [this](v3s16 bp) -> int {
        const Entry *e = at(bp);
        return e ? e->drawn_cell : -1;
    };
    // The live build tests region membership and the drawn cell together,
    // because one capture serves both the exact and the fallback pass and
    // only the cell tells them apart.
    spec.member = [this, cell](v3s16 bp) -> bool {
        const Entry *e = at(bp);
        return e && e->member && e->drawn_cell == cell;
    };
}

int lodRegionMarginBlocks(int cell, float ao_radius) {
    if (cell < 1)
        return 1;
    const int cpb = MAP_BLOCKSIZE / cell; // cells per block
    const int margin_cells = ao_radius > 0.0f ? (int)std::ceil(ao_radius / cell) : 0;
    return std::max(1, (margin_cells + cpb - 1) / cpb);
}

namespace {

// The tile behind (content, side), resolved once.
//
// Runs on a mesh worker, so the cache and the texture source calls that fill
// it are both under cache.mutex. Nothing here creates a Godot object: the
// texture source is asked only for an id, a name, an average colour and its
// GoannaTexture wrapper, and the Godot side texture is made separately, on
// the main thread, on first use (goanna_textures.h). Returns a copy so a
// clear on the main thread cannot pull the entry out from under the caller.
LodTileCache::Entry tileFor(LodTileCache &cache, const NodeDefManager *ndef,
        GoannaTextureSource *tsrc, const MaterialTable *materials, content_t c, int side) {
    const u32 key = (u32)c * 6 + side;
    std::lock_guard<std::mutex> cache_lock(cache.mutex);
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
        else if (tid) {
            // Static liquids can share an array with ordinary terrain. The
            // water/lava shaders require this layer's own 2D image, just as
            // the near material resolver does for special liquid shaders.
            const std::string name = tsrc->imageName(tid, l.texture_layer_idx);
            if (!name.empty())
                tid = tsrc->getTextureId(name);
        }
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
                // An animated tile the near mesh draws from an animation
                // array: the far tiers draw it from the same array and
                // layer, so it is textured and keeps moving past the near
                // range instead of turning into its first frame's average
                // colour at the hand-off. The table is built before any
                // block is meshed and never changes, so a worker may read it.
                const NodeAnimation *anim = tsrc->nodeAnimation(l.texture_id);
                if (anim && anim->array_id) {
                    e.texture_id = anim->array_id;
                    e.layer = anim->base_layer;
                }
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
    const int mb = lodRegionMarginBlocks(cell, spec.ao_radius);
    const int B = spec.blocks + 2 * mb;
    std::vector<const BlockLodChain *> chains((size_t)B * B * B, nullptr);
    std::vector<const LodLevel *> levels((size_t)B * B * B, nullptr);
    std::vector<uint8_t> member((size_t)B * B * B, 0);
    std::vector<uint8_t> stored((size_t)B * B * B, 0);
    std::vector<int> drawn((size_t)B * B * B, -1);
    for (int bz = 0; bz < B; ++bz)
        for (int by = 0; by < B; ++by)
            for (int bx = 0; bx < B; ++bx) {
                v3s16 bp = spec.origin + v3s16(bx - mb, by - mb, bz - mb);
                const BlockLodChain *ch = spec.chain(bp);
                const size_t i = ((size_t)bz * B + by) * B + bx;
                chains[i] = ch;
                levels[i] = ch ? ch->forCell(cell) : nullptr;
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
        const BlockLodChain *ch = chains[((size_t)bz * B + by) * B + bx];
        if (!ch || !ch->hasCell(cell))
            return nullptr;
        const int lx = (gx + mb * cpb) % cpb, ly = (gy + mb * cpb) % cpb, lz = (gz + mb * cpb) % cpb;
        return ch->cellAt(cell, lx, ly, lz);
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
    // Whether the geometry actually drawn in another block covers this
    // point. Reading `levels` alone is wrong at a tier boundary: it tests an
    // unused mip of the neighbour, which can say occupied because of a child
    // deeper inside the coarse voxel while the fine cells touching this face
    // are air. That suppresses our face and opens a strip between tiers.
    auto renderedFilledAtNode = [&](int nx, int ny, int nz) -> bool {
        const int sx = nx + mb * MAP_BLOCKSIZE;
        const int sy = ny + mb * MAP_BLOCKSIZE;
        const int sz = nz + mb * MAP_BLOCKSIZE;
        if (sx < 0 || sy < 0 || sz < 0)
            return false;
        const int bx = sx / MAP_BLOCKSIZE, by = sy / MAP_BLOCKSIZE, bz = sz / MAP_BLOCKSIZE;
        if (bx >= B || by >= B || bz >= B)
            return false;
        const size_t bi = ((size_t)bz * B + by) * B + bx;
        const int dc = drawn[bi];
        const BlockLodChain *ch = chains[bi];
        if (!ch || dc <= 0 || !ch->hasCell(dc))
            return false;
        const int lx = (sx % MAP_BLOCKSIZE) / dc;
        const int ly = (sy % MAP_BLOCKSIZE) / dc;
        const int lz = (sz % MAP_BLOCKSIZE) / dc;
        return ch->filledAt(dc, lx, ly, lz);
    };
    auto renderedLiquidAtNode = [&](int nx, int ny, int nz) -> bool {
        const int sx = nx + mb * MAP_BLOCKSIZE;
        const int sy = ny + mb * MAP_BLOCKSIZE;
        const int sz = nz + mb * MAP_BLOCKSIZE;
        if (sx < 0 || sy < 0 || sz < 0)
            return false;
        const int bx = sx / MAP_BLOCKSIZE, by = sy / MAP_BLOCKSIZE, bz = sz / MAP_BLOCKSIZE;
        if (bx >= B || by >= B || bz >= B)
            return false;
        const size_t bi = ((size_t)bz * B + by) * B + bx;
        const int dc = drawn[bi];
        const BlockLodChain *ch = chains[bi];
        if (!ch || dc <= 0 || !ch->hasCell(dc))
            return false;
        return ch->liquidAt(dc, (sx % MAP_BLOCKSIZE) / dc, (sy % MAP_BLOCKSIZE) / dc,
                (sz % MAP_BLOCKSIZE) / dc);
    };
    // liquid_covers: whether a liquid voxel counts as covering the face.
    // True keeps water culling water, which is what stops every internal
    // cell boundary of a sea from drawing. False is for a solid face: water
    // is drawn transparent, so a sea floor culled against the sea above it
    // left every water body bottomless, blue over the void.
    auto renderedFaceCovered = [&](const int g[3], int d, bool liquid_covers) -> bool {
        const int axis = DIRS[d][0] ? 0 : (DIRS[d][1] ? 1 : 2);
        const int ua = axis == 0 ? 1 : 0;
        const int va = axis == 2 ? 1 : 2;
        int centre[3] = {g[0] * cell + cell / 2, g[1] * cell + cell / 2,
                g[2] * cell + cell / 2};
        centre[axis] = DIRS[d][axis] > 0 ? (g[axis] + 1) * cell : g[axis] * cell - 1;

        const int sx = centre[0] + mb * MAP_BLOCKSIZE;
        const int sy = centre[1] + mb * MAP_BLOCKSIZE;
        const int sz = centre[2] + mb * MAP_BLOCKSIZE;
        if (sx < 0 || sy < 0 || sz < 0)
            return false;
        const int bx = sx / MAP_BLOCKSIZE, by = sy / MAP_BLOCKSIZE, bz = sz / MAP_BLOCKSIZE;
        if (bx >= B || by >= B || bz >= B)
            return false;
        const int dc = drawn[((size_t)bz * B + by) * B + bx];
        if (dc <= 0)
            return false;

        // A coarse face may touch several finer voxels. Cull it only if all
        // of them cover the interface; otherwise a full boundary face is the
        // conservative, closed-volume transition until a split transition
        // mesh is warranted.
        const int step = std::min(cell, dc);
        for (int v = step / 2; v < cell; v += step)
            for (int u = step / 2; u < cell; u += step) {
                int p[3] = {centre[0], centre[1], centre[2]};
                p[ua] = g[ua] * cell + u;
                p[va] = g[va] * cell + v;
                if (!renderedFilledAtNode(p[0], p[1], p[2]))
                    return false;
                if (!liquid_covers && renderedLiquidAtNode(p[0], p[1], p[2]))
                    return false;
            }
        return true;
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
                    const BlockLodChain *ch = chains[((size_t)bz * B + by) * B + bx];
                    if (!ch || !ch->hasCell(cell))
                        continue;
                    for (int z = 0; z < cpb; ++z)
                        for (int y = 0; y < cpb; ++y)
                            for (int x = 0; x < cpb; ++x)
                                if (ch->occludesAt(cell, x, y, z))
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
    // Connected ground surface, recovered from the occupancy hierarchy.
    //
    // The highest connected ground sample supplies each column's surface.
    // Tops remain horizontal and height changes have vertical faces. Joining
    // measured heights with ramps rounded the terrain's voxel ridgelines.
    // Independent liquid envelopes keep water flat and the seabed below it.
    // Each region reads a margin so neighbours can reproduce shared edges.
    //
    // Where a cell's edge does not meet a neighbour that agrees with it, at a
    // hole, the shore, a block drawn at another tier or at full detail, or
    // the edge of what is known, a skirt drops from the edge so nothing is
    // seen under the surface. The ground cells themselves emit no box faces
    // below; the box pass draws only what is not ground, which is the
    // vegetation and anything else the chain could not class as terrain.
    // Only floor-connected ground enters this pass. Other occupancy remains
    // volumetric in the box pass, including cave walls and island undersides.
    //
    // Only the exterior is drawn: buried ground does not need voxel boxes.
    // The silhouette remains stepped even when the interior is simplified.
    bool has_ground_surface = false;
    for (const LodLevel *lv : levels)
        has_ground_surface |= lv && !lv->terrain.empty();
    if (has_ground_surface) {
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
            float water_h = -32768.0f; // independent liquid envelope, if known
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
        // Both sides of a resolution seam must identify the same ground,
        // floating geometry, canopy and water. A second, reduced column
        // reader used to disagree at islands and shallow shores.
        auto readColumn = [&](int gx, int gz, int sample_cell, Column &col) {
            const int samples_per_block = MAP_BLOCKSIZE / sample_cell;
            const int sample_margin = mb * samples_per_block;
            const int bx = (gx + sample_margin) / samples_per_block;
            const int bz = (gz + sample_margin) / samples_per_block;
            const int lx = (gx + sample_margin) % samples_per_block;
            const int lz = (gz + sample_margin) % samples_per_block;
            for (int by = B - 1; by >= 0 && !col.has; --by) {
                const size_t bi = ((size_t)bz * B + by) * B + bx;
                const LodLevel *lv = chains[bi] ? chains[bi]->forCell(sample_cell) : nullptr;
                if (!lv)
                    continue;
                for (int wy = samples_per_block - 1; wy >= 0; --wy) {
                    const LodLevel::Cell &wc = lv->at(lx, wy, lz);
                    if (wc.flags & LodLevel::kLiquid) {
                        const int top = wc.liquid_top > 0 ? wc.liquid_top : sample_cell;
                        col.water_h = std::max(col.water_h,
                                (float)(origin_nodes.Y + (by - mb) * MAP_BLOCKSIZE +
                                        wy * sample_cell + top));
                        break;
                    }
                }
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
                if (sample_cell >= 8) {
                    for (int ty = samples_per_block - 1; ty >= 0 && ty * sample_cell + 1 > th; --ty) {
                        const LodLevel::Cell &vc = lv->at(lx, ty, lz);
                        if ((vc.flags & LodLevel::kFilled) && !(vc.flags & LodLevel::kTerrain) &&
                                lodIsVegetation(ndef, vc.face[0])) {
                            const int within = vc.top > 0 && vc.top < sample_cell ?
                                    vc.top : sample_cell;
                            const int vh = ty * sample_cell + within;
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
                if (!canopy && th < MAP_BLOCKSIZE && by > 0 &&
                        !(chains[bi] && chains[bi]->surface_shell)) {
                    const size_t below = ((size_t)bz * B + (by - 1)) * B + bx;
                    const LodLevel *lb = chains[below] ? chains[below]->forCell(sample_cell) : nullptr;
                    // Below half, not merely below the ceiling. The coarse
                    // tiers carry the mean of their wire heights, so under
                    // any slope the block below reads a little short of
                    // full, and requiring a full ceiling walked whole
                    // columns of ordinary mountainside into the floating
                    // case until nothing was left to draw: the see
                    // through hills. A real island or overhang has next
                    // to nothing under it and still qualifies.
                    if (lb && lb->terrainAt(lx, lz) * 2 < MAP_BLOCKSIZE) {
                        if (sample_cell == cell)
                            floatAt(bi, lx, lz) = 1;
                        continue;
                    }
                }
                col.has = true;
                col.canopy = canopy;
                col.same = drawn[bi] == sample_cell;
                col.drawn_at = drawn[bi];
                col.own = member[bi] != 0;
                col.is_stored = stored[bi] != 0;
                col.h = (float)(origin_nodes.Y + (by - mb) * MAP_BLOCKSIZE + th);
                if (!canopy && col.water_h > -32768.0f)
                    col.h = std::min(col.h, col.water_h - 0.5f);
                const int ty = (th - 1) / sample_cell;
                col.gy = (by - mb) * samples_per_block + ty;
                col.top = &lv->at(lx, ty, lz);
                col.above = sample_cell == cell ? cellAt(gx, col.gy + 1, gz) : nullptr;
                const content_t tc = col.top->face[0];
                if (tc != CONTENT_AIR && tc != CONTENT_IGNORE) {
                    const ContentFeatures &f = ndef->get(tc);
                    col.water = !canopy && f.isLiquid();
                }
            }
        };
        for (int gz = -margin; gz < n + margin; ++gz)
            for (int gx = -margin; gx < n + margin; ++gx) {
                Column &col = *colAt(gx, gz);
                readColumn(gx, gz, cell, col);
                if (col.canopy)
                    canopy_cols[(size_t)(gz + canopy_margin) * canopy_w +
                            (gx + canopy_margin)] = 1;
            }
        // Read the neighbour at the resolution it actually draws. Heights
        // meet through vertical step faces, never diagonal interpolation.
        auto quadHeights = [&](int gx, int gz, float out[4]) -> bool {
            const Column *c = colAt(gx, gz);
            if (!c || !c->has || !c->same)
                return false;
            std::fill(out, out + 4, c->h);
            return true;
        };
        auto neighbourHeight = [&](int gx, int gz, float &height) -> bool {
            const Column *c = colAt(gx, gz);
            if (!c || !c->has)
                return false;
            height = c->h;
            const int drawn_cell = c->drawn_at;
            if (drawn_cell > 0 && drawn_cell != cell) {
                auto divide = [](int v, int d) { return v >= 0 ? v / d : -((-v + d - 1) / d); };
                const int x0 = divide(gx * cell, drawn_cell);
                const int z0 = divide(gz * cell, drawn_cell);
                const int span = std::max(1, cell / drawn_cell);
                bool found = false;
                for (int z = z0; z < z0 + span; ++z)
                    for (int x = x0; x < x0 + span; ++x) {
                        Column actual;
                        readColumn(x, z, drawn_cell, actual);
                        if (!actual.has)
                            continue;
                        height = found ? std::min(height, actual.h) : actual.h;
                        found = true;
                    }
            }
            return true;
        };
        // How far a skirt drops: to the lowest corner of the neighbour it
        // does not agree with, plus a little, so it covers the step and no
        // more. Three cells of skirt at the coarsest tier were 48 node
        // plates standing on every mountainside (reported as distant hills
        // that "look like dominoes"). Where the neighbour is unknown, one
        // cell, which hides the underside at the frontier from most angles.
        // Detailed neighbours are captured for boundary evidence even
        // though the far pass never owns or draws them. Read their exact
        // column top so an apron cannot end above the real voxel surface.
        auto nearHeight = [&](int nx, int nz, float ref, float &height) {
            const int sx = nx + mb * MAP_BLOCKSIZE;
            const int sz = nz + mb * MAP_BLOCKSIZE;
            if (sx < 0 || sz < 0 || sx >= B * MAP_BLOCKSIZE || sz >= B * MAP_BLOCKSIZE)
                return false;
            const int bx = sx / MAP_BLOCKSIZE, bz = sz / MAP_BLOCKSIZE;
            const int lx = sx % MAP_BLOCKSIZE, lz = sz % MAP_BLOCKSIZE;
            for (int by = B - 1; by >= 0; --by) {
                const size_t bi = ((size_t)bz * B + by) * B + bx;
                const BlockLodChain *ch = chains[bi];
                if (drawn[bi] != 0 || !ch || !ch->hasCell(1))
                    continue;
                for (int y = MAP_BLOCKSIZE - 1; y >= 0; --y) {
                    const float top = (float)(origin_nodes.Y +
                            (by - mb) * MAP_BLOCKSIZE + y + 1);
                    if (top > ref + cell || !ch->filledAt(1, lx, y, lz))
                        continue;
                    const LodLevel::Cell *c = ch->cellAt(1, lx, y, lz);
                    if (c && lodIsVegetation(ndef, c->face[0]))
                        continue;
                    height = top;
                    return true;
                }
            }
            return false;
        };
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
                    col = f.visuals->getColor(f, p2);
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
                    const v3f nrm(0.0f, 1.0f, 0.0f);
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
                // Horizontal top, clockwise seen from above in Godot.
                for (u32 i : {0u, 2u, 1u, 0u, 3u, 2u})
                    sf.idx.push_back(base + i);
                if (!col.canopy && !col.water)
                    out.ground.push_back({origin_nodes.X+gx*cell,origin_nodes.Z+gz*cell,cell,hs[0]});
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
                    float actual_neighbour_height = 0.0f;
                    const bool has_neighbour = neighbourHeight(ngx, ngz, actual_neighbour_height);
                    if (!agree && has_neighbour && colAt(ngx, ngz)->drawn_at > 0 &&
                            std::fabs(actual_neighbour_height - col.h) < 0.01f)
                        agree = true;
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
                    const Column *neighbour = colAt(ngx, ngz);
                    if (neighbour && neighbour->has) {
                        // This includes another resolution and near-owned
                        // ground, which quadHeights deliberately excludes.
                        bottom = std::min(bottom, actual_neighbour_height - cell - 1.0f);
                    }
                    if (neighbour && neighbour->drawn_at == 0) {
                        for (int along = 0; along < cell; ++along) {
                            const int nx = e == 0 ? ngx * cell :
                                    e == 1 ? (ngx + 1) * cell - 1 : gx * cell + along;
                            const int nz = e == 2 ? ngz * cell :
                                    e == 3 ? (ngz + 1) * cell - 1 : gz * cell + along;
                            float height;
                            if (nearHeight(nx, nz, neighbour->h, height))
                                bottom = std::min(bottom, height - 1.0f);
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
                    // +X starts along the same edge direction as the box
                    // mesher and -X starts reversed. After mirroring Z,
                    // +Z starts like the box mesher while -Z is reversed.
                    // The old e==0||e==2 split wound both Z skirts inward,
                    // so back-face culling opened repeated horizontal cracks
                    // through every terraced far hillside.
                    if (e == 0 || e == 3) {
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
                    if (!c)
                        continue;
                    // Liquid is an independent exterior envelope, not filled
                    // transparent volume. Only its upper boundary is emitted;
                    // the ordinary solid pass below remains the seabed and
                    // prevents the water from becoming a portal into caves.
                    bool liquid_face = d == 0 && (c->flags & LodLevel::kLiquid);
                    if (liquid_face) {
                        const LodLevel::Cell *above = cellAt(g[0], g[1] + 1, g[2]);
                        if (above && (above->flags & (LodLevel::kLiquid | LodLevel::kFilled)))
                            liquid_face = false;
                    }
                    const bool solid_face = (c->flags & LodLevel::kFilled) &&
                            !(d == 0 && (c->flags & LodLevel::kLiquid));
                    if (!liquid_face && !solid_face)
                        continue;
                    // Ground is drawn by the exterior pass above, which
                    // already supplies its top and vertical boundary faces.
                    // Except a run with air under it, an overhang or an
                    // island, which the surface pass left for here.
                    if (!liquid_face && (c->flags & LodLevel::kTerrain)) {
                        const int bx = g[0] / cpb + mb, by = g[1] / cpb + mb, bz = g[2] / cpb + mb;
                        const size_t bi = ((size_t)bz * B + by) * B + bx;
                        if (!floatAt(bi, g[0] % cpb, g[2] % cpb))
                            continue;
                    } else if (!liquid_face && canopyAt(g[0], g[2]) &&
                            lodIsVegetation(ndef, c->face[0])) {
                        // Vegetation under a canopy surface is inside the
                        // roof the surface pass drew.
                        continue;
                    }
                    const int fx = g[0] + DIRS[d][0], fy = g[1] + DIRS[d][1], fz = g[2] + DIRS[d][2];
                    const LodLevel::Cell *front_cell = cellAt(fx, fy, fz);
                    // A liquid face keeps liquid-covers-liquid culling (the
                    // inside of a sea is not a stack of internal faces); a
                    // solid face is not covered by the transparent water in
                    // front of it, which is what draws the sea floor and the
                    // underwater risers.
                    const bool front_filled = !liquid_face &&
                            renderedFaceCovered(g, d, (c->flags & LodLevel::kLiquid) != 0);
                    // How high the content actually reaches in each cell.
                    auto height_of = [&](const LodLevel::Cell *cc, bool is_filled) -> int {
                        if (!is_filled)
                            return 0;
                        // A neighbour drawn at another resolution can cover
                        // this face even though it has no cell in `levels`,
                        // which is the current pass's resolution. Such a
                        // covering voxel spans this whole sample.
                        if (!cc)
                            return cell;
                        return cc->top > 0 && cc->top < cell ? (int)cc->top : cell;
                    };
                    const int h_self = liquid_face ?
                            (c->liquid_top > 0 ? (int)c->liquid_top : cell) : height_of(c, true);
                    const int h_front = height_of(front_cell, front_filled);
                    if (axis == 1) {
                        // Emit a boundary face when the neighbour is known
                        // air or unavailable. This mirrors Voxy's section-side
                        // meshing: a partially loaded voxel volume is closed,
                        // then remeshed and culled when its neighbour arrives.
                        // Suppressing the face against unknown left literal
                        // holes through caves, islands, and summary frontiers.
                        if (!liquid_face && front_filled)
                            continue;
                        fk.lo = 0;
                        fk.hi = (uint8_t)h_self;
                    } else {
                        // A side face spans from where the neighbour's
                        // content stops to where this cell's stops: nothing
                        // where the neighbour is as tall, a step where it is
                        // shorter, the whole cell where it is empty.
                        //
                        if (h_front >= h_self)
                            continue;
                        fk.lo = (uint8_t)h_front;
                        fk.hi = (uint8_t)h_self;
                        if (fk.lo != 0 || fk.hi != cell)
                            fk.row = (uint16_t)(1 + (u_is_vertical ? u : v));
                    }
                    const content_t content = liquid_face ? c->liquid : c->face[d];
                    if (content == CONTENT_AIR || content == CONTENT_IGNORE)
                        continue;
                    if (d==0 && cell==1 && !liquid_face && !lodIsVegetation(ndef,content)) {
                        const int bx=g[0]/cpb+mb,by=g[1]/cpb+mb,bz=g[2]/cpb+mb;
                        const auto *ch=chains[((size_t)bz*B+by)*B+bx];
                        const int lx=g[0]%cpb,lz=g[2]%cpb;
                        bool connected=true;
                        for (int y=0;y<=g[1]%cpb;++y) {
                            const auto *below=ch->cellAt(1,lx,y,lz);
                            if (!ch->filledAt(1,lx,y,lz) ||
                                    (below && lodIsVegetation(ndef,below->face[0]))) {
                                connected=false;break;
                            }
                        }
                        if (connected) out.ground.push_back({origin_nodes.X+g[0],
                                origin_nodes.Z+g[2],1,float(origin_nodes.Y+g[1]+h_self)});
                    }
                    const LodTileCache::Entry &te = tileFor(tiles, ndef, tsrc, materials, content,
                            liquid_face ? 0 : d);
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
                            col = f.visuals->getColor(f, liquid_face ? c->liquid_param2 : c->param2[d]);
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
                    // face. Mirroring Luanti Z into Godot Z reverses the two
                    // Z-facing vertex tables relative to the X and Y tables;
                    // giving every direction the same indices wound those
                    // two sides inward, so backface culling made coarse hills
                    // look like stacks of disconnected panels.
                    if (d == 4 || d == 5) {
                        for (u32 i : {0u, 1u, 2u, 0u, 2u, 3u})
                            sf.idx.push_back(base + i);
                    } else {
                        for (u32 i : {0u, 2u, 1u, 0u, 3u, 2u})
                            sf.idx.push_back(base + i);
                    }
                    ++out.quads;
                    u += w;
                }
        }
    }
    return out;
}

LodTileCache::Entry lodSurfaceTile(LodTileCache &cache, const NodeDefManager *ndef,
        GoannaTextureSource *tsrc, const MaterialTable *materials, content_t c, int side, uint8_t param2) {
    auto te = tileFor(cache, ndef, tsrc, materials, c, side);
    const ContentFeatures &cf = ndef->get(c);
    if (!te.tile_has_color && cf.visuals) {
        const video::SColor colour = cf.visuals->getColor(cf, param2);
        te.tint = colour.color | 0xff000000;
    }
    te.fallback = mulColour(te.fallback, te.tint);
    return te;
}

u32 lodFlatColour(LodTileCache &cache, const NodeDefManager *ndef,
        GoannaTextureSource *tsrc, const MaterialTable *materials,
        content_t c, uint8_t param2) {
    const LodTileCache::Entry te = tileFor(cache, ndef, tsrc, materials, c, 0);
    u32 tint = 0xffffffff;
    if (te.tile_has_color) {
        tint = te.tint;
    } else {
        const ContentFeatures &f = ndef->get(c);
        if (f.visuals) {
            video::SColor col;
            col = f.visuals->getColor(f, param2);
            tint = col.color | 0xff000000;
        }
    }
    return mulColour(te.fallback, tint);
}

} // namespace goanna
