// SPDX-License-Identifier: LGPL-2.1-or-later

#include "goanna_lod.h"

#include "mapblock.h"
#include "nodedef.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>

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
    testRecursiveVoxelMip();
    testLiquidSurfaceHeightSurvivesMip();
    testLiquidIsAnEnvelopeOverSolid();
    testIsolatedVoxelHasAllSixFaces();
    testCellOneTreeBoundary();
    testCellOneMeetsCellFourWithoutOverlap();
    testUnknownFrontierIsClosed();
    testTierBoundaryUsesDrawnOccupancy();
    std::cout << "goanna_lod_test: ok\n";
    return 0;
}
