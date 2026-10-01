// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_models.h"

#include <algorithm>
#include <cmath>
#include <optional>

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
    if (source)
        source->drop();
}

std::shared_ptr<GodotModel> buildGodotModel(scene::IAnimatedMesh *mesh) {
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
        model->mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
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

void ModelAnimator::step(float dt, scene::AnimSpec &anim, std::map<std::string, BoneOverride> &overrides,
        Skeleton3D *skeleton, Skeleton3D *unshrunk) {
    scene::SkinnedMesh *mesh = m_model->skinned;
    if (!mesh)
        return;

    // AnimatedMeshSceneNode::OnAnimate: advance every track, then
    // animateJoints: local transforms for this frame, each track blending
    // from the pose shown last step.
    anim.advance(dt);
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

    // relative -> global -> skin matrices
    auto to_globals = [&]() {
        for (size_t i = 0; i < joints.size(); ++i) {
            if (auto *m = std::get_if<core::matrix4>(&locals[i]))
                m_globals[i] = *m;
            else
                m_globals[i] = std::get<core::Transform>(locals[i]).buildMatrix();
        }
        mesh->calculateGlobalMatrices(m_globals);
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
    }
    const core::vector3df x(1, 0, 0), z(0, 0, 1);
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

// The water strokes: while the body is swimming or treading water, the
// shoulders and hips are turned from their rest by the stroke, blended over
// what the game's animation had them doing by how far the stroke has eased
// in. The knees and elbows follow in measureLimbs.
void ModelAnimator::poseLimbs(float dt, JointTransforms &locals,
        const std::map<std::string, BoneOverride> &overrides) {
    const float ease = 1.0f - std::exp(-dt / 0.25f);
    m_swim_w += ((m_water == WaterPose::Swim ? 1.0f : 0.0f) - m_swim_w) * ease;
    m_tread_w += ((m_water == WaterPose::Tread ? 1.0f : 0.0f) - m_tread_w) * ease;
    m_paddle_w += ((m_water == WaterPose::Paddle ? 1.0f : 0.0f) - m_paddle_w) * ease;
    m_stroke_phase = std::fmod(m_stroke_phase + strokeRate(m_water, m_water_speed) * dt,
            2.0f * 3.14159265f * 12.0f);
    const float w = m_swim_w + m_tread_w + m_paddle_w;
    if (w < 1e-3f)
        return;
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
        const LimbAngles s = strokeAngles(WaterPose::Swim, l.kind, l.right, m_stroke_phase);
        const LimbAngles d = strokeAngles(WaterPose::Tread, l.kind, l.right, m_stroke_phase);
        const LimbAngles b = strokeAngles(WaterPose::Paddle, l.kind, l.right, m_stroke_phase);
        const float pitch = (s.pitch * m_swim_w + d.pitch * m_tread_w + b.pitch * m_paddle_w) / w;
        const float spread = (s.spread * m_swim_w + d.spread * m_tread_w + b.spread * m_paddle_w) / w;
        core::Transform stroke = *r;
        turnLocal(stroke, x, pitch * m_pitch_sign[i]);
        turnLocal(stroke, z, spread * m_spread_sign[i]);
        t->rotation.slerp(t->rotation, stroke.rotation, std::min(w, 1.0f));
    }
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
    const float w = std::min(m_swim_w + m_tread_w + m_paddle_w, 1.0f);
    const float ease_rate = 1.0f - std::exp(-std::max(dt, 0.0f) / 0.05f);
    const float ease_bend = 1.0f - std::exp(-std::max(dt, 0.0f) / 0.06f);
    for (size_t i = 0; i < m_model->limbs.size(); ++i) {
        const LimbBend &l = m_model->limbs[i];
        const Basis rel = (to_body * toGodotTransform(skin[l.joint])).basis;
        const Vector3 d = rel.xform(Vector3(0, -1, 0));
        const float swing = std::atan2(-d.z, -d.y) * 57.29578f;
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
        if (w > 1e-3f) {
            const LimbAngles s = strokeAngles(WaterPose::Swim, l.kind, l.right, m_stroke_phase);
            const LimbAngles t = strokeAngles(WaterPose::Tread, l.kind, l.right, m_stroke_phase);
            const LimbAngles b = strokeAngles(WaterPose::Paddle, l.kind, l.right, m_stroke_phase);
            const float stroke = (s.bend * m_swim_w + t.bend * m_tread_w + b.bend * m_paddle_w)
                    / (m_swim_w + m_tread_w + m_paddle_w);
            target = target * (1.0f - w) + stroke * w;
        }
        m_bend[i] = dt > 0.0f ? m_bend[i] + (target - m_bend[i]) * ease_bend : target;
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
