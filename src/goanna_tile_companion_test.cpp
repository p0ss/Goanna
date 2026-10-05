// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Which companion a node tile string draws with, through the extension's own
// texture source (GoannaTextureSource::tileCompanion and composedCompanion)
// with images inserted the way server media is, and no Godot runtime. The
// arithmetic of composing is goanna_overlay_companions_test's; this checks
// the choice between the base image's companion and a composed one, the
// caching, and that a composed companion is a texture the material code can
// bind like any other:
//   cmake --build build --target goanna_tile_companion_test
//   ./build/goanna_tile_companion_test

#include <iostream>
#include <string>

#include "goanna_image_hooks.h"
#include "goanna_session.h"
#include "goanna_textures.h"

using namespace goanna;

namespace {

int g_failures = 0;
int g_checks = 0;

void expect(bool condition, const std::string &message) {
    ++g_checks;
    if (!condition) {
        ++g_failures;
        std::cerr << "goanna_tile_companion_test: " << message << "\n";
    }
}

video::IImage *solid(u32 w, u32 h, video::SColor c) {
    video::IImage *img = goanna_create_image(video::ECF_A8R8G8B8, {w, h});
    img->fill(c);
    return img;
}

void insert(GoannaTextureSource *tsrc, const std::string &name, video::IImage *img) {
    tsrc->insertSourceImage(name, img);
    img->drop();
}

std::string nameOf(GoannaTexture *t) {
    return t ? std::string(t->getName().getPath().c_str()) : std::string();
}

video::SColor at(GoannaTexture *t, u32 x, u32 y) {
    return t && t->image() ? t->image()->getPixel(x, y) : video::SColor(0);
}

bool rgba(video::SColor c, u32 r, u32 g, u32 b, u32 a) {
    return c.getRed() == r && c.getGreen() == g && c.getBlue() == b && c.getAlpha() == a;
}

} // namespace

int main() {
    GoannaSession session;
    GoannaTextureSource *tsrc = session.tsrc();

    // Netherrack with an eight times _n, and a nylium side overlay drawn on
    // its top half with a _n of its own at the art's size.
    insert(tsrc, "rack.png", solid(4, 4, video::SColor(255, 100, 30, 30)));
    insert(tsrc, "rack_n.png", solid(32, 32, video::SColor(230, 90, 160, 200)));
    video::IImage *side = solid(4, 4, video::SColor(0, 160, 20, 20));
    for (u32 y = 0; y < 2; ++y)
        for (u32 x = 0; x < 4; ++x)
            side->setPixel(x, y, video::SColor(255, 160, 20, 20));
    insert(tsrc, "side.png", side);
    insert(tsrc, "side_n.png", solid(4, 4, video::SColor(120, 170, 60, 255)));
    // Dirt with a shading overlay nobody authored, Mineclonia's grass side.
    insert(tsrc, "dirt.png", solid(4, 4, video::SColor(255, 90, 60, 30)));
    insert(tsrc, "dirt_n.png", solid(4, 4, video::SColor(200, 140, 110, 255)));
    insert(tsrc, "shadow.png", solid(4, 4, video::SColor(90, 0, 0, 0)));
    // A bookshelf front: an empty shelf and a book with its own _s.
    insert(tsrc, "shelf.png", solid(16, 16, video::SColor(255, 80, 50, 20)));
    insert(tsrc, "book.png", solid(4, 7, video::SColor(255, 150, 20, 20)));
    insert(tsrc, "book_s.png", solid(32, 56, video::SColor(255, 200, 20, 0)));
    // An animated strip of two frames with a _n laid out the same way.
    insert(tsrc, "strip.png", solid(4, 8, video::SColor(255, 10, 10, 10)));
    insert(tsrc, "strip_n.png", solid(4, 8, video::SColor(255, 128, 128, 255)));
    // A tool drawn flipped in the hand.
    video::IImage *tool_n = solid(2, 1, video::SColor(255, 200, 100, 255));
    tool_n->setPixel(1, 0, video::SColor(40, 128, 128, 255));
    insert(tsrc, "tool.png", solid(2, 1, video::SColor(255, 50, 50, 50)));
    insert(tsrc, "tool_n.png", tool_n);

    GoannaTexture *rack_n = dynamic_cast<GoannaTexture *>(tsrc->getTexture("rack_n.png"));
    GoannaTexture *dirt_n = dynamic_cast<GoannaTexture *>(tsrc->getTexture("dirt_n.png"));

    expect(tsrc->tileCompanion("rack.png", "_n") == rack_n, "a plain tile takes its own _n");
    expect(tsrc->tileCompanion("rack.png^[colorize:#ff000080", "_n") == rack_n,
            "a recoloured tile takes its base image's _n");

    GoannaTexture *nylium = tsrc->tileCompanion("rack.png^side.png", "_n");
    expect(nameOf(nylium) == "[goanna_composed_n:rack.png^side.png",
            "an authored overlay gets a composed _n, got '" + nameOf(nylium) + "'");
    expect(nylium && nylium->image() && nylium->image()->getDimension().Width == 32,
            "the composed _n keeps the netherrack's eight times scale");
    expect(rgba(at(nylium, 3, 3), 170, 60, 255, 120), "the overlay's _n where it is drawn");
    expect(rgba(at(nylium, 3, 30), 90, 160, 200, 230), "the netherrack's _n below it");
    expect(tsrc->tileCompanion("rack.png^side.png", "_n") == nylium, "built once and kept");
    expect(tsrc->tileCompanion("rack.png^side.png", "_s") == nullptr,
            "no _s anywhere is no _s, not a neutral image");

    expect(tsrc->tileCompanion("dirt.png^shadow.png", "_n") == dirt_n,
            "an overlay nobody authored leaves the base image's _n everywhere");

    const std::string front = "[combine:16x16:0,0=shelf.png:1,1=book.png";
    GoannaTexture *shelf = tsrc->tileCompanion(front, "_s");
    expect(shelf && shelf->image() && shelf->image()->getDimension().Width == 128,
            "a [combine composes at its parts' finest scale");
    expect(rgba(at(shelf, 10, 10), 200, 20, 0, 255), "the book's _s in its slot");
    expect(rgba(at(shelf, 100, 100), 0, 10, 0, 255), "neutral where only the shelf is");
    expect(tsrc->tileCompanion(front, "_n") == nullptr, "nothing authored, nothing composed");

    GoannaTexture *frame = tsrc->tileCompanion("strip.png^[verticalframe:2:1", "_n");
    expect(nameOf(frame) == "strip_n.png^[verticalframe:2:1",
            "an animation frame keeps the frame cut of its strip's _n, got '" +
            nameOf(frame) + "'");
    expect(tsrc->tileCompanion("rack.png^[invert:rgb", "_n") == rack_n,
            "a modifier the composer does not read falls back to the base image");

    bool supported = false;
    GoannaTexture *flipped = tsrc->composedCompanion("tool.png^[transformFX", "_n", &supported);
    expect(supported && flipped && rgba(at(flipped, 0, 0), 127, 128, 255, 40) &&
            rgba(at(flipped, 1, 0), 55, 100, 255, 255),
            "a flipped tool's _n is flipped and its red negated");
    tsrc->composedCompanion("tool.png^[invert:rgb", "_n", &supported);
    expect(!supported, "[invert is reported as not read");

    // Mineclonia's held trident: a five texel wide cut of its 32 x 32
    // entity skin, the shaft one column in the middle with transparency
    // either side. Built as upstream builds it, the cut keeps that
    // transparency (the 2026-10-05 review's pale slab was a pack's 256 px
    // albedo in place of the skin, which a pixel offset [combine cannot
    // take; see tools/pbr_author/stems/mineclonia.maps_only.txt).
    {
        insert(tsrc, "blank.png", solid(1, 1, video::SColor(0, 0, 0, 0)));
        video::IImage *tri = solid(32, 32, video::SColor(0, 0, 0, 0));
        for (u32 y = 7; y < 32; ++y)
            tri->setPixel(21, y, video::SColor(255, 109, 84, 62));
        insert(tsrc, "tri.png", tri);
        GoannaTexture *t = dynamic_cast<GoannaTexture *>(tsrc->getTexture(
                "blank.png^[resize:5x32^[combine:5x32:-19,0=tri.png"));
        const bool sized = t && t->image() && t->image()->getDimension().Width == 5 &&
                t->image()->getDimension().Height == 32;
        expect(sized && t->hasAlpha() && rgba(at(t, 2, 10), 109, 84, 62, 255) &&
                at(t, 0, 10).getAlpha() == 0 && at(t, 4, 10).getAlpha() == 0,
                "the trident's wield image is the shaft column on transparency");
    }

    // Node array layers sized from their companions. A head that ships maps
    // only (eight times its art), a tile with a map sized albedo, one with no
    // companion, one whose map is not a whole multiple, one past the cap, and
    // the bookshelf front above, whose composed _s is eight times it.
    {
        video::IImage *head = solid(16, 16, video::SColor(255, 40, 120, 40));
        head->setPixel(3, 5, video::SColor(255, 250, 10, 10));
        insert(tsrc, "head.png", head);
        insert(tsrc, "head_n.png", solid(128, 128, video::SColor(255, 128, 128, 255)));
        video::IImage *same = solid(16, 16, video::SColor(255, 70, 70, 70));
        same->setPixel(9, 2, video::SColor(255, 1, 2, 3));
        insert(tsrc, "same.png", same);
        insert(tsrc, "same_n.png", solid(16, 16, video::SColor(255, 128, 128, 255)));
        insert(tsrc, "bare.png", solid(16, 16, video::SColor(255, 9, 9, 9)));
        insert(tsrc, "odd.png", solid(16, 16, video::SColor(255, 9, 9, 9)));
        insert(tsrc, "odd_n.png", solid(24, 24, video::SColor(255, 128, 128, 255)));
        insert(tsrc, "tiny.png", solid(2, 2, video::SColor(255, 9, 9, 9)));
        insert(tsrc, "tiny_s.png", solid(128, 128, video::SColor(255, 9, 9, 9)));

        auto dims = [&](const std::string &n) {
            const core::dimension2du d = tsrc->getTextureDimensions(n);
            return std::to_string(d.Width) + "x" + std::to_string(d.Height);
        };
        expect(dims("head.png") == "16x16", "outside node grouping a size is the image's");
        tsrc->setImageCaching(true); // node_visuals starting its grouping
        const std::string grouped = dims("head.png");
        expect(grouped == "128x128", "a maps only tile groups at its map's size, got " + grouped);
        expect(dims(front) == "128x128", "a [combine groups at its composed companion's size");
        expect(dims("same.png") == "16x16", "a map sized albedo is unchanged");
        expect(dims("bare.png") == "16x16", "no companion, unchanged");
        expect(dims("odd.png") == "16x16", "a map not a whole multiple, unchanged");
        expect(dims("tiny.png") == "2x2", "past the cap of 32, unchanged");
        expect(dims("head.png") == "16x16", "a name asked twice ends the grouping");

        u32 big_id = 0;
        tsrc->setImageCaching(true);
        tsrc->addArrayTexture({"head.png", front}, &big_id);
        GoannaTexture *big = tsrc->goannaTexture(big_id);
        const bool big_ok = big && big->isArray() && big->getSize().Width == 128 &&
                big->getSize().Height == 128;
        expect(big_ok, "the maps only head and the [combine share a 128 px array");
        if (big_ok) {
            video::IImage *l = big->layerImage(0);
            expect(l->getPixel(3 * 8, 5 * 8) == video::SColor(255, 250, 10, 10) &&
                    l->getPixel(3 * 8 + 7, 5 * 8 + 7) == video::SColor(255, 250, 10, 10) &&
                    l->getPixel(3 * 8 + 8, 5 * 8) == video::SColor(255, 40, 120, 40) &&
                    l->getPixel(3 * 8 - 1, 5 * 8) == video::SColor(255, 40, 120, 40),
                    "the head's texel is an 8 x 8 block, nearest, not filtered");
        }
        expect(dims("head.png") == "16x16", "making an array ends the grouping");
        GoannaTexture *own = dynamic_cast<GoannaTexture *>(tsrc->getTexture("head.png"));
        expect(own && own->image() && own->image()->getDimension().Width == 16,
                "the image itself keeps the game's size, for items and entities");
        GoannaTexture *part = dynamic_cast<GoannaTexture *>(
                tsrc->getTexture("[combine:32x16:16,0=head.png"));
        expect(part && part->image() && rgba(at(part, 16 + 3, 5), 250, 10, 10, 255) &&
                rgba(at(part, 16 + 4, 5), 40, 120, 40, 255),
                "a [combine part is laid at the game's size");

        u32 small_id = 0;
        tsrc->addArrayTexture({"same.png", "bare.png"}, &small_id);
        GoannaTexture *small = tsrc->goannaTexture(small_id);
        const bool small_ok = small && small->isArray() && small->getSize().Width == 16;
        expect(small_ok, "tiles with no larger companion keep a 16 px array");
        if (small_ok)
            expect(small->layerImage(0)->getPixel(9, 2) == video::SColor(255, 1, 2, 3) &&
                    small->layerImage(0)->getPixel(8, 2) == video::SColor(255, 70, 70, 70),
                    "and their layers are the images as they were");
        u32 mixed_id = 0;
        expect(tsrc->addArrayTexture({"head.png", "same.png"}, &mixed_id) == nullptr,
                "a bunch mixing a sized head with a 16 px tile is refused, as any size mix is");
    }

    std::cout << "tile companions: " << g_checks << " checks, " << g_failures << " failure(s)\n";
    return g_failures == 0 ? 0 : 1;
}
