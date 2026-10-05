// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The texture resolution tier (goanna_texture_size.h): which maps are over
// the cap, the filters that bring them down, and the cap applied through
// the extension's texture source as server media and a pack are inserted,
// with no Godot runtime:
//   cmake --build build --target goanna_texture_size_test
//   ./build/goanna_texture_size_test

#include <cmath>
#include <iostream>
#include <set>
#include <string>
#include <vector>

#include "goanna_image_hooks.h"
#include "goanna_session.h"
#include "goanna_texture_size.h"
#include "goanna_textures.h"

using namespace goanna;

namespace {

int g_failures = 0;
int g_checks = 0;

void expect(bool condition, const std::string &message) {
    ++g_checks;
    if (!condition) {
        ++g_failures;
        std::cerr << "goanna_texture_size_test: " << message << "\n";
    }
}

video::IImage *solid(u32 w, u32 h, video::SColor c) {
    video::IImage *img = goanna_create_image(video::ECF_A8R8G8B8, {w, h});
    img->fill(c);
    return img;
}

// A tile of art_w by art_h texels, k pixels to a texel, each texel its own
// grey, as a pack writes the nearest upscaled art.
video::IImage *blocks(u32 art_w, u32 art_h, u32 k) {
    video::IImage *img = goanna_create_image(video::ECF_A8R8G8B8, {art_w * k, art_h * k});
    for (u32 y = 0; y < art_h * k; ++y)
        for (u32 x = 0; x < art_w * k; ++x) {
            const u32 v = (x / k * 7 + y / k * 13) % 256;
            img->setPixel(x, y, video::SColor(255, v, 255 - v, v / 2));
        }
    return img;
}

core::dimension2du dimsOf(GoannaTextureSource *tsrc, const std::string &name) {
    return tsrc->getTextureDimensions(name);
}

void testNames() {
    expect(mapKindOf("stone.png") == MapKind::Albedo, "a plain image is an albedo");
    expect(mapKindOf("stone_n.png") == MapKind::Normal, "_n is a normal companion");
    expect(mapKindOf("stone_s.png") == MapKind::Spec, "_s is a specular companion");
    expect(artNameOf("stone_n.png") == "stone.png", "a companion counts against its image");
    expect(artNameOf("hair_mask_s.png") == "hair_mask.png", "a mask's companion against the mask");
    expect(artNameOf("stone.png") == "stone.png", "an albedo against itself");
    expect(texelCapForSize(128) == 8 && texelCapForSize(256) == 16 && texelCapForSize(512) == 32,
            "size over 16 per art texel");
}

void testSizes() {
    u32 w, h;
    expect(cappedSize(256, 256, 16, 16, 8, w, h) && w == 128 && h == 128,
            "a 256 tile of 16 texel art comes to 128 at 8 per texel");
    expect(!cappedSize(256, 256, 16, 16, 16, w, h) && w == 256 && h == 256,
            "and stays 256 at 16 per texel");
    expect(!cappedSize(256, 256, 16, 16, 32, w, h), "a cap is never an enlargement");
    expect(cappedSize(256, 1024, 16, 64, 8, w, h) && w == 128 && h == 512,
            "an animation strip keeps its frames");
    expect(cappedSize(1024, 512, 64, 32, 8, w, h) && w == 512 && h == 256,
            "a player part's 16 per texel maps come to 8");
    expect(!cappedSize(512, 256, 64, 32, 8, w, h), "a mob's 8 per texel maps are within 8");
    expect(cappedSize(256, 256, 16, 64, 8, w, h) && w == 128 && h == 128,
            "a still map for a strip is held by its width");
    expect(!cappedSize(256, 256, 32, 32, 8, w, h), "32 texel art at 256 is 8 per texel already");
    expect(!cappedSize(256, 256, 16, 16, 0, w, h), "no cap, no change");
    expect(!cappedSize(256, 256, 0, 0, 8, w, h), "unknown art, no change");
}

std::vector<uint8_t> pixels(std::initializer_list<int> v) {
    std::vector<uint8_t> out;
    for (int x : v)
        out.push_back((uint8_t)x);
    return out;
}

void testFilters() {
    // Albedo: a 2x2 block of one colour stays that colour exactly, and a
    // block half cut out keeps the drawn colour, at half coverage.
    {
        std::vector<uint8_t> src = pixels({10, 20, 30, 255, 10, 20, 30, 255, 200, 0, 0, 0,
                200, 0, 0, 0, 10, 20, 30, 255, 10, 20, 30, 255, 200, 0, 0, 0, 200, 0, 0, 0});
        std::vector<uint8_t> out = downscaleRgba8(src.data(), 4, 2, 2, 1, MapKind::Albedo);
        expect(out[0] == 10 && out[1] == 20 && out[2] == 30 && out[3] == 255,
                "a uniform albedo block is exact");
        expect(out[4] == 200 && out[7] == 0, "a fully cut out block keeps its colour, alpha 0");
        std::vector<uint8_t> mixed = pixels({10, 20, 30, 255, 200, 0, 0, 0,
                10, 20, 30, 255, 200, 0, 0, 0});
        out = downscaleRgba8(mixed.data(), 2, 2, 1, 1, MapKind::Albedo);
        expect(out[0] == 10 && out[1] == 20 && out[2] == 30 && std::abs(out[3] - 128) <= 1,
                "a hidden colour does not bleed into a drawn one");
    }
    // Normal: two texels leaning opposite ways average to flat, renormalised,
    // occlusion and height averaged.
    {
        const int lean = 128 + 90, back = 255 - lean;
        std::vector<uint8_t> src = pixels({lean, 128, 200, 100, back, 128, 100, 200});
        std::vector<uint8_t> out = downscaleRgba8(src.data(), 2, 1, 1, 1, MapKind::Normal);
        expect(std::abs(out[0] - 128) <= 1 && std::abs(out[1] - 128) <= 1,
                "opposite leans average to flat");
        expect(out[2] == 150 && out[3] == 150, "occlusion and height averaged");
        // Two leans the same way keep their lean exactly.
        std::vector<uint8_t> same = pixels({lean, 128, 200, 100, lean, 128, 200, 100});
        out = downscaleRgba8(same.data(), 2, 1, 1, 1, MapKind::Normal);
        expect(out[0] == lean && out[1] == 128, "a uniform lean is kept");
        // A lean and a flat texel: the result is a unit vector between them,
        // not the short average a bilinear shrink of the bytes would give.
        std::vector<uint8_t> half = pixels({255, 128, 255, 0, 128, 128, 255, 0});
        out = downscaleRgba8(half.data(), 2, 1, 1, 1, MapKind::Normal);
        const double x = out[0] / 255.0 * 2.0 - 1.0;
        expect(std::abs(x - std::sqrt(0.5)) < 0.01,
                "a lean and a flat texel give the renormalised half angle");
    }
    // Spec: smoothness averaged, metal and emission by majority.
    {
        std::vector<uint8_t> src = pixels({200, 255, 0, 255, 100, 255, 0, 255,
                100, 255, 0, 255, 0, 10, 64, 100});
        std::vector<uint8_t> out = downscaleRgba8(src.data(), 2, 2, 1, 1, MapKind::Spec);
        expect(out[0] == 100, "smoothness averaged");
        expect(out[1] == 255 && out[2] == 0 && out[3] == 255,
                "metal, porosity and emission taken whole from the majority");
    }
    // The tile relief measure: a height rising 8/255 a pixel under a normal
    // leaning 0.2 (and 0.004 the other way, a byte of 128) reads 0.204 /
    // 0.98 / (8/255) = 6.6 pixels of rise over a
    // 64 pixel tile, 0.10 node; flat reads nothing.
    {
        std::vector<uint8_t> ramp(64 * 64 * 4);
        for (int y = 0; y < 64; ++y)
            for (int x = 0; x < 64; ++x) {
                uint8_t *p = &ramp[((size_t)y * 64 + x) * 4];
                p[0] = 153;
                p[1] = 128;
                p[2] = 255;
                p[3] = (uint8_t)((x % 32) * 8);
            }
        expect(std::abs(tileReliefDepth(ramp.data(), 64, 64) - 0.1037f) < 0.001f,
                "the tile measure reads the ramp's depth");
        std::vector<uint8_t> flat(64 * 64 * 4, 128);
        expect(tileReliefDepth(flat.data(), 64, 64) == 0.0f, "a flat map has no depth");
    }
    // A factor that is not whole covers by area.
    {
        std::vector<uint8_t> src(3 * 1 * 4);
        for (int i = 0; i < 3; ++i) {
            src[i * 4 + 0] = (uint8_t)(i * 90);
            src[i * 4 + 3] = 255;
        }
        std::vector<uint8_t> out = downscaleRgba8(src.data(), 3, 1, 2, 1, MapKind::Albedo);
        expect(out[0] == 30 && out[4] == 150, "a 3 to 2 reduction weights by coverage");
    }
}

void testSource() {
    GoannaSession session;
    GoannaTextureSource *tsrc = session.tsrc();
    tsrc->setTextureSize(128);
    expect(tsrc->textureSize() == 128, "the size is kept");
    // Server art, then a pack's 256 pixel set for it.
    video::IImage *img = blocks(16, 16, 1);
    tsrc->insertMediaImage("stone.png", img);
    img->drop();
    img = blocks(16, 16, 16);
    tsrc->insertLocalImage("stone.png", img);
    img->drop();
    img = solid(256, 256, video::SColor(255, 200, 128, 128));
    tsrc->insertLocalImage("stone_n.png", img);
    img->drop();
    img = solid(256, 256, video::SColor(255, 100, 10, 0));
    tsrc->insertLocalImage("stone_s.png", img);
    img->drop();
    expect(dimsOf(tsrc, "stone.png") == core::dimension2du(128, 128), "the pack's albedo at 128");
    expect(dimsOf(tsrc, "stone_n.png") == core::dimension2du(128, 128), "its _n at 128");
    expect(dimsOf(tsrc, "stone_s.png") == core::dimension2du(128, 128), "its _s at 128");
    {
        float d = -1.0f;
        expect(tsrc->reducedReliefDepth("stone_n.png", d) && d == 0.0f,
                "a reduced _n keeps the depth it had, none for a flat map");
        expect(!tsrc->reducedReliefDepth("stone_s.png", d), "only a _n keeps a depth");
    }
    {
        // The reduced albedo is the art at 8 pixels a texel, texel for texel.
        std::set<std::string> used;
        video::IImage *a = blocks(16, 16, 8);
        auto *gt = dynamic_cast<GoannaTexture *>(tsrc->getTexture("stone.png"));
        bool same = gt && gt->image();
        for (u32 y = 0; same && y < 128; y += 3)
            for (u32 x = 0; x < 128; x += 3)
                if (gt->image()->getPixel(x, y) != a->getPixel(x, y)) {
                    same = false;
                    break;
                }
        a->drop();
        expect(same, "a nearest upscaled albedo comes down to the same art at 8 a texel");
    }
    // A server companion that arrives before its albedo is held once the
    // albedo is in and the cap is finished.
    img = solid(256, 256, video::SColor(255, 128, 128, 255));
    tsrc->insertMediaImage("dirt_n.png", img);
    img->drop();
    img = blocks(16, 16, 1);
    tsrc->insertMediaImage("dirt.png", img);
    img->drop();
    // A maps only skin part: the server's 64 by 32 art and a pack's maps at
    // 16 a texel, as the player's parts ship.
    img = blocks(64, 32, 1);
    tsrc->insertMediaImage("part.png", img);
    img->drop();
    img = solid(1024, 512, video::SColor(255, 128, 128, 255));
    tsrc->insertLocalImage("part_n.png", img);
    img->drop();
    // A companion with no art anywhere is left alone.
    img = solid(256, 256, video::SColor(255, 128, 128, 255));
    tsrc->insertLocalImage("lonely_n.png", img);
    img->drop();
    tsrc->finishTextureCap();
    expect(dimsOf(tsrc, "dirt_n.png") == core::dimension2du(128, 128),
            "a companion ahead of its albedo is reduced at the finish");
    expect(dimsOf(tsrc, "dirt.png") == core::dimension2du(16, 16), "the server's art is untouched");
    expect(dimsOf(tsrc, "part_n.png") == core::dimension2du(512, 256),
            "a skin part's maps come to 8 a texel");
    expect(dimsOf(tsrc, "lonely_n.png") == core::dimension2du(256, 256),
            "a companion with no art is left as it is");
    expect(tsrc->textureCapStats().reduced == 5 && tsrc->textureCapStats().unknown == 1,
            "five reduced, one with no art");

    // Node layers sized from their companions stop at the cap: a 16 pixel
    // head with maps at 16 a texel makes a 128 pixel layer at 128.
    img = blocks(16, 16, 1);
    tsrc->insertMediaImage("head.png", img);
    img->drop();
    img = blocks(16, 16, 1);
    tsrc->insertMediaImage("head2.png", img);
    img->drop();
    for (const char *n : {"head_n.png", "head2_n.png"}) {
        img = solid(256, 256, video::SColor(255, 128, 128, 255));
        tsrc->insertLocalImage(n, img);
        img->drop();
    }
    u32 id = 0;
    tsrc->setImageCaching(true);
    expect(dimsOf(tsrc, "head.png") == core::dimension2du(128, 128),
            "the grouping sees the layer at the cap");
    video::ITexture *arr = tsrc->addArrayTexture({"head.png", "head2.png"}, &id);
    tsrc->setImageCaching(false);
    auto *garr = dynamic_cast<GoannaTexture *>(arr);
    expect(garr && garr->layerImage(0) &&
            garr->layerImage(0)->getDimension() == core::dimension2du(128, 128),
            "a maps only node layer is enlarged to the cap, not past it");
}

void testNoCap() {
    GoannaSession session;
    GoannaTextureSource *tsrc = session.tsrc();
    video::IImage *img = blocks(16, 16, 1);
    tsrc->insertMediaImage("stone.png", img);
    img->drop();
    img = blocks(16, 16, 16);
    tsrc->insertLocalImage("stone.png", img);
    img->drop();
    img = solid(512, 512, video::SColor(255, 128, 128, 255));
    tsrc->insertLocalImage("stone_n.png", img);
    img->drop();
    tsrc->finishTextureCap();
    expect(dimsOf(tsrc, "stone.png") == core::dimension2du(256, 256), "no cap keeps the albedo");
    expect(dimsOf(tsrc, "stone_n.png") == core::dimension2du(512, 512), "and the companion");
    expect(tsrc->textureCapStats().reduced == 0, "nothing reduced without a cap");
}

} // namespace

int main() {
    testNames();
    testSizes();
    testFilters();
    testSource();
    testNoCap();
    if (g_failures) {
        std::cerr << "goanna_texture_size_test: " << g_failures << " of " << g_checks
                  << " checks failed\n";
        return 1;
    }
    std::cout << "goanna_texture_size_test: " << g_checks << " checks passed\n";
    return 0;
}
