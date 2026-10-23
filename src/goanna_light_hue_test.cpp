// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Checks buildLightHue (goanna_light_hue.cpp) on cases whose answer is
// known by inspection: a cell no light reaches is white with no coverage;
// one light gives its own colour throughout its reach; between a red and a
// blue light of the same level the colour blends, and nearer either its
// own colour wins; a light's reach is its level in nodes.
//
// Build and run:
//   cmake --build build --target goanna_light_hue_test && ./build/goanna_light_hue_test

#include "goanna_light_hue.h"

#include <chrono>
#include <cstdlib>
#include <cstdio>
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

// A grid of 1-node cells, so cell (x, y, z) is centred at x + 0.5 and so on.
HueGrid unit(int n) {
    HueGrid g;
    g.cell = 1.0f;
    g.nx = g.ny = g.nz = n;
    return g;
}

const uint8_t *at(const HueGrid &g, const std::vector<uint8_t> &rgba, int x, int y, int z) {
    return &rgba[(((size_t)z * g.ny + y) * g.nx + x) * 4];
}

} // namespace

int main() {
    {
        HueGrid g = unit(8);
        std::vector<uint8_t> rgba;
        buildLightHue(g, {}, rgba);
        const uint8_t *c = at(g, rgba, 3, 3, 3);
        check(c[0] == 255 && c[1] == 255 && c[2] == 255 && c[3] == 0, "no light: white and uncovered");
    }
    {
        HueGrid g = unit(33);
        std::vector<uint8_t> rgba;
        buildLightHue(g, {{16.5f, 16.5f, 16.5f, 14.0f, 1.0f, 0.7f, 0.4f}}, rgba);
        const uint8_t *near = at(g, rgba, 18, 16, 16), *edge = at(g, rgba, 16, 16, 29);
        auto warm = [](const uint8_t *c) {
            return c[0] == 255 && std::abs(c[1] - 179) <= 1 && std::abs(c[2] - 102) <= 1;
        };
        check(warm(near), "one light's colour near it");
        check(warm(edge), "the same colour near the end of its reach");
        check(at(g, rgba, 16, 16, 31)[3] == 0, "nothing past the light's level in nodes");
        check(near[3] == 255, "near a bright light, fully covered");
    }
    {
        HueGrid g = unit(21);
        std::vector<uint8_t> rgba;
        buildLightHue(g, {{6.5f, 10.5f, 10.5f, 14.0f, 1.0f, 0.0f, 0.0f}, {14.5f, 10.5f, 10.5f, 14.0f, 0.0f, 0.0f, 1.0f}},
                rgba);
        const uint8_t *mid = at(g, rgba, 10, 10, 10), *red = at(g, rgba, 7, 10, 10);
        check(mid[0] == 255 && mid[2] == 255, "equal lights blend halfway between them");
        // Weights 13 squared against 7 squared: blue is under a third of red.
        check(red[0] == 255 && red[2] < 80, "nearer one light, its colour wins");
    }
    {
        // Timing at the client's size, 4-node cells, with 3000 lights.
        HueGrid g;
        g.cell = 4.0f;
        g.nx = 128;
        g.ny = 32;
        g.nz = 128;
        std::vector<HueLight> lights;
        for (int k = 0; k < 3000; ++k)
            lights.push_back({(float)((k * 37) % 512), 40.0f + (k % 7), (float)((k * 91) % 512), 14.0f, 1.0f, 0.7f, 0.4f});
        std::vector<uint8_t> rgba;
        const auto t0 = std::chrono::steady_clock::now();
        buildLightHue(g, lights, rgba);
        std::printf("128 x 32 x 128 cells, 3000 lights: %.1f ms\n",
                std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
    }
    if (failures) {
        std::printf("goanna_light_hue_test: %d failed\n", failures);
        return 1;
    }
    std::printf("goanna_light_hue_test: all checks passed\n");
    return 0;
}
