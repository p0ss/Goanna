// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Which tiles and sprites take the flame material (goanna_flame.h), on the
// names the 2026-10-05 def dumps of Minetest Game, Mineclonia, VoxeLibre,
// Asuna and Kythen hold. docs/fire-material.md.
//
//   cmake --build build --target goanna_flame_test && build/goanna_flame_test
#include "goanna_flame.h"

#include <cstdio>

static int failures = 0;

static void check(bool ok, const char *what) {
    if (!ok) {
        ++failures;
        std::printf("FAIL: %s\n", what);
    }
}

int main() {
    using namespace goanna;
    // Firelike draws fire whatever its tile is called.
    check(flameTile(NDT_FIRELIKE, 13, "fire_basic_flame_animated.png", true), "MTG fire");
    check(flameTile(NDT_FIRELIKE, 13, "everness_flame_permanent_blue.png", false),
            "Everness blue flame, firelike and still");
    check(flameTile(NDT_FIRELIKE, 10, "soul_fire_basic_flame_animated.png", true), "soul fire");
    // Glowing meshes and plants with an animated tile named for a flame.
    check(flameTile(NDT_MESH, 14, "mcl_campfires_campfire_fire.png", true), "campfire");
    check(flameTile(NDT_MESH, 3, "mcl_candles_flames.png", true), "one candle");
    check(flameTile(NDT_MESH, 3, "x_farming_candle_flame_animated.png", true), "x_farming candle");
    check(flameTile(NDT_PLANTLIKE, 14, "fire_basic_flame_animated.png", true),
            "caverealms constant flame");
    check(flameTile(NDT_MESH, 13, "everness_fire_animated.png", true), "Everness forsaken fire");
    // Not flames.
    check(!flameTile(NDT_MESH, 14, "mcl_campfires_campfire_log_lit.png", true), "campfire logs");
    check(!flameTile(NDT_MESH, 13, "everness_forsaken_fire_mesh.png", false), "a still fire mesh");
    check(!flameTile(NDT_PLANTLIKE_ROOTED, 9, "mcl_ocean_fire_coral_block.png", false),
            "sea pickle on fire coral");
    check(!flameTile(NDT_PLANTLIKE, 9, "caverealms_fire_vine.png", false), "fire vine");
    check(!flameTile(NDT_PLANTLIKE, 5, "ethereal_fire_flower.png", false), "fire flower");
    check(!flameTile(NDT_NORMAL, 9, "kythen_siku_qulliq_flame.png", true), "a cube face");
    check(!flameTile(NDT_MESH, 0, "mcl_candles_flames.png", true), "an unlit candle");
    check(!flameTile(NDT_MESH, 14, "default_torch_on_floor_animated.png", true), "a torch");
    check(!flameTile(NDT_PLANTLIKE, 2, "fireflies_firefly_animated.png", true), "fireflies");
    // Words, not substrings, and only the first image.
    check(flameTextureName("(mcl_burning_entity_flame_animated.png^[opacity:200)"), "grouped");
    check(!flameTextureName("mcl_campfires_campfire_inv.png^fire_overlay.png"), "overlay only");
    check(!flameTextureName("mcl_fireworks_rocket.png"), "fireworks");
    check(flameSpriteTexture("mcl_burning_entity_flame_animated.png"), "burning entity");
    std::printf("%s (%d failures)\n", failures ? "FAILED" : "passed", failures);
    return failures ? 1 : 0;
}
