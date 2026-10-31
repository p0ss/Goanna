// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Loading models through Irrlicht's own readers, converting them to Godot
// meshes with bones (and the knee and elbow cuts of goanna_limbs), and the
// per frame animator: tracks, bone overrides, first person posing, limb
// bends and body motion. Also the stand-in Client's getMesh. Main thread
// only; see goanna_models.h.

#include "goanna_models.h"
#include "goanna_steps.h"
#include "goanna_climb.h"

#include <algorithm>
#include <cmath>
#include <json/json.h>
#include <optional>
#include <type_traits>
#include <variant>
#include <vector>

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <ISceneManager.h>
#include <IMeshLoader.h>
#include <IMeshManipulator.h>
#include <IVertexBuffer.h>
#include <IIndexBuffer.h>
#include <SSkinMeshBuffer.h>
#include <S3DVertex.h>
#include <irrArray.h>
#include <IEventReceiver.h>
#include "CB3DMeshFileLoader.h"
#include "CXMeshFileLoader.h"
#include "COBJMeshFileLoader.h"
#include "CGLTFMeshFileLoader.h"
#include "CMeshManipulator.h"
#include "CMemoryFile.h"

#include "activeobject.h"
#include "constants.h"
#include "goanna_luanti_client.h"
#include "goanna_strokes.h"
#include "log.h"

scene::IAnimatedMesh *Client::getMesh(const std::string &filename, bool *is_shared) {
    if (is_shared)
        *is_shared = false;
    return m_models ? m_models->getMesh(filename, false) : nullptr;
}

scene::IMeshManipulator *Client::getMeshManipulator() {
    return m_models ? m_models->manipulator() : nullptr;
}

using namespace godot;

namespace goanna {

// The loaders take an ISceneManager and use it for the mesh manipulator
// (OBJ normals); everything else on the interface is unreachable here.
namespace {

class StubSceneManager final : public scene::ISceneManager {
public:
    StubSceneManager() : m_manip(new scene::CMeshManipulator()) {}
    ~StubSceneManager() override { m_manip->drop(); }

    scene::IAnimatedMesh *getMesh(io::IReadFile *) override { return nullptr; }
    scene::IMeshCache *getMeshCache() override { return nullptr; }
    video::IVideoDriver *getVideoDriver() override { return nullptr; }
    scene::AnimatedMeshSceneNode *addAnimatedMeshSceneNode(scene::IAnimatedMesh *, scene::ISceneNode *, s32,
            const core::vector3df &, const core::vector3df &, const core::vector3df &, bool) override { return nullptr; }
    scene::IMeshSceneNode *addMeshSceneNode(scene::IMesh *, scene::ISceneNode *, s32, const core::vector3df &,
            const core::vector3df &, const core::vector3df &, bool) override { return nullptr; }
    scene::ICameraSceneNode *addCameraSceneNode(scene::ISceneNode *, const core::vector3df &,
            const core::vector3df &, s32, bool) override { return nullptr; }
    scene::IBillboardSceneNode *addBillboardSceneNode(scene::ISceneNode *, const core::dimension2d<f32> &,
            const core::vector3df &, s32, video::SColor, video::SColor) override { return nullptr; }
    scene::ISceneNode *addEmptySceneNode(scene::ISceneNode *, s32) override { return nullptr; }
    scene::IDummyTransformationSceneNode *addDummyTransformationSceneNode(scene::ISceneNode *, s32) override { return nullptr; }
    scene::ISceneNode *getRootSceneNode() override { return nullptr; }
    scene::ISceneNode *getSceneNodeFromId(s32, scene::ISceneNode *) override { return nullptr; }
    scene::ISceneNode *getSceneNodeFromName(const c8 *, scene::ISceneNode *) override { return nullptr; }
    scene::ISceneNode *getSceneNodeFromType(scene::ESCENE_NODE_TYPE, scene::ISceneNode *) override { return nullptr; }
    void getSceneNodesFromType(scene::ESCENE_NODE_TYPE, core::array<scene::ISceneNode *> &, scene::ISceneNode *) override {}
    scene::ICameraSceneNode *getActiveCamera() const override { return nullptr; }
    void setActiveCamera(scene::ICameraSceneNode *) override {}
    u32 registerNodeForRendering(scene::ISceneNode *, scene::E_SCENE_NODE_RENDER_PASS) override { return 0; }
    void clearAllRegisteredNodesForRendering() override {}
    void drawAll() override {}
    void addExternalMeshLoader(scene::IMeshLoader *) override {}
    u32 getMeshLoaderCount() const override { return 0; }
    scene::IMeshLoader *getMeshLoader(u32) const override { return nullptr; }
    scene::ISceneCollisionManager *getSceneCollisionManager() override { return nullptr; }
    scene::IMeshManipulator *getMeshManipulator() override { return m_manip; }
    void addToDeletionQueue(scene::ISceneNode *) override {}
    bool postEventFromUser(const SEvent &) override { return false; }
    void clear() override {}
    scene::E_SCENE_NODE_RENDER_PASS getSceneNodeRenderPass() const override { return scene::ESNRP_NONE; }
    void setGlobalDebugData(u16, u16) override {}
    scene::ISceneManager *createNewSceneManager(bool) override { return nullptr; }
    scene::SkinnedMesh *createSkinnedMesh() override { return nullptr; }
    scene::E_SCENE_NODE_RENDER_PASS getCurrentRenderPass() const override { return scene::ESNRP_NONE; }
    void setCurrentRenderPass(scene::E_SCENE_NODE_RENDER_PASS) override {}
    bool isCulled(const scene::ISceneNode *) const override { return false; }

private:
    scene::CMeshManipulator *m_manip;
};

// Upstream: CNullDriver::getMaxJointTransforms. Godot skins on the GPU, so
// software skinning is never wanted; keep the threshold above any mesh.
constexpr u16 MAX_HW_JOINTS = 0xffff;

} // namespace

struct ModelLoader::Impl {
    StubSceneManager smgr;
    std::vector<scene::IMeshLoader *> loaders;
};

ModelLoader::ModelLoader() : m_impl(new Impl) {
    // Same set and order as CSceneManager; the last matching loader wins.
    m_impl->loaders.push_back(new scene::CXMeshFileLoader(&m_impl->smgr));
    m_impl->loaders.push_back(new scene::COBJMeshFileLoader(&m_impl->smgr));
    m_impl->loaders.push_back(new scene::CB3DMeshFileLoader(&m_impl->smgr));
    m_impl->loaders.push_back(new scene::CGLTFMeshFileLoader());
}

ModelLoader::~ModelLoader() {
    for (auto *l : m_impl->loaders)
        l->drop();
}

scene::IMeshManipulator *ModelLoader::manipulator() {
    return m_impl->smgr.getMeshManipulator();
}

scene::IAnimatedMesh *ModelLoader::load(const std::string &name, const std::string &bytes) {
    // CSceneManager::getUncachedMesh, without the cache.
    io::CMemoryReadFile file(bytes.data(), (long)bytes.size(), name.c_str(), false);
    for (auto it = m_impl->loaders.rbegin(); it != m_impl->loaders.rend(); ++it) {
        if (!(*it)->isALoadableFileExtension(name.c_str()))
            continue;
        file.seek(0);
        scene::IAnimatedMesh *mesh = (*it)->createMesh(&file);
        if (mesh) {
            mesh->prepareForAnimation(MAX_HW_JOINTS);
            return mesh;
        }
    }
    warningstream << "Goanna: could not load model " << name << std::endl;
    return nullptr;
}

ModelCache::ModelCache(MediaGetter media) : m_media(std::move(media)) {}

ModelCache::~ModelCache() {
    for (auto &kv : m_cache)
        kv.second->drop();
}

const ModelExtras *ModelCache::extras(const std::string &name) const {
    auto it = m_extras.find(name);
    return it == m_extras.end() ? nullptr : &it->second;
}

namespace {
int g_stroke_models = 0;
uint64_t g_stroke_poses = 0;
uint64_t g_stroke_evaluations = 0;
int g_stroke_tiers[3] = {};
uint64_t g_feet_frames = 0;
float g_feet_most = 0.0f;
uint64_t g_steps = 0, g_steps_unreachable = 0;
float g_steps_stretch = 0.0f;
uint64_t g_steps_walking = 0, g_steps_trotting = 0;
float g_steps_pitch = 0.0f;
} // namespace

uint64_t g_climb_ladders = 0, g_climb_mantles = 0, g_climb_landed = 0, g_climb_moves = 0;
uint64_t climbLadders() { return g_climb_ladders; }
uint64_t climbMantles() { return g_climb_mantles; }
uint64_t climbMantlesLanded() { return g_climb_landed; }
uint64_t climbMoves() { return g_climb_moves; }
uint64_t plannedSteps() { return g_steps; }
uint64_t plannedStepsUnreachable() { return g_steps_unreachable; }
float plannedStepsStretchMost() { return g_steps_stretch; }
uint64_t plannedStepsWalking() { return g_steps_walking; }
uint64_t plannedStepsTrotting() { return g_steps_trotting; }
float plannedGirdlePitchMost() { return g_steps_pitch; }

int strokeModelCount() { return g_stroke_models; }
uint64_t strokePoseCount() { return g_stroke_poses; }
uint64_t strokeEvaluationCount() { return g_stroke_evaluations; }
int strokeDetailCount(StrokeDetail detail) { return g_stroke_tiers[(int)detail]; }
void setStrokeDetailCounts(int full, int reduced, int clip) {
    g_stroke_tiers[0] = full;
    g_stroke_tiers[1] = reduced;
    g_stroke_tiers[2] = clip;
}
uint64_t fittedFootFrames() { return g_feet_frames; }
float fittedFootMost() { return g_feet_most; }

void ModelCache::buildStrokes(const std::string &name, ModelExtras &extras) {
    Json::CharReaderBuilder builder;
    std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
    Json::Value marks;
    std::string errors;
    const std::string &text = extras.strokes;
    if (!reader->parse(text.data(), text.data() + text.size(), &marks, &errors) || !marks.isObject()
            || !marks["family"].isString() || !marks["state"].isString()) {
        warningstream << "Goanna: unreadable stroke marks in " << name << std::endl;
        return;
    }
    // A family travels as a glTF with no scene (Luanti serves no .json
    // media), in its root extras; each is read once.
    auto load = [&](const std::string &family_name) -> std::shared_ptr<const StrokeFamily> {
        auto known = m_stroke_families.find(family_name);
        if (known != m_stroke_families.end())
            return known->second;
        std::string bytes;
        Json::Value file;
        auto parsed = std::make_shared<StrokeFamily>();
        if (!m_media(family_name, bytes)
                || !reader->parse(bytes.data(), bytes.data() + bytes.size(), &file, &errors)
                || !file.isObject() || !file["extras"].isObject()
                || !parseStrokeFamily(file["extras"]["stroke_family"], *parsed)) {
            warningstream << "Goanna: stroke family " << family_name << " for " << name
                    << " is missing or unreadable" << std::endl;
            return nullptr;
        }
        m_stroke_families[family_name] = parsed;
        return parsed;
    };
    std::shared_ptr<const StrokeFamily> family = load(marks["family"].asString());
    if (!family)
        return;
    StrokePlan plan;
    if (!parseStrokePlan(marks["plan"], plan)) {
        warningstream << "Goanna: unreadable stroke plan in " << name << std::endl;
        return;
    }
    auto evaluator = std::make_shared<StrokeEvaluator>(plan, family);
    if (!evaluator->valid()) {
        warningstream << "Goanna: " << name << " lacks the bones its stroke plan needs" << std::endl;
        return;
    }
    extras.stroke_evaluator = std::move(evaluator);
    // Task families on the same plan, in the order the state indexes.
    const Json::Value &tasks = marks["tasks"];
    for (Json::ArrayIndex i = 0; tasks.isArray() && i < tasks.size(); ++i) {
        const Json::Value &task = tasks[i];
        std::shared_ptr<const StrokeFamily> task_family =
                task.isArray() && task.size() == 2 && task[1].isString() ? load(task[1].asString()) : nullptr;
        auto task_evaluator = task_family ? std::make_shared<StrokeEvaluator>(plan, task_family) : nullptr;
        extras.task_evaluators.push_back(task_evaluator && task_evaluator->valid() ? task_evaluator : nullptr);
    }
    extras.stroke_state = marks["state"].asString();
    ++g_stroke_models;
}

scene::IAnimatedMesh *ModelCache::getMesh(const std::string &name, bool cache) {
    if (cache) {
        auto it = m_cache.find(name);
        if (it != m_cache.end()) {
            it->second->grab();
            return it->second;
        }
    }
    std::string bytes;
    if (!m_media(name, bytes)) {
        errorstream << "Goanna: mesh not found in media: " << name << std::endl;
        return nullptr;
    }
    scene::IAnimatedMesh *mesh = m_loader.load(name, bytes);
    if (!mesh)
        return nullptr;
    // The loader drops node extras; read them for the jiggle marks.
    ModelExtras extras;
    if (parseModelExtras(name, bytes, extras) && (!extras.empty() || !extras.air.empty())) {
        if (!extras.strokes.empty())
            buildStrokes(name, extras);
        if (!extras.air.empty())
            buildAir(name, extras);
        m_extras[name] = std::move(extras);
    } else {
        m_extras.erase(name);
    }
    if (cache) {
        mesh->grab();
        m_cache[name] = mesh;
    }
    return mesh;
}

// ---- conversion ------------------------------------------------------------

Transform3D toGodotTransform(const core::matrix4 &m) {
    // Irrlicht: out = v * M, translation in M[12..14]. Mirror z on both sides.
    Basis b(m[0], m[4], -m[8],
            m[1], m[5], -m[9],
            -m[2], -m[6], m[10]);
    return Transform3D(b, Vector3(m[12], m[13], -m[14]));
}

core::matrix4 fromGodotTransform(const Transform3D &t) {
    core::matrix4 m;
    const Basis &b = t.basis;
    m[0] = b[0][0];
    m[4] = b[0][1];
    m[8] = -b[0][2];
    m[1] = b[1][0];
    m[5] = b[1][1];
    m[9] = -b[1][2];
    m[2] = -b[2][0];
    m[6] = -b[2][1];
    m[10] = b[2][2];
    m[3] = m[7] = m[11] = 0.0f;
    m[12] = t.origin.x;
    m[13] = t.origin.y;
    m[14] = -t.origin.z;
    m[15] = 1.0f;
    return m;
}

Transform3D boneAttachmentTransform(const Transform3D &parent_root, const v3f &parent_visual_size,
        const Transform3D &bone_global, const v3f &position, const v3f &rotation_deg) {
    Transform3D parent_scale;
    parent_scale.basis.scale(Vector3(parent_visual_size.X, parent_visual_size.Y, parent_visual_size.Z) / BS);
    const Transform3D attach(Basis::from_euler(Vector3(Math::deg_to_rad(rotation_deg.X),
            Math::deg_to_rad(-rotation_deg.Y), Math::deg_to_rad(-rotation_deg.Z))),
            Vector3(position.X, position.Y, -position.Z));
    // Until 2026-10-27 the basis was orthonormalised here, which threw the
    // inherited scale away: a drape at visual_size 1 on a DorfCraft body at
    // visual_size 10 was drawn a tenth of its size, inside the body.
    Transform3D to_bs;
    to_bs.basis.scale(Vector3(BS, BS, BS));
    return parent_root * parent_scale * bone_global * attach * to_bs;
}

GodotModel::~GodotModel() {
    if (skinned)
        skinned->drop();
    if (source)
        source->drop();
}

// Vertex normals that face away from the surface they belong to, replaced
// by the surface's own. Mineclonia's villager and iron golem carry normals
// in their B3D files, and as the loader hands them over most point into the
// body: 120 of the villager's 172 triangles and 64 of the golem's 96 have
// normals opposite to their faces (the player and the cow have none, so
// Irrlicht recalculates theirs, and those are right). Luanti shades an
// entity by its normal only mildly; Goanna lights it as a surface, so the
// faces turned to a lantern drew black at night while the undersides of the
// arms caught its light, and a metal golem read dark in full sun. Each
// vertex is compared with the area weighted normal of the triangles that
// use it, and one more than 60 degrees off takes that instead. Smooth
// normals on a curved model stay within that of their faces and are kept.
// The outward side is the minus cross product of the edges in this (z
// mirrored) space: it is what the recalculated normals come out as, and the
// winding Godot already draws as front facing.
static int repairNormals(const PackedVector3Array &verts, PackedVector3Array &normals,
        const PackedInt32Array &indices) {
    const int nv = verts.size();
    std::vector<Vector3> face(nv);
    for (int t = 0; t + 2 < indices.size(); t += 3) {
        const int a = indices[t], b = indices[t + 1], c = indices[t + 2];
        if (a < 0 || b < 0 || c < 0 || a >= nv || b >= nv || c >= nv)
            continue;
        const Vector3 n = -(verts[b] - verts[a]).cross(verts[c] - verts[a]);
        face[a] += n;
        face[b] += n;
        face[c] += n;
    }
    int replaced = 0;
    for (int i = 0; i < nv; ++i) {
        if (face[i].length_squared() < 1e-20f)
            continue;
        const Vector3 geo = face[i].normalized();
        const Vector3 cur = normals[i];
        if (cur.length_squared() < 1e-12f || cur.normalized().dot(geo) < 0.5f) {
            normals.set(i, geo);
            ++replaced;
        }
    }
    return replaced;
}

// Each vertex's UV rectangle, for CUSTOM0: the UV bounds of the triangles
// connected to it through shared vertices, as (min u, min v, max u, max v).
// On a box model that is one box face, which is exactly the region of the
// atlas the face draws, and the parallax march in entity_common.gdshaderinc
// clamps to it so it never reads a neighbouring island of the skin. A
// mirrored limb's face gives the same rectangle as its twin. The cut a
// limb's knee makes shares its new vertices between both halves, so the
// face keeps its whole rectangle. Vertices in no triangle get an empty one,
// which the shader reads as unknown. `faces` receives each distinct
// rectangle once, for the relief measure (GodotModel::surface_faces).
static PackedFloat32Array faceRects(const PackedVector2Array &uvs, const PackedInt32Array &indices,
        std::vector<Rect2> &faces) {
    const int nv = uvs.size();
    std::vector<int> parent(nv);
    for (int i = 0; i < nv; ++i)
        parent[i] = i;
    auto find = [&](int v) {
        while (parent[v] != v)
            v = parent[v] = parent[parent[v]];
        return v;
    };
    std::vector<char> used(nv, 0);
    for (int t = 0; t + 2 < indices.size(); t += 3) {
        const int a = indices[t], b = indices[t + 1], c = indices[t + 2];
        if (a < 0 || b < 0 || c < 0 || a >= nv || b >= nv || c >= nv)
            continue;
        used[a] = used[b] = used[c] = 1;
        parent[find(b)] = find(a);
        parent[find(c)] = find(a);
    }
    std::vector<Vector4> rect(nv, Vector4(1e30f, 1e30f, -1e30f, -1e30f));
    for (int i = 0; i < nv; ++i) {
        if (!used[i])
            continue;
        Vector4 &r = rect[find(i)];
        const Vector2 uv = uvs[i];
        r = Vector4(std::min(r.x, uv.x), std::min(r.y, uv.y), std::max(r.z, uv.x), std::max(r.w, uv.y));
    }
    for (int i = 0; i < nv; ++i) {
        if (!used[i] || find(i) != i)
            continue;
        const Rect2 f(rect[i].x, rect[i].y, rect[i].z - rect[i].x, rect[i].w - rect[i].y);
        if (std::find(faces.begin(), faces.end(), f) == faces.end())
            faces.push_back(f);
    }
    PackedFloat32Array out;
    out.resize(nv * 4);
    for (int i = 0; i < nv; ++i) {
        const Vector4 r = used[i] ? rect[find(i)] : Vector4();
        out[i * 4] = r.x;
        out[i * 4 + 1] = r.y;
        out[i * 4 + 2] = r.z;
        out[i * 4 + 3] = r.w;
    }
    return out;
}

std::shared_ptr<GodotModel> buildGodotModel(scene::IAnimatedMesh *mesh, const ModelExtras *extras) {
    auto model = std::make_shared<GodotModel>();
    model->mesh.instantiate();
    mesh->grab();
    model->source = mesh;
    auto *skinned = dynamic_cast<scene::SkinnedMesh *>(mesh);
    if (skinned) {
        skinned->grab();
        model->skinned = skinned;
        model->animated = !skinned->isStatic();
        const auto &joints = skinned->getAllJoints();
        model->joint_count = (int)joints.size();
        model->attached_bone.assign(joints.size(), -1);
        model->bone_count = model->joint_count;
        if (model->animated) {
            for (size_t j = 0; j < joints.size(); ++j)
                if (!joints[j]->AttachedMeshes.empty())
                    model->attached_bone[j] = model->bone_count++;
            // Knees and elbows: each limb's lower half and its seam get a
            // bone of their own (goanna_limbs.h).
            model->limbs = findLimbs(*skinned);
            for (LimbBend &l : model->limbs) {
                l.bone = model->bone_count++;
                l.seam_bone = model->bone_count++;
            }
            model->jiggle = buildJiggleRig(*skinned, extras);
            if (extras && extras->air_plan)
                model->air = extras->air_plan;
            if (extras && extras->stroke_evaluator) {
                model->strokes = extras->stroke_evaluator;
                model->tasks = extras->task_evaluators;
                model->stroke_state = extras->stroke_state;
            }
            if (extras && extras->steps) {
                model->steps = true;
                model->step_clips = extras->step_clips;
            }
        }
    }
    // joint index of a rigidly attached buffer, or -1
    std::vector<int> attached_joint(mesh->getMeshBufferCount(), -1);
    if (skinned) {
        const auto &joints = skinned->getAllJoints();
        for (size_t j = 0; j < joints.size(); ++j)
            for (u32 b : joints[j]->AttachedMeshes)
                if (b < attached_joint.size())
                    attached_joint[b] = (int)j;
    }

    for (u32 bi = 0; bi < mesh->getMeshBufferCount(); ++bi) {
        scene::IMeshBuffer *buf = mesh->getMeshBuffer(bi);
        const scene::IVertexBuffer *vb = buf->getVertexBuffer();
        const scene::IIndexBuffer *ib = buf->getIndexBuffer();
        u32 vcount = vb->getCount();
        u32 icount = ib->getCount();
        if (!vcount || !icount)
            continue;
        const auto *ssb = skinned ? static_cast<const scene::SSkinMeshBuffer *>(buf) : nullptr;
        // Static skinned meshes: bake the buffer transform (rigid attachment).
        bool bake = ssb && !model->animated;
        const core::matrix4 *bake_m = bake ? &ssb->Transformation : nullptr;

        PackedVector3Array verts, normals;
        PackedVector2Array uvs;
        verts.resize(vcount);
        normals.resize(vcount);
        uvs.resize(vcount);
        u32 pitch = vb->getType() == video::EVT_STANDARD ? sizeof(video::S3DVertex)
                : vb->getType() == video::EVT_2TCOORDS ? sizeof(video::S3DVertex2TCoords)
                : sizeof(video::S3DVertexTangents);
        const u8 *vdata = static_cast<const u8 *>(vb->getData());
        for (u32 i = 0; i < vcount; ++i) {
            const auto *v = reinterpret_cast<const video::S3DVertex *>(vdata + i * pitch);
            core::vector3df p = v->Pos, n = v->Normal;
            if (bake_m) {
                bake_m->transformVect(p);
                n = bake_m->rotateAndScaleVect(n);
                n.normalize();
            }
            verts[i] = Vector3(p.X, p.Y, -p.Z);
            normals[i] = Vector3(n.X, n.Y, -n.Z);
            uvs[i] = Vector2(v->TCoords.X, v->TCoords.Y);
        }
        PackedInt32Array indices;
        indices.resize(icount);
        if (ib->getType() == video::EIT_16BIT) {
            const u16 *src = static_cast<const u16 *>(ib->getData());
            for (u32 i = 0; i < icount; ++i)
                indices[i] = src[i];
        } else {
            const u32 *src = static_cast<const u32 *>(ib->getData());
            for (u32 i = 0; i < icount; ++i)
                indices[i] = (int32_t)src[i];
        }
        repairNormals(verts, normals, indices);
        Array arrays;
        arrays.resize(Mesh::ARRAY_MAX);
        arrays[Mesh::ARRAY_VERTEX] = verts;
        arrays[Mesh::ARRAY_NORMAL] = normals;
        arrays[Mesh::ARRAY_TEX_UV] = uvs;
        arrays[Mesh::ARRAY_INDEX] = indices;

        if (ssb && model->animated) {
            const scene::WeightBuffer *w = ssb->getWeights();
            int aj = attached_joint[bi];
            // Every surface of an animated model gets bones, including a
            // static buffer with no weights and no attached joint (the B3D
            // loader never fills AttachedMeshes, so such buffers are common:
            // Mineclonia's llama has one). Godot cannot mix skinned and
            // unskinned surfaces in one skeleton bound mesh: mesh_storage
            // allocates the skinning vertex buffer only for surfaces with
            // bones and then binds a null one for the rest, which printed
            // "vertex_array is null" on every draw. The unweighted branch
            // below binds such a buffer to the identity bone, which is how
            // upstream draws it too, at rest.
            {
                PackedInt32Array bones;
                PackedFloat32Array weights;
                bones.resize(vcount * 4);
                weights.resize(vcount * 4);
                for (u32 i = 0; i < vcount; ++i) {
                    float sum = 0;
                    if (w) {
                        const auto &ids = w->getJointIds(i);
                        const auto &ws = w->getWeights(i);
                        for (int k = 0; k < 4; ++k)
                            sum += ws[k];
                        for (int k = 0; k < 4; ++k) {
                            bones[i * 4 + k] = ids[k];
                            weights[i * 4 + k] = sum > 0 ? ws[k] / sum : 0;
                        }
                    }
                    if (sum <= 0) {
                        // unweighted vertex: rigid with the attached joint, else identity
                        int bone = aj >= 0 ? model->attached_bone[aj] : -1;
                        if (bone < 0) {
                            if (model->identity_bone < 0)
                                model->identity_bone = model->bone_count++;
                            bone = model->identity_bone;
                        }
                        for (int k = 0; k < 4; ++k) {
                            bones[i * 4 + k] = bone;
                            weights[i * 4 + k] = k == 0 ? 1.0f : 0.0f;
                        }
                    }
                }
                if (!model->limbs.empty()) {
                    LimbMeshData d;
                    for (int i = 0; i < verts.size(); ++i) {
                        d.verts.push_back(verts[i]);
                        d.normals.push_back(normals[i]);
                        d.uvs.push_back(uvs[i]);
                    }
                    for (int i = 0; i < indices.size(); ++i)
                        d.indices.push_back(indices[i]);
                    for (int i = 0; i < bones.size(); ++i) {
                        d.bones.push_back(bones[i]);
                        d.weights.push_back(weights[i]);
                    }
                    splitLimbs(model->limbs, d);
                    const int n = (int)d.verts.size();
                    verts.resize(n);
                    normals.resize(n);
                    uvs.resize(n);
                    bones.resize(n * 4);
                    weights.resize(n * 4);
                    for (int i = 0; i < n; ++i) {
                        verts[i] = d.verts[i];
                        normals[i] = d.normals[i];
                        uvs[i] = d.uvs[i];
                    }
                    for (int i = 0; i < n * 4; ++i) {
                        bones[i] = d.bones[i];
                        weights[i] = d.weights[i];
                    }
                    indices.resize((int)d.indices.size());
                    for (int i = 0; i < (int)d.indices.size(); ++i)
                        indices[i] = d.indices[i];
                    arrays[Mesh::ARRAY_VERTEX] = verts;
                    arrays[Mesh::ARRAY_NORMAL] = normals;
                    arrays[Mesh::ARRAY_TEX_UV] = uvs;
                    arrays[Mesh::ARRAY_INDEX] = indices;
                }
                arrays[Mesh::ARRAY_BONES] = bones;
                arrays[Mesh::ARRAY_WEIGHTS] = weights;
            }
        }
        model->surface_faces.emplace_back();
        arrays[Mesh::ARRAY_CUSTOM0] = faceRects(uvs, indices, model->surface_faces.back());
        model->mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays, Array(),
                Dictionary(), Mesh::ARRAY_CUSTOM_RGBA_FLOAT << Mesh::ARRAY_FORMAT_CUSTOM0_SHIFT);
        model->texture_slots.push_back(mesh->getTextureSlot(bi));
    }
    return model;
}

// ---- animation -------------------------------------------------------------

// The pose the first-person arm is held at while mining: the first frame of
// the first track, or the rest pose on a mesh with no tracks.
static JointTransforms firstFramePose(const scene::SkinnedMesh &mesh) {
    scene::AnimSpec first;
    if (mesh.getTrackCount() > 0)
        first.tracks[0] = scene::TrackAnimSpec{};
    return animateTracks(mesh, first, OldJointTransforms(mesh.getAllJoints().size()));
}

ModelAnimator::ModelAnimator(std::shared_ptr<GodotModel> model) : m_model(std::move(model)) {
    size_t n = m_model->joint_count;
    m_old_transforms.assign(n, std::nullopt);
    m_globals.resize(n);
    const size_t limbs = m_model->limbs.size();
    m_bend.assign(limbs, 0.0f);
    m_eased_bend.assign(limbs, 0.0f);
    m_swing.assign(limbs, 0.0f);
    m_swing_rate.assign(limbs, 0.0f);
    if (limbs && m_model->skinned) {
        m_body_joint = m_model->skinned->getJointNumber("Body");
        probeLimbSigns();
    }
}

void ModelAnimator::inheritPose(const ModelAnimator &previous) {
    if (previous.m_model == m_model)
        m_old_transforms = previous.m_old_transforms;
}

void ModelAnimator::poseStroke(float dt, JointTransforms &locals,
        const std::map<std::string, BoneOverride> &overrides) {
    // The state: position (told angle in degrees, stroke time when sent,
    // target height), scale (action serial, phase: 0 none, 1 preparing,
    // 2 committed, format). Each set resends every override the object
    // holds, so the server sends only what this cannot work out: a stroke
    // ends unprompted at its length, commits by its clock, and phase 2 or
    // 0 arrive only for a frozen angle away from the told one or a stroke
    // cut short.
    auto it = overrides.find(m_model->stroke_state);
    const int format = it == overrides.end() ? 0 : (int)std::lround(it->second.scale.vector.Z);
    // One action at a time on the bone, of any kind; the format says which.
    const StrokeEvaluator *evaluator = nullptr;
    bool loops = false;
    switch (format) {
    case 1: // a stroke
        evaluator = m_model->strokes.get();
        break;
    case 2: { // a looping task: position Z picks the body's task family
        const long task = std::lround(it->second.position.vector.Z);
        if (task >= 0 && task < (long)m_model->tasks.size())
            evaluator = m_model->tasks[task].get();
        loops = true;
        break;
    }
    default: // nothing, or a kind this client does not show (the clip plays)
        break;
    }
    if (!evaluator) {
        m_melee = MeleeStroke();
        return;
    }
    const BoneOverride &state = it->second;
    const int action = (int)std::lround(state.scale.vector.X);
    const int phase = (int)std::lround(state.scale.vector.Y);
    const float told = state.position.vector.X;
    if (phase <= 0) {
        m_melee = MeleeStroke();
        return;
    }
    const bool fresh = !m_melee.active || action != m_melee.action || format != m_melee.format
            || evaluator != m_melee.evaluator;
    if (fresh || phase != m_melee.phase || std::fabs(told - m_melee.told) > 1e-3f) {
        if (fresh)
            m_melee.angle = told;
        m_melee.active = true;
        m_melee.format = format;
        m_melee.evaluator = evaluator;
        m_melee.loops = loops;
        m_melee.action = action;
        m_melee.phase = phase;
        m_melee.told = told;
        // dtime_passed has already advanced by this step's dt.
        m_melee.t = state.position.vector.Y + state.dtime_passed;
    } else {
        m_melee.t += dt;
    }
    // Ease towards the told angle the short way round, as the server does
    // (900 degrees a second).
    const float d = std::remainder(m_melee.told - m_melee.angle, 360.0f);
    const float step = 900.0f * dt;
    m_melee.angle = std::fmod(m_melee.angle + std::clamp(d, -step, step) + 360.0f, 360.0f);
    // A task loops until the server ends it; a stroke is over at its length.
    const float length = evaluator->length();
    const float t = loops && length > 0.0f ? std::fmod(m_melee.t, length) : m_melee.t;
    if (t > length)
        return; // over: the game's clip holds its last frame
    // Far off, the game's clip shows; at the edge, the pose fades in or
    // out over it (goanna_stroke_detail.h).
    const float w = m_stroke_lod.weight();
    if (w <= 0.0f)
        return;
    scene::SkinnedMesh *mesh = m_model->skinned;
    ++g_stroke_poses;
    const uint64_t evaluated = m_stroke_lod.evaluations();
    m_stroke_lod.pose(*evaluator, m_melee.angle, t, fresh, m_stroke_pose);
    g_stroke_evaluations += m_stroke_lod.evaluations() - evaluated;
    for (const StrokeBonePose &b : m_stroke_pose) {
        auto jn = mesh->getJointNumber(b.bone);
        if (!jn)
            continue;
        auto *t = std::get_if<core::Transform>(&locals[*jn]);
        if (!t)
            continue;
        // Exactly what an absolute Luanti bone override with these values
        // does (the old per-tick stream sent the same numbers).
        const v3f p(b.p[0], b.p[1], b.p[2]);
        core::quaternion q(v3f(b.r[0], b.r[1], b.r[2]));
        v3f euler;
        q.toEuler(euler);
        q = core::quaternion(euler).makeInverse();
        if (w < 1.0f) {
            t->translation = t->translation + (p - t->translation) * w;
            t->rotation.slerp(t->rotation, q, w);
        } else {
            t->translation = p;
            t->rotation = q;
        }
    }
}

// ---- fliers -----------------------------------------------------------------

namespace {
int g_air_models = 0;
uint64_t g_air_flying = 0, g_air_talons = 0, g_air_bank = 0, g_air_bank_agreeing = 0;

// The server's action state on a body's state bone (goanna_strokes.h,
// goanna_air.h) when it is of this format, else null: one action at a
// time rides on the bone, each kind reading only its own format.
const BoneOverride *actionState(const std::map<std::string, BoneOverride> &overrides,
        const std::string &bone, int format) {
    auto it = overrides.find(bone);
    if (it == overrides.end() || std::lround(it->second.scale.vector.Z) != format)
        return nullptr;
    return &it->second;
}
} // namespace

int airModelCount() { return g_air_models; }
uint64_t airFlyingFrames() { return g_air_flying; }
uint64_t airTalonFrames() { return g_air_talons; }
uint64_t airBankFrames() { return g_air_bank; }
uint64_t airBankAgreeing() { return g_air_bank_agreeing; }

void ModelCache::buildAir(const std::string &name, ModelExtras &extras) {
    Json::CharReaderBuilder builder;
    std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
    Json::Value marks;
    std::string errors;
    auto plan = std::make_shared<AirPlan>();
    if (!reader->parse(extras.air.data(), extras.air.data() + extras.air.size(), &marks, &errors)
            || !parseAirPlan(marks, *plan)) {
        warningstream << "Goanna: unreadable air plan in " << name << std::endl;
        return;
    }
    extras.air_plan = std::move(plan);
    ++g_air_models;
}

void ModelAnimator::stepAir(float dt, scene::AnimSpec &anim, const std::map<std::string, BoneOverride> &overrides) {
    const AirPlan &plan = *m_model->air;
    scene::SkinnedMesh *mesh = m_model->skinned;
    if (!m_air_found) {
        m_air_found = true;
        for (const AirPlan::Leg &l : plan.legs) {
            auto upper = mesh->getJointNumber(l.upper), lower = mesh->getJointNumber(l.lower);
            if (upper && lower)
                m_air_legs.push_back({*upper, *lower});
        }
        // Each wing's root and the first joint past it, whose height against
        // the other wing's says which way the wings banked.
        const auto &joints = mesh->getAllJoints();
        for (const std::string &w : plan.wings) {
            auto root = mesh->getJointNumber(w);
            if (!root)
                continue;
            u32 tip = *root;
            for (size_t j = 0; j < joints.size(); ++j) {
                if (joints[j]->ParentJointID && *joints[j]->ParentJointID == *root) {
                    tip = (u32)j;
                    break;
                }
            }
            m_air_wings.push_back({*root, tip});
        }
        m_air_fly_track = mesh->getTrackNumber(plan.fly);
        // The leg poses are the clips' own first frames: tucked from the fly
        // clip, standing from the idle, talons forward from the swoop.
        auto first = [&](const std::string &clip) {
            scene::AnimSpec a;
            if (auto track = mesh->getTrackNumber(clip))
                a.tracks[*track] = scene::TrackAnimSpec{};
            return animateTracks(*mesh, a, OldJointTransforms(joints.size()));
        };
        m_air_tuck = first(plan.fly);
        m_air_stand = first(plan.stand);
        m_air_talons = first(plan.talons);
    }
    // The server's air state: a new serial or manoeuvre restarts the clock
    // from the time sent; a resend of the same (every override is resent
    // when any changes) does not.
    if (const BoneOverride *s = actionState(overrides, plan.state, AIR_STATE_FORMAT)) {
        const int serial = (int)std::lround(s->scale.vector.X);
        const auto manoeuvre = (AirManoeuvre)std::lround(s->scale.vector.Y);
        if (serial != m_air_state.serial || manoeuvre != m_air_state.manoeuvre) {
            m_air_state.serial = serial;
            m_air_state.manoeuvre = manoeuvre;
            m_air_state.since = s->position.vector.Y + s->dtime_passed;
            m_air_state.param = s->position.vector.X;
        } else {
            m_air_state.since += dt;
        }
    } else {
        m_air_state = decltype(m_air_state){};
    }
    m_air_out = AirOutput();
    const float scale = m_ground.mesh_to_world.basis.get_column(1).length();
    if (m_ground.known && scale > 1e-6f) {
        AirInput in;
        in.dt = dt;
        const Vector3 o = m_ground.mesh_to_world.origin;
        in.x = o.x, in.y = o.y, in.z = -o.z;
        const Vector3 ahead = m_ground.mesh_to_world.basis.xform(Vector3(0, 0, -1));
        in.yaw = std::atan2(ahead.x, ahead.z);
        if (m_ground.floor)
            in.floor = m_ground.floor(in.x, in.z, in.y + 0.5f, in.y - 8.0f);
        in.leg = plan.leg_length * scale;
        in.serial = m_air_state.serial;
        in.manoeuvre = m_air_state.manoeuvre;
        in.since = m_air_state.since;
        in.param = m_air_state.param;
        m_air_out = m_air.step(in);
        if (m_air_out.flying)
            ++g_air_flying;
        if (m_air_out.talons > 0.5f)
            ++g_air_talons;
    }
    // The fly clip at the flight's beat (until poseAir puts it back), the
    // other tracks as they are.
    scene::TrackAnimSpec *fly = nullptr;
    if (m_air_fly_track) {
        auto it = anim.tracks.find(*m_air_fly_track);
        if (it != anim.tracks.end())
            fly = &it->second;
    }
    m_air_fly_spec = fly;
    if (fly) {
        m_air_fly_fps = fly->fps;
        fly->fps *= m_air_out.beat_rate;
    }
}

void ModelAnimator::poseAir(JointTransforms &locals) {
    // The fly clip has advanced at the flight's beat: back to the server's
    // rate.
    if (m_air_fly_spec)
        m_air_fly_spec->fps = m_air_fly_fps;
    m_air_fly_spec = nullptr;
    const AirOutput &o = m_air_out;
    auto rotation = [](const JointTransforms &pose, u32 j) -> std::optional<core::quaternion> {
        if (j >= pose.size())
            return std::nullopt;
        if (auto *t = std::get_if<core::Transform>(&pose[j]))
            return t->rotation;
        return std::nullopt;
    };
    // The legs: tucked to standing by the reach, then the talons forward,
    // over the clip's by the weight (the clip's own on the ground).
    if (o.weight > 0.001f) {
        for (const auto &[upper, lower] : m_air_legs) {
            for (u32 j : {upper, lower}) {
                auto *t = j < locals.size() ? std::get_if<core::Transform>(&locals[j]) : nullptr;
                auto tuck = rotation(m_air_tuck, j), stand = rotation(m_air_stand, j);
                auto talons = rotation(m_air_talons, j);
                if (!t || !tuck || !stand || !talons)
                    continue;
                core::quaternion want, out;
                want.slerp(*tuck, *stand, o.reach);
                if (o.talons > 0.0f) {
                    core::quaternion forward;
                    forward.slerp(want, *talons, o.talons);
                    want = forward;
                }
                out.slerp(t->rotation, want, o.weight);
                t->rotation = out;
            }
        }
    }
    // The wings banked about the body's length, both the same way.
    if (std::fabs(o.bank) > 1e-4f) {
        const core::quaternion bank(v3f(0.0f, 0.0f, o.bank));
        for (const auto &[root, tip] : m_air_wings) {
            (void)tip;
            if (auto *t = root < locals.size() ? std::get_if<core::Transform>(&locals[root]) : nullptr)
                t->rotation = t->rotation * bank;
        }
    }
}

// Whether the wings banked the way the turn goes: turning left (bank
// positive), the left wing's joint lower than the right's.
void ModelAnimator::checkAirBank() {
    if (std::fabs(m_air_out.bank) < 0.15f || m_air_wings.size() < 2)
        return;
    const float left = m_globals[m_air_wings[0].second].getTranslation().Y;
    const float right = m_globals[m_air_wings[1].second].getTranslation().Y;
    ++g_air_bank;
    if ((m_air_out.bank > 0.0f) == (left < right))
        ++g_air_bank_agreeing;
}

void ModelAnimator::findFeet() {
    m_feet_found = true;
    scene::SkinnedMesh *mesh = m_model->skinned;
    for (const std::string &clip : m_model->step_clips)
        if (auto n = mesh->getTrackNumber(clip))
            m_step_tracks.push_back(*n);
    const auto &joints = mesh->getAllJoints();
    auto pelvis = mesh->getJointNumber("body");
    if (!pelvis)
        return;
    std::vector<std::vector<u32>> children(joints.size());
    for (u32 i = 0; i < joints.size(); ++i)
        if (joints[i]->ParentJointID)
            children[*joints[i]->ParentJointID].push_back(i);
    auto below = [&](u32 top) {
        std::vector<u32> out{top};
        for (size_t k = 0; k < out.size(); ++k)
            for (u32 c : children[out[k]])
                out.push_back(c);
        return out;
    };
    // A leg: a joint named leg... (or a four-legged body's hind...) on the
    // pelvis, or fore... on the chest, then single children down to the
    // ankle (a tentacle's further segments ride on the ankle). The creature
    // kit's fore legs bend their middle joint the other way from its hind
    // legs and a biped's.
    auto chest = mesh->getJointNumber("chest");
    auto addLeg = [&](u32 parent, u32 hip, int girdle) {
        if (children[hip].size() != 1)
            return;
        const u32 knee = children[hip][0];
        if (children[knee].size() != 1)
            return;
        FootFit f;
        f.hip = hip;
        f.knee = knee;
        f.ankle = children[knee][0];
        f.parent = parent;
        f.girdle = girdle;
        f.knee_back = girdle == 1;
        f.below_hip = below(hip);
        f.below_knee = below(knee);
        f.below_ankle = below(f.ankle);
        m_feet.push_back(std::move(f));
    };
    for (u32 hip : children[*pelvis]) {
        const auto &name = joints[hip]->Name;
        if (name && (name->rfind("leg", 0) == 0 || name->rfind("hind", 0) == 0))
            addLeg(*pelvis, hip, 0);
    }
    if (chest && *chest != *pelvis && joints[*chest]->ParentJointID == *pelvis)
        for (u32 hip : children[*chest]) {
            const auto &name = joints[hip]->Name;
            if (name && name->rfind("fore", 0) == 0)
                addLeg(*chest, hip, 1);
        }
    for (const FootFit &f : m_feet)
        m_chest_girdle = m_chest_girdle || f.girdle == 1;

    // Planned steps: every leg a two-bone chain with at most a toe below
    // the ankle (a tentacle lower body keeps the fitting above).
    if (m_feet.empty())
        return;
    for (const FootFit &f : m_feet)
        if (f.below_ankle.size() > 2)
            return;
    auto bindLocal = [&](u32 j) {
        const auto &t = joints[j]->transform;
        if (const auto *tr = std::get_if<core::Transform>(&t))
            return toGodotTransform(tr->buildMatrix());
        return toGodotTransform(std::get<core::matrix4>(t));
    };
    std::vector<core::matrix4> rest(joints.size());
    for (u32 i = 0; i < joints.size(); ++i)
        rest[i] = fromGodotTransform(bindLocal(i));
    mesh->calculateGlobalMatrices(rest);
    for (FootFit &f : m_feet) {
        f.bind_hip = bindLocal(f.hip);
        f.bind_knee = bindLocal(f.knee);
        f.bind_ankle = bindLocal(f.ankle);
        f.rest_ankle = toGodotTransform(rest[f.ankle]);
        const Vector3 h = toGodotTransform(rest[f.hip]).origin, k = toGodotTransform(rest[f.knee]).origin;
        f.length = (k - h).length() + (f.rest_ankle.origin - k).length();
        if (f.length < 1e-4f)
            return;
    }
    // Gait groups: each side ordered front to back (Godot mesh space faces
    // -z), alternating along a side and across: a biped's two legs, a
    // quadruped's diagonals, a hexapod's tripods.
    for (int side : {-1, 1}) {
        std::vector<FootFit *> along;
        for (FootFit &f : m_feet)
            if ((f.rest_ankle.origin.x < 0 ? -1 : 1) == side)
                along.push_back(&f);
        std::sort(along.begin(), along.end(),
                [](const FootFit *a, const FootFit *b) { return a->rest_ankle.origin.z < b->rest_ankle.origin.z; });
        for (size_t k = 0; k < along.size(); ++k)
            along[k]->group = int((k + (side > 0 ? 1 : 0)) % 2);
        // Two girdles of two: the walk steps left hind, left fore, right
        // hind, right fore (along runs front to back).
        if (m_chest_girdle && m_feet.size() == 4 && along.size() == 2)
            for (size_t k = 0; k < 2; ++k)
                along[k]->slow_group = (side < 0 ? 0 : 2) + (k == 0 ? 1 : 0);
    }
    m_pelvis = *pelvis;
    m_bind_pelvis = bindLocal(*pelvis);
    // The look: the pelvis's children that are not legs (the chest); on a
    // four-legged body the chest is the fore legs', and the look is what
    // else hangs from it (the neck).
    if (m_chest_girdle) {
        for (u32 c : children[*chest]) {
            const auto &name = joints[c]->Name;
            if (!name || name->rfind("fore", 0) != 0)
                m_look_joints.push_back(c);
        }
        m_plans_steps = true;
        return;
    }
    for (u32 c : children[*pelvis]) {
        const auto &name = joints[c]->Name;
        if (name && *name == "chest") {
            m_look_joints = {c};
            break;
        }
        if (!name || name->rfind("leg", 0) != 0)
            m_look_joints.push_back(c);
    }
    m_plans_steps = true;
    findArms(children);
}

// Arms for climbing: under the chest (or whatever keeps the look), a joint
// named arm... with one child, the elbow, with one child, the hand.
void ModelAnimator::findArms(const std::vector<std::vector<u32>> &children) {
    const auto &joints = m_model->skinned->getAllJoints();
    auto below = [&](u32 top) {
        std::vector<u32> out{top};
        for (size_t k = 0; k < out.size(); ++k)
            for (u32 c : children[out[k]])
                out.push_back(c);
        return out;
    };
    auto origin = [&](u32 j) {
        const auto &t = joints[j]->transform;
        if (const auto *tr = std::get_if<core::Transform>(&t))
            return toGodotTransform(tr->buildMatrix()).origin;
        return toGodotTransform(std::get<core::matrix4>(t)).origin;
    };
    for (u32 look : m_look_joints) {
        for (u32 s : children[look]) {
            const auto &name = joints[s]->Name;
            if (!name || name->rfind("arm", 0) != 0 || children[s].size() != 1)
                continue;
            const u32 elbow = children[s][0];
            if (children[elbow].size() != 1)
                continue;
            ArmFit a;
            a.shoulder = s;
            a.elbow = elbow;
            a.hand = children[elbow][0];
            a.below_shoulder = below(s);
            a.below_elbow = below(elbow);
            a.length = origin(elbow).length() + origin(a.hand).length();
            a.side = origin(s).x < 0 ? -1 : 1;
            if (a.length > 1e-4f)
                m_arms.push_back(std::move(a));
        }
    }
}

// The legs own the pelvis: its place and base turn are the planner's. What
// the clip or the stroke gave it is kept only as a request: a turn bounded
// to STEP_PELVIS_TURN, applied, and a crouch for the planner (its drop
// below the bind, mesh units). The chest is turned back by what the pelvis
// was refused, so the pose's look and blade are kept from the chest up.
void ModelAnimator::ownPelvis(JointTransforms &locals) {
    constexpr float STEP_PELVIS_TURN = 15.0f * 3.14159265f / 180.0f;
    // A four-legged body's legs own both girdles: the pelvis is the bind's,
    // and the server's lean and height for clients without planned steps
    // (DorfCraft's terrain fit) give way to the planner's.
    if (m_chest_girdle) {
        m_crouch_request = 0.0f;
        locals[m_pelvis] = fromGodotTransform(m_bind_pelvis);
        return;
    }
    const Transform3D posed = std::visit(
            [](const auto &t) {
                if constexpr (std::is_same_v<std::decay_t<decltype(t)>, core::Transform>)
                    return toGodotTransform(t.buildMatrix());
                else
                    return toGodotTransform(t);
            },
            locals[m_pelvis]);
    Quaternion turn = (m_bind_pelvis.basis.inverse() * posed.basis).get_rotation_quaternion();
    const float angle = turn.get_angle();
    if (angle > STEP_PELVIS_TURN)
        turn = Quaternion().slerp(turn, STEP_PELVIS_TURN / angle);
    m_crouch_request = std::min(0.0f, posed.origin.y - m_bind_pelvis.origin.y);
    const Transform3D owned(m_bind_pelvis.basis * Basis(turn), m_bind_pelvis.origin);
    Transform3D refused = owned.affine_inverse() * posed;
    refused.origin = Vector3();
    locals[m_pelvis] = fromGodotTransform(owned);
    for (u32 c : m_look_joints) {
        const Transform3D local = std::visit(
                [](const auto &t) {
                    if constexpr (std::is_same_v<std::decay_t<decltype(t)>, core::Transform>)
                        return toGodotTransform(t.buildMatrix());
                    else
                        return toGodotTransform(t);
                },
                locals[c]);
        locals[c] = fromGodotTransform(refused * local);
    }
}

void ModelAnimator::fitFeet(float dt) {
    if (!m_feet_found)
        findFeet();
    if (m_feet.empty())
        return;
    // By distance (goanna_stroke_detail.h): the ground asked for every
    // step, or a few times a second with the feet easing towards what it
    // last said, or not at all, the feet easing back to the clip's.
    const bool clip = m_stroke_lod.detail() == StrokeDetail::Clip;
    const bool due = m_stroke_lod.groundDue(dt);
    const float ease = 1.0f - std::exp(-dt / (clip ? STROKE_DETAIL_BLEND / 3.0f : 0.06f));
    const bool fit = due && m_ground.known && m_ground.grounded && m_ground.floor && m_posed;
    // Luanti world nodes from Irrlicht mesh space (z mirrored both ways).
    auto world = [&](const v3f &p) {
        const Vector3 w = m_ground.mesh_to_world.xform(Vector3(p.X, p.Y, -p.Z));
        return Vector3(w.x, w.y, -w.z);
    };
    std::optional<float> base;
    Vector3 root;
    if (fit) {
        const Vector3 o = m_ground.mesh_to_world.origin;
        root = Vector3(o.x, o.y, -o.z);
        base = m_ground.floor(root.x, root.z, root.y + 0.6f, root.y - 0.8f);
    }
    float drop = 0.0f, most = 0.0f;
    for (FootFit &f : m_feet) {
        if (clip || due) {
            f.want = 0.0f;
            if (fit && base) {
                // Where the foot was shown last step, before its own lift.
                Vector3 at = world(m_globals[f.ankle].getTranslation());
                if (auto h = m_ground.floor(at.x, at.z, root.y + 0.7f, root.y - 0.8f))
                    f.want = std::clamp(*h - *base, -0.6f, 0.6f);
            }
        }
        f.lift += (f.want - f.lift) * ease;
        drop = std::min(drop, f.lift);
        most = std::max(most, std::fabs(f.lift));
    }
    m_body_drop = drop;
    if (most > 0.05f)
        ++g_feet_frames;
    g_feet_most = std::max(g_feet_most, most);
}

void ModelAnimator::applyFeet() {
    if (m_feet.empty() || !m_ground.known)
        return;
    const float scale = m_ground.mesh_to_world.basis.get_column(1).length();
    if (scale < 1e-6f)
        return;
    // The whole body down for the lower foot (mesh units).
    if (m_body_drop < -1e-4f) {
        const float d = m_body_drop / scale;
        for (core::matrix4 &m : m_globals)
            m[13] += d;
    }
    auto turn = [&](const std::vector<u32> &joints, const Quaternion &q, const Vector3 &about) {
        const Transform3D x(Basis(q), about - Basis(q).xform(about));
        for (u32 j : joints)
            m_globals[j] = fromGodotTransform(x * toGodotTransform(m_globals[j]));
    };
    for (const FootFit &f : m_feet) {
        const float up = (f.lift - m_body_drop) / scale;
        if (up < 1e-3f)
            continue;
        const Vector3 h = toGodotTransform(m_globals[f.hip]).origin;
        const Vector3 k = toGodotTransform(m_globals[f.knee]).origin;
        const Vector3 a = toGodotTransform(m_globals[f.ankle]).origin;
        const float l1 = (k - h).length(), l2 = (a - k).length();
        if (l1 < 1e-4f || l2 < 1e-4f)
            continue;
        Vector3 target = a + Vector3(0, up, 0);
        Vector3 reach = target - h;
        const float d = std::clamp(reach.length(), std::fabs(l1 - l2) + 1e-3f, l1 + l2 - 1e-3f);
        const Vector3 dir = reach.normalized();
        target = h + dir * d;
        // The knee stays on the side it is bent to now.
        Vector3 side = (k - h) - dir * (k - h).dot(dir);
        if (side.length() < 1e-4f)
            side = (a - h).cross(Vector3(1, 0, 0)).cross(dir);
        if (side.length() < 1e-4f)
            continue;
        side.normalize();
        const float along = (l1 * l1 - l2 * l2 + d * d) / (2.0f * d);
        const Vector3 knee = h + dir * along + side * std::sqrt(std::max(0.0f, l1 * l1 - along * along));
        const Quaternion r1((k - h).normalized(), (knee - h).normalized());
        turn(f.below_hip, r1, h);
        const Vector3 a1 = toGodotTransform(m_globals[f.ankle]).origin;
        const Quaternion r2((a1 - knee).normalized(), (target - knee).normalized());
        turn(f.below_knee, r2, knee);
        // The foot keeps the angle the animation gave it.
        turn(f.below_ankle, (r2 * r1).inverse(), target);
    }
}

void ModelAnimator::planSteps() {
    const float dt = m_plan_dt;
    m_plan_dt = 0.0f;
    const float scale = m_ground.mesh_to_world.basis.get_column(1).length();
    if (scale < 1e-6f || !m_ground.floor)
        return;
    if (!m_steps || std::fabs(scale - m_steps_scale) > 0.01f * m_steps_scale) {
        std::vector<StepLeg> legs;
        for (const FootFit &f : m_feet)
            legs.push_back({f.length * scale, std::max(0.0f, f.rest_ankle.origin.y) * scale, f.group, f.slow_group,
                    f.girdle});
        m_steps = std::make_shared<StepPlanner>(std::move(legs));
        m_steps_scale = scale;
    }
    // Luanti world nodes from Godot mesh space (z mirrored).
    auto world = [&](const Vector3 &p) {
        const Vector3 w = m_ground.mesh_to_world.xform(p);
        return StepVec{w.x, w.y, -w.z};
    };
    StepInput in;
    in.dt = dt;
    in.root = world(Vector3());
    const Vector3 ahead = m_ground.mesh_to_world.basis.xform(Vector3(0, 0, -1));
    in.yaw = std::atan2(ahead.x, ahead.z);
    in.grounded = m_ground.grounded;
    in.floor = m_ground.floor;
    // While a stroke is shown its legs' stance is where the feet belong;
    // otherwise the bind's. The server sends a commit only when the angle
    // it froze differs from the one told, so the stroke's own clock says
    // when it has committed.
    const StrokeEvaluator *shown = m_melee.evaluator;
    const bool striking = m_melee.active && shown && (m_melee.loops || m_melee.t <= shown->length());
    // A task's feet stay planted throughout; a stroke's from its commit.
    in.hold = striking && (m_melee.loops || m_melee.phase >= 2 || m_melee.t >= shown->commit());
    in.crouch = striking ? m_crouch_request * scale : 0.0f;
    for (const FootFit &f : m_feet) {
        in.hips.push_back(world(toGodotTransform(m_globals[f.hip]).origin));
        in.rest.push_back(world(striking ? toGodotTransform(m_globals[f.ankle]).origin : f.rest_ankle.origin));
    }
    planClimb(in);
    const StepStats before = m_steps->stats();
    m_steps->step(in);
    const StepStats &now = m_steps->stats();
    g_steps += now.steps - before.steps;
    g_steps_unreachable += now.unreachable - before.unreachable;
    g_steps_stretch = std::max(g_steps_stretch, now.most_stretch);
    if (m_chest_girdle) {
        (m_steps->walking() ? g_steps_walking : g_steps_trotting) += now.steps - before.steps;
        g_steps_pitch = std::max(g_steps_pitch, std::fabs(m_steps->girdleDrop(1) - m_steps->girdleDrop(0)));
    }
}

void ModelAnimator::applySteps() {
    if (!m_ground.known)
        return;
    if (m_plan_dt > 0.0f)
        planSteps();
    if (!m_steps)
        return;
    const float scale = m_ground.mesh_to_world.basis.get_column(1).length();
    if (scale < 1e-6f)
        return;
    const Transform3D to_mesh = m_ground.mesh_to_world.affine_inverse();
    auto global = [&](u32 j) { return toGodotTransform(m_globals[j]); };
    auto turn = [&](const std::vector<u32> &joints, const Basis &b, const Vector3 &about) {
        const Transform3D x(b, about - b.xform(about));
        for (u32 j : joints)
            m_globals[j] = fromGodotTransform(x * toGodotTransform(m_globals[j]));
    };
    auto set = [&](const std::vector<u32> &joints, const Transform3D &want) {
        const Transform3D x = want * global(joints[0]).affine_inverse();
        for (u32 j : joints)
            m_globals[j] = fromGodotTransform(x * toGodotTransform(m_globals[j]));
    };
    // The whole body down by the planner's drop (mesh units).
    const float drop = m_steps->drop() / scale;
    if (drop < -1e-5f)
        for (core::matrix4 &m : m_globals)
            m[13] += drop;
    // The pelvis turned towards the feet, the look turned back.
    const Basis twist(Vector3(0, 1, 0), m_steps->pelvisYaw());
    const Vector3 pelvis_at = global(m_pelvis).origin;
    std::vector<u32> below_pelvis, look;
    {
        const auto &joints = m_model->skinned->getAllJoints();
        std::vector<char> in_look(joints.size(), 0), in_body(joints.size(), 0);
        in_body[m_pelvis] = 1;
        for (u32 c : m_look_joints)
            in_look[c] = 1;
        for (u32 i = 0; i < joints.size(); ++i) {
            if (auto p = joints[i]->ParentJointID) {
                in_body[i] |= in_body[*p];
                in_look[i] |= in_look[*p];
            }
            if (in_body[i])
                below_pelvis.push_back(i);
            if (in_look[i])
                look.push_back(i);
        }
    }
    turn(below_pelvis, twist, pelvis_at);
    turn(look, twist.inverse(), pelvis_at);
    // A four-legged body: the chest's girdle lowered for the fore feet, the
    // pelvis's for the hind, so the body pitches about the hind hips; the
    // neck turned back, so the head keeps its look.
    if (m_chest_girdle) {
        Vector3 hind, fore;
        int hinds = 0, fores = 0;
        for (const FootFit &f : m_feet) {
            const Vector3 h = global(f.hip).origin;
            if (f.girdle == 1)
                fore += h, ++fores;
            else
                hind += h, ++hinds;
        }
        if (hinds && fores) {
            hind /= float(hinds);
            fore /= float(fores);
            const float along = Vector2(fore.x - hind.x, fore.z - hind.z).length();
            const float rise = (m_steps->girdleDrop(1) - m_steps->girdleDrop(0)) / scale;
            if (along > 1e-4f && std::fabs(rise) > 1e-5f) {
                const Vector3 axis = global(m_pelvis).basis.get_column(0).normalized();
                const Basis pitch(axis, std::atan2(rise, along));
                turn(below_pelvis, pitch, hind);
                if (!m_look_joints.empty()) {
                    std::vector<u32> neck;
                    const auto &joints = m_model->skinned->getAllJoints();
                    std::vector<char> in(joints.size(), 0);
                    in[m_look_joints[0]] = 1;
                    for (u32 i = 0; i < joints.size(); ++i) {
                        if (auto par = joints[i]->ParentJointID)
                            in[i] |= in[*par];
                        if (in[i])
                            neck.push_back(i);
                    }
                    turn(neck, pitch.inverse(), global(m_look_joints[0]).origin);
                }
            }
        }
    }

    const auto &feet = m_steps->feet();
    const float body_yaw = [&] {
        const Vector3 a = m_ground.mesh_to_world.basis.xform(Vector3(0, 0, -1));
        return std::atan2(a.x, a.z);
    }();
    const Vector3 forward(0, 0, -1);
    const Transform3D pelvis = global(m_pelvis);
    for (size_t i = 0; i < m_feet.size() && i < feet.size(); ++i) {
        const FootFit &f = m_feet[i];
        // The clip's leg motion replaced: the leg back to its bind under
        // the pelvis, then solved to the planned ankle.
        set(f.below_hip, global(f.parent) * f.bind_hip);
        set(f.below_knee, global(f.hip) * f.bind_knee);
        set(f.below_ankle, global(f.knee) * f.bind_ankle);
        const StepVec &sole = feet[i].sole;
        const Vector3 target_world(sole[0], sole[1] + m_steps->legs()[i].ankle, -sole[2]);
        Vector3 target = to_mesh.xform(target_world);
        const Vector3 h = global(f.hip).origin, k = global(f.knee).origin, a = global(f.ankle).origin;
        const float l1 = (k - h).length(), l2 = (a - k).length();
        if (l1 < 1e-4f || l2 < 1e-4f)
            continue;
        const Vector3 reach = target - h;
        const float d = std::clamp(reach.length(), std::fabs(l1 - l2) + 1e-3f, l1 + l2 - 1e-3f);
        const Vector3 dir = reach.normalized();
        target = h + dir * d;
        // The knee forward, between the body's facing and the foot's.
        const Basis foot_turn(Vector3(0, 1, 0), feet[i].yaw - body_yaw);
        Vector3 pole = twist.xform(forward) + foot_turn.xform(forward);
        if (f.knee_back)
            pole = -pole;
        Vector3 side = pole - dir * pole.dot(dir);
        if (side.length() < 1e-4f)
            side = forward - dir * forward.dot(dir);
        if (side.length() < 1e-4f)
            continue;
        side.normalize();
        const float along = (l1 * l1 - l2 * l2 + d * d) / (2.0f * d);
        const Vector3 knee = h + dir * along + side * std::sqrt(std::max(0.0f, l1 * l1 - along * along));
        turn(f.below_hip, Basis(Quaternion((k - h).normalized(), (knee - h).normalized())), h);
        const Vector3 a1 = global(f.ankle).origin;
        turn(f.below_knee, Basis(Quaternion((a1 - knee).normalized(), (target - knee).normalized())), knee);
        // The foot flat, pointing where the planner has it.
        Transform3D want = global(f.ankle);
        want.basis = foot_turn * f.rest_ankle.basis;
        set(f.below_ankle, want);
    }
    applyClimb();
}

// The climb's input from what this client sees: the body's rise, a
// climbable node at it and the wall it is on, or a ledge ahead while it
// rises. Climbing, the step planner lets the feet go (as in the air); when
// the climb ends it plants them from where the climb left them.
void ModelAnimator::planClimb(StepInput &in) {
    if (m_arms.size() != 2 || m_feet.size() != 2 || !m_ground.climbable || !m_ground.floor) {
        m_climb.reset();
        return;
    }
    const float scale = m_steps_scale;
    if (!m_climb || std::fabs(m_climb->limbs()[2].length - m_feet[0].length * scale) > 0.01f * scale) {
        std::vector<ClimbLimb> limbs;
        for (const ArmFit &a : m_arms)
            limbs.push_back({a.length * scale, 0.0f, true, a.side});
        for (size_t i = 0; i < m_feet.size(); ++i)
            limbs.push_back({m_feet[i].length * scale, m_steps->legs()[i].ankle, false,
                    m_feet[i].rest_ankle.origin.x < 0 ? -1 : 1});
        m_climb = std::make_shared<ClimbPlanner>(std::move(limbs));
    }
    const float y = in.root[1];
    if (m_climb_have && in.dt > 0.0f) {
        const float raw = (y - m_climb_last_y) / in.dt;
        if (std::fabs(raw) < 30.0f)
            m_climb_vy += (raw - m_climb_vy) * (1.0f - std::exp(-in.dt / 0.05f));
    } else {
        m_climb_vy = 0.0f;
    }
    m_climb_last_y = y;
    m_climb_have = true;
    const float x = in.root[0], z = in.root[2];
    const Vector3 a = m_ground.mesh_to_world.basis.xform(Vector3(0, 0, -1));
    float fx = a.x, fz = -a.z;
    const float fl = std::hypot(fx, fz);
    if (fl < 1e-4f)
        return;
    fx /= fl;
    fz /= fl;

    ClimbInput c;
    c.dt = in.dt;
    c.root = in.root;
    c.yaw = in.yaw;
    c.vy = m_climb_vy;
    c.grounded = in.grounded && m_ground.floor(x, z, y + 0.05f, y - 0.1f).has_value() && std::fabs(m_climb_vy) < 1.0f;
    // A stroke or a task shown (the same test as the step planner's).
    c.striking = m_melee.active && m_melee.evaluator
            && (m_melee.loops || m_melee.t <= m_melee.evaluator->length());
    const Transform3D &w = m_ground.mesh_to_world;
    for (const ArmFit &arm : m_arms) {
        const Vector3 s = w.xform(toGodotTransform(m_globals[arm.shoulder]).origin);
        c.anchors.push_back({s.x, s.y, -s.z});
    }
    for (const StepVec &h : in.hips)
        c.anchors.push_back(h);
    if (m_steps && m_steps->feet().size() == m_feet.size())
        for (const StepFoot &f : m_steps->feet())
            c.soles.push_back(f.sole);
    // A ladder: a climbable node at the body; its wall the walkable node
    // beside it nearest ahead, else straight ahead.
    for (float up : {0.5f, 1.2f}) {
        if (!m_ground.climbable(x, y + up, z))
            continue;
        const float cx = std::floor(x + 0.5f), cy = std::floor(y + up + 0.5f), cz = std::floor(z + 0.5f);
        float best = -2.0f;
        c.face = {x + fx * 0.3f, y, z + fz * 0.3f};
        c.face_nx = -fx;
        c.face_nz = -fz;
        for (const auto &d : {std::array<float, 2>{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
            if (!m_ground.floor(cx + d[0], cz + d[1], cy + 0.5f, cy - 0.4f))
                continue;
            const float along = d[0] * fx + d[1] * fz;
            if (along > best) {
                best = along;
                c.face = {cx + d[0] * 0.5f, y, cz + d[1] * 0.5f};
                c.face_nx = -d[0];
                c.face_nz = -d[1];
            }
        }
        c.ladder = true;
        break;
    }
    // A ledge ahead while rising: the first walkable top between
    // CLIMB_LEDGE_LOW and CLIMB_LEDGE_HIGH above the root.
    if (!c.ladder && m_climb->mode() == ClimbMode::None && m_climb_vy > CLIMB_RISE) {
        for (float d = 0.1f; d <= 1.0f; d += 0.05f) {
            if (auto top = m_ground.floor(x + fx * d, z + fz * d, y + CLIMB_LEDGE_HIGH, y + CLIMB_LEDGE_LOW)) {
                c.ledge = true;
                c.edge = {x + fx * (d - 0.025f), *top, z + fz * (d - 0.025f)};
                c.edge_nx = -fx;
                c.edge_nz = -fz;
                break;
            }
        }
    }
    const ClimbStats before = m_climb->stats();
    m_climb->step(c);
    const ClimbStats &now = m_climb->stats();
    g_climb_ladders += now.ladders - before.ladders;
    g_climb_mantles += now.mantles - before.mantles;
    g_climb_landed += now.landed - before.landed;
    g_climb_moves += now.moves - before.moves;
    if (m_climb->mode() != ClimbMode::None)
        in.grounded = false;
    if (m_climb->ended()) {
        std::vector<StepVec> soles;
        for (size_t i = m_arms.size(); i < m_climb->contacts().size(); ++i)
            soles.push_back(m_climb->contacts()[i].at);
        m_steps->seed(soles);
    }
}

// Each limb the climb holds, solved to its hold as far as the climb's
// weight on it says, over whatever the clip and the step planner gave it.
void ModelAnimator::applyClimb() {
    if (!m_climb || m_climb->weight() <= 0.0f)
        return;
    const Transform3D to_mesh = m_ground.mesh_to_world.affine_inverse();
    auto global = [&](u32 j) { return toGodotTransform(m_globals[j]); };
    auto turn = [&](const std::vector<u32> &joints, const Basis &b, const Vector3 &about) {
        const Transform3D x(b, about - b.xform(about));
        for (u32 j : joints)
            m_globals[j] = fromGodotTransform(x * toGodotTransform(m_globals[j]));
    };
    const auto &contacts = m_climb->contacts();
    const auto &limbs = m_climb->limbs();
    for (size_t i = 0; i < contacts.size() && i < limbs.size(); ++i) {
        const float wt = contacts[i].weight;
        if (wt <= 1e-3f)
            continue;
        const bool arm = i < m_arms.size();
        u32 top, mid, end;
        const std::vector<u32> *below_top, *below_mid;
        Vector3 pole;
        if (arm) {
            const ArmFit &a = m_arms[i];
            top = a.shoulder, mid = a.elbow, end = a.hand;
            below_top = &a.below_shoulder, below_mid = &a.below_elbow;
            pole = Vector3(0.6f * a.side, -1.0f, 0.5f); // elbows down, out and back
        } else {
            const FootFit &f = m_feet[i - m_arms.size()];
            top = f.hip, mid = f.knee, end = f.ankle;
            below_top = &f.below_hip, below_mid = &f.below_knee;
            pole = Vector3(0, 0, -1); // knees forward, towards what is climbed
        }
        const StepVec &at = contacts[i].at;
        const Vector3 want = to_mesh.xform(Vector3(at[0], at[1] + limbs[i].end, -at[2]));
        const Vector3 h = global(top).origin, k = global(mid).origin, e = global(end).origin;
        Vector3 target = e + (want - e) * wt;
        const float l1 = (k - h).length(), l2 = (e - k).length();
        if (l1 < 1e-4f || l2 < 1e-4f)
            continue;
        const Vector3 reach = target - h;
        if (reach.length() < 1e-4f)
            continue;
        const float d = std::clamp(reach.length(), std::fabs(l1 - l2) + 1e-3f, l1 + l2 - 1e-3f);
        const Vector3 dir = reach.normalized();
        target = h + dir * d;
        Vector3 side = pole - dir * pole.dot(dir);
        if (side.length() < 1e-4f)
            continue;
        side.normalize();
        const float along = (l1 * l1 - l2 * l2 + d * d) / (2.0f * d);
        const Vector3 knee = h + dir * along + side * std::sqrt(std::max(0.0f, l1 * l1 - along * along));
        turn(*below_top, Basis(Quaternion((k - h).normalized(), (knee - h).normalized())), h);
        const Vector3 e1 = global(end).origin;
        turn(*below_mid, Basis(Quaternion((e1 - knee).normalized(), (target - knee).normalized())), knee);
    }
}

void ModelAnimator::step(float dt, scene::AnimSpec &anim, std::map<std::string, BoneOverride> &overrides,
        Skeleton3D *skeleton, Skeleton3D *unshrunk) {
    scene::SkinnedMesh *mesh = m_model->skinned;
    if (!mesh)
        return;

    // A flier (goanna_air.h): its flight this frame, and its fly clip set
    // to beat at the rate the flight asks for until poseAir.
    if (m_model->air)
        stepAir(dt, anim, overrides);

    // AnimatedMeshSceneNode::OnAnimate: advance every track, then
    // animateJoints: local transforms for this frame, each track blending
    // from the pose shown last step.
    anim.advance(dt);
    if (fitsFeet()) {
        m_stroke_lod.step(dt, m_stroke_detail);
        if (!m_feet_found)
            findFeet();
        // Far off (goanna_stroke_detail.h) a planned body shows the clip's
        // legs; its planner is dropped, to plant afresh when it comes back.
        // So does a body planned without strokes playing a clip that is
        // not one of its planned clips (sleeping, dying, grazing).
        bool planned_clip = m_model->strokes != nullptr;
        if (!planned_clip) {
            planned_clip = true;
            for (const auto &track : anim.tracks)
                if (std::find(m_step_tracks.begin(), m_step_tracks.end(), track.first) == m_step_tracks.end())
                    planned_clip = false;
        }
        m_planning = m_plans_steps && planned_clip && m_stroke_lod.detail() != StrokeDetail::Clip;
        if (m_planning)
            m_plan_dt = dt;
        else if (m_plans_steps) {
            m_steps.reset();
            m_climb.reset();
        }
        else if (m_model->strokes)
            fitFeet(dt);
    }
    const auto &joints = mesh->getAllJoints();
    JointTransforms locals = animateTracks(*mesh, anim, m_old_transforms);
    // The arm also inherits the baked punch's torso twist. Hold its ancestor
    // chain as well as its subtree, leaving the legs/other arm animated.
    if (m_freeze_arm && m_rot_override_joint) {
        if (m_arm_reference.empty())
            m_arm_reference = firstFramePose(*mesh);
        std::vector<bool> mining_joints(joints.size(), false);
        std::optional<u16> parent = (u16)*m_rot_override_joint;
        while (parent) {
            mining_joints[*parent] = true;
            parent = joints[*parent]->ParentJointID;
        }
        for (size_t i = 0; i < joints.size(); ++i) {
            std::optional<u16> ancestor = (u16)i;
            while (ancestor && *ancestor != *m_rot_override_joint)
                ancestor = joints[*ancestor]->ParentJointID;
            if (ancestor) mining_joints[i] = true;
            if (mining_joints[i]) locals[i] = m_arm_reference[i];
        }
    }
    // copyOldTransforms: the pose to blend from next step, taken before the
    // bone overrides, as upstream takes it.
    keepOldTransforms(locals, m_old_transforms);

    // GenericCAO's OnAnimate callback: bone overrides on the joint transforms.
    // BoneSceneNode keeps rotations inverted relative to Euler input; mirrored
    // here so overrides mean what they mean in the vanilla client.
    for (auto it = overrides.begin(); it != overrides.end();) {
        BoneOverride &props = it->second;
        props.dtime_passed += dt;
        if (props.isIdentity()) {
            it = overrides.erase(it);
            continue;
        }
        if (auto jn = mesh->getJointNumber(it->first)) {
            if (auto *t = std::get_if<core::Transform>(&locals[*jn])) {
                core::quaternion inv = t->rotation;
                inv.makeInverse();
                v3f euler;
                inv.toEuler(euler);
                euler *= core::RADTODEG;
                t->translation = props.getPosition(t->translation);
                t->rotation = core::quaternion(props.getRotationEulerDeg(euler) * core::DEGTORAD).makeInverse();
                t->scale = props.getScale(t->scale);
            }
        }
        ++it;
    }

    // A melee stroke the server announced, evaluated here (goanna_strokes.h).
    if (m_model->strokes)
        poseStroke(dt, locals, overrides);
    if (m_planning && m_ground.known)
        ownPelvis(locals);
    if (m_model->air)
        poseAir(locals);

    // Goanna's strokes in the water, on the shoulders and hips.
    if (!m_model->limbs.empty())
        poseLimbs(dt, locals, overrides);

    // First-person arm swing, added to whatever the animation and the server's
    // own bone override left on the joint, in the same euler degrees (and the
    // same inverted storage) a Luanti bone override uses. Added rather than
    // replacing: an absolute pose of Goanna's own throws away the arm pitch
    // the game itself sets for the held item, and silently mirrors any model
    // that bakes a half turn into the joint's rest, which Mineclonia's
    // character does as a scale flip on Arm_Right_Pitch_Control.
    if (m_rot_override_joint && *m_rot_override_joint < locals.size()) {
        if (auto *t = std::get_if<core::Transform>(&locals[*m_rot_override_joint])) {
            core::quaternion inv = t->rotation;
            inv.makeInverse();
            v3f euler;
            inv.toEuler(euler);
            euler *= core::RADTODEG;
            t->rotation = core::quaternion((euler + m_rot_override_euler) * core::DEGTORAD).makeInverse();
        }
    }

    // Jiggle bones: from the pose so far as their target, to where their
    // simulated tips are, before the globals, so whatever hangs below them
    // (a cloak's lower panels, a plait's end) follows.
    if (!m_model->jiggle.bones.empty())
        m_jiggle.step(m_model->jiggle, *mesh, dt, m_jiggle_frame, locals);

    // relative -> global -> skin matrices
    auto to_globals = [&]() {
        for (size_t i = 0; i < joints.size(); ++i) {
            if (auto *m = std::get_if<core::matrix4>(&locals[i]))
                m_globals[i] = *m;
            else
                m_globals[i] = std::get<core::Transform>(locals[i]).buildMatrix();
        }
        mesh->calculateGlobalMatrices(m_globals);
        if (m_planning)
            applySteps();
        else if (m_model->strokes && !m_plans_steps)
            applyFeet();
    };
    // A bone animated to zero scale (models hide parts that way) has a
    // singular basis that Godot cannot split into a rotation, and it says
    // so for every frame. Set such a pose by parts, rotation left alone.
    auto write_poses = [&](Skeleton3D *sk, const std::vector<core::matrix4> &skin) {
        auto set_pose = [&](int bone, const Transform3D &xf) {
            if (std::fabs(xf.basis.determinant()) < 1e-9f) {
                sk->set_bone_pose_position(bone, xf.origin);
                sk->set_bone_pose_scale(bone, xf.basis.get_scale());
                return;
            }
            sk->set_bone_pose(bone, xf);
        };
        for (size_t i = 0; i < joints.size(); ++i) {
            set_pose((int)i, toGodotTransform(skin[i]));
            int ab = m_model->attached_bone[i];
            if (ab >= 0)
                set_pose(ab, bentGlobal(i));
        }
        // The limbs' lower halves turned by their bend, the seams by half.
        for (size_t i = 0; i < m_model->limbs.size(); ++i) {
            const LimbBend &l = m_model->limbs[i];
            const Transform3D limb = toGodotTransform(skin[l.joint]);
            set_pose(l.bone, limb * bendTransform(l, m_bend[i]));
            set_pose(l.seam_bone, limb * bendTransform(l, 0.5f * m_bend[i]));
        }
    };

    // The bends this step, from the swing the pose now gives each limb.
    if (!m_model->limbs.empty()) {
        to_globals();
        measureLimbs(dt, mesh->calculateSkinMatrices(m_globals), overrides);
    }

    // The unshrunk pose first, for the shadow-only copy of the model: the head
    // has to be in the shadow pass even though the camera must not see it, and
    // one skinned mesh cannot be two shapes at once. m_globals is left holding
    // the shrunk pose because that is the one jointGlobal callers are asking
    // about (where the wield item hangs, which arm faces the camera).
    if (unshrunk && m_shrink_joint) {
        to_globals();
        write_poses(unshrunk, mesh->calculateSkinMatrices(m_globals));
    }

    // First-person: collapse the shrink joint so the head (and hat layers
    // attached to it) never block the camera.
    if (m_shrink_enabled && m_shrink_joint && *m_shrink_joint < locals.size()) {
        if (auto *t = std::get_if<core::Transform>(&locals[*m_shrink_joint]))
            t->scale *= 0.01f;
    }
    to_globals();
    m_posed = true;
    if (m_model->air)
        checkAirBank();
    if (!m_model->limbs.empty())
        m_skin = mesh->calculateSkinMatrices(m_globals);
    if (!skeleton)
        return;
    write_poses(skeleton, m_model->limbs.empty() ? mesh->calculateSkinMatrices(m_globals) : m_skin);
}

// ---- limbs -------------------------------------------------------------------

namespace {

// Turns a joint's local rotation by `deg` about `axis` in its own frame, in
// the inverted storage a Luanti bone keeps (BoneSceneNode), as the bone
// overrides above do.
void turnLocal(core::Transform &t, const core::vector3df &axis, float deg) {
    core::quaternion actual = t.rotation;
    actual.makeInverse();
    core::quaternion d;
    d.fromAngleAxis(deg * core::DEGTORAD, axis);
    actual = d * actual;
    actual.makeInverse();
    t.rotation = actual;
}

} // namespace

void ModelAnimator::setWaterPose(WaterPose pose, float speed) {
    m_water = pose;
    m_water_speed = speed;
}

// Which way a turn about each limb joint's own x axis moves its end (the
// hand or foot) forward, and a turn about its z axis outward, found by
// trying a small turn on the rest pose. Models flip their limb joints
// (Mineclonia's right arm's pitch control carries a scale flip), so the
// same local turn can swing one arm forward and the other back.
void ModelAnimator::probeLimbSigns() {
    scene::SkinnedMesh *mesh = m_model->skinned;
    const auto &joints = mesh->getAllJoints();
    JointTransforms rest;
    for (const auto *j : joints)
        rest.push_back(j->transform);
    auto end_after = [&](const LimbBend &l, const core::vector3df *axis, float deg) {
        JointTransforms locals = rest;
        if (axis)
            if (auto *t = std::get_if<core::Transform>(&locals[l.joint]))
                turnLocal(*t, *axis, deg);
        std::vector<core::matrix4> globals(joints.size());
        for (size_t i = 0; i < joints.size(); ++i) {
            if (auto *m = std::get_if<core::matrix4>(&locals[i]))
                globals[i] = *m;
            else
                globals[i] = std::get<core::Transform>(locals[i]).buildMatrix();
        }
        mesh->calculateGlobalMatrices(globals);
        return toGodotTransform(mesh->calculateSkinMatrices(globals)[l.joint]).xform(l.end);
    };
    // Joints hanging from a limb's lower half: under the limb's joint and,
    // at rest, below its cut. They follow its bend (bentGlobal).
    {
        std::vector<core::matrix4> globals(joints.size());
        for (size_t i = 0; i < joints.size(); ++i) {
            if (auto *m = std::get_if<core::matrix4>(&rest[i]))
                globals[i] = *m;
            else
                globals[i] = std::get<core::Transform>(rest[i]).buildMatrix();
        }
        mesh->calculateGlobalMatrices(globals);
        m_lower_limb.assign(joints.size(), -1);
        for (size_t j = 0; j < joints.size(); ++j)
            for (size_t i = 0; i < m_model->limbs.size(); ++i) {
                const LimbBend &l = m_model->limbs[i];
                if ((int)j == l.joint)
                    continue;
                std::optional<u16> a = joints[j]->ParentJointID;
                while (a && (int)*a != l.joint)
                    a = joints[*a]->ParentJointID;
                if (a && toGodotTransform(globals[j]).origin.y < l.cut_y)
                    m_lower_limb[j] = (int)i;
            }
        // A leg's thigh, from its joint down to the knee, and its shin, from
        // the knee to the foot: how far a crouch lowers the body.
        for (const LimbBend &l : m_model->limbs)
            if (l.kind == LimbKind::Leg) {
                m_leg_upper = std::max(0.0f, toGodotTransform(globals[l.joint]).origin.y - l.cut_y);
                m_leg_lower = std::max(0.0f, l.cut_y - l.end.y);
                break;
            }
    }
    const core::vector3df x(1, 0, 0), z(0, 0, 1);
    // The root, which the whole body leans and drops by: which way a turn
    // about its x axis takes the hips forward, and about its z axis to the
    // left (Godot's forward is -z, its left -x).
    for (const auto *j : joints)
        if (!j->ParentJointID) {
            m_root_joint = j->JointID;
            break;
        }
    auto marker_after = [&](const core::vector3df *axis, float deg) {
        JointTransforms locals = rest;
        if (axis && m_root_joint)
            if (auto *t = std::get_if<core::Transform>(&locals[*m_root_joint]))
                turnLocal(*t, *axis, deg);
        std::vector<core::matrix4> globals(joints.size());
        for (size_t i = 0; i < joints.size(); ++i) {
            if (auto *m = std::get_if<core::matrix4>(&locals[i]))
                globals[i] = *m;
            else
                globals[i] = std::get<core::Transform>(locals[i]).buildMatrix();
        }
        mesh->calculateGlobalMatrices(globals);
        const LimbBend &l = m_model->limbs[0];
        return toGodotTransform(mesh->calculateSkinMatrices(globals)[l.joint]).xform(l.pivot + Vector3(0, 6.0f, 0));
    };
    if (m_root_joint) {
        const Vector3 base = marker_after(nullptr, 0.0f);
        m_lean_sign = marker_after(&x, 10.0f).z < base.z ? 1.0f : -1.0f;
        m_bank_sign = marker_after(&z, 10.0f).x < base.x ? 1.0f : -1.0f;
    }
    m_pitch_sign.assign(m_model->limbs.size(), 1.0f);
    m_spread_sign.assign(m_model->limbs.size(), 1.0f);
    for (size_t i = 0; i < m_model->limbs.size(); ++i) {
        const LimbBend &l = m_model->limbs[i];
        const Vector3 base = end_after(l, nullptr, 0.0f);
        const Vector3 pitched = end_after(l, &x, 10.0f);
        const Vector3 spread = end_after(l, &z, 10.0f);
        // Forward is -z in Godot; outward is away from the middle in x.
        m_pitch_sign[i] = pitched.z < base.z ? 1.0f : -1.0f;
        m_spread_sign[i] = std::fabs(spread.x) > std::fabs(base.x) ? 1.0f : -1.0f;
    }
}

// The whole-limb poses: while the body is swimming, treading water or
// climbing, the shoulders and hips are turned from their rest by the
// stroke, blended over what the game's animation had them doing by how far
// the stroke has eased in. Then, on top, the movement poses (a landing's
// crouch, a fall's flailing, a leg lifting onto a step), and the whole body
// leaned into starts, stops and turns and lowered for a crouch, at the root.
// The knees and elbows follow in measureLimbs.
void ModelAnimator::poseLimbs(float dt, JointTransforms &locals,
        const std::map<std::string, BoneOverride> &overrides) {
    const float ease = 1.0f - std::exp(-dt / 0.25f);
    for (int p = 1; p < kPoseCount; ++p)
        m_pose_w[p] += (((int)m_water == p ? 1.0f : 0.0f) - m_pose_w[p]) * ease;
    m_stroke_phase = std::fmod(m_stroke_phase + strokeRate(m_water, m_water_speed) * dt,
            2.0f * 3.14159265f * 12.0f);
    updateMotion(dt);
    float w = 0.0f;
    for (int p = 1; p < kPoseCount; ++p)
        w += m_pose_w[p];
    const auto &joints = m_model->skinned->getAllJoints();
    const core::vector3df x(1, 0, 0), z(0, 0, 1);
    for (size_t i = 0; i < m_model->limbs.size(); ++i) {
        const LimbBend &l = m_model->limbs[i];
        // The game's own bone override on the limb (an aimed bow, a held
        // map) wins.
        const auto &name = joints[l.joint]->Name;
        if (name && overrides.count(*name))
            continue;
        auto *t = std::get_if<core::Transform>(&locals[l.joint]);
        const auto *r = std::get_if<core::Transform>(&joints[l.joint]->transform);
        if (!t || !r)
            continue;
        if (w > 1e-3f) {
            float pitch = 0.0f, spread = 0.0f;
            for (int p = 1; p < kPoseCount; ++p) {
                if (m_pose_w[p] < 1e-4f)
                    continue;
                const LimbAngles s = strokeAngles((WaterPose)p, l.kind, l.right, m_stroke_phase);
                pitch += s.pitch * m_pose_w[p];
                spread += s.spread * m_pose_w[p];
            }
            core::Transform stroke = *r;
            turnLocal(stroke, x, pitch / w * m_pitch_sign[i]);
            turnLocal(stroke, z, spread / w * m_spread_sign[i]);
            t->rotation.slerp(t->rotation, stroke.rotation, std::min(w, 1.0f));
        }
        const LimbAngles m = motionAngles(i);
        if (m.pitch != 0.0f)
            turnLocal(*t, x, m.pitch * m_pitch_sign[i]);
        if (m.spread != 0.0f)
            turnLocal(*t, z, m.spread * m_spread_sign[i]);
    }
    if (m_root_joint && *m_root_joint < locals.size())
        if (auto *t = std::get_if<core::Transform>(&locals[*m_root_joint])) {
            if (m_lean != 0.0f)
                turnLocal(*t, x, m_lean * m_lean_sign);
            if (m_bank != 0.0f)
                turnLocal(*t, z, m_bank * m_bank_sign);
            t->translation.Y -= m_drop;
        }
}

// What the body's movement does this step: a landing (the crouch comes in
// fast and eases out over half a second, deeper the harder the landing), a
// fall (the arms go out after a fifth of a second falling fast, flailing
// more the longer it lasts), a step up (a quick rise while on the ground
// lifts the forward leg), and the lean into a start or a stop and the bank
// into a turn, on the ground and out of the water. The lean and bank are
// for others to see: seen from the eye they would only move the body
// under the camera.
void ModelAnimator::updateMotion(float dt) {
    m_clock += dt;
    const BodyMotion &mo = m_motion;
    if (mo.known) {
        if (!mo.grounded) {
            m_air_time += dt;
            m_fall_peak = std::max(m_fall_peak, -mo.vy);
        } else {
            if (!m_prev_grounded && m_have_y) {
                m_land = std::max(m_land, landDepth(m_fall_peak));
                // Down: the flailing stops at once, and the crouch takes
                // the legs (its drop allows for its own bend, not the
                // fall's, and eased out the feet went through the ground).
                m_fall_w = 0.0f;
            }
            if (m_have_y && m_prev_grounded && mo.y - m_prev_y > 0.25f && mo.y - m_prev_y < 1.2f) {
                // The leg further forward takes the step.
                float best = -1e9f;
                for (size_t i = 0; i < m_model->limbs.size(); ++i)
                    if (m_model->limbs[i].kind == LimbKind::Leg && m_swing[i] > best) {
                        best = m_swing[i];
                        m_step_leg = (int)i;
                    }
                m_step = 1.0f;
            }
            m_air_time = 0.0f;
            m_fall_peak = 0.0f;
        }
        m_prev_grounded = mo.grounded;
        m_prev_y = mo.y;
        m_have_y = true;
    }
    const float k = [&](float tau) { return 1.0f - std::exp(-std::max(dt, 0.0f) / tau); }(0.04f);
    m_land_amt += (m_land - m_land_amt) * k;
    m_land *= std::exp(-std::max(dt, 0.0f) / 0.18f);
    m_step *= std::exp(-std::max(dt, 0.0f) / 0.12f);
    const bool falling = mo.known && !mo.grounded && mo.vy < -5.0f && m_air_time > 0.2f;
    m_fall_w += ((falling ? 1.0f : 0.0f) - m_fall_w) * (1.0f - std::exp(-std::max(dt, 0.0f) / 0.25f));
    float water = 0.0f;
    for (int p = 1; p < kPoseCount; ++p)
        water += m_pose_w[p];
    float lean = 0.0f, bank = 0.0f;
    if (mo.known && mo.grounded && water < 0.5f && !m_first_person) {
        lean = std::clamp(mo.accel * 1.6f, -9.0f, 9.0f)
                + 6.0f * std::clamp((mo.speed - 4.0f) / 2.5f, 0.0f, 1.0f);
        bank = std::clamp(mo.speed * mo.yaw_rate * 0.0174533f * 3.0f, -12.0f, 12.0f);
    }
    const float lb = 1.0f - std::exp(-std::max(dt, 0.0f) / 0.15f);
    m_lean += (lean - m_lean) * lb;
    m_bank += (bank - m_bank) * lb;
    const LimbAngles crouch = landAngles(LimbKind::Leg, m_land_amt);
    m_drop = legShortening(m_leg_upper, m_leg_lower, crouch.pitch, crouch.bend);
}

// One limb's share of the movement poses, degrees on top of everything
// else: the landing's crouch, the fall's flailing, the step's lifted leg.
LimbAngles ModelAnimator::motionAngles(size_t i) const {
    const LimbBend &l = m_model->limbs[i];
    const bool arm = l.kind == LimbKind::Arm;
    LimbAngles a = landAngles(l.kind, m_land_amt);
    if (m_fall_w > 1e-3f) {
        const float f = m_fall_w;
        const float wob = std::sin(m_clock * 7.0f + (l.right ? 0.0f : 3.14159f) + (arm ? 1.5708f : 0.0f))
                * std::min(1.0f, m_air_time);
        if (arm) {
            a.spread += 55.0f * f;
            a.pitch += (25.0f + 20.0f * wob) * f;
            a.bend += 20.0f * f;
        } else {
            a.pitch += (15.0f + 15.0f * wob) * f;
            a.spread += 8.0f * f;
            a.bend += (25.0f + 15.0f * std::max(0.0f, wob)) * f;
        }
    }
    if (!arm && (int)i == m_step_leg && m_step > 1e-3f) {
        a.pitch += 50.0f * m_step;
        a.bend += 75.0f * m_step;
    }
    return a;
}

// Each limb's swing forward of hanging straight, relative to the body, from
// this step's skin matrices, and how fast it is changing; from those (and
// the strokes) the knee and elbow bends, eased.
void ModelAnimator::measureLimbs(float dt, const std::vector<core::matrix4> &skin,
        const std::map<std::string, BoneOverride> &overrides) {
    Transform3D body;
    if (m_body_joint && *m_body_joint < skin.size())
        body = toGodotTransform(skin[*m_body_joint]);
    m_body_lying = m_body_joint && std::fabs(body.basis.xform(Vector3(0, 1, 0)).normalized().y) < 0.5f;
    const Transform3D to_body = body.affine_inverse();
    const auto &joints = m_model->skinned->getAllJoints();
    float pose_total = 0.0f;
    for (int p = 1; p < kPoseCount; ++p)
        pose_total += m_pose_w[p];
    const float w = std::min(pose_total, 1.0f);
    const float ease_rate = 1.0f - std::exp(-std::max(dt, 0.0f) / 0.05f);
    const float ease_bend = 1.0f - std::exp(-std::max(dt, 0.0f) / 0.06f);
    for (size_t i = 0; i < m_model->limbs.size(); ++i) {
        const LimbBend &l = m_model->limbs[i];
        const Basis rel = (to_body * toGodotTransform(skin[l.joint])).basis;
        const Vector3 d = rel.xform(Vector3(0, -1, 0));
        // The game's own swing: what the pose shows less what Goanna's
        // movement poses turned the limb, which otherwise fed back as a
        // swing of their own (a landing's hip flex bent the knee again).
        const float swing = std::atan2(-d.z, -d.y) * 57.29578f - motionAngles(i).pitch;
        if (m_have_swing && dt > 0.0f) {
            float delta = swing - m_swing[i];
            if (delta > 180.0f)
                delta -= 360.0f;
            if (delta < -180.0f)
                delta += 360.0f;
            m_swing_rate[i] += (delta / dt - m_swing_rate[i]) * ease_rate;
        }
        m_swing[i] = swing;
        float target = walkBend(l.kind, swing, m_swing_rate[i]);
        // An arm the game is aiming, or Goanna's own first-person swing is
        // moving, keeps a nearly straight elbow.
        const auto &name = joints[l.joint]->Name;
        const bool held = l.kind == LimbKind::Arm && ((name && overrides.count(*name))
                || (m_rot_override_joint && (u32)l.joint == *m_rot_override_joint));
        if (held)
            target = 5.0f;
        else if (m_first_person && l.kind == LimbKind::Arm)
            target *= FIRST_PERSON_ELBOW;
        if (w > 1e-3f) {
            float stroke = 0.0f;
            for (int p = 1; p < kPoseCount; ++p)
                if (m_pose_w[p] > 1e-4f)
                    stroke += strokeAngles((WaterPose)p, l.kind, l.right, m_stroke_phase).bend * m_pose_w[p];
            target = target * (1.0f - w) + stroke / pose_total * w;
        }
        // The walk and the strokes ease; the movement poses are smooth of
        // themselves and go straight on top, so a landing's knee is exactly
        // what lowered the body (updateMotion): eased with the rest, it bent
        // behind the drop and the feet sank through the ground.
        m_eased_bend[i] = dt > 0.0f ? m_eased_bend[i] + (target - m_eased_bend[i]) * ease_bend : target;
        m_bend[i] = m_eased_bend[i] + motionAngles(i).bend;
    }
    m_have_swing = true;
}

bool ModelAnimator::limbEnd(size_t i, Vector3 &out) const {
    if (i >= m_model->limbs.size() || m_skin.empty())
        return false;
    const LimbBend &l = m_model->limbs[i];
    out = (toGodotTransform(m_skin[l.joint]) * bendTransform(l, m_bend[i])).xform(l.end);
    return true;
}

void ModelAnimator::setShrinkJoint(const std::string &name) {
    if (m_model->skinned)
        m_shrink_joint = m_model->skinned->getJointNumber(name);
}

bool ModelAnimator::hasJoint(const std::string &name) const {
    return m_model->skinned && m_model->skinned->getJointNumber(name).has_value();
}

void ModelAnimator::setJointRotationOverride(const std::string &name, const v3f &euler_deg, bool freeze_arm) {
    if (!freeze_arm || name != m_rot_override_name) m_arm_reference.clear();
    m_freeze_arm = freeze_arm;
    if (name != m_rot_override_name) {
        m_rot_override_name = name;
        m_rot_override_joint = m_model->skinned ? m_model->skinned->getJointNumber(name)
                                                : std::optional<u32>();
    }
    m_rot_override_euler = euler_deg;
}

void ModelAnimator::jiggleColliders(const Transform3D &mesh_to_world,
        std::vector<JiggleCapsule> &out) const {
    if (m_model->jiggle.colliders.empty() || !m_posed)
        return;
    jiggleCapsules(m_model->jiggle, [&](int joint) { return bentGlobal((size_t)joint); },
            mesh_to_world, out);
}

bool ModelAnimator::jointGlobal(const std::string &name, Transform3D &out) const {
    if (!m_model->skinned)
        return false;
    auto jn = m_model->skinned->getJointNumber(name);
    if (!jn || *jn >= m_globals.size())
        return false;
    out = bentGlobal(*jn);
    return true;
}

Transform3D ModelAnimator::bentGlobal(size_t joint) const {
    const Transform3D g = toGodotTransform(m_globals[joint]);
    if (joint >= m_lower_limb.size() || m_lower_limb[joint] < 0 || m_skin.empty())
        return g;
    // Carried along with the lower half: from where the limb's skin puts
    // it, back to rest, bent, and out again.
    const size_t i = (size_t)m_lower_limb[joint];
    const LimbBend &l = m_model->limbs[i];
    const Transform3D limb = toGodotTransform(m_skin[l.joint]);
    return limb * bendTransform(l, m_bend[i]) * limb.affine_inverse() * g;
}

} // namespace goanna
