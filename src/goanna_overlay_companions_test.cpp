// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Overlay stacks and their composited companions (goanna_overlay_companions.h),
// with the texture strings Mineclonia actually sends for its mobs. Pure
// arithmetic, so it links nothing:
//   cmake --build build --target goanna_overlay_companions_test
//   ./build/goanna_overlay_companions_test

#include "goanna_overlay_companions.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>
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

Rgba8 fill(int w, int h, const uint8_t c[4]) {
    return solid(w, h, c[0], c[1], c[2], c[3]);
}

void setPx(Rgba8 &img, int x, int y, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    uint8_t *p = &img.px[((size_t)y * img.w + x) * 4];
    p[0] = r;
    p[1] = g;
    p[2] = b;
    p[3] = a;
}

bool same(const uint8_t *p, int r, int g, int b, int a) {
    return p[0] == r && p[1] == g && p[2] == b && p[3] == a;
}

void testTransformParse() {
    check(parseImageTransform("FX") == 4, "FX is 4");
    check(parseImageTransform("R90") == 1, "R90 is 1");
    check(parseImageTransform("fyr90") == 7, "names are read in any case");
    check(parseImageTransform("FXR90") == 5, "FX then R90 is 5");
    check(parseImageTransform("R90R90") == 2, "two quarter turns are a half");
    check(parseImageTransform("FXFX") == 0, "two flips are none");
    check(parseImageTransform("3") == 3, "a digit is its own number");
    check(parseImageTransform("R90FX") == 7, "R90 then FX is FY then R90");
}

// A LabPBR _n from a height field, the convention the shaders decode: R
// tilts toward +x of the image, G toward its top, so a slope rising to the
// right leans the normal left (R below 128) and one rising down the image
// leans it up (G above 128). Interior texels only.
Rgba8 normalsOf(const std::vector<float> &h, int w, int hh) {
    Rgba8 n = solid(w, hh, 128, 128, 255, 255);
    for (int y = 1; y < hh - 1; ++y)
        for (int x = 1; x < w - 1; ++x) {
            const float dx = (h[y * w + x + 1] - h[y * w + x - 1]) * 0.5f;
            const float dy = (h[(y + 1) * w + x] - h[(y - 1) * w + x]) * 0.5f;
            setPx(n, x, y, (uint8_t)std::lround(127.5f - dx), (uint8_t)std::lround(127.5f + dy),
                    255, 255);
        }
    return n;
}

void testTransformNormals() {
    // One texel leaning right and down the image: R 200, G 100.
    Rgba8 one = solid(1, 1, 200, 100, 40, 70);
    struct Want { int t, r, g; } table[] = {
        {0, 200, 100}, {4, 55, 100}, {6, 200, 155}, {2, 55, 155},
        {1, 155, 200}, {3, 100, 55}, {5, 155, 55}, {7, 100, 200},
    };
    for (const Want &w : table) {
        Rgba8 out = transformCompanion(one, w.t, true);
        check(same(px(out, 0, 0), w.r, w.g, 40, 70),
                "transform " + std::to_string(w.t) + " turns R and G as the table says");
    }
    Rgba8 spec = transformCompanion(one, 1, false);
    check(same(px(spec, 0, 0), 200, 100, 40, 70), "a scalar companion only moves");

    // The real test: the normals of a transformed height field are the
    // transformed normals, for every transform. A 7x5 field, so a rotation
    // that swapped the wrong axis would land texels in the wrong place too.
    const int w = 7, hh = 5;
    std::vector<float> field(w * hh);
    for (int y = 0; y < hh; ++y)
        for (int x = 0; x < w; ++x)
            field[y * w + x] = 9.0f * x + 31.0f * y + 4.0f * ((x * y) % 3);
    Rgba8 hf;
    hf.w = w;
    hf.h = hh;
    for (float v : field)
        hf.px.insert(hf.px.end(), {(uint8_t)v, 0, 0, 255});
    Rgba8 n = normalsOf(field, w, hh);
    for (int t = 0; t < 8; ++t) {
        Rgba8 th = transformCompanion(hf, t, false);
        std::vector<float> tf;
        for (size_t i = 0; i < th.px.size(); i += 4)
            tf.push_back(th.px[i]);
        Rgba8 want = normalsOf(tf, th.w, th.h);
        Rgba8 got = transformCompanion(n, t, true);
        bool ok = got.w == want.w && got.h == want.h;
        for (int y = 1; ok && y < want.h - 1; ++y)
            for (int x = 1; x < want.w - 1; ++x)
                if (std::abs(px(got, x, y)[0] - px(want, x, y)[0]) > 1 ||
                        std::abs(px(got, x, y)[1] - px(want, x, y)[1]) > 1)
                    ok = false;
        check(ok, "transform " + std::to_string(t) + " of _n matches _n of the transformed height");
    }
}

// A fake source: albedos and companions by name.
struct Fake {
    std::map<std::string, Rgba8> albedo, comp;
    CompanionSources sources() {
        return {[this](const std::string &n) {
                    auto it = albedo.find(n);
                    return it == albedo.end() ? Rgba8() : it->second;
                },
                [this](const std::string &n) {
                    auto it = comp.find(n);
                    return it == comp.end() ? Rgba8() : it->second;
                }};
    }
};

void testCompose() {
    const uint8_t netherrack_n[4] = {90, 160, 200, 230};
    const uint8_t nylium_n[4] = {170, 60, 255, 120};
    Fake f;
    // Crimson nylium's side: netherrack with the nylium laid over its top
    // half. The netherrack _n is authored at eight times, the nylium's at
    // one: the composite keeps eight.
    f.albedo["mcl_nether_netherrack.png"] = solid(4, 4, 100, 30, 30, 255);
    f.comp["mcl_nether_netherrack.png"] = fill(32, 32, netherrack_n);
    Rgba8 side = solid(4, 4, 160, 20, 20, 0);
    for (int y = 0; y < 2; ++y)
        for (int x = 0; x < 4; ++x)
            setPx(side, x, y, 160, 20, 20, 255);
    f.albedo["crimson_nylium_side.png"] = side;
    f.comp["crimson_nylium_side.png"] = fill(4, 4, nylium_n);
    Rgba8 out;
    check(composeCompanion("mcl_nether_netherrack.png^crimson_nylium_side.png", kNormalKind,
            f.sources(), out) == Composed::Done && out.w == 32 && out.h == 32,
            "nylium side composes at the finer scale");
    check(same(px(out, 5, 3), 170, 60, 255, 120) && same(px(out, 30, 30), 90, 160, 200, 230),
            "the nylium's maps where it covers, the netherrack's below");

    // The same with no nylium companion: neutral where the nylium covers.
    Fake g = f;
    g.comp.erase("crimson_nylium_side.png");
    composeCompanion("mcl_nether_netherrack.png^crimson_nylium_side.png", kNormalKind,
            g.sources(), out);
    check(same(px(out, 0, 0), 128, 128, 255, 255) && same(px(out, 0, 31), 90, 160, 200, 230),
            "an overlay with no companion is neutral where it covers");
    g.comp.clear();
    check(composeCompanion("mcl_nether_netherrack.png^crimson_nylium_side.png", kNormalKind,
            g.sources(), out) == Composed::NoCompanion && out.empty(),
            "no companion anywhere is NoCompanion");

    // The chiseled bookshelf's front: a 16 texel canvas, the empty shelf at
    // the corner and books laid in at their slots.
    const uint8_t book_s[4] = {200, 20, 0, 255};
    Fake b;
    b.albedo["mcl_books_chiseled_bookshelf_empty.png"] = solid(16, 16, 80, 50, 20, 255);
    b.albedo["mcl_books_book_0.png"] = solid(4, 7, 150, 20, 20, 255);
    b.albedo["mcl_books_book_4.png"] = solid(4, 7, 20, 150, 20, 255);
    b.comp["mcl_books_book_0.png"] = fill(32, 56, book_s);
    const std::string front = "[combine:16x16:0,0=mcl_books_chiseled_bookshelf_empty.png"
            ":1,1=mcl_books_book_0.png:6,9=mcl_books_book_4.png";
    check(composeCompanion(front, kSpecKind, b.sources(), out) == Composed::Done &&
            out.w == 128 && out.h == 128, "the bookshelf composes at the books' scale");
    check(same(px(out, 8, 8), 200, 20, 0, 255) && same(px(out, 39, 63), 200, 20, 0, 255),
            "book 0's _s across its slot, (1,1) to (5,8) in art texels");
    check(same(px(out, 40, 8), 0, 10, 0, 255) && same(px(out, 7, 8), 0, 10, 0, 255),
            "the shelf around it, with nothing authored, is neutral");
    check(same(px(out, 50, 80), 0, 10, 0, 255), "a book with no companion is neutral");

    // The trident's held image: blank resized, the entity texture combined
    // in at a negative offset, so only its strip from x 19 shows.
    Fake t;
    t.albedo["blank.png"] = solid(1, 1, 0, 0, 0, 0);
    Rgba8 tri = solid(32, 32, 120, 120, 120, 255);
    t.albedo["mcl_tridents_trident_entity.png"] = tri;
    Rgba8 tri_n = solid(64, 64, 128, 128, 255, 255);
    for (int y = 0; y < 64; ++y)
        setPx(tri_n, 38, y, 10, 128, 255, 255); // art x 19, the strip's left edge
    t.comp["mcl_tridents_trident_entity.png"] = tri_n;
    check(composeCompanion("blank.png^[resize:5x32^[combine:5x32:-19,0="
            "mcl_tridents_trident_entity.png",
            kNormalKind, t.sources(), out) == Composed::Done && out.w == 10 && out.h == 64,
            "the trident's strip composes at its own scale");
    check(px(out, 0, 5)[0] == 10 && px(out, 2, 5)[0] == 128,
            "the negative offset brings art x 19 to the left edge");

    // Escapes, as Mineclonia's shield builder writes them: a part that is
    // itself a modified image, and a nested [combine.
    Fake s;
    s.albedo["base.png"] = solid(4, 4, 1, 1, 1, 255);
    s.albedo["pat.png"] = solid(2, 2, 2, 2, 2, 255);
    s.comp["pat.png"] = solid(2, 2, 7, 8, 9, 10);
    const std::string shield = "[combine:8x8:0,0=base.png\\^[resize\\:8x8"
            ":4,4=[combine\\:3x3\\:-1,-1=pat.png";
    check(composeCompanion(shield, kSpecKind, s.sources(), out) == Composed::Done &&
            out.w == 8 && same(px(out, 4, 4), 7, 8, 9, 10) && same(px(out, 5, 5), 0, 10, 0, 255) &&
            same(px(out, 3, 4), 0, 10, 0, 255),
            "an escaped nested [combine places its own crop");

    // A held item drawn flipped: the screwdriver. Negation is 255 - v, so a
    // flat 128 comes back 127, a 1/255 lean nobody can see.
    Fake d;
    Rgba8 sd = solid(2, 1, 50, 50, 50, 255);
    d.albedo["screwdriver.png"] = sd;
    Rgba8 sd_n = solid(2, 1, 200, 100, 255, 255);
    setPx(sd_n, 1, 0, 128, 128, 255, 40);
    d.comp["screwdriver.png"] = sd_n;
    check(composeCompanion("screwdriver.png^[transformFX", kNormalKind, d.sources(), out) ==
            Composed::Done && same(px(out, 0, 0), 127, 128, 255, 40) &&
            same(px(out, 1, 0), 55, 100, 255, 255),
            "a flipped item's _n moves and its R is negated");

    // Carrot on a stick: FY then R90 as two modifiers, the same as one 7.
    Fake c;
    Rgba8 carrot = solid(3, 2, 9, 9, 9, 255);
    Rgba8 carrot_n = solid(6, 4, 128, 128, 255, 255);
    for (int y = 0; y < 4; ++y)
        for (int x = 0; x < 6; ++x)
            setPx(carrot_n, x, y, (uint8_t)(40 * x), (uint8_t)(60 * y), 255, (uint8_t)(10 * x + y));
    c.albedo["carrot.png"] = carrot;
    c.comp["carrot.png"] = carrot_n;
    check(composeCompanion("carrot.png^[transformFY^[transformR90", kNormalKind, c.sources(),
            out) ==
            Composed::Done && out.px == transformCompanion(carrot_n, 7, true).px && out.w == 4,
            "two transforms in a row are their product");

    // A redstone cross: a rotated line in a group over the dot and the
    // other line.
    Fake r;
    Rgba8 dot = solid(4, 4, 0, 0, 0, 0);
    setPx(dot, 1, 1, 255, 255, 255, 255);
    Rgba8 line = solid(4, 4, 0, 0, 0, 0);
    for (int x = 0; x < 4; ++x)
        setPx(line, x, 2, 255, 255, 255, 255);
    r.albedo["dot.png"] = dot;
    r.albedo["line0.png"] = line;
    r.albedo["line1.png"] = line;
    r.comp["line1.png"] = solid(4, 4, 255, 128, 255, 255);
    check(composeCompanion("dot.png^line0.png^(line1.png^[transformR90)", kNormalKind,
            r.sources(), out) == Composed::Done && out.w == 4,
            "a redstone cross composes");
    // R90 counter-clockwise takes row 2 to column 2, R 255 to G 255, and G
    // 128 to R 127 (255 - 128).
    check(px(out, 2, 0)[0] == 127 && px(out, 2, 0)[1] == 255 && px(out, 0, 2)[0] == 128 &&
            px(out, 0, 2)[1] == 128, "the rotated line's _n is turned and placed");

    // A Mineclonia standing banner, as the server sends it: the pole cut
    // from the base image by the inverted mask, the cloth cut from a
    // coloured copy by the mask, and a pattern cut by its own shape. Here
    // a 4 x 1 atlas: x 0 the pole, x 1 to 3 the cloth, the pattern on x 2.
    Fake m;
    m.albedo["base.png"] = solid(4, 1, 90, 60, 30, 255);
    Rgba8 base_n = solid(8, 2, 128, 128, 255, 255);
    for (int y = 0; y < 2; ++y)
        for (int x = 0; x < 8; ++x)
            setPx(base_n, x, y, x < 2 ? 60 : 200, 128, 255, 255); // pole 60, cloth 200
    m.comp["base.png"] = base_n;
    Rgba8 cloth_mask = solid(4, 1, 255, 255, 255, 255), pole_mask = solid(4, 1, 0, 0, 0, 0);
    setPx(cloth_mask, 0, 0, 0, 0, 0, 0);
    setPx(pole_mask, 0, 0, 255, 255, 255, 255);
    m.albedo["mask.png"] = cloth_mask;
    m.albedo["inverted.png"] = pole_mask;
    Rgba8 creeper = solid(4, 1, 0, 0, 0, 0);
    setPx(creeper, 2, 0, 255, 255, 255, 255);
    m.albedo["creeper.png"] = creeper;
    m.comp["creeper.png"] = solid(4, 1, 128, 20, 255, 255);
    const std::string banner = "(base.png^[mask:inverted.png)^((base.png^[colorize:#d0d6d7:255)"
            "^[mask:mask.png)^(creeper.png^[colorize:#080a10:255^[mask:creeper.png)";
    check(composeCompanion(banner, kNormalKind, m.sources(), out) == Composed::Done &&
            out.w == 8 && out.h == 2, "a banner's [mask composite composes");
    check(px(out, 1, 0)[0] == 60 && px(out, 3, 1)[0] == 200 && px(out, 7, 0)[0] == 200,
            "the pole and the cloth each keep the base's maps where the masks leave them");
    check(px(out, 4, 0)[1] == 20 && px(out, 5, 1)[1] == 20 && px(out, 3, 0)[1] == 128,
            "the pattern's maps exactly where its own mask draws it");
    m.comp.erase("creeper.png");
    composeCompanion(banner, kNormalKind, m.sources(), out);
    check(same(px(out, 4, 0), 128, 128, 255, 255) && px(out, 6, 0)[0] == 200,
            "a pattern with no maps is neutral inside its mask, not across the cloth");
    // [mask:x where x is larger: the image is scaled up to it, as there.
    m.albedo["big_mask.png"] = solid(8, 2, 255, 255, 255, 255);
    check(composeCompanion("base.png^[mask:big_mask.png", kNormalKind, m.sources(), out) ==
            Composed::Done && out.w == 16 && out.h == 4,
            "a larger mask scales the image up, keeping the map's scale over it");

    // A golem's crack in a group with [opacity, as compositeCompanions
    // composites it (96: 230 to 40 at 180/255).
    Fake o;
    o.albedo["golem.png"] = solid(2, 2, 200, 200, 200, 255);
    o.comp["golem.png"] = solid(2, 2, 230, 255, 0, 255);
    o.albedo["crack.png"] = solid(2, 2, 40, 40, 40, 255);
    o.comp["crack.png"] = solid(2, 2, 40, 10, 30, 200);
    check(composeCompanion("golem.png^(crack.png^[opacity:180)", kSpecKind, o.sources(), out) ==
            Composed::Done && same(px(out, 0, 0), 96, 10, 30, 200),
            "an [opacity group mixes as the overlay stack does");

    const char *unread[] = {
        "a.png^[verticalframe:2:0",
        "a.png^[crack:1:1",
        "missing.png",
        "a.png^(b.png",
        "[inventorycube{a.png{a.png{a.png",
    };
    Fake u;
    u.albedo["a.png"] = solid(2, 2, 1, 1, 1, 255);
    u.albedo["b.png"] = solid(2, 2, 1, 1, 1, 255);
    u.comp["a.png"] = solid(2, 2, 1, 1, 1, 255);
    for (const char *t : unread)
        check(composeCompanion(t, kNormalKind, u.sources(), out) == Composed::Unsupported,
                std::string("does not read ") + t);
    check(composeCompanion("a.png^[colorize:#ff0000:120^[brighten", kNormalKind, u.sources(),
            out) ==
            Composed::Done, "colour modifiers are read and change nothing");
}

} // namespace

int main() {
    testParse();
    testNames();
    testComposite();
    testTransformParse();
    testTransformNormals();
    testCompose();
    std::printf("overlay companions: %d checks, %d failure(s)\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
