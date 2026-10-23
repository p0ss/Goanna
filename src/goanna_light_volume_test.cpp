// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Checks floodColouredLight (goanna_light_volume.cpp) on grids whose answer
// is known by inspection: a level 14 lamp in open air gives Luanti's own
// levels, one less per node of Manhattan distance; its colour is the same
// at every distance; a wall stops light and the light does not find a way
// round that is too long; two lamps keep the brighter level, not the sum,
// and blend their colours where they arrive at the same level; a solid cell
// reads its brightest open neighbour and passes nothing on.
//
// Build and run:
//   cmake --build build --target goanna_light_volume_test && ./build/goanna_light_volume_test

#include "goanna_light_volume.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <vector>

using namespace goanna;

namespace {

int failures = 0;

void check(bool ok, const char *what) {
    if (!ok) {
        ++failures;
        std::printf("FAIL: %s\n", what);
    }
}

LightVolumeGrid open(int n) {
    LightVolumeGrid g;
    g.resize(n, n, n);
    std::fill(g.pass.begin(), g.pass.end(), 1);
    return g;
}

void lamp(LightVolumeGrid &g, int x, int y, int z, int level, int r, int gr, int b) {
    const size_t i = g.index(x, y, z);
    g.emit[i] = (uint8_t)level;
    g.colour[i * 3] = (uint8_t)r;
    g.colour[i * 3 + 1] = (uint8_t)gr;
    g.colour[i * 3 + 2] = (uint8_t)b;
}

struct Result {
    std::vector<uint8_t> level, colour;
};

Result flood(const LightVolumeGrid &g) {
    Result r;
    floodColouredLight(g, r.level, r.colour);
    return r;
}

int lv(const LightVolumeGrid &g, const Result &r, int x, int y, int z) { return r.level[g.index(x, y, z)]; }
int col(const LightVolumeGrid &g, const Result &r, int x, int y, int z, int c) {
    return r.colour[g.index(x, y, z) * 3 + c];
}

} // namespace

int main() {
    {
        // A level 14 lamp in open air: Luanti's levels exactly, and a warm
        // colour that stays the same out to the last lit node.
        LightVolumeGrid g = open(33);
        lamp(g, 16, 16, 16, 14, 255, 180, 106);
        Result r = flood(g);
        bool levels = true, hue = true;
        for (int z = 0; z < 33; ++z)
            for (int y = 0; y < 33; ++y)
                for (int x = 0; x < 33; ++x) {
                    const int d = std::abs(x - 16) + std::abs(y - 16) + std::abs(z - 16);
                    const int want = std::max(0, 14 - d);
                    if (lv(g, r, x, y, z) != want) levels = false;
                    if (want > 0 && (col(g, r, x, y, z, 0) != 255 || col(g, r, x, y, z, 1) != 180 ||
                                            col(g, r, x, y, z, 2) != 106))
                        hue = false;
                }
        check(levels, "a lamp in open air gives 14 less the Manhattan distance");
        check(hue, "a lamp's colour is the same at every distance");
    }
    {
        // A wall across x = 10, open only at its top row: light must go round.
        LightVolumeGrid g = open(21);
        for (int z = 0; z < 21; ++z)
            for (int y = 0; y < 20; ++y) g.pass[g.index(10, y, z)] = 0;
        lamp(g, 8, 2, 10, 14, 255, 255, 255);
        Result r = flood(g);
        check(lv(g, r, 9, 2, 10) == 13, "light reaches the wall's lit face");
        // Through the gap at y = 20 it is 2 + 18 + 1 + 18 nodes: dark.
        check(lv(g, r, 11, 2, 10) == 0, "no light through the wall");
        check(lv(g, r, 10, 2, 10) == 13, "a solid cell reads the light in front of it");
    }
    {
        // Two lamps of the same level and different colours: halfway
        // between, both arrive at the same level and the colours blend;
        // nearer either, its own colour wins.
        LightVolumeGrid g = open(21);
        lamp(g, 6, 10, 10, 14, 255, 0, 0);
        lamp(g, 14, 10, 10, 14, 0, 0, 255);
        Result r = flood(g);
        check(lv(g, r, 10, 10, 10) == 10, "two lamps keep the level, not the sum");
        check(col(g, r, 10, 10, 10, 0) > 100 && col(g, r, 10, 10, 10, 2) > 100,
                "colours blend where two lamps arrive at the same level");
        check(col(g, r, 8, 10, 10, 0) == 255 && col(g, r, 8, 10, 10, 2) == 0,
                "nearer one lamp, its own colour wins");
        LightVolumeGrid h = open(21);
        lamp(h, 6, 10, 10, 14, 255, 255, 255);
        lamp(h, 8, 10, 10, 12, 255, 255, 255);
        Result r2 = flood(h);
        check(lv(h, r2, 8, 10, 10) == 12, "the brighter arrival is kept, not the sum");
    }
    {
        // A solid emitter (glowstone) lights its open neighbours.
        LightVolumeGrid g = open(9);
        g.pass[g.index(4, 4, 4)] = 0;
        lamp(g, 4, 4, 4, 14, 255, 213, 140);
        Result r = flood(g);
        check(lv(g, r, 5, 4, 4) == 13 && col(g, r, 5, 4, 4, 1) == 213, "a solid emitter lights its neighbours");
    }
    {
        // Timing at the size the client uses, with a few hundred lamps.
        LightVolumeGrid g;
        g.resize(128, 64, 128);
        std::fill(g.pass.begin(), g.pass.end(), 1);
        for (int z = 0; z < 128; ++z)
            for (int x = 0; x < 128; ++x)
                for (int y = 0; y < 24; ++y) g.pass[g.index(x, y, z)] = 0;
        for (int k = 0; k < 400; ++k)
            lamp(g, (k * 37) % 128, 24 + (k % 3), (k * 91) % 128, 14, 255, 180, 106);
        const auto t0 = std::chrono::steady_clock::now();
        Result r = flood(g);
        const double ms =
                std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        std::printf("128 x 64 x 128 with 400 lamps: %.1f ms\n", ms);
    }
    if (failures) {
        std::printf("goanna_light_volume_test: %d failed\n", failures);
        return 1;
    }
    std::printf("goanna_light_volume_test: all checks passed\n");
    return 0;
}
