// SPDX-License-Identifier: LGPL-2.1-or-later

#include "goanna_lod.h"

#include "mapblock.h"
#include "nodedef.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <map>

using namespace goanna;

namespace {

void expect(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "goanna_lod_test: " << message << "\n";
        std::abort();
    }
}

BlockLodChain airChain() {
    BlockLodChain ch;
    LodLevel &lv = ch.level[BlockLodChain::levelForCell(4)];
    lv.cell = 4;
    lv.n = 4;
    lv.cells.assign(64, LodLevel::Cell());
    for (LodLevel::Cell &c : lv.cells)
        c.flags = LodLevel::kKnown | LodLevel::kLit;
    buildLodMipLevels(ch, BlockLodChain::levelForCell(4));
    return ch;
}

BlockLodChain fineAirChain() {
    BlockLodChain ch;
    LodLevel &lv = ch.level[BlockLodChain::levelForCell(1)];
    lv.cell = 1;
    lv.n = MAP_BLOCKSIZE;
    lv.cells.assign((size_t)MAP_BLOCKSIZE * MAP_BLOCKSIZE * MAP_BLOCKSIZE, LodLevel::Cell());
    for (LodLevel::Cell &c : lv.cells)
        c.flags = LodLevel::kKnown | LodLevel::kLit;
    buildLodMipLevels(ch, BlockLodChain::levelForCell(1));
    return ch;
}

void fillCell(LodLevel::Cell &cell, content_t content, bool occludes = true) {
    cell.flags |= LodLevel::kFilled | (occludes ? LodLevel::kOccludes : 0);
    for (content_t &face : cell.face)
        face = content;
}

void testSparseCaptureBounds() {
    std::map<v3s16, int> field;
    for (int x = -7; x <= 7; ++x)
        for (int y = -7; y <= 7; ++y)
            for (int z = -7; z <= 7; ++z)
                if ((x + y + z) % 3 == 0)
                    field.emplace(v3s16(x, y, z), x * 100 + y * 10 + z);
    const v3s16 low(-4, -3, -2);
    std::map<v3s16, int> visited, expected;
    visitLodBox(field, low, 5, [&](v3s16 bp, int value) {
        expect(visited.emplace(bp, value).second, "sparse capture visited a block twice");
    });
    for (const auto &entry : field) {
        const v3s16 d = entry.first - low;
        if (d.X >= 0 && d.Y >= 0 && d.Z >= 0 && d.X < 5 && d.Y < 5 && d.Z < 5)
            expected.insert(entry);
    }
    expect(!expected.empty() && visited == expected,
            "sparse capture differs from the complete three-dimensional bounds");
}

void testProjectedDetailIncludesAltitudeAndResolution() {
    const float radius = 512.0f, focal = 640.0f;
    expect(lodProjectedTier(v3f(0, 40, 0), 0, true, radius, focal) == 0,
            "close terrain lost full detail");
    expect(lodProjectedTier(v3f(0, 300, 0), 0, true, radius, focal) == 2,
            "high-altitude terrain stayed in the near cylinder");
    expect(lodProjectedTier(v3f(300, 0, 0), 0, true, radius, focal) == 2,
            "altitude and horizontal distance do not share the projection rule");
    expect(lodProjectedTier(v3f(300, 0, 0), 0, true, radius, focal * 2) == 1,
            "higher display resolution did not retain more detail");
    expect(lodProjectedTier(v3f(0, 0, 0), 0, false, radius, focal) == 1,
            "missing live data suppressed the far fallback");
    expect(lodProjectedTier(v3f(130, 0, 0), 1, true, radius, focal) == 1,
            "near boundary has no return hysteresis");
    expect(lodProjectedTier(v3f(110, 0, 0), 1, true, radius, focal) == 0,
            "approaching terrain did not regain full detail");
    expect(lodProjectedTier(v3f(100, 0, 0), 0, true, 64, focal * 4) == 1,
            "projection exceeded the configured detail radius");
    expect(lodProjectedTier(v3f(0, 1000, 0), 3, true, 0, focal) == 0,
            "disabled LOD still reduced detail");
}

void testRecursiveVoxelMip() {
    BlockLodChain ch = airChain();
    LodLevel &fine = ch.level[BlockLodChain::levelForCell(4)];
    LodLevel::Cell &leaf = fine.at(0, 0, 0);
    leaf.flags |= LodLevel::kFilled;
    for (content_t &face : leaf.face)
        face = 100;
    LodLevel::Cell &stone = fine.at(1, 1, 1);
    stone.flags |= LodLevel::kFilled | LodLevel::kOccludes;
    for (content_t &face : stone.face)
        face = 101;

    buildLodMipLevels(ch, BlockLodChain::levelForCell(4));
    const LodLevel::Cell &coarse = ch.level[BlockLodChain::levelForCell(8)].at(0, 0, 0);
    expect(coarse.flags & LodLevel::kFilled, "mip lost occupied child");
    expect(coarse.flags & LodLevel::kOccludes, "opaque child did not win");
    expect(coarse.face[0] == 101, "mip chose the wrong representative");
    expect(coarse.top == 0, "mip voxel does not occupy its complete cell");
}

void testLiquidSurfaceHeightSurvivesMip() {
    BlockLodChain ch = airChain();
    LodLevel &fine = ch.level[BlockLodChain::levelForCell(4)];
    LodLevel::Cell &water = fine.at(0, 0, 0);
    water.flags |= LodLevel::kLiquid;
    water.liquid = 100;
    water.liquid_top = 2;

    buildLodMipLevels(ch, BlockLodChain::levelForCell(4));
    const LodLevel::Cell &cell8 = ch.level[BlockLodChain::levelForCell(8)].at(0, 0, 0);
    const LodLevel::Cell &cell16 = ch.level[BlockLodChain::levelForCell(16)].at(0, 0, 0);
    expect(cell8.flags & LodLevel::kLiquid, "mip lost liquid identity");
    expect(!(cell8.flags & LodLevel::kFilled), "liquid became solid occupancy");
    expect(cell8.liquid_top == 2, "cell-8 mip raised the liquid surface");
    expect(cell16.liquid_top == 2, "cell-16 mip raised the liquid surface");

    BlockLodChain full_child = airChain();
    LodLevel::Cell &full_water =
            full_child.level[BlockLodChain::levelForCell(4)].at(0, 0, 0);
    full_water.flags |= LodLevel::kLiquid;
    full_water.liquid = 100;
    full_water.liquid_top = 0;
    buildLodMipLevels(full_child, BlockLodChain::levelForCell(4));
    expect(full_child.level[BlockLodChain::levelForCell(8)].at(0, 0, 0).liquid_top == 4,
            "full liquid child expanded to the parent ceiling");
    expect(full_child.level[BlockLodChain::levelForCell(16)].at(0, 0, 0).liquid_top == 4,
            "full liquid child expanded through the recursive mip");
}

void testLiquidIsAnEnvelopeOverSolid() {
    BlockLodChain ocean = airChain();
    LodLevel::Cell &cell = ocean.level[BlockLodChain::levelForCell(4)].at(1, 1, 1);
    cell.flags |= LodLevel::kLiquid;
    cell.liquid = CONTENT_UNKNOWN;
    cell.liquid_top = 3;

    LodRegionSpec spec;
    spec.origin = v3s16(0, 0, 0);
    spec.blocks = 1;
    spec.cell = 4;
    spec.member = [](v3s16 bp) { return bp == v3s16(0, 0, 0); };
    spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
        return bp == v3s16(0, 0, 0) ? &ocean : nullptr;
    };
    spec.drawn_cell = [](v3s16 bp) { return bp == v3s16(0, 0, 0) ? 4 : -1; };

    NodeDefManager ndef;
    LodTileCache tiles;
    LodRegionMesh mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
    expect(mesh.faces == 1, "liquid voxel emitted transparent sides or underside");
    float max_y = -1000.0f;
    for (const LodSurface &surface : mesh.surfaces)
        for (const v3f &p : surface.pos)
            max_y = std::max(max_y, p.Y);
    expect(std::abs(max_y - 7.0f) < 0.001f, "liquid envelope lost its partial height");

    fillCell(cell, CONTENT_UNKNOWN);
    mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
    expect(mesh.faces == 6, "solid seabed and liquid envelope did not coexist");
}

void testIsolatedVoxelHasAllSixFaces() {
    BlockLodChain solid = airChain();
    LodLevel &lv = solid.level[BlockLodChain::levelForCell(4)];
    LodLevel::Cell &c = lv.at(1, 2, 1);
    c.flags |= LodLevel::kFilled | LodLevel::kOccludes;
    for (content_t &face : c.face)
        face = CONTENT_UNKNOWN;

    const BlockLodChain air = airChain();
    LodRegionSpec spec;
    spec.origin = v3s16(0, 0, 0);
    spec.blocks = 1;
    spec.cell = 4;
    spec.member = [](v3s16 bp) { return bp == v3s16(0, 0, 0); };
    spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
        return bp == v3s16(0, 0, 0) ? &solid : &air;
    };
    spec.drawn_cell = [](v3s16 bp) { return bp == v3s16(0, 0, 0) ? 4 : -1; };

    NodeDefManager ndef;
    LodTileCache tiles;
    LodRegionMesh mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
    expect(mesh.faces == 6, "isolated voxel did not emit six faces");
    bool underside = false;
    int winding_sign = 0;
    for (const LodSurface &surface : mesh.surfaces) {
        for (const v3f &normal : surface.nrm)
            underside |= normal.Y < -0.99f;
        for (size_t i = 0; i + 2 < surface.idx.size(); i += 3) {
            const u32 ia = surface.idx[i], ib = surface.idx[i + 1], ic = surface.idx[i + 2];
            const v3f ab = surface.pos[ib] - surface.pos[ia];
            const v3f ac = surface.pos[ic] - surface.pos[ia];
            const float facing = ab.crossProduct(ac).dotProduct(surface.nrm[ia]);
            const int sign = facing < 0.0f ? -1 : (facing > 0.0f ? 1 : 0);
            expect(sign != 0, "isolated voxel emitted a degenerate triangle");
            if (!winding_sign)
                winding_sign = sign;
            expect(sign == winding_sign, "isolated voxel face winding changes between axes");
        }
    }
    expect(underside, "isolated voxel has no lower face");
}

void testConnectedGroundFollowsAValley() {
    BlockLodChain valley = airChain();
    LodLevel &lv = valley.level[BlockLodChain::levelForCell(4)];
    // A four-node floor everywhere, with a second layer on the two valley
    // walls. Binary voxel mips draw the underside of that upper layer as a
    // lid; the terrain surface must instead descend through the middle.
    for (int z = 0; z < 4; ++z)
        for (int x = 0; x < 4; ++x) {
            fillCell(lv.at(x, 0, z), CONTENT_UNKNOWN);
            if (x == 0 || x == 3)
                fillCell(lv.at(x, 1, z), CONTENT_UNKNOWN);
        }
    NodeDefManager ndef;
    buildLodTerrainSurface(&ndef, valley, BlockLodChain::levelForCell(4));
    expect(lv.terrainAt(0, 1) == 8 && lv.terrainAt(1, 1) == 4 &&
                    lv.terrainAt(2, 1) == 4 && lv.terrainAt(3, 1) == 8,
            "terrain surface closed a valley instead of following its floor");

    LodRegionSpec spec;
    spec.origin = v3s16(0, 0, 0);
    spec.blocks = 1;
    spec.cell = 4;
    spec.member = [](v3s16 bp) { return bp == v3s16(0, 0, 0); };
    spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
        return bp == v3s16(0, 0, 0) ? &valley : nullptr;
    };
    spec.drawn_cell = [](v3s16 bp) { return bp == v3s16(0, 0, 0) ? 4 : -1; };
    LodTileCache tiles;
    const LodRegionMesh mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
    expect(mesh.surface_cells == 16, "connected valley was not emitted as terrain surface");
    for (const LodSurface &surface : mesh.surfaces)
        for (const v3f &normal : surface.nrm)
            expect(normal.Y > -0.99f, "terrain valley emitted a horizontal underside lid");
}

void testTerrainSkirtsFaceOutwardOnBothAxes() {
    BlockLodChain slope = airChain();
    LodLevel &lv = slope.level[BlockLodChain::levelForCell(4)];
    // Changing height in both horizontal directions produces all four skirt
    // orientations. Their triangles must use the same clockwise-from-outside
    // convention as the ordinary coarse voxel faces after Z is mirrored.
    for (int z = 0; z < 4; ++z)
        for (int x = 0; x < 4; ++x) {
            fillCell(lv.at(x, 0, z), CONTENT_UNKNOWN);
            if (x + z >= 3)
                fillCell(lv.at(x, 1, z), CONTENT_UNKNOWN);
        }
    NodeDefManager ndef;
    buildLodTerrainSurface(&ndef, slope, BlockLodChain::levelForCell(4));
    LodRegionSpec spec;
    spec.origin = v3s16(0, 0, 0);
    spec.blocks = 1;
    spec.cell = 4;
    spec.member = [](v3s16 bp) { return bp == v3s16(0, 0, 0); };
    spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
        return bp == v3s16(0, 0, 0) ? &slope : nullptr;
    };
    spec.drawn_cell = [](v3s16 bp) { return bp == v3s16(0, 0, 0) ? 4 : -1; };
    LodTileCache tiles;
    const LodRegionMesh mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
    int x_faces = 0, z_faces = 0;
    for (const LodSurface &surface : mesh.surfaces)
        for (size_t i = 0; i + 2 < surface.idx.size(); i += 3) {
            const u32 ia = surface.idx[i], ib = surface.idx[i + 1], ic = surface.idx[i + 2];
            const v3f normal = surface.nrm[ia];
            if (std::fabs(normal.Y) > 0.01f)
                continue;
            x_faces += std::fabs(normal.X) > 0.99f ? 1 : 0;
            z_faces += std::fabs(normal.Z) > 0.99f ? 1 : 0;
            const v3f ab = surface.pos[ib] - surface.pos[ia];
            const v3f ac = surface.pos[ic] - surface.pos[ia];
            expect(ab.crossProduct(ac).dotProduct(normal) < 0.0f,
                    "terrain skirt was wound inward and will be back-face culled");
        }
    expect(x_faces > 0 && z_faces > 0, "skirt winding fixture did not cover both axes");
}

// Ground on both sides of negative block coordinates exercises the region
// margin and fine/coarse alignment independently of a live world fixture.
void testGroundSurfaceJoins(bool mixed) {
    NodeDefManager ndef;
    std::map<v3s16, BlockLodChain> field;
    for (int bz = -2; bz <= 1; ++bz)
        for (int bx = -3; bx <= 1; ++bx) {
            BlockLodChain ch = airChain();
            LodLevel &lv = ch.level[BlockLodChain::levelForCell(4)];
            for (int z = 0; z < 4; ++z)
                for (int x = 0; x < 4; ++x) {
                    const int height = 3 + (bx + 2) * 2 + x / 2 + (z >= 2 ? 2 : 0);
                    for (int y = 0; y * 4 < height; ++y) {
                        fillCell(lv.at(x, y, z), CONTENT_UNKNOWN);
                        const int top = height - y * 4;
                        lv.at(x, y, z).top = top < 4 ? top : 0;
                    }
                }
            buildLodMipLevels(ch, BlockLodChain::levelForCell(4));
            buildLodTerrainSurface(&ndef, ch, BlockLodChain::levelForCell(4));
            field.emplace(v3s16(bx, 0, bz), std::move(ch));
        }
    auto chain = [&](v3s16 bp) -> const BlockLodChain * {
        auto it = field.find(bp);
        return it == field.end() ? nullptr : &it->second;
    };
    auto drawn = [&](v3s16 bp) {
        return chain(bp) ? (mixed && bp.X >= -1 ? 8 : 4) : -1;
    };
    auto mesh_at = [&](v3s16 origin) {
        LodRegionSpec spec;
        spec.origin = origin;
        spec.blocks = 1;
        spec.cell = drawn(origin);
        spec.member = [=](v3s16 bp) { return bp == origin; };
        spec.chain = chain;
        spec.drawn_cell = drawn;
        LodTileCache tiles;
        return meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
    };
    const LodRegionMesh fine = mesh_at(v3s16(-2, 0, -1));
    const LodRegionMesh other = mesh_at(v3s16(-1, 0, -1));
    auto boundary = [](const LodRegionMesh &mesh) {
        std::map<float, float> heights;
        for (const LodSurface &sf : mesh.surfaces)
            for (size_t i = 0; i < sf.pos.size(); ++i) {
                const v3f &p = sf.pos[i];
                if (std::fabs(p.X + 16.0f) > 0.001f || sf.nrm[i].Y < 0.1f)
                    continue;
                auto previous = heights.find(p.Z);
                if (previous != heights.end())
                    expect(std::fabs(previous->second - p.Y) < 0.001f,
                            "adjacent terrain quads disagree at a shared corner");
                heights[p.Z] = p.Y;
            }
        return heights;
    };
    const auto a = boundary(fine), b = boundary(other);
    expect(a.size() == 5 && b.size() == (mixed ? 3 : 5), "surface boundary is incomplete");
    for (auto [z, y] : a) {
        auto hi = b.lower_bound(z);
        expect(hi != b.end(), "surface boundary did not reach the fine edge");
        float target = hi->second;
        if (hi->first != z) {
            expect(hi != b.begin(), "surface boundary starts after the fine edge");
            auto lo = std::prev(hi);
            const float t = (z - lo->first) / (hi->first - lo->first);
            target = lo->second * (1 - t) + hi->second * t;
        }
        expect(std::fabs(y - target) < 0.001f, "ground has an open seam between regions");
    }
    // Continuous slopes contain no internal vertical risers. This fixture
    // has neighbours on every horizontal edge, so no frontier skirt is due.
    expect(fine.skirts == 0, "continuous hillside still has terrace risers");
    bool slope_normal = false;
    for (const LodSurface &sf : fine.surfaces)
        for (const v3f &normal : sf.nrm)
            slope_normal |= normal.Y > 0.1f && normal.Y < 0.999f;
    expect(slope_normal, "sloping ground is still lit as horizontal plates");
}

void testFarApronReachesDetailedGround() {
    NodeDefManager ndef;
    BlockLodChain far = airChain();
    for (int z = 0; z < 4; ++z)
        for (int x = 0; x < 4; ++x)
            for (int y = 0; y < 3; ++y)
                fillCell(far.level[2].at(x, y, z), CONTENT_UNKNOWN);
    buildLodTerrainSurface(&ndef, far, 2);
    BlockLodChain near = fineAirChain();
    for (int z = 0; z < 16; ++z)
        for (int x = 0; x < 16; ++x)
            fillCell(near.level[0].at(x, 0, z), CONTENT_UNKNOWN);
    buildLodMipLevels(near, 0);
    buildLodTerrainSurface(&ndef, near, 0);
    compactLodFineBoundary(near);
    LodRegionSpec spec;
    spec.blocks = 1;
    spec.cell = 4;
    spec.member = [](v3s16 bp) { return bp == v3s16(0, 0, 0); };
    spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
        if (bp == v3s16(0, 0, 0)) return &far;
        if (bp == v3s16(1, 0, 0)) return &near;
        return nullptr;
    };
    spec.drawn_cell = [](v3s16 bp) {
        if (bp == v3s16(0, 0, 0)) return 4;
        if (bp == v3s16(1, 0, 0)) return 0;
        return -1;
    };
    LodTileCache tiles;
    const auto mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
    float lowest = 1000, highest = -1000;
    for (const LodSurface &sf : mesh.surfaces)
        for (size_t i = 0; i < sf.pos.size(); ++i)
            if (sf.nrm[i].X > 0.99f && std::fabs(sf.pos[i].X - 16.0f) < 0.001f) {
                lowest = std::min(lowest, sf.pos[i].Y);
                highest = std::max(highest, sf.pos[i].Y);
            }
    expect(lowest <= 1.0f && highest >= 12.0f,
            "far boundary apron stopped above the detailed neighbour's ground");
}

void testProviderShellIsGroundButVoxelSlabIsNot() {
    NodeDefManager ndef;
    BlockLodChain shell = airChain();
    LodLevel &lv = shell.level[BlockLodChain::levelForCell(4)];
    // A provider sends the visible skin and omits buried cells. The same
    // occupancy in an ordinary voxel summary is a genuinely floating slab.
    for (int z = 0; z < 4; ++z)
        for (int x = 0; x < 4; ++x)
            fillCell(lv.at(x, 2, z), CONTENT_UNKNOWN);
    buildLodMipLevels(shell, BlockLodChain::levelForCell(4));
    BlockLodChain slab = shell;
    shell.surface_shell = true;
    buildLodTerrainSurface(&ndef, shell, BlockLodChain::levelForCell(4));
    buildLodTerrainSurface(&ndef, slab, BlockLodChain::levelForCell(4));
    expect(shell.level[2].terrainAt(1, 1) == 12, "provider shell did not retain its ground height");
    expect(slab.level[2].terrainAt(1, 1) == 0, "voxel slab was mistaken for provider ground");
    expect(!(shell.level[2].at(1, 0, 1).flags & LodLevel::kFilled),
            "provider presentation invented filled voxel occupancy");
    LodRegionSpec spec;
    spec.blocks = 1;
    spec.cell = 4;
    spec.member = [](v3s16 bp) { return bp == v3s16(0, 0, 0); };
    spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
        return bp == v3s16(0, 0, 0) ? &shell : nullptr;
    };
    spec.drawn_cell = [](v3s16 bp) { return bp == v3s16(0, 0, 0) ? 4 : -1; };
    LodTileCache tiles;
    const auto mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
    expect(mesh.surface_cells == 16, "provider skin fell back to floating voxel boxes");
    for (const LodSurface &sf : mesh.surfaces)
        for (const v3f &normal : sf.nrm)
            expect(normal.Y >= 0.0f, "provider ground emitted an underside lid");
}

void testSurfaceRetainsMeasuredRidgeHeight() {
    NodeDefManager ndef;
    BlockLodChain ch = airChain();
    LodLevel &lv = ch.level[BlockLodChain::levelForCell(4)];
    for (int z = 0; z < 4; ++z)
        for (int x = 0; x < 4; ++x)
            fillCell(lv.at(x, 0, z), CONTENT_UNKNOWN);
    fillCell(lv.at(1, 1, 1), CONTENT_UNKNOWN);
    fillCell(lv.at(1, 2, 1), CONTENT_UNKNOWN);
    buildLodTerrainSurface(&ndef, ch, BlockLodChain::levelForCell(4));
    LodRegionSpec spec;
    spec.blocks = 1;
    spec.cell = 4;
    spec.member = [](v3s16 bp) { return bp == v3s16(0, 0, 0); };
    spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
        return bp.Y == 0 ? &ch : nullptr;
    };
    spec.drawn_cell = [](v3s16 bp) { return bp.Y == 0 ? 4 : -1; };
    LodTileCache tiles;
    const LodRegionMesh mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
    float peak = 0;
    for (const LodSurface &sf : mesh.surfaces)
        for (const v3f &p : sf.pos)
            peak = std::max(peak, p.Y);
    expect(std::fabs(peak - 12.0f) < 0.001f,
            "surface averaging erased the measured ridge height");
}

void testGroundCannotCoverShallowWater() {
    NodeDefManager ndef;
    BlockLodChain ch = airChain();
    LodLevel &lv = ch.level[BlockLodChain::levelForCell(4)];
    for (int z = 0; z < 4; ++z)
        for (int x = 0; x < 4; ++x) {
            LodLevel::Cell &c = lv.at(x, 0, z);
            fillCell(c, CONTENT_UNKNOWN);
            c.flags |= LodLevel::kLiquid;
            c.liquid = CONTENT_UNKNOWN;
            c.liquid_top = 3;
        }
    buildLodMipLevels(ch, BlockLodChain::levelForCell(4));
    buildLodTerrainSurface(&ndef, ch, BlockLodChain::levelForCell(4));
    for (int cell : {4, 8, 16}) {
        LodRegionSpec spec;
        spec.blocks = 1;
        spec.cell = cell;
        spec.member = [](v3s16 bp) { return bp == v3s16(0, 0, 0); };
        spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
            return bp.Y == 0 ? &ch : nullptr;
        };
        spec.drawn_cell = [=](v3s16 bp) { return bp.Y == 0 ? cell : -1; };
        LodTileCache tiles;
        const LodRegionMesh mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
        bool water = false, ground = false;
        for (const LodSurface &sf : mesh.surfaces)
            for (size_t i = 0; i < sf.pos.size(); ++i) {
                if (sf.nrm[i].Y < 0.1f)
                    continue;
                expect(sf.pos[i].Y <= 3.001f, "coarse ground rose above shallow water");
                water |= std::fabs(sf.pos[i].Y - 3.0f) < 0.001f;
                ground |= sf.pos[i].Y < 2.9f;
            }
        expect(water && ground, "shallow water lost its envelope or opaque seabed");
    }
}

void testSurfaceKeepsFloatingRockAtCoarseResolution() {
    NodeDefManager ndef;
    BlockLodChain ch = airChain();
    LodLevel &lv = ch.level[BlockLodChain::levelForCell(4)];
    // A rock suspended above known air must not become a forest canopy or a
    // sheet draped down to the block floor at the cell-8 rung.
    fillCell(lv.at(0, 2, 0), CONTENT_UNKNOWN);
    buildLodMipLevels(ch, BlockLodChain::levelForCell(4));
    buildLodTerrainSurface(&ndef, ch, BlockLodChain::levelForCell(4));
    LodRegionSpec spec;
    spec.blocks = 1;
    spec.cell = 8;
    spec.member = [](v3s16 bp) { return bp == v3s16(0, 0, 0); };
    spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
        return bp == v3s16(0, 0, 0) ? &ch : nullptr;
    };
    spec.drawn_cell = [](v3s16 bp) { return bp == v3s16(0, 0, 0) ? 8 : -1; };
    LodTileCache tiles;
    const LodRegionMesh mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
    expect(mesh.surface_cells == 0, "floating rock became a terrain or canopy surface");
    expect(mesh.faces == 6, "floating rock lost its closed volumetric boundary");
}

void testCellOneTreeBoundary() {
    BlockLodChain tree = fineAirChain();
    LodLevel &fine = tree.level[BlockLodChain::levelForCell(1)];
    // Two-node trunk and a three-node leaf crown. Every node is retained on
    // the actual node grid; the four shared faces are the only ones culled.
    fillCell(fine.at(8, 0, 8), CONTENT_UNKNOWN);
    fillCell(fine.at(8, 1, 8), CONTENT_UNKNOWN);
    fillCell(fine.at(8, 2, 8), CONTENT_UNKNOWN, false);
    fillCell(fine.at(7, 2, 8), CONTENT_UNKNOWN, false);
    fillCell(fine.at(9, 2, 8), CONTENT_UNKNOWN, false);
    compactLodFineBoundary(tree);
    expect(tree.fine_available && tree.level[BlockLodChain::levelForCell(1)].cells.empty(),
            "cell-1 boundary retained its dense material volume");
    expect(tree.fine_records.size() < 64, "small tree did not compact to sparse records");

    const BlockLodChain air = fineAirChain();
    LodRegionSpec spec;
    spec.origin = v3s16(0, 0, 0);
    spec.blocks = 1;
    spec.cell = 1;
    spec.member = [](v3s16 bp) { return bp == v3s16(0, 0, 0); };
    spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
        return bp == v3s16(0, 0, 0) ? &tree : &air;
    };
    spec.drawn_cell = [](v3s16 bp) { return bp == v3s16(0, 0, 0) ? 1 : -1; };

    NodeDefManager ndef;
    LodTileCache tiles;
    const LodRegionMesh mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
    expect(mesh.faces == 22, "cell-1 trunk and leaves lost their exposed boundary");
    float min_x = 1000.0f, max_x = -1000.0f, max_y = -1000.0f;
    for (const LodSurface &surface : mesh.surfaces)
        for (const v3f &p : surface.pos) {
            min_x = std::min(min_x, p.X);
            max_x = std::max(max_x, p.X);
            max_y = std::max(max_y, p.Y);
        }
    expect(std::abs(min_x - 7.0f) < 0.001f && std::abs(max_x - 10.0f) < 0.001f,
            "cell-1 crown was inflated off the node grid");
    expect(std::abs(max_y - 3.0f) < 0.001f, "cell-1 tree height was quantised");
}

void testCellOneMeetsCellFourWithoutOverlap() {
    BlockLodChain coarse = airChain();
    fillCell(coarse.level[BlockLodChain::levelForCell(4)].at(3, 0, 0), CONTENT_UNKNOWN);
    buildLodMipLevels(coarse, BlockLodChain::levelForCell(4));

    BlockLodChain fine = fineAirChain();
    LodLevel &fl = fine.level[BlockLodChain::levelForCell(1)];
    for (int z = 0; z < 4; ++z)
        for (int y = 0; y < 4; ++y)
            fillCell(fl.at(0, y, z), CONTENT_UNKNOWN);
    buildLodMipLevels(fine, BlockLodChain::levelForCell(1));
    compactLodFineBoundary(fine);

    auto chain = [&](v3s16 bp) -> const BlockLodChain * {
        if (bp == v3s16(0, 0, 0)) return &coarse;
        if (bp == v3s16(1, 0, 0)) return &fine;
        return nullptr;
    };
    auto drawn = [](v3s16 bp) {
        if (bp == v3s16(0, 0, 0)) return 4;
        if (bp == v3s16(1, 0, 0)) return 1;
        return -1;
    };
    NodeDefManager ndef;
    LodTileCache tiles;
    LodRegionSpec coarse_spec;
    coarse_spec.origin = v3s16(0, 0, 0);
    coarse_spec.blocks = 1;
    coarse_spec.cell = 4;
    coarse_spec.member = [](v3s16 bp) { return bp == v3s16(0, 0, 0); };
    coarse_spec.chain = chain;
    coarse_spec.drawn_cell = drawn;
    const LodRegionMesh cm = meshLodRegion(coarse_spec, &ndef, nullptr, nullptr, tiles);
    for (const LodSurface &surface : cm.surfaces)
        for (size_t i = 0; i < surface.pos.size(); ++i)
            expect(!(surface.nrm[i].X > 0.99f && std::abs(surface.pos[i].X - 16.0f) < 0.001f),
                    "coarse face overlaps a covering cell-1 boundary");

    LodRegionSpec fine_spec;
    fine_spec.origin = v3s16(1, 0, 0);
    fine_spec.blocks = 1;
    fine_spec.cell = 1;
    fine_spec.member = [](v3s16 bp) { return bp == v3s16(1, 0, 0); };
    fine_spec.chain = chain;
    fine_spec.drawn_cell = drawn;
    const LodRegionMesh fm = meshLodRegion(fine_spec, &ndef, nullptr, nullptr, tiles);
    for (const LodSurface &surface : fm.surfaces)
        for (size_t i = 0; i < surface.pos.size(); ++i)
            expect(!(surface.nrm[i].X < -0.99f && std::abs(surface.pos[i].X - 16.0f) < 0.001f),
                    "cell-1 face overlaps a covering coarse boundary");
}

void testUnknownFrontierIsClosed() {
    BlockLodChain solid = airChain();
    LodLevel::Cell &c = solid.level[BlockLodChain::levelForCell(4)].at(0, 0, 0);
    c.flags |= LodLevel::kFilled | LodLevel::kOccludes;
    for (content_t &face : c.face)
        face = CONTENT_UNKNOWN;

    LodRegionSpec spec;
    spec.origin = v3s16(0, 0, 0);
    spec.blocks = 1;
    spec.cell = 4;
    spec.member = [](v3s16 bp) { return bp == v3s16(0, 0, 0); };
    spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
        return bp == v3s16(0, 0, 0) ? &solid : nullptr;
    };
    spec.drawn_cell = [](v3s16 bp) { return bp == v3s16(0, 0, 0) ? 4 : -1; };

    NodeDefManager ndef;
    LodTileCache tiles;
    const LodRegionMesh mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
    expect(mesh.faces == 6, "unknown section frontier left an open voxel");
}

void testTierBoundaryUsesDrawnOccupancy() {
    BlockLodChain coarse = airChain();
    LodLevel::Cell &coarse_edge = coarse.level[BlockLodChain::levelForCell(8)].at(1, 0, 0);
    coarse_edge.flags |= LodLevel::kFilled | LodLevel::kOccludes;
    for (content_t &face : coarse_edge.face)
        face = CONTENT_UNKNOWN;

    BlockLodChain fine = airChain();
    // This lies in the same cell-8 mip as the interface, but not on the x=0
    // face that actually touches the coarse block.
    LodLevel::Cell &fine_inner = fine.level[BlockLodChain::levelForCell(4)].at(1, 0, 0);
    fine_inner.flags |= LodLevel::kFilled | LodLevel::kOccludes;
    for (content_t &face : fine_inner.face)
        face = CONTENT_UNKNOWN;
    buildLodMipLevels(fine, BlockLodChain::levelForCell(4));

    LodRegionSpec spec;
    spec.origin = v3s16(0, 0, 0);
    spec.blocks = 1;
    spec.cell = 8;
    spec.member = [](v3s16 bp) { return bp == v3s16(0, 0, 0); };
    spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
        if (bp == v3s16(0, 0, 0))
            return &coarse;
        if (bp == v3s16(1, 0, 0))
            return &fine;
        return nullptr;
    };
    spec.drawn_cell = [](v3s16 bp) {
        if (bp == v3s16(0, 0, 0))
            return 8;
        if (bp == v3s16(1, 0, 0))
            return 4;
        return -1;
    };

    NodeDefManager ndef;
    LodTileCache tiles;
    const LodRegionMesh mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
    expect(mesh.faces == 6, "tier seam culled against an undrawn neighbour mip");
}

} // namespace

int main() {
    testSparseCaptureBounds();
    testProjectedDetailIncludesAltitudeAndResolution();
    testRecursiveVoxelMip();
    testLiquidSurfaceHeightSurvivesMip();
    testLiquidIsAnEnvelopeOverSolid();
    testIsolatedVoxelHasAllSixFaces();
    testConnectedGroundFollowsAValley();
    testTerrainSkirtsFaceOutwardOnBothAxes();
    testGroundSurfaceJoins(false);
    testGroundSurfaceJoins(true);
    testFarApronReachesDetailedGround();
    testProviderShellIsGroundButVoxelSlabIsNot();
    testSurfaceRetainsMeasuredRidgeHeight();
    testGroundCannotCoverShallowWater();
    testSurfaceKeepsFloatingRockAtCoarseResolution();
    testCellOneTreeBoundary();
    testCellOneMeetsCellFourWithoutOverlap();
    testUnknownFrontierIsClosed();
    testTierBoundaryUsesDrawnOccupancy();
    std::cout << "goanna_lod_test: ok\n";
    return 0;
}
