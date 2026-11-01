// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Tree branches drawn as round rods from their arms (goanna_branch_rods.h),
// first as bare geometry, then meshed by the transplanted content_mapblock
// with no server and no Godot runtime. Not built by default:
// cmake --build build --target goanna_branch_rods_test
//
// Checks that each arm runs from the centre to the node's boundary in its own
// direction at its radius, that every triangle faces out, that caps show only
// where an arm's end is open, that the joint ball is drawn only where no two
// arms hold it already, and that a branch without arms in its metadata, or a
// node outside the group, keeps its node box.

#include <cmath>
#include <iostream>
#include <string>
#include <vector>

#include "client/content_mapblock.h"
#include "client/item_visuals_manager.h"
#include "client/mapblock_mesh.h"
#include "client/meshgen/collector.h"
#include "client/node_visuals.h"
#include "goanna_branch_rods.h"
#include "goanna_image_hooks.h"
#include "goanna_luanti_client.h"
#include "goanna_models.h"
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
        std::cerr << "goanna_branch_rods_test: " << message << "\n";
    }
}

int armIndex(int x, int y, int z) {
    for (int i = 0; i < kBranchArmCount; ++i) {
        const BranchOffset o = branchArmOffset(i);
        if (o.x == x && o.y == y && o.z == z)
            return i;
    }
    return -1;
}

uint32_t bit(int x, int y, int z) {
    return 1u << armIndex(x, y, z);
}

// Every triangle's face normal agrees with its vertices' normals.
bool facesOut(const RodMesh &m) {
    for (size_t t = 0; t + 2 < m.indices.size(); t += 3) {
        const float *a = m.vertices[m.indices[t]].pos;
        const float *b = m.vertices[m.indices[t + 1]].pos;
        const float *c = m.vertices[m.indices[t + 2]].pos;
        const float e1[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]};
        const float e2[3] = {c[0] - a[0], c[1] - a[1], c[2] - a[2]};
        const float f[3] = {e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2],
                e1[0] * e2[1] - e1[1] * e2[0]};
        float d = 0.0f;
        for (int v = 0; v < 3; ++v) {
            const float *n = m.vertices[m.indices[t + v]].normal;
            d += f[0] * n[0] + f[1] * n[1] + f[2] * n[2];
        }
        if (d <= 0.0f)
            return false;
    }
    return true;
}

void checkGeometry() {
    // The kernel's order: faces, corners, edges.
    expect(armIndex(-1, 0, 0) == 0 && armIndex(0, 1, 0) == 3 && armIndex(0, 0, 1) == 5,
            "faces are not xn xp yn yp zn zp");
    expect(armIndex(-1, -1, -1) == 6 && armIndex(1, 1, 1) == 13, "corners are not 6 to 13");
    expect(armIndex(-1, -1, 0) == 14 && armIndex(1, 1, 0) == 17 && armIndex(0, 1, 1) == 25,
            "edges are not 14 to 25 in xnyn ... ypzp order");
    for (int i = 0; i < kBranchArmCount; ++i) {
        const BranchOffset o = branchArmOffset(i), p = branchArmOffset(branchArmOpposite(i));
        expect(o.x == -p.x && o.y == -p.y && o.z == -p.z, "arm " + std::to_string(i) + " has no opposite");
    }
    expect(parseBranchArms("") == 0 && parseBranchArms("x") == 0 && parseBranchArms("-4") == 0,
            "bad arms parse as arms");
    expect(parseBranchArms("12") == 12, "\"12\" is not arms 12");

    const float r = 4 / 32.0f;
    // Every arm on its own: a rod to the boundary along its direction, the
    // ball at the joint, a cap at the end.
    for (int i = 0; i < kBranchArmCount; ++i) {
        const RodMesh m = branchRodMesh(1u << i, r, 1u << i);
        const BranchOffset o = branchArmOffset(i);
        const float len = 0.5f * std::sqrt((float)(o.x * o.x + o.y * o.y + o.z * o.z));
        const float dl = std::sqrt((float)(o.x * o.x + o.y * o.y + o.z * o.z));
        const float d[3] = {o.x / dl, o.y / dl, o.z / dl};
        float far = 0.0f, worst = 0.0f;
        for (const RodVertex &v : m.vertices) {
            const float along = v.pos[0] * d[0] + v.pos[1] * d[1] + v.pos[2] * d[2];
            far = std::max(far, along);
            const float q[3] = {v.pos[0] - along * d[0], v.pos[1] - along * d[1],
                    v.pos[2] - along * d[2]};
            worst = std::max(worst, std::sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2]));
        }
        const std::string what = "arm " + std::to_string(i);
        expect(std::fabs(far - len) < 1e-4f, what + " ends at " + std::to_string(far));
        expect(worst <= r + 1e-4f, what + " is wider than its radius");
        expect(facesOut(m), what + " has a triangle facing in");
        // rod 18, cap 9, ball 5 rings of 9
        expect(m.vertices.size() == 18 + 9 + 45, what + " has " + std::to_string(m.vertices.size()) +
                " vertices");
    }
    // A straight stem holds its own joint: no ball, and no caps asked.
    {
        const RodMesh m = branchRodMesh(bit(0, -1, 0) | bit(0, 1, 0), r, 0);
        expect(m.vertices.size() == 36 && m.indices.size() == 2 * 16 * 3,
                "a bare stem is not two plain rods");
        expect(facesOut(m), "a stem has a triangle facing in");
    }
    // A rod and the neighbour's rod back along the same line share rim
    // points and texture where they meet.
    {
        const int i = armIndex(1, 1, 0), j = branchArmOpposite(i);
        const RodMesh a = branchRodMesh(1u << i, r, 0), b = branchRodMesh(1u << j, r, 0);
        bool same = true;
        for (int k = 0; k <= kRodSides; ++k) {
            const RodVertex &va = a.vertices[2 * k + 1], &vb = b.vertices[2 * k + 1];
            // b is drawn one node across, at (+1, +1, 0)
            same = same && std::fabs(va.pos[0] - (vb.pos[0] + 1)) < 1e-5f &&
                    std::fabs(va.pos[1] - (vb.pos[1] + 1)) < 1e-5f &&
                    std::fabs(va.pos[2] - vb.pos[2]) < 1e-5f &&
                    std::fabs(va.uv[0] - vb.uv[0]) < 1e-5f && std::fabs(va.uv[1] - vb.uv[1]) < 1e-5f;
        }
        expect(same, "a diagonal rod and its neighbour's do not meet rim to rim");
    }
}

struct Drawn {
    size_t vertices = 0;
    size_t triangles = 0;
};

// What the generator drew for these nodes, with these arms in the snapshot.
Drawn mesh(const NodeDefManager *ndef, const std::vector<std::pair<v3s16, content_t>> &nodes,
        const BranchSnapshot *arms) {
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
    g_goanna_branch_block = arms;
    MapblockMeshGenerator(&data, &collector).generate();
    g_goanna_branch_block = nullptr;
    Drawn d;
    for (const auto &layer : collector.prebuffers)
        for (const PreMeshBuffer &buffer : layer) {
            d.vertices += buffer.vertices.size();
            d.triangles += buffer.indices.size() / 3;
        }
    return d;
}

} // namespace

int main() {
    checkGeometry();

    GoannaSession session;
    NodeDefManager *ndef = const_cast<NodeDefManager *>(session.nodeDefs());
    auto *idef = static_cast<IWritableItemDefManager *>(session.getItemDefManager());
    GoannaTextureSource *tsrc = session.tsrc();
    for (const char *name : {"test_bark.png", "test_stone.png"}) {
        video::IImage *img = goanna_create_image(video::ECF_A8R8G8B8, {16, 16});
        img->fill(video::SColor(255, 110, 80, 50));
        tsrc->insertSourceImage(name, img);
    }
    ModelCache models([](const std::string &, std::string &) { return false; });
    ItemVisualsManager visuals;
    Client client(tsrc, &session.shsrc(), ndef, idef, &models, &visuals);

    auto branchDef = [&](const std::string &name, int width) {
        // DorfCraft's branch: a node box (here a plain square stem), facedir,
        // one bark tile, the group naming its width.
        ContentFeatures f;
        f.name = name;
        f.drawtype = NDT_NODEBOX;
        f.param_type = CPT_LIGHT;
        f.param_type_2 = CPT2_FACEDIR;
        const float h = width / 32.0f * BS;
        f.node_box.type = NODEBOX_FIXED;
        f.node_box.fixed.push_back(aabb3f(-h, -BS / 2, -h, h, BS / 2, h));
        for (int i = 0; i < 6; ++i)
            f.tiledef[i].name = "test_bark.png";
        if (width > 0)
            f.groups["kindred_branch"] = width;
        return ndef->set(name, std::move(f));
    };
    const content_t branch = branchDef("test:branch_4", 4);
    // The same shape outside the group: never rods.
    const content_t plain = [&] {
        ContentFeatures f;
        f.name = "test:plain";
        f.drawtype = NDT_NODEBOX;
        f.param_type = CPT_LIGHT;
        f.node_box.type = NODEBOX_FIXED;
        f.node_box.fixed.push_back(aabb3f(-BS / 8, -BS / 2, -BS / 8, BS / 8, BS / 2, BS / 8));
        for (int i = 0; i < 6; ++i)
            f.tiledef[i].name = "test_bark.png";
        return ndef->set(f.name, std::move(f));
    }();
    content_t stone;
    {
        ContentFeatures f;
        f.name = "test:stone";
        f.drawtype = NDT_NORMAL;
        for (int i = 0; i < 6; ++i)
            f.tiledef[i].name = "test_stone.png";
        stone = ndef->set(f.name, std::move(f));
    }
    ndef->setNodeRegistrationStatus(true);
    NodeVisuals::fillNodeVisuals(ndef, &client, nullptr);

    const uint32_t stem = bit(0, -1, 0) | bit(0, 1, 0);
    const v3s16 at(5, 5, 5);
    // 1. No arms in metadata: the node box, six faces of a box.
    {
        const Drawn d = mesh(ndef, {{at, branch}}, nullptr);
        expect(d.triangles == 12, "a branch with no arms drew " + std::to_string(d.triangles) +
                " triangles, not its box's 12");
    }
    // 2. A lone stem: two rods, both ends open.
    {
        BranchSnapshot s;
        s.set(at.X, at.Y, at.Z, stem);
        const Drawn d = mesh(ndef, {{at, branch}}, &s);
        expect(d.triangles == 2 * 16 + 2 * 8, "a lone stem drew " + std::to_string(d.triangles) +
                " triangles, not 48");
    }
    // 3. Two stems stacked: the caps where they meet are hidden.
    {
        BranchSnapshot s;
        s.set(at.X, at.Y, at.Z, stem);
        s.set(at.X, at.Y + 1, at.Z, stem);
        const Drawn d = mesh(ndef, {{at, branch}, {at + v3s16(0, 1, 0), branch}}, &s);
        expect(d.triangles == 2 * (2 * 16 + 8), "two stacked stems drew " +
                std::to_string(d.triangles) + " triangles, not 80");
    }
    // 4. A stem on stone: no cap against the stone's face, which the stone
    // draws, a branch not being solid.
    {
        BranchSnapshot s;
        s.set(at.X, at.Y, at.Z, stem);
        const Drawn d = mesh(ndef, {{at, branch}, {at - v3s16(0, 1, 0), stone}}, &s);
        // the stone's own six faces, then the stem with one cap
        expect(d.triangles == 12 + 2 * 16 + 8, "a stem on stone drew " +
                std::to_string(d.triangles) + " triangles, not 52");
    }
    // 5. A neighbour across a diagonal edge with the arm back: no cap there.
    {
        BranchSnapshot s;
        const uint32_t lean = bit(0, -1, 0) | bit(1, 1, 0);
        s.set(at.X, at.Y, at.Z, lean);
        s.set(at.X + 1, at.Y + 1, at.Z, bit(-1, -1, 0));
        const Drawn d = mesh(ndef, {{at, branch}}, &s);
        // two rods, the downward end capped, and the ball (8 x 4 rows less
        // the 16 degenerate pole triangles)
        expect(d.triangles == 2 * 16 + 8 + 48, "a lean met at its edge drew " +
                std::to_string(d.triangles) + " triangles, not 88");
    }
    // 6. Arms on a node outside the group change nothing.
    {
        BranchSnapshot s;
        s.set(at.X, at.Y, at.Z, stem);
        const Drawn d = mesh(ndef, {{at, plain}}, &s);
        expect(d.triangles == 12, "a node outside the group drew rods");
    }

    std::cout << "goanna_branch_rods_test: " << g_checks << " checks, " << g_failures
              << " failures\n";
    return g_failures == 0 ? 0 : 1;
}
