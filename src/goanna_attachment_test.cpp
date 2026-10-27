// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Objects attached to a parent's bone (boneAttachmentTransform), with no
// Godot runtime. Not built by default: cmake --build build --target
// goanna_attachment_test
//
// Upstream hangs an attached object's scene node under the parent's joint
// node, which sits under the parent's mesh node, scaled by its visual_size.
// So a child is drawn at its own visual_size times the parent's, and times
// any scale the bone has. Goanna used to orthonormalise the child's
// transform, which drew DorfCraft's drapes (visual_size 1 on bodies at
// visual_size 10) a tenth of their size, inside the body, where nobody saw
// them.
//
// Checked: a child vertex lands where upstream's scene graph puts it, for a
// parent at visual_size 10 and at 1, turned and with an attachment offset;
// a bone scaled to zero hides what hangs from it; and, where the DorfCraft
// checkout is, its tabard drape loads with its named clips and hangs at its
// full width, not a tenth of it.

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

#include <SkinnedMesh.h>

#include "activeobject.h"
#include "constants.h"
#include "goanna_models.h"

using namespace goanna;
using godot::Basis;
using godot::Transform3D;
using godot::Vector3;

namespace {

int g_failures = 0;
int g_checks = 0;

void expect(bool condition, const std::string &message) {
    ++g_checks;
    if (!condition) {
        ++g_failures;
        std::cerr << "goanna_attachment_test: " << message << "\n";
    }
}

bool near(const Vector3 &a, const Vector3 &b, float eps = 1e-4f) {
    return (a - b).length() < eps;
}

std::string str(const Vector3 &v) {
    char buf[96];
    std::snprintf(buf, sizeof buf, "(%.4f, %.4f, %.4f)", v.x, v.y, v.z);
    return buf;
}

std::string slurp(const std::string &path) {
    std::ifstream f(path, std::ios::binary);
    std::stringstream s;
    s << f.rdbuf();
    return s.str();
}

// Where a vertex of the child's mesh (mesh units, Godot handedness) is drawn:
// the child's root transform, then the holder buildMeshVisual puts under it,
// scaled by the child's visual_size over BS.
Vector3 drawn(const Transform3D &root, const v3f &child_vs, const Vector3 &vertex) {
    Transform3D holder;
    holder.basis.scale(Vector3(child_vs.X, child_vs.Y, child_vs.Z) / BS);
    return (root * holder).xform(vertex);
}

} // namespace

int main() {
    // 1. A parent at visual_size 10, standing at the origin, a bone 1.5 mesh
    // units up. Upstream: the bone at 1.5 * 10 BS = 1.5 nodes, and a child
    // vertex 0.25 mesh units out at 0.25 * 1 * 10 BS = 0.25 nodes from it.
    {
        Transform3D bone(Basis(), Vector3(0, 1.5f, 0));
        const Transform3D root = boneAttachmentTransform(Transform3D(), v3f(10, 10, 10), bone, v3f(), v3f());
        const Vector3 at = drawn(root, v3f(1, 1, 1), Vector3(0.25f, 0, 0));
        expect(near(root.origin, Vector3(0, 1.5f, 0)), "bone at " + str(root.origin) + ", not 1.5 nodes up");
        expect(near(at, Vector3(0.25f, 1.5f, 0)),
                "a child vertex 0.25 mesh units out on a parent at visual_size 10 is drawn at " + str(at)
                + ", not (0.25, 1.5, 0): the parent's visual_size is not inherited");
    }

    // 2. A parent at visual_size 1 (a player, Mineclonia's wield item): the
    // child keeps its own scale, as it always did.
    {
        Transform3D bone(Basis(), Vector3(0, 6.3f, 0));
        const Transform3D root = boneAttachmentTransform(Transform3D(), v3f(1, 1, 1), bone, v3f(), v3f());
        const Vector3 at = drawn(root, v3f(1, 1, 1), Vector3(2, 0, 0));
        expect(near(at, Vector3(0.2f, 0.63f, 0)), "visual_size 1 parent: child vertex at " + str(at));
    }

    // 3. Turned parent, attachment offset (BS, in the bone's frame, scaled
    // with the parent) and the child's own visual_size 2.
    {
        Transform3D parent(Basis(Vector3(0, 1, 0), (float)M_PI / 2), Vector3(5, 100, -3));
        Transform3D bone(Basis(), Vector3(0, 1, 0));
        const Transform3D root = boneAttachmentTransform(parent, v3f(10, 10, 10), bone, v3f(0, 0, 1), v3f());
        // Offset 1 BS along Luanti z, which is Godot -z, in mesh units of a
        // parent at visual_size 10: one node, turned a quarter about y.
        const Vector3 expect_origin = parent.xform(Vector3(0, 1, -1));
        expect(near(root.origin, expect_origin), "offset attachment at " + str(root.origin) + ", not "
                + str(expect_origin));
        const Vector3 at = drawn(root, v3f(2, 2, 2), Vector3(0, 0.5f, 0));
        expect(near(at, expect_origin + Vector3(0, 1, 0)), "visual_size 2 child vertex at " + str(at));
    }

    // 4. Models hide parts by scaling a bone to zero; whatever hangs from it
    // goes with it, as upstream's child scene node does.
    {
        Transform3D bone;
        bone.basis.scale(Vector3(0, 0, 0));
        bone.origin = Vector3(0, 1, 0);
        const Transform3D root = boneAttachmentTransform(Transform3D(), v3f(10, 10, 10), bone, v3f(), v3f());
        const Vector3 a = drawn(root, v3f(1, 1, 1), Vector3(3, 0, 0));
        const Vector3 b = drawn(root, v3f(1, 1, 1), Vector3(-3, 2, 1));
        expect(near(a, b), "a child of a bone at zero scale is still drawn at its size");
    }

    // 5. DorfCraft's tabard, where its checkout is.
    const char *home = std::getenv("HOME");
    const std::string drape = std::string(home ? home : "")
            + "/Documents/Code/DorfCraft/mods/kindred_creatures/models/appearance/"
              "creature_kit_drape_frame_medium_tabard.gltf";
    const std::string bytes = slurp(drape);
    if (bytes.empty()) {
        std::printf("skipped (no DorfCraft checkout): %s\n", drape.c_str());
    } else {
        ModelLoader loader;
        scene::IAnimatedMesh *m = loader.load("creature_kit_drape_frame_medium_tabard.gltf", bytes);
        auto *sm = dynamic_cast<scene::SkinnedMesh *>(m);
        expect(sm != nullptr && !sm->isStatic(), "the tabard is not a skinned, animated mesh");
        if (sm) {
            expect(sm->getTrackNumber("walk").has_value() && sm->getTrackNumber("rest").has_value(),
                    "the tabard's walk and rest clips do not resolve by name");
            // Hung on a chest bone of a body at visual_size 10, a mesh unit
            // of the drape is a node, as it is of the body.
            const Transform3D root = boneAttachmentTransform(Transform3D(), v3f(10, 10, 10),
                    Transform3D(Basis(), Vector3(0, 1.0f, 0)), v3f(), v3f());
            const core::aabbox3df box = m->getBoundingBox();
            const float width = drawn(root, v3f(1, 1, 1), Vector3(box.MaxEdge.X, 0, 0)).x
                    - drawn(root, v3f(1, 1, 1), Vector3(box.MinEdge.X, 0, 0)).x;
            const float want = box.MaxEdge.X - box.MinEdge.X;
            expect(want > 0.0f && std::fabs(width - want) < 1e-3f, "the tabard is drawn "
                    + std::to_string(width) + " nodes across, not " + std::to_string(want));
        }
        if (m)
            m->drop();
    }

    std::cout << "goanna_attachment_test: " << g_checks << " checks, " << g_failures << " failures\n";
    return g_failures == 0 ? 0 : 1;
}
