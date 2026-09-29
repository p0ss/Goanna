// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Leaves side by side, meshed by the transplanted content_mapblock with no
// server and no Godot runtime. Not built by default:
// cmake --build build --target goanna_allfaces_test
//
// Fancy leaves are allfaces nodes, a whole cube each, so two of them side by
// side put two faces in one plane. Godot lit the downward one darker than the
// upward one and the pair z-fought through every tree. drawAllfacesNode now
// keeps one face of each such pair; this checks that no plane is drawn twice
// and that nothing else is lost.
//
// The same test holds water beside a dug block. A block draws its face
// against a carved neighbour, whose holes must show something behind them;
// water did too, and its face lay in the plane of the dug block's surface.
// From above the water that face is only ever seen from behind and the
// water shader drops it, but under the water it draws back faces (from in
// there they are the surface), and the two fought: a flashing blue sheet at
// every dig site, seen only while swimming.

#include <cmath>
#include <iostream>
#include <string>
#include <vector>

#include "client/content_mapblock.h"
#include "client/item_visuals_manager.h"
#include "client/mapblock_mesh.h"
#include "client/meshgen/collector.h"
#include "client/node_visuals.h"
#include "goanna_image_hooks.h"
#include "goanna_luanti_client.h"
#include "goanna_models.h"
#include "goanna_radial_form.h"
#include "goanna_session.h"
#include "goanna_textures.h"
#include "itemdef.h"
#include "nodedef.h"

using namespace goanna;

namespace {

int g_failures = 0;
int g_checks = 0;

void expect(bool condition, const std::string &message) {
    ++g_checks;
    if (!condition) {
        ++g_failures;
        std::cerr << "goanna_allfaces_test: " << message << "\n";
    }
}

struct Quad {
    v3f centre;
    v3f normal;
    bool liquid = false;
};

// Every quad the generator drew for the nodes placed, by centre and normal.
std::vector<Quad> meshQuads(const NodeDefManager *ndef,
        const std::vector<std::pair<v3s16, content_t>> &nodes) {
    MeshMakeData data(ndef, MAP_BLOCKSIZE, MeshGrid{1});
    data.fillBlockDataBegin(v3s16(0, 0, 0));
    const VoxelArea area = data.m_vmanip.m_area;
    for (s32 z = area.MinEdge.Z; z <= area.MaxEdge.Z; ++z)
        for (s32 y = area.MinEdge.Y; y <= area.MaxEdge.Y; ++y)
            for (s32 x = area.MinEdge.X; x <= area.MaxEdge.X; ++x)
                data.m_vmanip.setNodeNoEmerge(v3s16(x, y, z), MapNode(CONTENT_AIR));
    for (const auto &n : nodes)
        data.m_vmanip.setNodeNoEmerge(n.first, MapNode(n.second));
    data.m_smooth_lighting = false;
    MeshCollector collector(v3f(0.0f));
    MapblockMeshGenerator(&data, &collector).generate();
    std::vector<Quad> quads;
    for (const auto &layer : collector.prebuffers)
        for (const PreMeshBuffer &buffer : layer)
            for (size_t i = 0; i + 3 < buffer.vertices.size(); i += 4) {
                Quad q;
                q.centre = (buffer.vertices[i].Pos + buffer.vertices[i + 1].Pos
                        + buffer.vertices[i + 2].Pos + buffer.vertices[i + 3].Pos) / 4.0f;
                q.normal = buffer.vertices[i].Normal;
                q.liquid = buffer.layer.material_type == TILE_MATERIAL_LIQUID_TRANSPARENT
                        || buffer.layer.material_type == TILE_MATERIAL_WAVING_LIQUID_TRANSPARENT;
                quads.push_back(q);
            }
    return quads;
}

// Quads whose centres coincide: two faces in one plane.
int sharedPlanes(const std::vector<Quad> &quads) {
    int shared = 0;
    for (size_t i = 0; i < quads.size(); ++i)
        for (size_t j = i + 1; j < quads.size(); ++j)
            if (quads[i].centre.getDistanceFrom(quads[j].centre) < 0.01f)
                ++shared;
    return shared;
}

} // namespace

int main() {
    GoannaSession session;
    NodeDefManager *ndef = const_cast<NodeDefManager *>(session.nodeDefs());
    auto *idef = static_cast<IWritableItemDefManager *>(session.getItemDefManager());
    GoannaTextureSource *tsrc = session.tsrc();
    video::IImage *leaf = goanna_create_image(video::ECF_A8R8G8B8, {16, 16});
    leaf->fill(video::SColor(255, 40, 140, 30));
    leaf->setPixel(3, 3, video::SColor(0, 0, 0, 0));
    tsrc->insertSourceImage("test_leaves.png", leaf);
    ModelCache models([](const std::string &, std::string &) { return false; });
    ItemVisualsManager visuals;
    Client client(tsrc, &session.shsrc(), ndef, idef, &models, &visuals);

    auto add = [&](const std::string &name, float scale) {
        // Mineclonia's leaves: allfaces_optional, cut out, not culled.
        ContentFeatures f;
        f.name = name;
        f.drawtype = NDT_ALLFACES_OPTIONAL;
        f.param_type = CPT_LIGHT;
        f.alpha = ALPHAMODE_CLIP;
        f.visual_scale = scale;
        for (int i = 0; i < 6; ++i) {
            f.tiledef[i].name = "test_leaves.png";
            f.tiledef[i].backface_culling = false;
        }
        return ndef->set(name, std::move(f));
    };
    const content_t oak = add("test:oak_leaves", 1.0f);
    const content_t birch = add("test:birch_leaves", 1.0f);
    const content_t big = add("test:big_leaves", 1.3f);
    tsrc->insertSourceImage("test_stone.png", [] {
        video::IImage *img = goanna_create_image(video::ECF_A8R8G8B8, {16, 16});
        img->fill(video::SColor(255, 120, 120, 120));
        return img;
    }());
    tsrc->insertSourceImage("test_water.png", [] {
        video::IImage *img = goanna_create_image(video::ECF_A8R8G8B8, {16, 16});
        img->fill(video::SColor(160, 40, 80, 200));
        return img;
    }());
    content_t stone, water;
    {
        ContentFeatures f;
        f.name = "test:stone";
        f.drawtype = NDT_NORMAL;
        for (int i = 0; i < 6; ++i)
            f.tiledef[i].name = "test_stone.png";
        stone = ndef->set(f.name, std::move(f));
    }
    for (const bool source : {true, false}) {
        // Water as Mineclonia's is: a source and its flowing form, blended.
        ContentFeatures f;
        f.name = source ? "test:water" : "test:water_flowing";
        f.drawtype = source ? NDT_LIQUID : NDT_FLOWINGLIQUID;
        f.liquid_type = source ? LIQUID_SOURCE : LIQUID_FLOWING;
        f.liquid_alternative_source = "test:water";
        f.liquid_alternative_flowing = "test:water_flowing";
        f.param_type = CPT_LIGHT;
        f.alpha = ALPHAMODE_BLEND;
        for (int i = 0; i < 6; ++i) {
            f.tiledef[i].name = "test_water.png";
            f.tiledef[i].backface_culling = false;
            f.tiledef_special[i].name = "test_water.png";
        }
        const content_t id = ndef->set(f.name, std::move(f));
        if (source)
            water = id;
    }
    ndef->setNodeRegistrationStatus(true);
    NodeVisuals::fillNodeVisuals(ndef, &client, nullptr);
    expect(ndef->get(oak).drawtype == NDT_ALLFACES, "fancy leaves are not allfaces");

    // 1. One leaf alone keeps all six faces.
    {
        auto q = meshQuads(ndef, {{v3s16(5, 5, 5), oak}});
        expect(q.size() == 6, "a lone leaf has " + std::to_string(q.size()) + " faces, not 6");
    }
    // 2. A pair along each axis, and a pair of different leaves: one face
    // per shared plane, eleven faces a pair.
    const v3s16 axes[3] = {v3s16(0, 1, 0), v3s16(1, 0, 0), v3s16(0, 0, 1)};
    for (const v3s16 &axis : axes) {
        for (content_t upper : {oak, birch}) {
            auto q = meshQuads(ndef, {{v3s16(5, 5, 5), oak}, {v3s16(5, 5, 5) + axis, upper}});
            const std::string what = "pair along (" + std::to_string(axis.X) + ","
                    + std::to_string(axis.Y) + "," + std::to_string(axis.Z) + ")"
                    + (upper == oak ? "" : " of two kinds");
            expect(sharedPlanes(q) == 0, what + " draws a plane twice");
            expect(q.size() == 11, what + " has " + std::to_string(q.size()) + " faces, not 11");
        }
    }
    // 3. A solid run of leaves: no plane twice anywhere, and only the
    // outside faces plus one per interior plane.
    {
        std::vector<std::pair<v3s16, content_t>> clump;
        for (s16 z = 4; z < 7; ++z)
            for (s16 y = 4; y < 7; ++y)
                for (s16 x = 4; x < 7; ++x)
                    clump.push_back({v3s16(x, y, z), oak});
        auto q = meshQuads(ndef, clump);
        expect(sharedPlanes(q) == 0, "a 3x3x3 clump draws a plane twice");
        // 162 faces drawn upstream, 54 interior planes each lose one.
        expect(q.size() == 108, "a 3x3x3 clump has " + std::to_string(q.size()) + " faces, not 108");
    }
    // 4. Scaled leaves do not share a plane with their neighbour, so they
    // keep every face.
    {
        auto q = meshQuads(ndef, {{v3s16(5, 5, 5), big}, {v3s16(5, 6, 5), big}});
        expect(q.size() == 12, "scaled leaves lost a face: " + std::to_string(q.size()));
    }
    // 5. Across a mapblock edge: the node below lives in the neighbour's
    // block and draws the shared face there, so this block's leaf drops its
    // bottom and the neighbour's leaf is not meshed here at all.
    {
        auto q = meshQuads(ndef, {{v3s16(5, 0, 5), oak}, {v3s16(5, -1, 5), oak}});
        expect(q.size() == 5, "leaf over the block edge has " + std::to_string(q.size()) + " faces, not 5");
    }

    // 6. Water beside a dug block: no water face against the block, carved
    // or not; beside open air, the water keeps its face.
    {
        auto waterFacing = [&](bool carved, content_t beside) {
            CarveSnapshot snap;
            if (carved) {
                CarveSnapshot::Entry e;
                e.x = 5;
                e.y = 5;
                e.z = 5;
                e.damage.delta[0] = 0.4f;
                e.damage.crater[0] = 0.3f;
                snap.entries.push_back(e);
            }
            g_goanna_carve_block = carved ? &snap : nullptr;
            auto q = meshQuads(ndef, {{v3s16(5, 5, 5), beside}, {v3s16(6, 5, 5), water},
                    {v3s16(6, 6, 5), stone}});
            g_goanna_carve_block = nullptr;
            // The water's face towards -X, in the plane between the two.
            int n = 0;
            for (const Quad &f : q)
                if (f.liquid && std::fabs(f.centre.X - 5.5f * BS) < 0.01f * BS)
                    ++n;
            return n;
        };
        expect(waterFacing(false, stone) == 0, "water draws a face against a whole block");
        const int dug = waterFacing(true, stone);
        expect(dug == 0, "water draws " + std::to_string(dug) + " face(s) against a dug block");
        expect(waterFacing(false, CONTENT_AIR) == 1, "water beside air lost its face");
    }

    std::cout << "goanna_allfaces_test: " << g_checks << " checks, "
              << g_failures << " failures\n";
    return g_failures == 0 ? 0 : 1;
}
