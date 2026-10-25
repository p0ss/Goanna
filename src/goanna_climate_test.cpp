// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Checks ClimateStore (goanna_climate.cpp) on cases whose answer is known
// by inspection: a level reads as its band's representative value; a lone
// block reads its own value throughout and is half known at its edge;
// between two blocks the value runs smoothly with no step at the boundary;
// a claim's fine cells keep their own values at their centres; the step
// where a fine block meets a wild one is small; bad sizes and band lists
// are refused; and build encodes and times the grid round the camera.
//
// Build and run:
//   cmake --build build --target goanna_climate_test && ./build/goanna_climate_test

#include "goanna_climate.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>
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

bool near(float a, float b, float eps = 0.01f) {
    return std::fabs(a - b) <= eps;
}

// Levels 1 to 15 at 10 C apart from -50, wetness and humidity in fifteenths.
ClimateStore banded() {
    ClimateStore s;
    std::vector<float> t, w;
    for (int i = 1; i <= 15; ++i) {
        t.push_back(-60.0f + 10.0f * i);
        w.push_back(i / 15.0f);
    }
    s.setBands(t, w, w);
    return s;
}

// A block of `size` cells, every cell temperature level t, wetness w,
// humidity h.
std::string cells(int size, int t, int w, int h) {
    const int n = 16 / size;
    std::string out;
    for (int i = 0; i < n * n * n; ++i) {
        out.push_back((char)(t * 16 + w));
        out.push_back((char)h);
    }
    return out;
}

} // namespace

int main() {
    {
        ClimateStore s = banded();
        check(s.put(0, 0, 0, 16, cells(16, 7, 3, 9)), "a wild block is stored");
        const ClimateValue v = s.sample(7.5f, 7.5f, 7.5f);
        check(near(v.temp, 10.0f) && near(v.wet, 0.2f) && near(v.hum, 0.6f) && near(v.known, 1.0f),
                "a level reads as its representative value at the block centre");
        const ClimateValue edge = s.sample(15.5f, 7.5f, 7.5f);
        check(near(edge.temp, 10.0f) && near(edge.known, 0.5f),
                "a lone block keeps its value to its edge, half known there");
        check(s.sample(100.0f, 0.0f, 0.0f).known == 0.0f, "nothing is known far from any block");
    }
    {
        ClimateStore s = banded();
        s.put(0, 0, 0, 16, cells(16, 6, 8, 8)); // 0 C
        s.put(1, 0, 0, 16, cells(16, 8, 8, 8)); // 20 C
        check(near(s.sample(15.5f, 7.5f, 7.5f).temp, 10.0f), "halfway between two blocks is the mean");
        float worst = 0, last = s.sample(7.5f, 7.5f, 7.5f).temp;
        for (float x = 7.6f; x <= 23.5f; x += 0.1f) {
            const float t = s.sample(x, 7.5f, 7.5f).temp;
            worst = std::max(worst, std::fabs(t - last));
            last = t;
        }
        check(worst < 0.2f, "no step anywhere between two wild block centres");
    }
    {
        ClimateStore s = banded();
        std::string fine;
        for (int z = 0; z < 4; ++z)
            for (int y = 0; y < 4; ++y)
                for (int x = 0; x < 4; ++x) {
                    fine.push_back((char)((5 + x) * 16 + 8));
                    fine.push_back((char)8);
                }
        check(s.put(0, 0, 0, 4, fine), "a claim block of 4-node cells is stored");
        s.put(-1, 0, 0, 16, cells(16, 5, 8, 8)); // -10 C, the same as the claim's first column
        s.put(1, 0, 0, 16, cells(16, 8, 8, 8));  // 20 C, the claim's last column
        for (int x = 0; x < 4; ++x)
            check(near(s.sample(x * 4 + 1.5f, 1.5f, 1.5f).temp, -10.0f + 10.0f * x),
                    "a fine cell reads its own value at its centre");
        const float in = s.sample(15.4f, 1.5f, 1.5f).temp, out = s.sample(15.6f, 1.5f, 1.5f).temp;
        check(std::fabs(in - out) < 2.0f, "a small step where the claim meets the wild");
        std::printf("claim to wild: %.2f C to %.2f C across the boundary\n", in, out);
    }
    {
        ClimateStore s = banded();
        check(!s.put(0, 0, 0, 3, std::string(2, '\0')), "a size that does not divide 16 is refused");
        check(!s.put(0, 0, 0, 4, cells(16, 1, 1, 1)), "bytes that do not fit the size are refused");
        check(!s.setBands({1, 2}, {1}, {1}), "short band lists are refused");
        std::vector<float> t16(16, 5.0f), w16(16, 0.5f);
        t16[0] = 999;
        check(s.setBands(t16, w16, w16), "sixteen values with level 0 first are taken");
        s.put(0, 0, 0, 16, cells(16, 1, 1, 0));
        const ClimateValue v = s.sample(7.5f, 7.5f, 7.5f);
        check(near(v.temp, 5.0f) && near(v.hum, 0.5f), "level 0 is skipped; unknown humidity falls back to wetness");
        s.put(1, 0, 0, 16, cells(16, 0, 4, 4));
        check(near(s.sample(15.5f, 7.5f, 7.5f).known, 0.5f), "an unknown cell counts for nothing");
        const uint64_t r = s.revision();
        s.drop(1, 0, 0);
        check(s.revision() != r && s.blocks() == 1, "a drop removes the block");
    }
    {
        // The camera's grid: 25 by 6 by 25 wild blocks, one claim of 4-node
        // cells, at 4 nodes a texel.
        ClimateStore s = banded();
        for (int z = -12; z <= 12; ++z)
            for (int y = -2; y <= 3; ++y)
                for (int x = -12; x <= 12; ++x)
                    s.put(x, y, z, 16, cells(16, 6 + ((x + z) & 3), 8, 8));
        for (int z = 0; z < 3; ++z)
            for (int x = 0; x < 3; ++x)
                s.put(x, 0, z, 4, cells(4, 9, 15, 15));
        ClimateGrid g;
        g.cell = 4.0f;
        g.nx = 100;
        g.ny = 24;
        g.nz = 100;
        g.ox = -12 * 16 - 0.5f;
        g.oy = -2 * 16 - 0.5f;
        g.oz = -12 * 16 - 0.5f;
        std::vector<uint8_t> rgba;
        s.build(g, rgba); // the first build pays for the allocations
        const auto start = std::chrono::steady_clock::now();
        s.build(g, rgba);
        const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
        std::printf("build: %d texels from %zu blocks in %.1f ms\n", g.nx * g.ny * g.nz, s.blocks(), ms);
        check(rgba.size() == (size_t)g.nx * g.ny * g.nz * 4, "four bytes a texel");
        // The texel at the claim's first cell centre, node (1.5, 1.5, 1.5).
        const int i = 48, j = 8, k = 48;
        const size_t o = (((size_t)k * g.ny + j) * g.nx + i) * 4;
        check(rgba[o] == (uint8_t)std::lround((30.0f + 60.0f) / 170.0f * 255.0f) && rgba[o + 1] == 255 && rgba[o + 3] == 255,
                "a texel encodes temperature, wetness and known");
    }
    if (failures) {
        std::printf("goanna_climate_test: %d failed\n", failures);
        return 1;
    }
    std::printf("goanna_climate_test: all checks passed\n");
    return 0;
}
