// SPDX-License-Identifier: LGPL-2.1-or-later

#include "goanna_trees.h"
#include "goanna_tree_atlas.h"

#include <cmath>
#include <cstdlib>
#include <iostream>

using namespace goanna;

namespace {

void expect(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "goanna_trees_test: " << message << "\n";
        std::abort();
    }
}

constexpr content_t kWood = 10;
constexpr content_t kLeaf = 20;

TreeField emptyField(int side, int cell = 1) {
    TreeField f;
    f.origin = v3s16(0, 0, 0);
    f.size = v3s16(side, side, side);
    f.cell = cell;
    f.resize();
    return f;
}

void putTrunk(TreeField &f, int x, int z, int y0, int y1) {
    for (int y = y0; y <= y1; ++y) {
        const size_t i = f.index(x, y, z);
        f.content[i] = kWood;
        f.canopy[i] = 1;
        f.trunk[i] = 1;
    }
}

void putCrown(TreeField &f, int cx, int cz, int y0, int y1, int reach) {
    for (int y = y0; y <= y1; ++y)
        for (int z = cz - reach; z <= cz + reach; ++z)
            for (int x = cx - reach; x <= cx + reach; ++x) {
                if (!f.inside(x, y, z))
                    continue;
                const size_t i = f.index(x, y, z);
                if (f.trunk[i])
                    continue;
                f.content[i] = kLeaf;
                f.canopy[i] = 1;
            }
}

// A tree standing on its own is the case the far field draws worst and the one
// an impostor has to get exactly right: the foot of the trunk where the trunk
// is, the height it really is, the crown as wide as it really is.
void testLoneTreeIsMeasured() {
    TreeField f = emptyField(16);
    putTrunk(f, 8, 8, 0, 4);
    putCrown(f, 8, 8, 4, 6, 2);
    std::vector<TreeInstance> trees = detectTrees(f);
    expect(trees.size() == 1, "a lone tree should be found exactly once");
    const TreeInstance &t = trees[0];
    expect(std::abs(t.base.X - 8.5f) < 0.01f && std::abs(t.base.Z - 8.5f) < 0.01f,
            "the impostor stands at the middle of the trunk's own voxel");
    expect(std::abs(t.base.Y - 0.0f) < 0.01f, "it stands on the foot of the trunk");
    expect(std::abs(t.height - 7.0f) < 0.01f, "height runs trunk foot to crown top");
    expect(std::abs(t.radius - 2.5f) < 0.01f, "the crown is as wide as the crown");
    expect(t.trunk == kWood && t.leaves == kLeaf, "species comes from the wood and the foliage");
}

// Two trees touching at the leaves are two trees. Drawing them as one is the
// fault this exists to fix, only larger.
void testTouchingCrownsStayTwoTrees() {
    TreeField f = emptyField(20);
    putTrunk(f, 5, 8, 0, 4);
    putTrunk(f, 11, 8, 0, 4);
    putCrown(f, 5, 8, 4, 6, 3);
    putCrown(f, 11, 8, 4, 6, 3);
    std::vector<TreeInstance> trees = detectTrees(f);
    expect(trees.size() == 2, "a stand joined at the leaves is still two trees");
    const float a = std::min(trees[0].base.X, trees[1].base.X);
    const float b = std::max(trees[0].base.X, trees[1].base.X);
    expect(std::abs(a - 5.5f) < 0.01f && std::abs(b - 11.5f) < 0.01f,
            "each keeps its own trunk's position rather than their average");
}

// What the far field can honestly answer at four node voxels: a tree on its
// own, and nothing at all for a wood. Drawing two enormous lumps for a stand
// of hundreds is worse than drawing none, which is what this rejects.
void testIsolatedOnlyRejectsAStand() {
    TreeDetectOptions coarse;
    coarse.isolated_only = true;

    TreeField stand = emptyField(20);
    putTrunk(stand, 5, 8, 0, 4);
    putTrunk(stand, 11, 8, 0, 4);
    putCrown(stand, 5, 8, 4, 6, 3);
    putCrown(stand, 11, 8, 4, 6, 3);
    expect(detectTrees(stand).size() == 2, "at node resolution it is two trees");
    expect(detectTrees(stand, coarse).empty(),
            "at four it is a stand, and a stand is the aggregate tier's");

    TreeField lone = emptyField(20);
    putTrunk(lone, 8, 8, 0, 4);
    putCrown(lone, 8, 8, 4, 6, 2);
    expect(detectTrees(lone, coarse).size() == 1,
            "but a tree standing on its own still comes through");
}

void testStrayLeavesAreNotTrees() {
    TreeField f = emptyField(16);
    const size_t i = f.index(4, 4, 4);
    f.content[i] = kLeaf;
    f.canopy[i] = 1;
    expect(detectTrees(f).empty(), "one leaf is not a tree");

    // A crown whose trunk is outside the field would be drawn hanging in the
    // air if its position were guessed, so it is left alone by default.
    TreeField g = emptyField(16);
    putCrown(g, 8, 8, 6, 10, 2);
    expect(detectTrees(g).empty(), "foliage with no stem is not placed by guesswork");
    TreeDetectOptions allow;
    allow.allow_trunkless = true;
    expect(detectTrees(g, allow).size() == 1, "unless it is asked for explicitly");
}

// A closed canopy has no separable trees in it, and inventing one enormous tree
// for the whole thing is worse than the box it replaced. That case belongs to
// the aggregate tier and its coverage.
// A log lying on the ground is a trunk with leaves beside it, and drawing a
// tree for it puts saplings through every forest floor.
void testStumpsAreNotTrees() {
    TreeField f = emptyField(16);
    putTrunk(f, 8, 8, 0, 1);
    putCrown(f, 8, 8, 1, 2, 1);
    expect(detectTrees(f).empty(), "a two node stump is not a tree");
}

void testClosedCanopyIsLeftToTheAggregateTier() {
    TreeField f = emptyField(48);
    putTrunk(f, 24, 24, 0, 4);
    putCrown(f, 24, 24, 5, 7, 20);
    expect(detectTrees(f).empty(), "a canopy twenty nodes across is not one tree");
}

// A summary's voxels are four nodes wide, so everything scales by the cell and
// nothing assumes nodes.
void testCoarseFieldScalesToNodes() {
    TreeField f = emptyField(16, 4);
    putTrunk(f, 8, 8, 0, 4);
    putCrown(f, 8, 8, 4, 6, 2);
    std::vector<TreeInstance> trees = detectTrees(f);
    expect(trees.size() == 1, "the same tree, found in coarser voxels");
    const TreeInstance &t = trees[0];
    expect(std::abs(t.base.X - 34.0f) < 0.01f, "position is in nodes, not voxels");
    expect(std::abs(t.height - 28.0f) < 0.01f, "so is height");
    // Two voxels of reach at four nodes each, plus the half node that puts the
    // edge inside the outermost voxel rather than outside it.
    expect(std::abs(t.radius - 8.5f) < 0.01f, "and so is the crown, without the coarse bias");
    expect(t.cell == 4, "and it records how coarsely it was seen");
}


// The impostor is built from the voxels the detector assigned to that tree, so
// a tree in a stand carries its own crown and not the one next to it.
void testMaskIsTheTreesOwnVoxels() {
    TreeField f = emptyField(20);
    putTrunk(f, 5, 8, 0, 4);
    putTrunk(f, 11, 8, 0, 4);
    putCrown(f, 5, 8, 4, 6, 3);
    putCrown(f, 11, 8, 4, 6, 3);
    std::vector<TreeMask> masks;
    std::vector<TreeInstance> trees = detectTrees(f, {}, &masks);
    expect(trees.size() == 2 && masks.size() == 2, "a mask per tree, in the same order");
    for (const TreeMask &m : masks) {
        int wood = 0, leaf = 0;
        for (content_t c : m.content) {
            if (c == kWood) ++wood;
            if (c == kLeaf) ++leaf;
        }
        expect(wood == 5, "each mask holds one trunk, not both");
        expect(leaf > 0, "and its own foliage");
        expect(m.size.X <= 9, "and is no wider than the tree it belongs to");
    }
}

// Two trees of the same shape and colour must share a slot, or a forest of one
// species would fill the atlas with four hundred copies of one oak.
void testIdenticalTreesShareASlot() {
    TreeField f = emptyField(16);
    putTrunk(f, 8, 8, 0, 4);
    putCrown(f, 8, 8, 4, 6, 2);
    std::vector<TreeMask> masks;
    detectTrees(f, {}, &masks);
    expect(masks.size() == 1, "one tree to build from");

    auto colour = [](content_t c) -> uint32_t {
        return c == kWood ? 0xff5a3a1eu : 0xff2f6a2fu;
    };
    TreeVolume a = buildTreeVolume(masks[0], colour);
    TreeVolume b = buildTreeVolume(masks[0], colour);
    expect(a.key == b.key && a.key != 0, "the same tree hashes the same");

    TreeAtlas atlas;
    const int first = atlas.add(a);
    const int again = atlas.add(b);
    expect(first == 0 && again == 0, "and takes one slot, not two");
    expect(atlas.used() == 1, "so the atlas holds one tree");

    // A different species is a different tree even at the same shape.
    TreeVolume other = buildTreeVolume(masks[0], [](content_t) { return 0xffffffffu; });
    expect(atlas.add(other) == 1, "a differently coloured tree takes its own slot");
    expect(atlas.used() == 2, "and the atlas grows by one");
}

// One slot per species, not per tree. Sharing by exact shape was measured
// against a real wood and shared almost nothing, because the generator rotates
// and resizes every tree and the ground clips it.
void testSpeciesShareOneSlot() {
    TreeField f = emptyField(20);
    putTrunk(f, 5, 8, 0, 4);
    putTrunk(f, 13, 8, 0, 6);      // same species, taller, its own crown
    putCrown(f, 5, 8, 4, 6, 2);
    putCrown(f, 13, 8, 6, 9, 3);
    std::vector<TreeMask> masks;
    std::vector<TreeInstance> trees = detectTrees(f, {}, &masks);
    expect(trees.size() == 2, "two trees of one species");
    expect(std::abs(trees[0].height - trees[1].height) > 1.0f,
            "of genuinely different heights, so this is not a trivial case");

    auto colour = [](content_t c) { return c == kWood ? 0xff5a3a1eu : 0xff2f6a2fu; };
    TreeAtlas atlas;
    for (size_t i = 0; i < masks.size(); ++i) {
        TreeVolume v = buildTreeVolume(masks[i], colour);
        expect(v.key != treePrototypeKey(trees[i].trunk, trees[i].leaves),
                "the content hash and the species key are different things");
        v.key = treePrototypeKey(trees[i].trunk, trees[i].leaves);
        atlas.add(v);
    }
    expect(atlas.used() == 1, "both oaks stand on one oak");

    // Variants exist so a hillside is not one picture repeated.
    TreeVolume v = buildTreeVolume(masks[0], colour);
    v.key = treePrototypeKey(trees[0].trunk, trees[0].leaves, 1);
    expect(atlas.add(v) == 1, "a second variant of the same species is its own slot");
    expect(atlas.used() == 2, "so the atlas grows by exactly one");
}

// A crown in the sun above a trunk in shade is the ordinary case, so one light
// value per tree has to be wrong for one of them. Two are carried.
void testLightIsTakenAtTwoHeights() {
    TreeField f = emptyField(16);
    putTrunk(f, 8, 8, 0, 6);
    putCrown(f, 8, 8, 6, 10, 2);
    f.resizeLight();
    // Dark at the foot, bright at the crown, the way a wood actually is.
    for (int z = 0; z < 16; ++z)
        for (int y = 0; y < 16; ++y)
            for (int x = 0; x < 16; ++x) {
                const size_t i = f.index(x, y, z);
                f.day[i] = (uint8_t)(y < 6 ? 40 : 230);
                f.night[i] = (uint8_t)(y < 6 ? 90 : 0);
            }
    std::vector<TreeInstance> trees = detectTrees(f);
    expect(trees.size() == 1, "one tree");
    expect(trees[0].day_base < trees[0].day_top, "the crown is lighter than the foot");
    expect(trees[0].day_base < 120 && trees[0].day_top > 150,
            "and both are near what was actually there");
    expect(trees[0].night_base > trees[0].night_top,
            "block light runs the other way here, and is not confused with sky");

    // A field with no light at all must not turn every tree black.
    TreeField g = emptyField(16);
    putTrunk(g, 8, 8, 0, 6);
    putCrown(g, 8, 8, 6, 10, 2);
    std::vector<TreeInstance> unlit = detectTrees(g);
    expect(unlit.size() == 1 && unlit[0].day_base == 255 && unlit[0].day_top == 255,
            "no light data means unknown, which is daylight, not darkness");
}

void testAtlasPlacesSlotsWithoutOverlapping() {
    TreeAtlas atlas(v3s16(8, 12, 8), 2, 2);
    expect(atlas.capacity() == 4, "two by two slots");
    expect(atlas.size().X == 16 && atlas.size().Y == 12 && atlas.size().Z == 16,
            "the atlas is the grid of them");
    expect(atlas.slotOrigin(0) == v3s16(0, 0, 0), "slot 0 at the corner");
    expect(atlas.slotOrigin(1) == v3s16(8, 0, 0), "slot 1 along x");
    expect(atlas.slotOrigin(2) == v3s16(0, 0, 8), "slot 2 wraps to the next row");
    expect(atlas.slotOrigin(3) == v3s16(8, 0, 8), "slot 3 at the far corner");
}

// A tree taller than its slot is reduced to fit rather than having its top cut
// off, and a reduced crown keeps its thin parts: averaging them away is what
// turns a tree into a lollipop.
void testOversizeTreeIsReducedNotCropped() {
    TreeField f = emptyField(64);
    putTrunk(f, 32, 32, 0, 30);
    putCrown(f, 32, 32, 28, 40, 5);
    std::vector<TreeMask> masks;
    std::vector<TreeInstance> trees = detectTrees(f, {}, &masks);
    expect(trees.size() == 1 && masks.size() == 1, "one very tall tree");
    expect(masks[0].size.Y > 20, "taller than the slot it is going into");

    TreeAtlas atlas(v3s16(24, 20, 24), 1, 1);
    TreeVolume v = buildTreeVolume(masks[0], [](content_t c) {
        return c == kWood ? 0xff5a3a1eu : 0xff2f6a2fu;
    });
    expect(atlas.add(v) == 0, "it still fits somewhere");

    // The crown has to survive the reduction, at the top of the slot.
    const v3s16 size = atlas.size();
    int top_filled = 0;
    for (int z = 0; z < size.Z; ++z)
        for (int x = 0; x < size.X; ++x)
            if (atlas.voxels()[((size_t)z * size.Y + (size.Y - 1)) * size.X + x] >> 24)
                ++top_filled;
    expect(top_filled > 0, "the top of the tree is still in the slot");
    expect(atlas.occupancy() > 0.02f, "and the slot is actually used, not a tree in a corner");
    int foot_filled = 0;
    for (int z = 0; z < size.Z; ++z)
        for (int x = 0; x < size.X; ++x)
            if (atlas.voxels()[((size_t)z * size.Y + 0) * size.X + x] >> 24)
                ++foot_filled;
    expect(foot_filled > 0, "and so is the foot it stands on");
}

} // namespace

int main() {
    testLoneTreeIsMeasured();
    testTouchingCrownsStayTwoTrees();
    testIsolatedOnlyRejectsAStand();
    testStrayLeavesAreNotTrees();
    testStumpsAreNotTrees();
    testClosedCanopyIsLeftToTheAggregateTier();
    testCoarseFieldScalesToNodes();
    testMaskIsTheTreesOwnVoxels();
    testIdenticalTreesShareASlot();
    testSpeciesShareOneSlot();
    testLightIsTakenAtTwoHeights();
    testAtlasPlacesSlotsWithoutOverlapping();
    testOversizeTreeIsReducedNotCropped();
    std::cout << "goanna_trees_test: ok\n";
    return 0;
}
