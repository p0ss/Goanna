// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_models.h"

#include <algorithm>
#include <cmath>

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
#include "goanna_luanti_client.h"
#include "log.h"

scene::IAnimatedMesh *Client::getMesh(const std::string &filename, bool cache) {
    return m_models ? m_models->getMesh(filename, cache) : nullptr;
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

GodotModel::~GodotModel() {
    if (skinned)
        skinned->drop();
}

std::shared_ptr<GodotModel> buildGodotModel(scene::IAnimatedMesh *mesh) {
    auto model = std::make_shared<GodotModel>();
    model->mesh.instantiate();
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
        Array arrays;
        arrays.resize(Mesh::ARRAY_MAX);
        arrays[Mesh::ARRAY_VERTEX] = verts;
        arrays[Mesh::ARRAY_NORMAL] = normals;
        arrays[Mesh::ARRAY_TEX_UV] = uvs;
        arrays[Mesh::ARRAY_INDEX] = indices;

        if (ssb && model->animated) {
            const scene::WeightBuffer *w = ssb->getWeights();
            int aj = attached_joint[bi];
            if (w || aj >= 0) {
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
                arrays[Mesh::ARRAY_BONES] = bones;
                arrays[Mesh::ARRAY_WEIGHTS] = weights;
            }
        }
        model->mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
        model->texture_slots.push_back(mesh->getTextureSlot(bi));
    }
    return model;
}

// ---- animation -------------------------------------------------------------

ModelAnimator::ModelAnimator(std::shared_ptr<GodotModel> model) : m_model(std::move(model)) {
    size_t n = m_model->joint_count;
    m_last_locals.resize(n);
    m_last_locals_valid.assign(n, false);
    m_globals.resize(n);
    if (m_model->skinned)
        m_end_frame = m_model->skinned->getMaxFrameNumber();
}

// AnimatedMeshSceneNode::setFrameLoop
void ModelAnimator::setFrameLoop(float begin, float end) {
    const float max_frame = m_model->skinned ? m_model->skinned->getMaxFrameNumber() : 0;
    if (end < begin) {
        m_start_frame = std::clamp<float>(end, 0, max_frame);
        m_end_frame = std::clamp<float>(begin, m_start_frame, max_frame);
    } else {
        m_start_frame = std::clamp<float>(begin, 0, max_frame);
        m_end_frame = std::clamp<float>(end, m_start_frame, max_frame);
    }
    m_current_frame = m_fps < 0 ? m_end_frame : m_start_frame;
    beginTransition();
}

void ModelAnimator::setAnimationSpeed(float fps) {
    m_fps = fps * 0.001f;
}

void ModelAnimator::setTransitionTime(float seconds) {
    m_transition_time_ms = (u32)core::floor32(seconds * 1000.0f);
}

// AnimatedMeshSceneNode::beginTransition, reached through setCurrentFrame
void ModelAnimator::beginTransition() {
    if (m_transition_time_ms != 0)
        m_transiting = core::reciprocal((f32)m_transition_time_ms);
    m_transiting_blend = 0.f;
}

void ModelAnimator::step(float dt, std::map<std::string, BoneOverride> &overrides, Skeleton3D *skeleton) {
    scene::SkinnedMesh *mesh = m_model->skinned;
    if (!mesh)
        return;
    const u32 time_ms = (u32)(dt * 1000.0f);

    // AnimatedMeshSceneNode::buildFrameNr
    if (m_transiting != 0.f) {
        m_transiting_blend += (f32)time_ms * m_transiting;
        if (m_transiting_blend > 1.f) {
            m_transiting = 0.f;
            m_transiting_blend = 0.f;
        }
    }
    if (m_start_frame == m_end_frame) {
        m_current_frame = m_start_frame;
    } else if (m_looping) {
        m_current_frame += time_ms * m_fps;
        if (m_fps > 0.f) {
            if (m_current_frame > m_end_frame)
                m_current_frame = m_start_frame + fmodf(m_current_frame - m_start_frame, m_end_frame - m_start_frame);
        } else {
            if (m_current_frame < m_start_frame)
                m_current_frame = m_end_frame - fmodf(m_end_frame - m_current_frame, m_end_frame - m_start_frame);
        }
    } else {
        m_current_frame += time_ms * m_fps;
        if (m_fps > 0.f)
            m_current_frame = std::min(m_current_frame, m_end_frame);
        else
            m_current_frame = std::max(m_current_frame, m_start_frame);
    }

    // animateJoints: local transforms for this frame, transition blending
    const auto &joints = mesh->getAllJoints();
    std::vector<scene::SkinnedMesh::SJoint::VariantTransform> locals = mesh->animateMesh(m_current_frame);
    for (size_t i = 0; i < joints.size(); ++i) {
        if (auto *t = std::get_if<core::Transform>(&locals[i])) {
            // Transition: blend from the pose shown last step (copyOldTransforms).
            if (m_transiting != 0.f && m_last_locals_valid[i])
                *t = m_last_locals[i].interpolate(*t, m_transiting_blend);
            m_last_locals[i] = *t;
            m_last_locals_valid[i] = true;
        } else {
            m_last_locals_valid[i] = false;
        }
    }

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
                m_last_locals[*jn] = *t;
            }
        }
        ++it;
    }

    // First-person: collapse the shrink joint so the head (and hat layers
    // attached to it) never block the camera.
    if (m_shrink_joint && *m_shrink_joint < locals.size()) {
        if (auto *t = std::get_if<core::Transform>(&locals[*m_shrink_joint]))
            t->scale *= 0.01f;
    }
    // First-person arm pose wins over animation and server overrides.
    if (m_rot_override_joint && *m_rot_override_joint < locals.size()) {
        if (auto *t = std::get_if<core::Transform>(&locals[*m_rot_override_joint]))
            t->rotation = m_rot_override_q;
    }

    // relative -> global -> skin matrices
    for (size_t i = 0; i < joints.size(); ++i) {
        if (auto *m = std::get_if<core::matrix4>(&locals[i]))
            m_globals[i] = *m;
        else
            m_globals[i] = std::get<core::Transform>(locals[i]).buildMatrix();
    }
    mesh->calculateGlobalMatrices(m_globals);
    if (!skeleton)
        return;
    std::vector<core::matrix4> skin = mesh->calculateSkinMatrices(m_globals);
    for (size_t i = 0; i < joints.size(); ++i) {
        skeleton->set_bone_pose((int)i, toGodotTransform(skin[i]));
        int ab = m_model->attached_bone[i];
        if (ab >= 0)
            skeleton->set_bone_pose(ab, toGodotTransform(m_globals[i]));
    }
}

void ModelAnimator::setShrinkJoint(const std::string &name) {
    if (m_model->skinned)
        m_shrink_joint = m_model->skinned->getJointNumber(name);
}

bool ModelAnimator::hasJoint(const std::string &name) const {
    return m_model->skinned && m_model->skinned->getJointNumber(name).has_value();
}

void ModelAnimator::setJointRotationOverride(const std::string &name, const core::quaternion &q) {
    if (name != m_rot_override_name) {
        m_rot_override_name = name;
        m_rot_override_joint = m_model->skinned ? m_model->skinned->getJointNumber(name)
                                                : std::optional<u32>();
    }
    m_rot_override_q = q;
}

bool ModelAnimator::jointGlobal(const std::string &name, Transform3D &out) const {
    if (!m_model->skinned)
        return false;
    auto jn = m_model->skinned->getJointNumber(name);
    if (!jn || *jn >= m_globals.size())
        return false;
    out = toGodotTransform(m_globals[*jn]);
    return true;
}

} // namespace goanna
