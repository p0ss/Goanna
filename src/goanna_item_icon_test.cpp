// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Node item icons end to end, with no server and no Godot runtime: node
// definitions as a server would send them, upstream's node visuals and item
// mesh (the extension's transplanted copies, built through a GoannaSession's
// texture and shader sources), then goanna_icon_raster. Not built by
// default: cmake --build build --target goanna_item_icon_test
//
// The case that started it: Mineclonia's chest is a mesh node whose tile is
// the model's texture atlas, with transparent gaps between the parts. Folded
// into an [inventorycube, that atlas became a see-through box. Drawn from its
// item mesh, every pixel inside the chest's outline is a face of the model,
// coloured from the part of the atlas that face maps to, and the gaps never
// show. The checks below would fail on the folded cube, and the test proves
// that by folding the same atlas and running the same hole count on it.

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

#include "client/item_visuals_manager.h"
#include "client/node_visuals.h"
#include "goanna_icon_raster.h"
#include "goanna_image_hooks.h"
#include "goanna_item_icons.h"
#include "goanna_luanti_client.h"
#include "goanna_models.h"
#include "goanna_session.h"
#include "goanna_textures.h"
#include "inventory.h"
#include "itemdef.h"
#include "nodedef.h"
#include "transplant/client/wieldmesh.h"

using namespace goanna;

namespace {

int g_failures = 0;
int g_checks = 0;

void expect(bool condition, const std::string &message) {
    ++g_checks;
    if (!condition) {
        ++g_failures;
        std::cerr << "goanna_item_icon_test: " << message << "\n";
    }
}

video::IImage *solid(video::SColor c) {
    video::IImage *img = goanna_create_image(video::ECF_A8R8G8B8, {16, 16});
    img->fill(c);
    return img;
}

// A 16 by 16 atlas in quadrants, like a model's texture sheet: red top left,
// green top right, blue bottom left, and the bottom right quadrant left
// transparent, the gap a folded cube would show as a hole.
video::IImage *atlas() {
    video::IImage *img = goanna_create_image(video::ECF_A8R8G8B8, {16, 16});
    for (u32 y = 0; y < 16; ++y)
        for (u32 x = 0; x < 16; ++x) {
            video::SColor c(0, 0, 0, 0);
            if (y < 8)
                c = x < 8 ? video::SColor(255, 255, 0, 0) : video::SColor(255, 0, 255, 0);
            else if (x < 8)
                c = video::SColor(255, 0, 0, 255);
            img->setPixel(x, y, c);
        }
    return img;
}

// A chest shaped box (14/16 wide, 7/8 tall) whose top samples the red
// quadrant, its sides the green one and its bottom the blue one. Standard
// OBJ conventions; Irrlicht's loader mirrors x and flips v.
std::string chestObj() {
    const float a = 0.4375f, lo = -0.5f, hi = 0.375f;
    std::string s = "# test chest\n";
    auto v = [&](float x, float y, float z) {
        s += "v " + std::to_string(x) + " " + std::to_string(y) + " " + std::to_string(z) + "\n";
    };
    // 1..8: bottom ring then top ring
    v(-a, lo, -a); v(a, lo, -a); v(a, lo, a); v(-a, lo, a);
    v(-a, hi, -a); v(a, hi, -a); v(a, hi, a); v(-a, hi, a);
    // UV rectangles in image space (v down), written with v flipped for OBJ
    auto vt = [&](float u, float vimg) {
        s += "vt " + std::to_string(u) + " " + std::to_string(1.0f - vimg) + "\n";
    };
    auto rect = [&](float u0, float v0, float u1, float v1) {
        vt(u0, v0); vt(u1, v0); vt(u1, v1); vt(u0, v1);
    };
    rect(0.05f, 0.05f, 0.45f, 0.45f); // 1..4 red: top
    rect(0.55f, 0.05f, 0.95f, 0.45f); // 5..8 green: sides
    rect(0.05f, 0.55f, 0.45f, 0.95f); // 9..12 blue: bottom
    s += "vn 0 1 0\nvn 0 -1 0\nvn 1 0 0\nvn -1 0 0\nvn 0 0 1\nvn 0 0 -1\n";
    auto f = [&](int p0, int p1, int p2, int p3, int t0, int n) {
        s += "f " + std::to_string(p0) + "/" + std::to_string(t0) + "/" + std::to_string(n) + " " +
                std::to_string(p1) + "/" + std::to_string(t0 + 1) + "/" + std::to_string(n) + " " +
                std::to_string(p2) + "/" + std::to_string(t0 + 2) + "/" + std::to_string(n) + " " +
                std::to_string(p3) + "/" + std::to_string(t0 + 3) + "/" + std::to_string(n) + "\n";
    };
    f(5, 6, 7, 8, 1, 1);  // top
    f(1, 4, 3, 2, 9, 2);  // bottom
    f(2, 3, 7, 6, 5, 3);  // +x
    f(4, 1, 5, 8, 5, 4);  // -x
    f(3, 4, 8, 7, 5, 5);  // +z
    f(1, 2, 6, 5, 5, 6);  // -z
    return s;
}

// Where drawItemStack puts a point of the node, in icon pixels (top row
// first): scaled to 0.12 of a node (so node units times 1.2), turned -45
// degrees about y and -30 about x, orthographic onto a two unit square.
struct P2 {
    float x, y;
};

P2 project(v3f p, u32 size) {
    p *= 1.2f;
    const float c1 = std::cos(-45.0f * (float)M_PI / 180.0f), s1 = std::sin(-45.0f * (float)M_PI / 180.0f);
    float x = c1 * p.X - s1 * p.Z, z = s1 * p.X + c1 * p.Z;
    const float c2 = std::cos(-30.0f * (float)M_PI / 180.0f), s2 = std::sin(-30.0f * (float)M_PI / 180.0f);
    float y = c2 * p.Y - s2 * z;
    return {(x + 1.0f) * 0.5f * size, (1.0f - y) * 0.5f * size};
}

// Convex hull of a box's eight projected corners (monotone chain), counter
// clockwise in pixel coordinates.
std::vector<P2> boxHull(v3f lo, v3f hi, u32 size) {
    std::vector<P2> pts;
    for (int i = 0; i < 8; ++i)
        pts.push_back(project(v3f(i & 1 ? hi.X : lo.X, i & 2 ? hi.Y : lo.Y, i & 4 ? hi.Z : lo.Z), size));
    std::sort(pts.begin(), pts.end(), [](P2 a, P2 b) { return a.x < b.x || (a.x == b.x && a.y < b.y); });
    auto cross = [](P2 o, P2 a, P2 b) { return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x); };
    std::vector<P2> h(16);
    int k = 0;
    for (const P2 &p : pts) {
        while (k >= 2 && cross(h[k - 2], h[k - 1], p) <= 0)
            --k;
        h[k++] = p;
    }
    for (int i = (int)pts.size() - 2, t = k + 1; i >= 0; --i) {
        while (k >= t && cross(h[k - 2], h[k - 1], pts[i]) <= 0)
            --k;
        h[k++] = pts[i];
    }
    h.resize(k - 1);
    return h;
}

// Signed distance of a point inside a counter-clockwise convex polygon from
// its nearest edge: positive inside.
float insideBy(const std::vector<P2> &hull, float x, float y) {
    float d = 1e9f;
    for (size_t i = 0; i < hull.size(); ++i) {
        P2 a = hull[i], b = hull[(i + 1) % hull.size()];
        float ex = b.x - a.x, ey = b.y - a.y;
        float len = std::sqrt(ex * ex + ey * ey);
        d = std::min(d, (ex * (y - a.y) - ey * (x - a.x)) / len);
    }
    return d;
}

struct Icon {
    u32 size = 0;
    std::vector<u8> px;
    const u8 *at(u32 x, u32 y) const { return &px[(y * size + x) * 4]; }
};

// The outline check: every pixel well inside the box's projected outline is
// drawn, every pixel well outside it is not. A folded atlas fails the first
// half; a chamfered or wrongly scaled mesh fails one or the other.
void checkOutline(const Icon &icon, v3f lo, v3f hi, const std::string &what) {
    std::vector<P2> hull = boxHull(lo, hi, icon.size);
    int holes = 0, spill = 0;
    for (u32 y = 0; y < icon.size; ++y)
        for (u32 x = 0; x < icon.size; ++x) {
            float d = insideBy(hull, x + 0.5f, y + 0.5f);
            u8 a = icon.at(x, y)[3];
            if (d > 1.5f && a == 0)
                ++holes;
            if (d < -1.5f && a != 0)
                ++spill;
        }
    expect(holes == 0, what + ": " + std::to_string(holes) + " undrawn pixels inside the outline");
    expect(spill == 0, what + ": " + std::to_string(spill) + " drawn pixels outside the outline");
}

bool drawIcon(Client &client, GoannaShaderSource &shsrc, const ItemStack &stack, u32 size, Icon &out) {
    IconJob job;
    std::string key;
    if (!itemIconKey(&client, stack, key) || !buildItemIconJob(&client, shsrc, stack, job))
        return false;
    out.size = size;
    rasteriseItemIcon(job, size, out.px);
    return true;
}

} // namespace

int main() {
    // The session is here for what it initialises: the extension's settings
    // layer (which node visuals read), its node and item definition managers,
    // and its texture and shader sources.
    GoannaSession session;
    NodeDefManager *ndef = const_cast<NodeDefManager *>(session.nodeDefs());
    auto *idef = static_cast<IWritableItemDefManager *>(session.getItemDefManager());
    GoannaTextureSource *tsrc = session.tsrc();
    tsrc->insertSourceImage("test_red.png", solid(video::SColor(255, 255, 0, 0)));
    tsrc->insertSourceImage("test_green.png", solid(video::SColor(255, 0, 255, 0)));
    tsrc->insertSourceImage("test_blue.png", solid(video::SColor(255, 0, 0, 255)));
    tsrc->insertSourceImage("test_grey.png", solid(video::SColor(255, 128, 128, 128)));
    tsrc->insertSourceImage("test_atlas.png", atlas());
    tsrc->insertSourceImage("test_glass.png", solid(video::SColor(128, 255, 0, 0)));
    const std::string obj = chestObj();
    ModelCache models([&](const std::string &name, std::string &bytes) {
        if (name != "test_chest.obj")
            return false;
        bytes = obj;
        return true;
    });
    ItemVisualsManager visuals;
    Client client(tsrc, &session.shsrc(), ndef, idef, &models, &visuals);

    auto add = [&](const std::string &name, ContentFeatures f) {
        f.name = name;
        ndef->set(name, std::move(f));
        ItemDefinition d;
        d.type = ITEM_NODE;
        d.name = name;
        idef->registerItem(d);
    };
    {
        // A faced cube, like a furnace: distinct top, +x and -z (front)
        // tiles, grey elsewhere. In the crumbly group, which Goanna's world
        // mesher bevels; an inventory mesh must not be.
        ContentFeatures f;
        f.drawtype = NDT_NORMAL;
        const char *tiles[6] = {"test_red.png", "test_grey.png", "test_green.png",
                "test_grey.png", "test_grey.png", "test_blue.png"};
        for (int i = 0; i < 6; ++i)
            f.tiledef[i].name = tiles[i];
        f.groups["crumbly"] = 1;
        add("test:faced", std::move(f));
    }
    {
        ContentFeatures f;
        f.drawtype = NDT_MESH;
        f.mesh = "test_chest.obj";
        f.param_type = CPT_LIGHT;
        f.alpha = ALPHAMODE_CLIP;
        for (int i = 0; i < 6; ++i) {
            f.tiledef[i].name = "test_atlas.png";
            f.tiledef[i].backface_culling = false;
        }
        add("test:chest", std::move(f));
    }
    {
        ContentFeatures f;
        f.drawtype = NDT_NODEBOX;
        f.param_type = CPT_LIGHT;
        f.node_box.type = NODEBOX_FIXED;
        f.node_box.fixed.emplace_back(v3f(-BS / 2, -BS / 2, -BS / 2), v3f(BS / 2, 0, BS / 2));
        for (int i = 0; i < 6; ++i)
            f.tiledef[i].name = "test_red.png";
        add("test:slab", std::move(f));
    }
    {
        // Mineclonia's ice: a liquid drawtype that is not a liquid, alpha
        // blended, no back face culling, here with a half transparent tile.
        ContentFeatures f;
        f.drawtype = NDT_LIQUID;
        f.liquid_type = LIQUID_NONE;
        f.param_type = CPT_LIGHT;
        f.alpha = ALPHAMODE_BLEND;
        for (int i = 0; i < 6; ++i) {
            f.tiledef[i].name = "test_glass.png";
            f.tiledef[i].backface_culling = false;
        }
        add("test:ice", std::move(f));
    }
    ndef->setNodeRegistrationStatus(true);
    NodeVisuals::fillNodeVisuals(ndef, &client, nullptr);
    WieldMesh extrusion_holder; // createItemMesh needs the extrusion mesh cache

    const u32 S = 64;
    const v3f cube_lo(-0.5f, -0.5f, -0.5f), cube_hi(0.5f, 0.5f, 0.5f);

    // 1. Orientation, face choice and drawItemStack's light, against numbers
    // worked out by hand from upstream's formula: ambient 0.5 plus |n.l| with
    // l = 0.7 normalize(-0.6, -1.2, 0.4) gives the top 1.0, the front (-z,
    // drawn on the left) 0.80 and +x (drawn on the right) 0.62.
    {
        Icon icon;
        expect(drawIcon(client, session.shsrc(), ItemStack("test:faced", 1, 0, idef), S, icon),
                "faced cube: no icon");
        if (!icon.px.empty()) {
            auto is = [&](P2 p, int r, int g, int b, const char *what) {
                const u8 *c = icon.at((u32)p.x, (u32)p.y);
                expect(c[0] == r && c[1] == g && c[2] == b && c[3] == 255,
                        std::string("faced cube ") + what + ": got " + std::to_string(c[0]) + "," +
                                std::to_string(c[1]) + "," + std::to_string(c[2]) + "," +
                                std::to_string(c[3]));
            };
            is(project(v3f(0, 0.5f, 0), S), 255, 0, 0, "top");
            is(project(v3f(0, 0, -0.5f), S), 0, 0, 204, "front, on the left");
            is(project(v3f(0.5f, 0, 0), S), 0, 159, 0, "+x, on the right");
            // Only those three colours: no back face shows through and no
            // chamfer adds a fourth shade.
            int other = 0;
            for (u32 i = 0; i < S * S; ++i) {
                const u8 *c = &icon.px[i * 4];
                if (c[3] == 0)
                    continue;
                bool known = (c[0] == 255 && c[1] == 0 && c[2] == 0) ||
                        (c[0] == 0 && c[1] == 0 && c[2] == 204) || (c[0] == 0 && c[1] == 159 && c[2] == 0);
                other += !known;
            }
            expect(other == 0, "faced cube: " + std::to_string(other) + " pixels of another colour");
            checkOutline(icon, cube_lo, cube_hi, "faced cube");
        }
    }

    // 2. The chest: a mesh node on an atlas.
    int folded_holes = 0;
    {
        Icon icon;
        expect(drawIcon(client, session.shsrc(), ItemStack("test:chest", 1, 0, idef), S, icon),
                "chest: no icon");
        if (!icon.px.empty()) {
            checkOutline(icon, v3f(-0.4375f, -0.5f, -0.4375f), v3f(0.4375f, 0.375f, 0.4375f), "chest");
            int red = 0, green = 0, blue = 0, partial = 0;
            for (u32 i = 0; i < S * S; ++i) {
                const u8 *c = &icon.px[i * 4];
                if (c[3] == 0)
                    continue;
                partial += c[3] != 255;
                if (c[0] >= c[1] && c[0] >= c[2])
                    ++red;
                else if (c[1] >= c[2])
                    ++green;
                else
                    ++blue;
            }
            expect(red > 200, "chest: the lid should show the red part of the atlas, " + std::to_string(red) + " pixels");
            expect(green > 400, "chest: the sides should show the green part, " + std::to_string(green) + " pixels");
            expect(blue == 0, "chest: the underside is hidden, yet " + std::to_string(blue) + " blue pixels");
            expect(partial == 0, "chest: clip alpha draws a texel or not, " + std::to_string(partial) + " partial pixels");
        }
        // What the old path made of the same node: the atlas folded into a
        // cube. Its hexagon fills the image, so the middle third is all face;
        // the atlas's transparent quadrant shows through there.
        u32 id = tsrc->getTextureId("[inventorycube{test_atlas.png{test_atlas.png{test_atlas.png");
        GoannaTexture *gt = tsrc->goannaTexture(id);
        video::IImage *img = gt ? gt->image() : nullptr;
        expect(img != nullptr, "folded atlas: [inventorycube did not generate");
        if (img) {
            u32 w = img->getDimension().Width, h = img->getDimension().Height;
            for (u32 y = h / 3; y < 2 * h / 3; ++y)
                for (u32 x = w / 3; x < 2 * w / 3; ++x)
                    folded_holes += img->getPixel(x, y).getAlpha() == 0;
            expect(folded_holes > 0, "folded atlas: expected holes, the check would not tell the two apart");
        }
    }

    // 3. A nodebox: the lower half slab keeps its own outline, not a cube's.
    {
        Icon icon;
        expect(drawIcon(client, session.shsrc(), ItemStack("test:slab", 1, 0, idef), S, icon),
                "slab: no icon");
        if (!icon.px.empty())
            checkOutline(icon, v3f(-0.5f, -0.5f, -0.5f), v3f(0.5f, 0.0f, 0.5f), "slab");
    }

    // 4. Colour from metadata: drawItemStack multiplies untinted tiles by the
    // stack's colour key, and the icon key has to tell the two stacks apart.
    {
        ItemStack plain("test:slab", 1, 0, idef);
        ItemStack tinted = plain;
        tinted.metadata.setString("color", "#808080");
        std::string k1, k2;
        expect(itemIconKey(&client, plain, k1) && itemIconKey(&client, tinted, k2) && k1 != k2,
                "colour: a tinted stack must have its own icon key");
        Icon icon;
        if (drawIcon(client, session.shsrc(), tinted, S, icon)) {
            P2 top = project(v3f(0, 0, 0), S);
            const u8 *c = icon.at((u32)top.x, (u32)top.y);
            expect(c[0] == 128 && c[1] == 0 && c[2] == 0,
                    "colour: the slab top should be 128,0,0, got " + std::to_string(c[0]) + "," +
                            std::to_string(c[1]) + "," + std::to_string(c[2]));
        }
    }

    // 5. Alpha blending with the depth writes vanilla has in game (see
    // goanna_icon_raster.cpp). drawSolidNode emits the faces top, bottom, +x,
    // -x, +z, -z, all in one buffer, and blending follows that order: the
    // top and the front right (+x) are drawn before the faces behind them,
    // which then fail the depth test, so they show one layer of the tile;
    // the front left (-z) comes last, over the back left (-x) already drawn,
    // and shows two. Without the depth write the top would show three.
    {
        Icon icon;
        expect(drawIcon(client, session.shsrc(), ItemStack("test:ice", 1, 0, idef), S, icon),
                "ice: no icon");
        if (!icon.px.empty()) {
            auto alpha = [&](v3f p, int want, const char *what) {
                P2 q = project(p, S);
                const u8 *c = icon.at((u32)q.x, (u32)q.y);
                expect(c[3] == want && c[1] == 0 && c[2] == 0,
                        std::string("ice ") + what + ": want alpha " + std::to_string(want) + ", got " +
                                std::to_string(c[0]) + "," + std::to_string(c[1]) + "," +
                                std::to_string(c[2]) + "," + std::to_string(c[3]));
            };
            alpha(v3f(0, 0.5f, 0), 128, "top");
            alpha(v3f(0.5f, 0, 0), 128, "front right");
            alpha(v3f(0, 0, -0.5f), 192, "front left");
        }
    }

    // 6. Not a node item: no mesh icon, the caller keeps its own image path.
    {
        ItemDefinition d;
        d.type = ITEM_CRAFT;
        d.name = "test:stick";
        d.inventory_image.name = "test_grey.png";
        idef->registerItem(d);
        std::string key;
        expect(!itemIconKey(&client, ItemStack("test:stick", 1, 0, idef), key),
                "a craft item with an inventory image is not drawn as a mesh");
    }

    if (g_failures) {
        std::cerr << "goanna_item_icon_test: FAIL: " << g_failures << " of " << g_checks << " checks\n";
        return 1;
    }
    std::cout << "goanna_item_icon_test: PASS: " << g_checks << " checks (the folded atlas had "
              << folded_holes << " holes in its middle third)\n";
    return 0;
}
