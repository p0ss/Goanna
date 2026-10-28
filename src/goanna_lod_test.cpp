// SPDX-License-Identifier: LGPL-2.1-or-later

// The far field's chain reducer and region mesher, checked on hand built
// chains with no Godot and no session: the mip keeps exposed materials and
// liquid envelopes, the ground surface follows valleys and joins its
// neighbours without gaps or overlap, cell 1 keeps exact boundaries, unknown
// is never meshed as open, and the projected tier takes altitude and screen
// resolution into account. Single threaded; run by the `check` target.

#include "goanna_lod.h"

#include "light.h"
#include "mapblock.h"
#include "nodedef.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <map>
#include <memory>
#include <utility>
#include <vector>

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

void testHorizonUsesSurfaceHeight() {
    BlockLodChain shore = fineAirChain();
    LodLevel &fine = shore.level[0];
    fillCell(fine.at(0, 0, 0), 100);
    buildLodMipLevels(shore, 0);
    expect(lodHorizonTop(shore).height == 1, "shore rose to the 16-node block ceiling");
    compactLodFineBoundary(shore);
    expect(lodHorizonTop(shore).height == 1, "compacted shore lost its exact height");

    BlockLodChain sea = airChain();
    LodLevel::Cell &water = sea.level[2].at(0, 0, 0);
    water.flags |= LodLevel::kLiquid;
    water.liquid = 101;
    water.liquid_top = 1;
    water.liquid_param2 = 7;
    buildLodMipLevels(sea, 2);
    LodTopSample top = lodHorizonTop(sea);
    expect(top.height == 1 && top.content == 101 && top.param2 == 7,
            "liquid-only horizon lost its height or material");
    fillCell(water, 100);
    buildLodMipLevels(sea, 2);
    top = lodHorizonTop(sea);
    expect(top.height == 1 && top.content == 101, "mixed seabed became a horizon wall");

    fillCell(sea.level[2].at(1, 2, 1), 102);
    buildLodMipLevels(sea, 2);
    top = lodHorizonTop(sea);
    expect(top.height == 12 && top.content == 102, "higher known land lost its silhouette");
    expect(lodHorizonTop(airChain()).height == 0, "known air invented a horizon");
}

void testProjectedDetailIncludesAltitudeAndResolution() {
    const float radius = 512.0f, focal = 640.0f;
    expect(lodProjectedTier(v3f(0, 40, 0), 0, true, radius, focal) == 0,
            "close terrain lost full detail");
    expect(lodProjectedTier(v3f(0, 300, 0), 0, true, radius, focal) == 1,
            "high-altitude terrain stayed in the near cylinder");
    expect(lodProjectedTier(v3f(300, 0, 0), 0, true, radius, focal) == 1,
            "altitude and horizontal distance do not share the projection rule");
    expect(lodProjectedTier(v3f(600, 0, 0), 0, true, radius, focal) == 2,
            "two-node band did not begin beyond the one-node silhouette band");
    expect(lodProjectedTier(v3f(600, 0, 0), 0, true, radius, focal * 2) == 1,
            "higher display resolution did not retain more detail");
    expect(lodProjectedTier(v3f(0, 0, 0), 0, false, radius, focal) == 1,
            "missing live data suppressed the far fallback");
    expect(lodProjectedTier(v3f(300, 0, 0), 0, false, radius, focal) == 1,
            "visited terrain lost its one-node far band");
    expect(lodProjectedTier(v3f(900, 0, 0), 0, false, radius, focal) == 3,
            "four-node band arrived before the finer bands");
    expect(lodProjectedTier(v3f(4000, 0, 0), 0, false, radius, focal) == 5,
            "the coarsest retained rung became unreachable");
    expect(lodProjectedTier(v3f(420, 0, 0), 2, false, radius, focal) == 2,
            "fine far boundary has no return hysteresis");
    expect(lodProjectedTier(v3f(350, 0, 0), 2, false, radius, focal) == 1,
            "returning to the fine far band failed");
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

void testMipMaterialsFollowExposedFaces() {
    BlockLodChain ch = fineAirChain();
    auto &fine = ch.level[0];
    // A trunk enclosed by leaves above and on every side, with an exposed
    // wooden underside. Check every mip, including the single block cell.
    for (int z = 0; z < 16; ++z)
        for (int y = 0; y < 16; ++y)
            for (int x = 0; x < 16; ++x) {
                const bool leaf = y == 15 || x == 0 || x == 15 || z == 0 || z == 15;
                auto &c = fine.at(x, y, z);
                fillCell(c, leaf ? 100 : 101, !leaf);
                c.coverage = 255;
                for (auto &p2 : c.param2) p2 = leaf ? 7 : 3;
            }
    buildLodMipLevels(ch, 0);
    for (int level = 1; level < BlockLodChain::kLevels; ++level) {
        const auto &lv = ch.level[level];
        for (int z = 0; z < lv.n; ++z)
            for (int x = 0; x < lv.n; ++x) {
                const auto &c = lv.at(x, lv.n - 1, z);
                expect(c.face[0] == 100 && c.param2[0] == 7,
                        "buried wood replaced a leaf top or lost its palette");
            }
    }
    const auto &whole = ch.level[4].at(0, 0, 0);
    expect(whole.face[1] == 101, "exposed wooden underside was replaced with leaves");
    for (int d = 2; d < 6; ++d)
        expect(whole.face[d] == 100, "buried wood replaced a leafy side");

    ch = fineAirChain();
    fillCell(ch.level[0].at(5, 7, 6), 101);
    buildLodMipLevels(ch, 0);
    expect(ch.level[4].at(0, 0, 0).face[0] == 101,
            "an exposed log lost its wood top");
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

void testCliffCrossesVerticalRegions() {
    NodeDefManager ndef;
    BlockLodChain solid = airChain();
    for (auto &c : solid.level[2].cells)
        fillCell(c, CONTENT_UNKNOWN);
    buildLodMipLevels(solid, 2);
    buildLodTerrainSurface(&ndef, solid, 2);
    BlockLodChain air = airChain();
    LodRegionSpec spec;
    spec.origin = v3s16(0, 1, 0);
    spec.blocks = 1;
    spec.cell = 4;
    spec.member = [](v3s16 bp) { return bp == v3s16(0, 1, 0); };
    spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
        return bp.X == 0 && bp.Z == 0 && bp.Y >= 0 && bp.Y < 5 ? &solid : &air;
    };
    spec.drawn_cell = [](v3s16 bp) {
        return bp.X == 0 && bp.Z == 0 && bp.Y >= 0 && bp.Y < 5 ? 4 : -1;
    };
    LodTileCache tiles;
    const auto mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
    float side_area = 0.0f;
    for (const auto &sf : mesh.surfaces)
        for (size_t i = 0; i + 3 < sf.pos.size(); i += 4)
            if (sf.nrm[i].X > 0.99f && std::abs(sf.pos[i].X - 16.0f) < 0.001f)
                side_area += (sf.pos[i + 1] - sf.pos[i]).crossProduct(
                        sf.pos[i + 3] - sf.pos[i]).getLength();
    expect(side_area >= 256.0f, "a cliff lost its side below another region's surface");
}

void testFullMapblockIslandHasAnUnderside() {
    NodeDefManager ndef;
    BlockLodChain solid = airChain(), air = airChain();
    for (auto &c : solid.level[2].cells)
        fillCell(c, CONTENT_UNKNOWN);
    buildLodMipLevels(solid, 2);
    buildLodTerrainSurface(&ndef, solid, 2);
    LodRegionSpec spec;
    spec.origin = v3s16(0, 1, 0);
    spec.blocks = 1;
    spec.cell = 4;
    spec.member = [](v3s16 bp) { return bp == v3s16(0, 1, 0); };
    spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
        return spec.member(bp) ? &solid : &air;
    };
    spec.drawn_cell = [&](v3s16 bp) { return spec.member(bp) ? 4 : -1; };
    LodTileCache tiles;
    const auto mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
    float underside = 0.0f;
    for (const auto &sf : mesh.surfaces)
        for (size_t i = 0; i + 3 < sf.pos.size(); i += 4)
            if (sf.nrm[i].Y < -0.99f && std::abs(sf.pos[i].Y - 16.0f) < 0.001f)
                underside += (sf.pos[i + 1] - sf.pos[i]).crossProduct(
                        sf.pos[i + 3] - sf.pos[i]).getLength();
    expect(underside >= 256.0f, "a full mapblock island lost its underside");
}

void testCanopyDoesNotDrapeAcrossKnownAir() {
    NodeDefManager ndef;
    ContentFeatures leaves;
    leaves.name = "test:leaves";
    leaves.groups["leaves"] = 1;
    const content_t leaf = ndef.set("test:leaves", std::move(leaves));
    BlockLodChain ground = airChain(), crown = airChain(), air = airChain();
    for (int z = 0; z < 4; ++z)
        for (int x = 0; x < 4; ++x)
            fillCell(ground.level[2].at(x, 0, z), CONTENT_UNKNOWN);
    fillCell(crown.level[2].at(0, 2, 0), leaf, false);
    for (auto *ch : {&ground, &crown}) {
        buildLodMipLevels(*ch, 2);
        buildLodTerrainSurface(&ndef, *ch, 2);
    }
    LodRegionSpec spec;
    spec.blocks = 4;
    spec.cell = 8;
    spec.member = [](v3s16 bp) {
        return bp.X == 0 && bp.Z == 0 && (bp.Y == 0 || bp.Y == 2);
    };
    spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
        if (bp == v3s16(0, 0, 0)) return &ground;
        if (bp == v3s16(0, 2, 0)) return &crown;
        return &air;
    };
    spec.drawn_cell = [&](v3s16 bp) { return spec.member(bp) ? 8 : -1; };
    LodTileCache tiles;
    const auto mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
    bool underside = false;
    for (const auto &sf : mesh.surfaces)
        for (size_t i = 0; i + 3 < sf.pos.size(); i += 4) {
            float low = sf.pos[i].Y, high = low;
            for (int j = 1; j < 4; ++j) {
                low = std::min(low, sf.pos[i + j].Y);
                high = std::max(high, sf.pos[i + j].Y);
            }
            expect(!(low < 24.0f && high > 24.0f),
                    "a canopy skirt invented a wall through known air");
            underside |= sf.nrm[i].Y < -0.99f && std::abs(low - 40.0f) < 0.001f;
        }
    expect(underside, "a distant leaf crown lost its underside");
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
    slope.surface_shell = true;
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
    auto top_at = [](const LodRegionMesh &mesh, float x, float z) {
        for (const LodSurface &sf : mesh.surfaces)
            for (size_t i = 0; i + 3 < sf.pos.size(); i += 4) {
                if (sf.nrm[i].Y < 0.99f)
                    continue;
                float xmin = sf.pos[i].X, xmax = xmin, zmin = sf.pos[i].Z, zmax = zmin;
                for (int j = 0; j < 4; ++j) {
                    expect(std::fabs(sf.pos[i + j].Y - sf.pos[i].Y) < 0.001f,
                            "terrain top introduced a diagonal ramp");
                    xmin = std::min(xmin, sf.pos[i + j].X);
                    xmax = std::max(xmax, sf.pos[i + j].X);
                    zmin = std::min(zmin, sf.pos[i + j].Z);
                    zmax = std::max(zmax, sf.pos[i + j].Z);
                }
                if (x > xmin && x < xmax && z > zmin && z < zmax)
                    return sf.pos[i].Y;
            }
        expect(false, "terrain top missing beside the region boundary");
        return 0.0f;
    };
    for (float z = 1.0f; z < 16.0f; z += 2.0f) {
        const float a = top_at(fine, -17.0f, z), b = top_at(other, -15.0f, z);
        for (float y = std::min(a, b) + 0.25f; y < std::max(a, b); y += 0.5f) {
            bool closed = false;
            for (const LodRegionMesh *mesh : {&fine, &other})
                for (const LodSurface &sf : mesh->surfaces)
                    for (size_t i = 0; i + 3 < sf.pos.size(); i += 4) {
                        if (std::fabs(sf.nrm[i].X) < 0.99f || std::fabs(sf.pos[i].X + 16) > 0.001f)
                            continue;
                        float ymin = sf.pos[i].Y, ymax = ymin, zmin = sf.pos[i].Z, zmax = zmin;
                        for (int j = 1; j < 4; ++j) {
                            ymin = std::min(ymin, sf.pos[i + j].Y);
                            ymax = std::max(ymax, sf.pos[i + j].Y);
                            zmin = std::min(zmin, sf.pos[i + j].Z);
                            zmax = std::max(zmax, sf.pos[i + j].Z);
                        }
                        closed |= y >= ymin && y <= ymax && z >= zmin && z <= zmax;
                    }
            if (!closed)
                std::cerr << "seam mixed=" << mixed << " z=" << z << " y=" << y
                        << " sides=" << a << "," << b << "\n";
            expect(closed, "vertical height difference has an open region seam");
        }
    }
    expect(fine.faces > 0, "hillside lost its vertical steps");
    for (const LodSurface &sf : fine.surfaces)
        for (const v3f &normal : sf.nrm)
            expect(std::fabs(normal.X) > 0.999f || std::fabs(normal.Y) > 0.999f ||
                    std::fabs(normal.Z) > 0.999f, "terrain introduced a diagonal ridge normal");

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

void testCellOneGroundBoundary() {
    auto ground=fineAirChain();
    auto &fine=ground.level[0];
    for (int z=0;z<16;++z) for (int x=0;x<16;++x)
        fillCell(fine.at(x,0,z),CONTENT_UNKNOWN);
    NodeDefManager ndef;
    buildLodTerrainSurface(&ndef,ground,0);
    expect(fine.terrain.empty(),"one-node ground must use its exact voxel boundary");
    compactLodFineBoundary(ground);
    auto air=fineAirChain();
    LodRegionSpec spec;
    spec.origin=v3s16(0,0,0);spec.blocks=1;spec.cell=1;
    spec.member=[](v3s16 p){return p==v3s16(0,0,0);};
    spec.chain=[&](v3s16 p){return p==v3s16(0,0,0)?&ground:&air;};
    spec.drawn_cell=[](v3s16 p){return p==v3s16(0,0,0)?1:-1;};
    LodTileCache tiles;
    auto mesh=meshLodRegion(spec,&ndef,nullptr,nullptr,tiles);
    float top_area=0;
    for (const auto &surface:mesh.surfaces)
        for (size_t i=0;i<surface.pos.size();i+=4)
            if (surface.nrm[i].Y>0.9f)
                top_area+=(surface.pos[i+1]-surface.pos[i]).crossProduct(
                        surface.pos[i+3]-surface.pos[i]).getLength();
    expect(std::abs(top_area-256)<0.01f,"compacted one-node ground lost its top faces");
    size_t coverage=0;
    for (const auto &patch:mesh.ground) coverage+=patch.size*patch.size;
    expect(coverage==256,"ground footprint differs from emitted top faces");
    auto buried=fineAirChain();
    for (auto &c:buried.level[0].cells) fillCell(c,CONTENT_UNKNOWN);
    buildLodMipLevels(buried,0);buildLodTerrainSurface(&ndef,buried,0);
    compactLodFineBoundary(buried);
    spec.chain=[&](v3s16 p){return p==v3s16(0,0,0)||p==v3s16(0,1,0)?&buried:&air;};
    spec.drawn_cell=[](v3s16 p){return p==v3s16(0,0,0)||p==v3s16(0,1,0)?1:-1;};
    mesh=meshLodRegion(spec,&ndef,nullptr,nullptr,tiles);
    expect(mesh.ground.empty(),"buried block claimed coverage without a visible ground face");
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

// A canopy and a cliff are both "occupied" and the reducer keeps them both, so
// what separates them at range is how much of the cell they fill. See the note
// on LodLevel::Cell::coverage.
void testCoverageSeparatesCanopyFromRock() {
    auto chainWith = [](int filled_of_eight) {
        BlockLodChain ch;
        LodLevel &lv = ch.level[BlockLodChain::levelForCell(4)];
        lv.cell = 4;
        lv.n = 4;
        lv.cells.assign(64, LodLevel::Cell());
        for (LodLevel::Cell &c : lv.cells)
            c.flags = LodLevel::kKnown;
        // The eight cell-4 voxels under one cell-8 cell, filling as many as
        // asked. A summary cannot report a partial cell-4, so each filled one
        // is solid and openness is entirely a matter of how many there are.
        int placed = 0;
        for (int dz = 0; dz < 2; ++dz)
            for (int dy = 0; dy < 2; ++dy)
                for (int dx = 0; dx < 2; ++dx) {
                    if (placed++ >= filled_of_eight)
                        continue;
                    LodLevel::Cell &c = lv.at(dx, dy, dz);
                    fillCell(c, 100);
                    c.coverage = 255;
                }
        buildLodMipLevels(ch, BlockLodChain::levelForCell(4));
        return ch;
    };

    const LodLevel &solid = chainWith(8).level[BlockLodChain::levelForCell(8)];
    expect(solid.at(0, 0, 0).flags & LodLevel::kFilled, "solid cell-8 should be filled");
    expect(solid.at(0, 0, 0).coverage == 255, "eight of eight should read completely full");

    const LodLevel &sparse = chainWith(1).level[BlockLodChain::levelForCell(8)];
    expect(sparse.at(0, 0, 0).flags & LodLevel::kFilled,
            "a sparse cell is still occupied: coverage informs drawing, it does not gate it");
    expect(sparse.at(0, 0, 0).coverage == 32,
            "one of eight should read an eighth full, not full");

    // And it survives the next reduction rather than being rounded back to
    // solid, which is where the wall of cubes actually appeared.
    const LodLevel &coarser = chainWith(1).level[BlockLodChain::levelForCell(16)];
    expect(coarser.at(0, 0, 0).coverage > 0 && coarser.at(0, 0, 0).coverage < 32,
            "cell 16 should thin further, one filled voxel in sixty-four");

    // An unknown neighbour is not sky. A half streamed crown keeps the density
    // of the half that arrived instead of being averaged towards empty.
    BlockLodChain partial;
    LodLevel &lv = partial.level[BlockLodChain::levelForCell(4)];
    lv.cell = 4;
    lv.n = 4;
    lv.cells.assign(64, LodLevel::Cell());
    LodLevel::Cell &only = lv.at(0, 0, 0);
    only.flags = LodLevel::kKnown;
    fillCell(only, 100);
    only.coverage = 255;
    buildLodMipLevels(partial, BlockLodChain::levelForCell(4));
    expect(partial.level[BlockLodChain::levelForCell(8)].at(0, 0, 0).coverage == 255,
            "the one known child should set the parent, not one eighth of it");
}


// A summary block: cell-4 voxels from `filled(x, y, z)`, the rest known air,
// lit the way lodTakeSummaries lights one under `above`.
template <typename Filled>
BlockLodChain summaryChain(Filled filled, uint8_t raw_day, const BlockLodChain *above,
        bool above_dark = false) {
    BlockLodChain ch;
    LodLevel &lv = ch.level[BlockLodChain::levelForCell(4)];
    lv.cell = 4;
    lv.n = 4;
    lv.cells.assign(64, LodLevel::Cell());
    for (int z = 0; z < 4; ++z)
        for (int y = 0; y < 4; ++y)
            for (int x = 0; x < 4; ++x) {
                LodLevel::Cell &c = lv.at(x, y, z);
                c.flags = LodLevel::kKnown;
                if (filled(x, y, z)) {
                    fillCell(c, CONTENT_UNKNOWN);
                    c.coverage = 255;
                }
            }
    ch.summary = true;
    ch.summary_day = raw_day;
    // What decode_light gives a client; the library's own table is empty
    // until a session sets its curve. Only LIGHT_SUN is fixed, at 255.
    ch.summary_light = raw_day >= LIGHT_SUN ? 255 : (uint8_t)(raw_day * 16);
    buildLodMipLevels(ch, BlockLodChain::levelForCell(4));
    lodLightSummary(ch, lodSummarySkySeed(above, above_dark, raw_day));
    return ch;
}

BlockLodChain solidSummary(uint8_t raw_day = 0) {
    return summaryChain([](int, int, int) { return true; }, raw_day, nullptr);
}

// A cave whose own block is open at the top: a rock floor and air above it.
BlockLodChain caveSummary(uint8_t raw_day, const BlockLodChain *above, bool above_dark = false) {
    return summaryChain([](int, int y, int) { return y == 0; }, raw_day, above, above_dark);
}

uint8_t summaryDay(const BlockLodChain &ch, int cell, int x, int y, int z) {
    const LodLevel::Cell *c = ch.cellAt(cell, x, y, z);
    expect(c && (c->flags & LodLevel::kLit), "summary air cell was not lit at all");
    return c->day;
}

void testCaveUnderRockAboveIsDark() {
    // The cave's own block has nothing over it, but the block above is rock.
    // Raw day 14 is a lava lit cave; 15 is a cave Luanti lit as open sky.
    const BlockLodChain rock = solidSummary();
    for (uint8_t raw : {(uint8_t)14, (uint8_t)LIGHT_SUN}) {
        const BlockLodChain cave = caveSummary(raw, &rock);
        expect(summaryDay(cave, 4, 1, 2, 1) == 0, "cave under rock in the block above was sky lit");
        expect(summaryDay(cave, 16, 0, 0, 0) == 0, "cave under rock was sky lit at cell 16");
        expect(cave.sky_below == 0, "cave under rock passed sky to the block below");
    }
    // A cave in an all-air block that is itself dark (cave air above).
    const BlockLodChain under_cave_air = caveSummary(LIGHT_SUN, nullptr, true);
    expect(summaryDay(under_cave_air, 4, 1, 2, 1) == 0, "cave under dark cave air was sky lit");
    // Nothing known above and no sunlight in the block: lava, not sky.
    const BlockLodChain lava = caveSummary(14, nullptr);
    expect(summaryDay(lava, 4, 1, 2, 1) == 0, "lava lit summary was drawn as open sky");
}

void testRavineOpenThroughSeveralBlocks() {
    // A two-voxel-wide ravine at x = 1..2 through three blocks, the bottom
    // one with a floor. Beside it at x = 3 the bottom block has a pocket of
    // air open to its own top, under the rock wall of the blocks above.
    auto walls = [](int x, int, int) { return x == 0 || x == 3; };
    const BlockLodChain top = summaryChain(walls, LIGHT_SUN, nullptr);
    const BlockLodChain middle = summaryChain(walls, LIGHT_SUN, &top);
    const BlockLodChain bottom = summaryChain([](int x, int y, int) {
        return y == 0 || x == 0;
    }, LIGHT_SUN, &middle);
    const uint8_t sun = 255;
    expect(summaryDay(top, 4, 1, 1, 1) == sun, "ravine top was not sky lit");
    expect(summaryDay(middle, 4, 2, 0, 3) == sun, "ravine middle was not sky lit");
    expect(summaryDay(bottom, 4, 1, 1, 1) == sun, "ravine floor open to the sky was not lit");
    expect(summaryDay(bottom, 4, 3, 1, 2) == 0, "pocket under rock beside the ravine was sky lit");
    expect((bottom.sky_below & (1u << (2 * 4 + 1))) == 0, "the ravine floor passed sky through rock");

    // The far face of the ravine floor reads that light.
    NodeDefManager ndef;
    LodRegionSpec spec;
    spec.blocks = 1;
    spec.cell = 4;
    spec.member = [](v3s16 bp) { return bp == v3s16(0, 0, 0); };
    spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
        if (bp == v3s16(0, 0, 0)) return &bottom;
        if (bp == v3s16(0, 1, 0)) return &middle;
        return nullptr;
    };
    spec.drawn_cell = [](v3s16 bp) { return bp == v3s16(0, 0, 0) ? 4 : -1; };
    LodTileCache tiles;
    const auto mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
    // Floor tops at y = 4: the ravine's start at x = 4, the pocket's end at
    // x = 16. Nothing else has a top there.
    int ravine = 0, pocket = 0;
    for (const LodSurface &sf : mesh.surfaces)
        for (size_t i = 0; i < sf.pos.size(); ++i) {
            if (sf.nrm[i].Y < 0.99f || std::fabs(sf.pos[i].Y - 4.0f) > 0.001f)
                continue;
            if (std::fabs(sf.pos[i].X - 4.0f) < 0.001f) {
                ++ravine;
                expect(sf.custom0[i * 4 + 1] == 255, "ravine floor face was not sky lit");
            } else if (std::fabs(sf.pos[i].X - 16.0f) < 0.001f) {
                ++pocket;
                expect(sf.custom0[i * 4 + 1] == 0, "pocket floor under rock was sky lit");
            }
        }
    expect(ravine > 0 && pocket > 0, "ravine or pocket floor face was not drawn");
}

void testCaveDarkensWhenBlockAboveArrives() {
    // The cave arrives first with nothing known above it and full sun in its
    // record, so it is open sky for now. A cave in the block under it too.
    std::map<v3s16, std::shared_ptr<const BlockLodChain>> chains;
    chains[v3s16(0, 0, 0)] = std::make_shared<BlockLodChain>(caveSummary(LIGHT_SUN, nullptr));
    chains[v3s16(0, -1, 0)] = std::make_shared<BlockLodChain>(
            caveSummary(LIGHT_SUN, chains[v3s16(0, 0, 0)].get()));
    const std::shared_ptr<const BlockLodChain> first = chains[v3s16(0, 0, 0)];
    expect(summaryDay(*first, 4, 1, 2, 1) == 255,
            "cave with nothing known above was not provisionally lit");
    // Then the rock above it arrives.
    chains[v3s16(0, 1, 0)] = std::make_shared<BlockLodChain>(solidSummary());
    std::vector<v3s16> replaced;
    auto get = [&](v3s16 bp) -> std::shared_ptr<const BlockLodChain> {
        auto it = chains.find(bp);
        return it == chains.end() ? nullptr : it->second;
    };
    const int relit = lodPropagateSky(v3s16(0, 1, 0), get, [](v3s16) { return false; },
            [&](v3s16 bp, std::shared_ptr<const BlockLodChain> chain) {
                replaced.push_back(bp);
                chains[bp] = std::move(chain);
            });
    expect(relit == 1 && replaced.size() == 1 && replaced[0] == v3s16(0, 0, 0),
            "the block under newly arrived rock was not relit exactly once");
    expect(summaryDay(*chains[v3s16(0, 0, 0)], 4, 1, 2, 1) == 0,
            "cave stayed sky lit after the rock above it arrived");
    expect(summaryDay(*chains[v3s16(0, 0, 0)], 16, 0, 0, 0) == 0,
            "cave's coarse light stayed sky lit after the rock above it arrived");
    expect(summaryDay(*first, 4, 1, 2, 1) == 255,
            "relighting changed a published chain in place");
    // Its floor was already closed, so the block below needed nothing.
    expect(lodPropagateSky(v3s16(0, 1, 0), get, [](v3s16) { return false; },
            [&](v3s16, std::shared_ptr<const BlockLodChain>) {}) == 0,
            "a second pass relit an unchanged column");

    // The same through an open shaft: rock arriving on top darkens every
    // block of it, walking down.
    chains.clear();
    auto shaft = [](int x, int, int z) { return !(x == 1 && z == 1); };
    chains[v3s16(0, 2, 0)] = std::make_shared<BlockLodChain>(summaryChain(shaft, LIGHT_SUN, nullptr));
    for (int y = 1; y >= 0; --y)
        chains[v3s16(0, y, 0)] = std::make_shared<BlockLodChain>(summaryChain(shaft, LIGHT_SUN,
                chains[v3s16(0, y + 1, 0)].get()));
    expect(summaryDay(*chains[v3s16(0, 0, 0)], 4, 1, 0, 1) == 255,
            "open shaft was not lit to its bottom");
    chains[v3s16(0, 3, 0)] = std::make_shared<BlockLodChain>(solidSummary());
    lodPropagateSky(v3s16(0, 3, 0), get, [](v3s16) { return false; },
            [&](v3s16 bp, std::shared_ptr<const BlockLodChain> chain) { chains[bp] = std::move(chain); });
    for (int y = 0; y <= 2; ++y)
        expect(summaryDay(*chains[v3s16(0, y, 0)], 4, 1, 1, 1) == 0,
                "capped shaft stayed sky lit below the cap");
}

void testCoarseCellMixingSkyAndCaveAir() {
    // One cell-8 parent with four sky lit and four cave children: it must
    // not count as fully sky lit.
    BlockLodChain ch = airChain();
    LodLevel &lv = ch.level[BlockLodChain::levelForCell(4)];
    for (int z = 0; z < 2; ++z)
        for (int y = 0; y < 2; ++y)
            for (int x = 0; x < 2; ++x)
                lv.at(x, y, z).day = y == 1 ? 255 : 0;
    buildLodMipLevels(ch, BlockLodChain::levelForCell(4));
    const uint8_t mixed = ch.cellAt(8, 0, 0, 0)->day;
    expect(mixed > 64 && mixed < 192, "coarse cell of sky and cave air was not between the two");
    expect(ch.cellAt(8, 1, 1, 1)->day == 255, "coarse cell of open air lost its sky");
}

// Faces whose neighbour has no chain take their light from what is known
// about it: cave air is dark, anything else keeps the sky.
void testFaceTowardsCaveAirIsDark() {
    NodeDefManager ndef;
    const BlockLodChain rock = solidSummary();
    for (bool dark : {true, false}) {
        LodRegionSpec spec;
        spec.blocks = 1;
        spec.cell = 4;
        spec.member = [](v3s16 bp) { return bp == v3s16(0, 0, 0); };
        spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
            return bp == v3s16(0, 0, 0) ? &rock : nullptr;
        };
        spec.drawn_cell = [](v3s16 bp) { return bp == v3s16(0, 0, 0) ? 4 : -1; };
        spec.dark_air = [dark](v3s16 bp) { return dark && bp == v3s16(1, 0, 0); };
        LodTileCache tiles;
        const auto mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
        int east = 0, west = 0;
        for (const LodSurface &sf : mesh.surfaces)
            for (size_t i = 0; i < sf.pos.size(); ++i) {
                const uint8_t day = sf.custom0[i * 4 + 1];
                if (sf.nrm[i].X > 0.99f) {
                    ++east;
                    expect(day == (dark ? 0 : 255), dark ? "wall facing cave air was sky lit" :
                            "wall facing unknown air lost its sky");
                } else if (sf.nrm[i].X < -0.99f) {
                    ++west;
                    expect(day == 255, "wall facing unknown air lost its sky");
                }
            }
        expect(east > 0 && west > 0, "rock block did not draw its side walls");
    }
}

// An exact neighbour drops interior air from its sparse cell-1 records. The
// wall facing it reads the neighbour's coarser light, not the sky.
void testFaceTowardsExactCaveIsDark() {
    NodeDefManager ndef;
    // Solid rock is not lit, as buildLodChain classifies it.
    BlockLodChain wall = fineAirChain();
    for (LodLevel::Cell &c : wall.level[0].cells) {
        c.flags &= ~LodLevel::kLit;
        fillCell(c, CONTENT_UNKNOWN);
    }
    buildLodMipLevels(wall, 0);
    compactLodFineBoundary(wall);
    BlockLodChain cave = fineAirChain();
    for (LodLevel::Cell &c : cave.level[0].cells)
        c.day = 0;
    fillCell(cave.level[0].at(15, 15, 15), CONTENT_UNKNOWN);
    buildLodMipLevels(cave, 0);
    compactLodFineBoundary(cave);
    expect(cave.cellAt(1, 0, 8, 8) == nullptr, "cave interior air was retained; test is moot");
    LodRegionSpec spec;
    spec.blocks = 1;
    spec.cell = 1;
    spec.member = [](v3s16 bp) { return bp == v3s16(0, 0, 0); };
    spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
        if (bp == v3s16(0, 0, 0)) return &wall;
        if (bp == v3s16(1, 0, 0)) return &cave;
        return nullptr;
    };
    spec.drawn_cell = [](v3s16 bp) {
        if (bp == v3s16(0, 0, 0)) return 1;
        if (bp == v3s16(1, 0, 0)) return 1;
        return -1;
    };
    LodTileCache tiles;
    const auto mesh = meshLodRegion(spec, &ndef, nullptr, nullptr, tiles);
    int east = 0;
    for (const LodSurface &sf : mesh.surfaces)
        for (size_t i = 0; i < sf.pos.size(); ++i)
            if (sf.nrm[i].X > 0.99f) {
                ++east;
                expect(sf.custom0[i * 4 + 1] == 0, "wall facing an exact cave block was sky lit");
            }
    expect(east > 0, "wall facing the exact cave block was not drawn");
}

void testAppendedVertexAttributes() {
    auto make = [](uint8_t light) {
        LodRegionMesh mesh;
        LodSurface sf;
        sf.texture_id = 7;
        sf.pos = {v3f(0, 0, 0), v3f(1, 0, 0), v3f(0, 0, 1)};
        sf.nrm.assign(3, v3f(0, 1, 0));
        sf.uv.assign(3, v2f(0, 0));
        sf.uv2.assign(3, v2f(0, 0));
        sf.col.assign(3, 0xffffffff);
        sf.custom0.assign(12, light);
        sf.custom2.assign(12, light + 1);
        sf.idx = {0, 1, 2};
        mesh.surfaces.push_back(std::move(sf));
        return mesh;
    };
    auto mesh = make(3);
    appendLodMesh(mesh, make(9));
    expect(mesh.surfaces.size() == 1, "matching material groups must merge");
    const auto &sf = mesh.surfaces[0];
    expect(sf.pos.size() == 6 && sf.nrm.size() == 6 && sf.uv.size() == 6 &&
            sf.uv2.size() == 6 && sf.col.size() == 6, "merged vertex arrays must align");
    expect(sf.custom0.size() == 24 && sf.custom2.size() == 24,
            "merged light and AO attributes must cover every vertex");
    expect(sf.custom2[11] == 4 && sf.custom2[12] == 10,
            "both source AO values must survive the merge");
    expect(sf.idx == std::vector<u32>({0, 1, 2, 3, 4, 5}), "merged indices must be rebased");
}

int main() {
    testAppendedVertexAttributes();
    testSparseCaptureBounds();
    testHorizonUsesSurfaceHeight();
    testProjectedDetailIncludesAltitudeAndResolution();
    testRecursiveVoxelMip();
    testMipMaterialsFollowExposedFaces();
    testLiquidSurfaceHeightSurvivesMip();
    testLiquidIsAnEnvelopeOverSolid();
    testIsolatedVoxelHasAllSixFaces();
    testCliffCrossesVerticalRegions();
    testFullMapblockIslandHasAnUnderside();
    testCanopyDoesNotDrapeAcrossKnownAir();
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
    testCellOneGroundBoundary();
    testCellOneMeetsCellFourWithoutOverlap();
    testUnknownFrontierIsClosed();
    testTierBoundaryUsesDrawnOccupancy();
    testCoverageSeparatesCanopyFromRock();
    testCaveUnderRockAboveIsDark();
    testRavineOpenThroughSeveralBlocks();
    testCaveDarkensWhenBlockAboveArrives();
    testCoarseCellMixingSkyAndCaveAir();
    testFaceTowardsCaveAirIsDark();
    testFaceTowardsExactCaveIsDark();
    std::cout << "goanna_lod_test: ok\n";
    return 0;
}
