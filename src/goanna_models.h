// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Models: Luanti's own model loaders (Irrlicht's B3D, X, OBJ and glTF
// readers, compiled CPU-only from the submodule) behind a stub scene manager,
// a cache of loaded meshes by media name, conversion of an Irrlicht mesh to a
// Godot ArrayMesh with bones and weights, and a per-instance animator that
// drives SkinnedMesh's own keyframe evaluation into skeleton bone poses.
//
// Coordinates: mesh units are Luanti world units (BS = 10 per node), z is
// mirrored into Godot's right-handed space, index order is kept.

#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include "irrlichttypes_bloated.h"
#include <IAnimatedMesh.h>
#include <SkinnedMesh.h>

struct BoneOverride;
namespace scene {
class IMeshManipulator;
class IMeshLoader;
}

namespace goanna {

// Bytes of a media file by name; false if unknown.
using MediaGetter = std::function<bool(const std::string &name, std::string &out)>;

// The Irrlicht loaders and the mesh manipulator, without a scene graph.
class ModelLoader {
public:
    ModelLoader();
    ~ModelLoader();
    // Loads a model from memory; the returned mesh is grabbed for the caller.
    scene::IAnimatedMesh *load(const std::string &name, const std::string &bytes);
    scene::IMeshManipulator *manipulator();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

// Client::getMesh semantics: cached meshes are shared (and grabbed for the
// caller); uncached ones are freshly read so callers may mutate them.
class ModelCache {
public:
    explicit ModelCache(MediaGetter media);
    ~ModelCache();
    scene::IAnimatedMesh *getMesh(const std::string &name, bool cache);
    scene::IMeshManipulator *manipulator() { return m_loader.manipulator(); }

private:
    ModelLoader m_loader;
    MediaGetter m_media;
    std::map<std::string, scene::IAnimatedMesh *> m_cache;
};

// An Irrlicht mesh converted for Godot.
struct GodotModel {
    godot::Ref<godot::ArrayMesh> mesh;
    std::vector<u32> texture_slots; // per surface: index into ObjectProperties::textures
    // Skinned meshes only: the SkinnedMesh (grabbed) and the skeleton layout.
    // Bones 0..joint_count-1 take skin matrices (global * inverse bind);
    // joints with rigidly attached buffers get an extra bone taking the
    // global matrix, at attached_bone[joint] (or -1).
    scene::SkinnedMesh *skinned = nullptr;
    int joint_count = 0;
    std::vector<int> attached_bone;
    int identity_bone = -1; // for unweighted, unattached vertices, or -1
    int bone_count = 0;
    bool animated = false;
    ~GodotModel();
};

// Builds a Godot model from an Irrlicht mesh (does not take a reference).
std::shared_ptr<GodotModel> buildGodotModel(scene::IAnimatedMesh *mesh);

// Per-instance animation state for a skinned GodotModel: the frame loop of
// Irrlicht's AnimatedMeshSceneNode (buildFrameNr, transitions), Luanti's bone
// overrides, and the resulting bone poses.
class ModelAnimator {
public:
    explicit ModelAnimator(std::shared_ptr<GodotModel> model);
    void setFrameLoop(float begin, float end);
    void setAnimationSpeed(float fps);
    void setLoopMode(bool loop) { m_looping = loop; }
    void setTransitionTime(float seconds);
    float frame() const { return m_current_frame; }
    // Advances by dt seconds, applies overrides (their dtime_passed advances,
    // finished identity overrides are erased) and writes bone poses.
    void step(float dt, std::map<std::string, BoneOverride> &overrides, godot::Skeleton3D *skeleton);
    // Global transform (mesh space, Godot handedness) of a named joint after
    // the last step; false if unknown.
    bool jointGlobal(const std::string &name, godot::Transform3D &out) const;

private:
    std::shared_ptr<GodotModel> m_model;
    float m_start_frame = 0, m_end_frame = 0, m_current_frame = 0;
    float m_fps = 0.025f; // frames per millisecond, as Irrlicht keeps it
    bool m_looping = true;
    u32 m_transition_time_ms = 0;
    float m_transiting = 0, m_transiting_blend = 0;
    std::vector<core::Transform> m_last_locals;
    std::vector<bool> m_last_locals_valid;
    void beginTransition();
    std::vector<core::matrix4> m_globals;
};

// Irrlicht matrix (row vectors, left-handed) to a Godot transform, z mirrored.
godot::Transform3D toGodotTransform(const core::matrix4 &m);

} // namespace goanna
