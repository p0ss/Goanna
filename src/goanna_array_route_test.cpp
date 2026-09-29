// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Which array shader a tile is drawn with, decided per tile. Upstream
// bunches tiles into arrays by size alone, so nearly every array in a game
// like Mineclonia holds a cut-out somewhere, and deciding by the array drew
// sand, stone and planks with nodes_array_scissor.gdshader, which has no
// parallax march. These checks build small arrays with no Godot runtime
// and ask arrayTileKey, the function the near mesher calls per face, what
// key an opaque tile and a cut-out tile get. Not built by default:
// cmake --build build --target goanna_array_route_test

#include <cstdio>
#include <string>
#include <vector>

#include "goanna_client.h"
#include "goanna_image_hooks.h"
#include "goanna_materials.h"
#include "goanna_textures.h"

using namespace goanna;

namespace {

int g_failures = 0;

void check(bool ok, const char *what) {
    if (!ok) {
        std::printf("FAIL: %s\n", what);
        ++g_failures;
    }
}

// A 16 pixel layer, fully opaque, or with one transparent texel as a
// cut-out has.
video::IImage *layer(bool alpha) {
    video::IImage *img = goanna_create_image(video::ECF_A8R8G8B8, core::dimension2du(16, 16));
    for (u32 y = 0; y < 16; ++y)
        for (u32 x = 0; x < 16; ++x)
            img->setPixel(x, y, video::SColor(255, 200, 180, 120));
    if (alpha)
        img->setPixel(3, 5, video::SColor(0, 0, 0, 0));
    return img;
}

// GoannaTexture grabs each image, so the test's own reference is dropped.
GoannaTexture *array(const std::vector<bool> &alpha, u32 id) {
    std::vector<video::IImage *> images;
    std::vector<std::string> names;
    for (size_t i = 0; i < alpha.size(); ++i) {
        images.push_back(layer(alpha[i]));
        names.push_back("layer" + std::to_string(i) + ".png");
    }
    auto *out = new GoannaTexture("array" + std::to_string(id), images, names, id);
    for (video::IImage *img : images)
        img->drop();
    return out;
}

MaterialKey arrayKey(u32 id) {
    MaterialKey k;
    k.texture_id = id;
    k.array_texture = true;
    return k;
}

} // namespace

int main() {
    // Sand, a leaf, stone: the mix every Mineclonia bunch has.
    GoannaTexture *mixed = array({false, true, false}, 7);
    check(mixed->hasAlpha(), "an array holding a cut-out has alpha");
    check(!mixed->tileHasAlpha(0) && mixed->tileHasAlpha(1) && !mixed->tileHasAlpha(2),
            "alpha is read per layer");
    const MaterialKey base = arrayKey(7);
    const MaterialKey sand = arrayTileKey(base, mixed, 0);
    const MaterialKey leaf = arrayTileKey(base, mixed, 1);
    const MaterialKey stone = arrayTileKey(base, mixed, 2);
    check(sand.opaque_tile, "an opaque layer in an alpha array gets the opaque key");
    check(!leaf.opaque_tile, "a cut-out layer keeps the scissor key");
    check(sand.hash() != leaf.hash(), "the opaque and scissor keys are different materials");
    check(sand.hash() == stone.hash(), "every opaque layer of one array shares one material");
    check(sand.texture_id == 7 && sand.array_texture,
            "the opaque key samples the same array");
    check(leaf.hash() == base.hash(), "a cut-out's key is the buffer's own key");
    check(!arrayTileKey(base, mixed, 40).opaque_tile, "a layer past the end counts as alpha");

    // An array with no alpha anywhere is never split: one material, keyed
    // as it always was.
    GoannaTexture *opaque = array({false, false}, 8);
    check(!opaque->hasAlpha(), "an all opaque array has no alpha");
    const MaterialKey plain = arrayKey(8);
    check(!arrayTileKey(plain, opaque, 0).opaque_tile
                    && arrayTileKey(plain, opaque, 1).hash() == plain.hash(),
            "an all opaque array keeps its one key");

    // Not on the array path at all, or the crack's second pass: unchanged.
    MaterialKey single;
    single.texture_id = 7;
    check(!arrayTileKey(single, mixed, 0).opaque_tile, "a single image key is left alone");
    MaterialKey crack = arrayKey(7);
    crack.crack_overlay = true;
    check(!arrayTileKey(crack, mixed, 0).opaque_tile, "a crack overlay key is left alone");
    check(!arrayTileKey(base, nullptr, 0).opaque_tile, "no texture means no split");

    // An animated tile names its first frame; the shader steps on through
    // the frames after it, so one cut-out frame makes the whole tile alpha.
    GoannaTexture *anim = array({false, true, false, false}, 9);
    std::vector<GoannaTexture::LayerAnim> frames(4);
    frames[0] = {2, 100}; // layers 0 and 1, the second with a hole
    frames[2] = {2, 100}; // layers 2 and 3, both opaque
    anim->setLayerAnim(frames);
    check(anim->tileHasAlpha(0), "an animated tile with one cut-out frame has alpha");
    check(!anim->tileHasAlpha(2), "an animated tile whose frames are all opaque has none");
    check(!arrayTileKey(arrayKey(9), anim, 0).opaque_tile
                    && arrayTileKey(arrayKey(9), anim, 2).opaque_tile,
            "animated tiles are routed by all their frames");

    mixed->drop();
    opaque->drop();
    anim->drop();

    // Clear glass and see-through ice leave the array by name, so the name
    // test must take whole words only. The cases come from the node lists
    // of minetest_game, Mineclonia, VoxeLibre, Kythen and Asuna.
    check(nameHasWord("default:glass", "glass") && nameHasWord("doors:door_glass_a", "glass")
                    && nameHasWord("xpanes:pane_flat", "pane")
                    && nameHasWord("mcl_panes:pane_natural", "pane"),
            "glass and panes are recognised by name");
    check(!nameHasWord("kythen:moana_plaited_panel", "pane")
                    && !nameHasWord("vessels:glasses", "glass"),
            "a longer word is not the material");
    check(nameHasWord("ethereal:thin_ice", "ice") && nameHasWord("kythen:siku_ice_window", "ice")
                    && nameHasWord("mcl_core:ice", "ice"),
            "ice is recognised anywhere among the words");
    check(!nameHasWord("kythen:crop_norse_iceland_moss_1", "ice")
                    && !nameHasWord("farming:rice", "ice") && !nameHasWord("x_farming:icefishing_1", "ice"),
            "iceland, rice and icefishing are not ice");
    check(!nameHasWord("ice:stone", "ice"), "the mod prefix is not part of the name");

    // Gem codes are mode | kind << 2; diamond is kind 0 and unchanged.
    check(gemTextureCode("default_diamond_block.png") == 2
                    && gemTextureCode("default_stone.png^default_mineral_diamond.png") == 1
                    && gemTextureCode("default_tool_diamondpick.png") == 1,
            "diamond codes are what they were");
    check(gemTextureCode("mcl_core_emerald_ore.png") == (1 | 1 << 2)
                    && gemTextureCode("mcl_core_emerald_block.png") == (2 | 1 << 2)
                    && gemTextureCode("mcl_core_emerald.png") == (1 | 1 << 2),
            "emerald ore, block and item");
    check(gemTextureCode("mcl_amethyst_amethyst_block.png") == (2 | 2 << 2)
                    && gemTextureCode("mcl_amethyst_budding_amethyst.png") == (2 | 2 << 2)
                    && gemTextureCode("mcl_amethyst_amethyst_shard.png") == (1 | 2 << 2)
                    && gemTextureCode("amethyst_block.png") == (2 | 2 << 2),
            "amethyst blocks and shard");
    check(gemTextureCode("mcl_amethyst_calcite_block.png") == 0
                    && gemTextureCode("mcl_amethyst_tinted_glass.png") == 0
                    && gemTextureCode("mcl_amethyst_amethyst_cluster.png") == 0,
            "calcite, tinted glass and clusters in the amethyst mod are not amethyst");
    check(gemTextureCode("default_stone.png^default_mineral_mese.png") == (1 | 3 << 2)
                    && gemTextureCode("default_mese_block.png") == (2 | 3 << 2)
                    && gemTextureCode("default_tool_mesepick.png") == (1 | 3 << 2),
            "mese ore, block and tools");
    check(gemTextureCode("mesecons_wire_on.png") == 0 && gemTextureCode("default_meselamp.png") == 0
                    && gemTextureCode("everness_ancient_emerald_ice.png") == 0,
            "mesecons, the mese lamp and emerald ice are not gems");
    check(gemTextureCode("mcl_nether_quartz_ore.png") == (1 | 4 << 2)
                    && gemTextureCode("mcl_nether_quartz.png") == (1 | 4 << 2)
                    && gemTextureCode("mcl_nether_quartz_block_side.png") == 0
                    && gemTextureCode("mcl_backstone_quartz_bricks.png") == 0,
            "quartz ore and item, not its polished blocks");
    if (g_failures) {
        std::printf("goanna_array_route_test: %d failure(s)\n", g_failures);
        return 1;
    }
    std::printf("goanna_array_route_test: ok\n");
    return 0;
}
