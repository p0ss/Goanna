// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Sub node form, checked on its own, and mostly checked against the other
// implementation of it.
//
// The same authored forms are baked twice: here at mesh time, and in Kythen at
// load time by mods/kythen/core/radial_form.lua. If the two disagree a player
// sees the block change shape on connect, which is the one failure no
// screenshot of either half would ever show. So the reference table below
// comes from running the Lua, and is the real subject of this file.

#include "goanna_radial_form.h"

#include <cmath>
#include <cstdio>
#include <algorithm>
#include <array>
#include <cstring>

using namespace goanna;

namespace {

int g_failures = 0;

void check(bool ok, const char *what) {
    if (!ok) {
        std::printf("FAIL: %s\n", what);
        ++g_failures;
    }
}

// Generated from mods/kythen/core/radial_form.lua in the Kythen repository.
// Regenerate rather than edit: these are the other implementation of the same
// rule, and they are the only thing stopping the two from drifting apart.
//
// They have already earned that once. Adding bores to the Lua changed word 240
// (both Y faces dug through, which is a drilled axis) from 14 boxes to 8, and
// this table failed within a minute of the change. Nothing else in either
// project would have noticed until a player saw a block change shape.
//
// The last four cover drilling: 240 is one bored axis, 4095 is every face dug
// through so all three, and 4095 + 4096 is the same inverted.
struct WordCase {
    uint16_t word;
    int boxes;
    int solid;
};

const WordCase kWordCases[] = {
    {    0,   1, 512},
    {   64,   1, 512},
    {  128,   5, 508},
    {  192,  13, 496},
    {    1,   1, 512},
    {    2,   5, 508},
    {    3,  13, 496},
    {  240,   8, 416},
    {   15,   8, 416},
    { 3840,   8, 416},
    { 4095,  28, 312},
    {   68,   1, 512},
    {12288,   1, 512},
    { 4096,   1, 512},
    { 8191,  28, 312},
};

void testAgreesWithTheLua() {
    for (const WordCase &c : kWordCases) {
        const RadialForm form = formFromWord(c.word);
        const std::vector<FormBox> boxes = formBoxes(form, 8);
        const std::vector<bool> grid = formGrid(form, 8);
        int solid = 0;
        for (size_t at = 0; at < grid.size(); ++at) {
            if (grid[at]) { ++solid; }
        }
        char what[128];
        std::snprintf(what, sizeof(what),
                      "word %u bakes to %d boxes as the Lua does", c.word, c.boxes);
        check(static_cast<int>(boxes.size()) == c.boxes, what);
        std::snprintf(what, sizeof(what),
                      "word %u fills %d sub cubes as the Lua does", c.word, c.solid);
        check(solid == c.solid, what);
    }
}

// The property everything rests on. Every node in every existing world carries
// param1 = param2 = 0, so if the zero word meant anything other than untouched
// then turning this on would empty the map. It has to hold in both modes,
// which is why the word stores damage and the damage to extent mapping flips
// with the mode rather than being one constant.
void testZeroIsPristine() {
    const std::vector<FormBox> outward = formBoxes(formFromWord(0), 8);
    check(outward.size() == 1, "a zero word bakes to one box, not 512");
    check(std::fabs(outward[0].x1 + 0.5f) < 1e-6f
          && std::fabs(outward[0].y2 - 0.5f) < 1e-6f,
          "and that box is the node itself, not the ball inside it");
    check(formVolume(formFromWord(0), 8) == 1.0f, "outward zero is solid");
    check(formVolume(formFromWord(0x1000), 8) == 1.0f,
          "inverted zero is solid too, its cavity closed");
}


// Mining and chopping drive this and nothing else does, so the progression has
// to be monotonic and has to saturate. A step that wrapped would put geometry
// on screen that no server could agree with, and on a server that stores the
// result it would then be written back.
void testDiggingIsMonotonicAndSaturates() {
    uint16_t word = 0;
    float last = 1.0f;
    for (int i = 0; i < 6; ++i) {
        word = digWord(word, AXIS_YP, 0.34f);
        const float v = formVolume(formFromWord(word), 8);
        check(v <= last, "volume never grows while digging");
        last = v;
    }
    // Depth, not volume. Volume was the assertion here and it was a proxy that
    // broke the moment the carve became properly local: a narrow deep pit takes
    // very little of a node's volume while being perfectly visible. Measured at
    // kPower 12, a fully dug face leaves 0.97 of the block and a hole you can
    // see.
    int top = 16;
    const RadialForm dug = formFromWord(word);
    for (int j = 15; j >= 0; --j) {
        if (formSolid(dug, 0.0f, (j + 0.5f) / 16.0f - 0.5f, 0.0f)) {
            top = j + 1;
            break;
        }
    }
    check(top <= 13, "a fully dug face has a visible pit in it");
    check(digWord(word, AXIS_YP, 1.0f) == word, "and further digging changes nothing");
}

void testDigProgressIsAFraction() {
    check(digWord(0, AXIS_YP, 0.0f) == 0, "no progress is no damage");
    check(digWord(0, AXIS_YP, 1.0f) != digWord(0, AXIS_YP, 0.34f),
          "a finished dig differs from a third of one");
    check(digWord(0, AXIS_YP, 5.0f) == digWord(0, AXIS_YP, 1.0f),
          "progress past the end is clamped, not wrapped");
    check(digWord(0, AXIS_YP, 1.0f) != digWord(0, AXIS_XN, 1.0f),
          "which face was hit is in the word");
}


void testParamsRoundTrip() {
    for (int p1 = 0; p1 < 256; p1 += 37) {
        for (int p2 = 0; p2 < 256; p2 += 41) {
            const uint16_t w = wordFromParams(static_cast<uint8_t>(p1),
                                              static_cast<uint8_t>(p2));
            check((w & 0xff) == static_cast<uint16_t>(p1), "param1 is the low byte");
            check(((w >> 8) & 0xff) == static_cast<uint16_t>(p2),
                  "param2 is the high byte");
        }
    }
}


void testGreedyBoxesCoverExactlyTheSolidCells() {
    const RadialForm form = formFromWord(digWord(digWord(0, AXIS_YP, 1.0f), AXIS_XN, 0.67f));
    const int n = 8;
    const std::vector<bool> grid = formGrid(form, n);
    std::vector<int> covered(grid.size(), 0);
    for (const FormBox &b : formBoxes(form, n)) {
        for (int k = 0; k < n; ++k) {
            for (int j = 0; j < n; ++j) {
                for (int i = 0; i < n; ++i) {
                    const float x = (static_cast<float>(i) + 0.5f) / n - 0.5f;
                    const float y = (static_cast<float>(j) + 0.5f) / n - 0.5f;
                    const float z = (static_cast<float>(k) + 0.5f) / n - 0.5f;
                    if (x > b.x1 && x < b.x2 && y > b.y1 && y < b.y2
                        && z > b.z1 && z < b.z2) {
                        ++covered[static_cast<size_t>(k) * n * n
                                  + static_cast<size_t>(j) * n + i];
                    }
                }
            }
        }
    }
    for (size_t at = 0; at < grid.size(); ++at) {
        check(covered[at] <= 1, "boxes never overlap");
        check((covered[at] == 1) == grid[at], "boxes cover exactly the solid cells");
    }
}

// The bake has to stay cheap or it cannot ship: nothing culls faces between
// the boxes of one node and each box is six quads, so a naive 8 cubed
// expansion is 512 boxes and 3072 quads for a single node.
void testTheBakeStaysCheap() {
    for (const WordCase &c : kWordCases) {
        // Thirty two, not twenty four: a block drilled through all three axes
        // is the dearest thing a word can describe, at 28 boxes, because a
        // round hole staircases in two axes at once and there are three of
        // them. Everything else in the table is under 16.
        check(formBoxes(formFromWord(c.word), 8).size() <= 32,
              "a structured form bakes to a handful of boxes");
    }
}

// Drilling. A face carve reaches the origin and stops, because a crater bottoms
// out in the middle of the block. Past that it is a hole, which is neither a
// convex clip nor a star shaped carve, so it is its own field. It costs no bit:
// both faces of an axis at full damage IS "dug through from both sides".
void testDiggingThroughOpensABore() {
    const uint16_t one = digWord(0, AXIS_YP, 1.0f);
    check(formFromWord(one).bore[1] == 0.0f, "one face is a crater, not a hole");

    const uint16_t both = digWord(one, AXIS_YN, 1.0f);
    const RadialForm drilled = formFromWord(both);
    check(drilled.bore[1] > 0.0f, "both faces is a hole");
    check(!formSolid(drilled, 0.0f, 0.0f, 0.0f), "and it is open at the middle");
    check(formSolid(drilled, 0.45f, 0.0f, 0.45f), "while the corner is untouched");

    // The bug the origin ordering exists to stop: the origin lies on every bore
    // axis, so testing it after the short circuit left one cube floating in the
    // middle of a hole drilled clean through.
    check(!formSolid(drilled, 0.0f, 0.2f, 0.0f), "the whole shaft is open");
    check(!formSolid(drilled, 0.0f, -0.45f, 0.0f), "right out the far side");
}


void testImpactLocality() {
    const std::array<std::array<float,3>,8> hits = {{{0,.5f,0}, {.125f,.5f,0},
        {.25f,.5f,0}, {.49f,.5f,0}, {.5f,.5f,.5f},
        {-.5f,.15f,-.2f}, {.2f,-.5f,0}, {.1f,.2f,-.5f}}};
    for (const auto &hit : hits) {
        RadialForm form;
        auto previous = formGrid(form,16);
        for (int step=1; step<=5; ++step) {
            form = strike(form,hit[0],hit[1],hit[2],.08f);
            const auto grid = formGrid(form,16);
            int removed=0;
            for (int z=0;z<16;++z) for (int y=0;y<16;++y) for (int x=0;x<16;++x) {
                const int index=z*256+y*16+x;
                check(previous[index] || !grid[index], "successive blows never regrow material");
                if (!grid[index]) ++removed;
            }
            check(removed>0, "the first visible blow cuts face, edge and corner impacts");
            previous=grid;
        }
    }
    RadialForm moving;
    auto old=formGrid(moving,16);
    for (int i=0;i<12;++i) {
        moving=strike(moving,.03f*i-.15f,.5f,.06f,.025f);
        const auto now=formGrid(moving,16);
        for (size_t j=0;j<now.size();++j)
            check(old[j] || !now[j], "moving the impact never fills an existing cut");
        old=now;
    }
}

void testInterpolatedControls() {
    // Halfway between face, two edges and corner: four equal influences.
    const auto mixed = strike(RadialForm(), .25f, .5f, .25f, .2f, AXIS_YP);
    int changed = 0;
    for (const auto &d : mixed.displacement) {
        if (d.axis[1] > 0) ++changed;
        check(d.axis[0] == 0 && d.axis[2] == 0, "top impact has no sideways displacement");
    }
    check(changed == 4, "off-centre impact updates four neighbouring controls");
    check(std::fabs(formInset(mixed, AXIS_YP, .25f,.5f,.25f)-.2f)<1e-6f,
            "interpolated depth at impact equals requested depth");
    for (int f : {AXIS_XN,AXIS_XP,AXIS_YN,AXIS_ZN,AXIS_ZP})
        check(formInset(mixed,f,.1f,.1f,.1f)==0, "unstruck faces keep their extents");
    check(formSolid(mixed, -.49f,.49f,-.49f), "opposite corner remains intact");
    const auto a = strike(RadialForm(), 0,.5f,0,.2f,AXIS_YP);
    const auto b = strike(RadialForm(), .5f,.5f,0,.2f,AXIS_YP);
    RadialForm average;
    for (int i=0;i<26;++i) for (int axis=0;axis<3;++axis)
        average.displacement[i].axis[axis] =
            .5f*(a.displacement[i].axis[axis]+b.displacement[i].axis[axis]);
    for (float x : {-.3f,0.f,.1f,.25f,.4f})
        check(std::fabs(formInset(average,AXIS_YP,x,.5f,0) - .5f*(
                formInset(a,AXIS_YP,x,.5f,0)+formInset(b,AXIS_YP,x,.5f,0)))<1e-6f,
                "surface blends control values, rather than taking a union of cuts");
    // Sweep across the former nearest-slot boundaries and the lattice seams.
    for (int i=-499;i<500;++i) {
        const float x=i*.001f;
        auto left=strike(RadialForm(),x,.5f,.13f,.2f,AXIS_YP);
        auto right=strike(RadialForm(),x+.001f,.5f,.13f,.2f,AXIS_YP);
        for (float q : {-.4f,-.1f,0.f,.1f,.3f,.49f})
            check(std::fabs(formInset(left,AXIS_YP,q,.5f,.13f)-
                    formInset(right,AXIS_YP,q,.5f,.13f))<.003f,
                    "moving the impact continuously changes the surface");
    }
    // Sharing an edge control must not make a later side strike erase top damage.
    auto both=strike(mixed,.5f,.25f,.25f,.15f,AXIS_XP);
    check(formInset(both,AXIS_YP,.25f,.5f,.25f)==formInset(mixed,AXIS_YP,.25f,.5f,.25f),
            "adjacent face retains its deformation when a shared edge is struck");
}

void testDigFrameIndependence() {
    FormDig fine, coarse;
    for (int i=1;i<=240;++i) fine.advance(i/240.f,.125f,.5f,0);
    for (float progress : {.07f,.32f,.68f,1.f}) coarse.advance(progress,.125f,.5f,0);
    check(formGrid(fine.form,16)==formGrid(coarse.form,16), "skipping dig stages preserves depth");
    check(!coarse.advance(1.f,.125f,.5f,0), "holding the same progress adds no damage");
    check(!coarse.advance(.5f,.125f,.5f,0), "earlier progress cannot undo a cut");
    // Health, not surface depth: a half-health sand block is half material,
    // while a harder block loses the same total volume in smaller contacts.
    for (int blows : {2, 3, 8}) for (int face = 0; face < 6; ++face) {
        FormDig dig;
        dig.form.resolution = 16;
        auto before = formGrid(dig.form,16);
        for (int hit = 1; hit <= blows; ++hit) {
            float p[3] = {.21f,-.12f,.34f};
            p[face/2] = (face & 1) ? .5f : -.5f;
            float damage = float(hit)/blows;
            dig.advance(damage,p[0],p[1],p[2],face);
            check(std::abs(formVolume(dig.form,16)-(1-damage)) < .015f,
                    "visible material tracks remaining health on every face");
            auto after = formGrid(dig.form,16);
            for (size_t i=0;i<after.size();++i)
                check(!after[i] || before[i], "a health-based impact cannot refill a cut");
            before = after;
        }
    }
    FormDig moved;
    moved.form.resolution = 16;
    moved.advance(.25f,.2f,.5f,.1f,AXIS_YP);
    const auto before = formGrid(moved.form,16);
    moved.advance(.5f,.5f,-.15f,.3f,AXIS_XP);
    const auto after = formGrid(moved.form,16);
    check(std::abs(formVolume(moved.form,16)-.5f)<.015f,
            "changing impact face retains the cumulative health budget");
    for (size_t i=0;i<after.size();++i)
        check(!after[i] || before[i], "changing faces never restores removed material");
}

// Rasterise every emitted rectangle onto the oriented unit face lattice. Each
// expected interface must be covered exactly once; this catches wrong normals,
// holes, internal faces and overlaps, including the neighbour-owned patches.
void testSurfaceCoverage() {
    constexpr int n=8;
    const int axes[6]={1,1,0,0,2,2};
    for (const auto &hit : std::vector<std::array<float,3>>{{0,.5f,0},{.49f,.5f,.49f},{-.5f,0,-.5f}}) {
        const auto grid=formGrid(strike(RadialForm(),hit[0],hit[1],hit[2],.4f),n);
        for (int mask=0;mask<64;++mask) {
            std::vector<int> expected(6*(n+1)*n*n,0), actual(expected.size(),0);
            auto idx=[&](int f,int layer,int u,int v){return ((f*(n+1)+layer)*n+v)*n+u;};
            auto solid=[&](const int p[3]){return grid[p[2]*n*n+p[1]*n+p[0]];};
            for (int f=0;f<6;++f) {
                const int a=axes[f],u=(a+1)%3,v=(a+2)%3,sign=(f&1)?-1:1;
                for (int z=0;z<n;++z) for (int y=0;y<n;++y) for (int x=0;x<n;++x) {
                    int p[3]={x,y,z};const bool here=solid(p);
                    const int layer=p[a]+(sign>0?1:0),i=p[u],j=p[v];
                    p[a]+=sign;
                    const bool boundary=p[a]<0 || p[a]>=n;
                    if (!boundary) {
                        if (here && !solid(p)) ++expected[idx(f,layer,i,j)];
                    } else if (mask&(1<<f)) {
                        if (here) ++expected[idx(f,layer,i,j)];
                    } else if (!here) {
                        ++expected[idx(f^1,layer,i,j)];
                    }
                }
            }
            const auto quads=formSurfaces(grid,n,mask,63^mask);
            for (const auto &q:quads) {
                const int a=axes[q.face],u=(a+1)%3,v=(a+2)%3;
                const float lo[3]={q.box.x1,q.box.y1,q.box.z1},hi[3]={q.box.x2,q.box.y2,q.box.z2};
                check(lo[a]==hi[a], "surface is a plane, not overlapping cuboids");
                const int layer=std::lround((lo[a]+.5f)*n);
                for (int j=std::lround((lo[v]+.5f)*n); j<std::lround((hi[v]+.5f)*n); ++j)
                    for (int i=std::lround((lo[u]+.5f)*n); i<std::lround((hi[u]+.5f)*n); ++i)
                        ++actual[idx(q.face,layer,i,j)];
                if (q.backing>=0) check(q.face==(q.backing^1), "revealed neighbour faces into the cut");
            }
            check(actual==expected, "every surface and neighbour reveal has exactly one owner");
        }
    }
    check(formSurfaces(formGrid(RadialForm(),n),n).size()==6, "pristine surface is six merged quads");
    check(formSurfaces(formGrid(RadialForm(),n),n,0,63).empty(), "buried pristine block emits nothing");
}

// Export the actual displacement controls and occupancy for the optional Lua parity
// check. No second C++ shape implementation or hand-maintained fixture.
void dumpImpactCases() {
    std::vector<std::array<float,3>> hits = {{0,.5f,0},{.125f,.5f,0},
            {.49f,.5f,.49f},{-.5f,0,-.5f}};
    for (int i=-9;i<=9;++i) hits.push_back({i*.05f,.5f,.13f});
    for (const auto &hit : hits) {
        RadialForm form;
        for (int step=0;step<5;++step) {
            form=strike(form,hit[0],hit[1],hit[2],.08f);
            std::printf("{\"hit\":[%.9g,%.9g,%.9g],\"step\":%d,\"displacement\":[",hit[0],hit[1],hit[2],step);
            bool first=true;
            for (const auto &c:form.displacement) {
                std::printf("%s[%.9g,%.9g,%.9g]",first?"":",",c.axis[0],c.axis[1],c.axis[2]);
                first=false;
            }
            std::printf("],\"grid\":\"");
            for (bool occupied:formGrid(form,16)) std::putchar(occupied?'1':'0');
            std::printf("\"}\n");
        }
    }
}

} // namespace

int main(int argc, char **argv) {
    if (argc==2 && std::strcmp(argv[1], "--dump-impacts")==0) {
        dumpImpactCases();
        return 0;
    }
    testInterpolatedControls();
    testImpactLocality();
    testDigFrameIndependence();
    testSurfaceCoverage();
    testAgreesWithTheLua();
    testZeroIsPristine();
    testDiggingIsMonotonicAndSaturates();
    testDigProgressIsAFraction();
    testParamsRoundTrip();
    testGreedyBoxesCoverExactlyTheSolidCells();
    testTheBakeStaysCheap();
    testDiggingThroughOpensABore();

    if (g_failures != 0) {
        std::printf("%d failure(s)\n", g_failures);
        return 1;
    }
    std::printf("goanna_radial_form_test: all checks passed\n");
    return 0;
}
