// SPDX-License-Identifier: LGPL-2.1-or-later

#include "goanna_lod.h"

#include "nodedef.h"

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
    water.flags |= LodLevel::kFilled | LodLevel::kLiquid;
    water.top = 2;
    for (content_t &face : water.face)
        face = 100;

    buildLodMipLevels(ch, BlockLodChain::levelForCell(4));
    const LodLevel::Cell &cell8 = ch.level[BlockLodChain::levelForCell(8)].at(0, 0, 0);
    const LodLevel::Cell &cell16 = ch.level[BlockLodChain::levelForCell(16)].at(0, 0, 0);
    expect(cell8.flags & LodLevel::kLiquid, "mip lost liquid identity");
    expect(cell8.top == 2, "cell-8 mip raised the liquid surface");
    expect(cell16.top == 2, "cell-16 mip raised the liquid surface");

    BlockLodChain full_child = airChain();
    LodLevel::Cell &full_water =
            full_child.level[BlockLodChain::levelForCell(4)].at(0, 0, 0);
    full_water.flags |= LodLevel::kFilled | LodLevel::kLiquid;
    full_water.top = 0;
    for (content_t &face : full_water.face)
        face = 100;
    buildLodMipLevels(full_child, BlockLodChain::levelForCell(4));
    expect(full_child.level[BlockLodChain::levelForCell(8)].at(0, 0, 0).top == 4,
            "full liquid child expanded to the parent ceiling");
    expect(full_child.level[BlockLodChain::levelForCell(16)].at(0, 0, 0).top == 4,
            "full liquid child expanded through the recursive mip");
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
    for (const LodSurface &surface : mesh.surfaces)
        for (const v3f &normal : surface.nrm)
            underside |= normal.Y < -0.99f;
    expect(underside, "isolated voxel has no lower face");
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
    testIsolatedVoxelHasAllSixFaces();
    testUnknownFrontierIsClosed();
    testTierBoundaryUsesDrawnOccupancy();
    std::cout << "goanna_lod_test: ok\n";
    return 0;
}
