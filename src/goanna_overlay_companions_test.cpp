// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Overlay stacks and their composited companions (goanna_overlay_companions.h),
// with the texture strings Mineclonia actually sends for its mobs. Pure
// arithmetic, so it links nothing:
//   cmake --build build --target goanna_overlay_companions_test
//   ./build/goanna_overlay_companions_test

#include "goanna_overlay_companions.h"

#include <cstdio>
#include <string>
#include <vector>

using namespace goanna;

namespace {

int g_failures = 0;
int g_checks = 0;

void check(bool ok, const std::string &what) {
    ++g_checks;
    if (!ok) {
        std::printf("FAIL: %s\n", what.c_str());
        ++g_failures;
    }
}

std::string names(const std::vector<OverlayLayer> &layers) {
    std::string s;
    for (const OverlayLayer &l : layers)
        s += (s.empty() ? "" : "|") + l.image;
    return s;
}

void testParse() {
    std::vector<OverlayLayer> l;
    check(parseOverlayLayers("mobs_mc_iron_golem.png", l) && names(l) == "mobs_mc_iron_golem.png",
            "a single image is a stack of one");
    check(parseOverlayLayers("mobs_mc_villager_base.png^mobs_mc_villager_plains.png^"
            "mobs_mc_villager_profession_farmer.png^mobs_mc_stone.png", l) &&
            names(l) == "mobs_mc_villager_base.png|mobs_mc_villager_plains.png|"
            "mobs_mc_villager_profession_farmer.png|mobs_mc_stone.png",
            "a villager is four layers, base first");
    check(parseOverlayLayers("mobs_mc_iron_golem.png^(mobs_mc_iron_golem_crack_low.png^[opacity:180)",
            l) && l.size() == 2 && l[1].image == "mobs_mc_iron_golem_crack_low.png" &&
            l[1].opacity > 0.705f && l[1].opacity < 0.707f,
            "a golem's crack is a layer at 180/255 opacity");
    check(parseOverlayLayers("mobs_mc_villager_base.png^mobs_mc_villager_desert.png^"
            "[colorize:#d42222:175", l) && l.size() == 2,
            "a damage tint over the whole stack keeps the layers");
    check(parseOverlayLayers("mobs_mc_creeper.png^[brighten", l) && l.size() == 1,
            "a brightened creeper is one layer");
    check(parseOverlayLayers("a.png^(b.png^[multiply:#808080)", l) && l.size() == 2 &&
            l[1].opacity == 1.0f, "a recoloured group is a full layer");
    // Mineclonia's player skin (mcl_skins compile_skin) and its first
    // person hand (mesh_hand.lua, the same layers without brackets).
    check(parseOverlayLayers("(mcl_skins_base_1_mask.png^[colorize:#EEB592FF:alpha)^"
            "mcl_skins_base_1.png^mcl_skins_eye_1.png^(mcl_skins_hair_1_mask.png^"
            "[colorize:#715D57FF:alpha)^mcl_skins_hair_1.png", l) &&
            names(l) == "mcl_skins_base_1_mask.png|mcl_skins_base_1.png|mcl_skins_eye_1.png|"
            "mcl_skins_hair_1_mask.png|mcl_skins_hair_1.png",
            "a player skin is its masks and parts in order");
    check(parseOverlayLayers("mcl_skins_base_1_mask.png^[colorize:#eeb592:alpha^mcl_skins_base_1.png",
            l) && names(l) == "mcl_skins_base_1_mask.png|mcl_skins_base_1.png",
            "the hand's skin is the base mask and the base");
    // Not plain stacks: the caller keeps its single image lookup.
    const char *refused[] = {
        "mobs_mc_creeper_charge.png^[opacity:95",
        "[combine:16x16:0,0=a.png",
        "a.png^[transformFX",
        "a.png^[mask:b.png",
        "a.png^[verticalframe:4:1",
        "a.png^(b.png^(c.png))",
        "a.png^(b.png^[transformR90)",
        "a.png^(b.png",
        "a.png^b\\^c.png",
        "a.png^^b.png",
        "[brighten",
        "",
    };
    for (const char *t : refused)
        check(!parseOverlayLayers(t, l) && l.empty(), std::string("refuses ") + t);
}

Rgba8 solid(int w, int h, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    Rgba8 img;
    img.w = w;
    img.h = h;
    for (int i = 0; i < w * h; ++i)
        img.px.insert(img.px.end(), {r, g, b, a});
    return img;
}

const uint8_t *px(const Rgba8 &img, int x, int y) {
    return &img.px[((size_t)y * img.w + x) * 4];
}

void testNames() {
    auto n = companionNames("mobs_mc_iron_golem.png", "_n");
    check(n.size() == 1 && n[0] == "mobs_mc_iron_golem_n.png", "a plain image has one name");
    n = companionNames("mcl_skins_hair_3_mask.png", "_s");
    check(n.size() == 2 && n[0] == "mcl_skins_hair_3_mask_s.png" && n[1] == "mcl_skins_hair_3_s.png",
            "a mask tries its own name, then the part it colours");
    n = companionNames("_mask.png", "_n");
    check(n.size() == 1, "a name that is only _mask has no part");
}

void testComposite() {
    // A 4x4 skin whose relief tilts every texel right, under a clothes
    // layer covering the left half with nothing authored.
    Rgba8 base_albedo = solid(4, 4, 90, 60, 40, 255);
    Rgba8 base_n = solid(4, 4, 220, 128, 200, 255);
    Rgba8 clothes = solid(4, 4, 10, 120, 30, 0);
    for (int y = 0; y < 4; ++y)
        for (int x = 0; x < 2; ++x)
            clothes.px[((size_t)y * 4 + x) * 4 + 3] = 255;
    Rgba8 out = compositeCompanions({{&base_albedo, &base_n, 1.0f}, {&clothes, nullptr, 1.0f}},
            kNormalKind);
    check(out.w == 4 && out.h == 4, "composite keeps the size");
    check(px(out, 0, 0)[0] == 128 && px(out, 0, 0)[2] == 255,
            "clothes with no _n are flat where they cover");
    check(px(out, 3, 0)[0] == 220 && px(out, 3, 0)[2] == 200,
            "the skin's relief stays where nothing covers it");

    // The same clothes with their own _n, at four times the resolution,
    // and a half opacity layer over the lot.
    Rgba8 clothes_n = solid(16, 16, 40, 200, 255, 255);
    Rgba8 badge = solid(4, 4, 255, 255, 255, 255);
    Rgba8 out2 = compositeCompanions({{&base_albedo, &base_n, 1.0f},
            {&clothes, &clothes_n, 1.0f}, {&badge, nullptr, 0.5f}}, kNormalKind);
    check(out2.w == 16 && out2.h == 16, "composite takes the largest size");
    check(px(out2, 0, 0)[0] == 84, "half opacity mixes halfway (40 to 128)");
    check(px(out2, 15, 0)[0] == 174, "half opacity mixes halfway (220 to 128)");

    // A villager's _s: only the badge is metal.
    Rgba8 badge_s = solid(4, 4, 200, 255, 0, 255);
    Rgba8 badge_a = solid(4, 4, 0, 0, 0, 0);
    badge_a.px[3] = 255;
    Rgba8 out3 = compositeCompanions({{&base_albedo, nullptr, 1.0f}, {&badge_a, &badge_s, 1.0f}},
            kSpecKind);
    check(px(out3, 0, 0)[1] == 255 && px(out3, 0, 0)[0] == 200, "the badge texel is metal");
    check(px(out3, 1, 0)[1] == 10 && px(out3, 1, 0)[3] == 255,
            "a skin with no _s is a rough dielectric with no emission");

    // A golem's crack at 180/255 over its metal: smoothness mixes, the
    // metal flag and the rest stay whole with the dominant layer, and a
    // layer under half opacity keeps the one beneath.
    Rgba8 golem_a = solid(2, 2, 200, 200, 200, 255);
    Rgba8 golem_s = solid(16, 16, 230, 255, 0, 255);
    Rgba8 crack_a = solid(2, 2, 40, 40, 40, 255);
    Rgba8 crack_s = solid(2, 2, 40, 10, 30, 200);
    Rgba8 cracked = compositeCompanions({{&golem_a, &golem_s, 1.0f},
            {&crack_a, &crack_s, 180.0f / 255.0f}}, kSpecKind);
    check(cracked.w == 16, "an eight times _s keeps its size over small art");
    check(px(cracked, 0, 0)[0] == 96, "smoothness mixes by the mask (230 to 40 at 0.706)");
    check(px(cracked, 0, 0)[1] == 10 && px(cracked, 0, 0)[2] == 30 && px(cracked, 0, 0)[3] == 200,
            "F0, scattering and emission come whole from the dominant crack");
    Rgba8 faint = compositeCompanions({{&golem_a, &golem_s, 1.0f},
            {&crack_a, &crack_s, 0.4f}}, kSpecKind);
    check(px(faint, 0, 0)[1] == 255, "a layer under half opacity keeps the metal beneath");
    Rgba8 cracked_n = compositeCompanions({{&golem_a, &base_n, 1.0f},
            {&crack_a, nullptr, 180.0f / 255.0f}}, kNormalKind);
    check(px(cracked_n, 0, 0)[0] == 155, "a normal mixes in every channel (220 to 128)");

    check(compositeCompanions({}, kNormalKind).empty(), "no layers, no image");
}

} // namespace

int main() {
    testParse();
    testNames();
    testComposite();
    std::printf("overlay companions: %d checks, %d failure(s)\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
