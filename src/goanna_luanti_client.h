// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Luanti's meshing code (mapblock_mesh, content_mapblock, node_visuals,
// wieldmesh, item_visuals_manager) only forward-declares `class Client` and
// calls a handful of accessors on it.
// This is Goanna's stand-in with exactly that surface. It is deliberately a
// global-namespace class named Client so the transplanted code compiles
// against unmodified headers.

#include <string>

#include "irrlichttypes_bloated.h"

class ITextureSource;
class IShaderSource;
class NodeDefManager;
class IItemDefManager;
struct ItemVisualsManager;
namespace scene {
class IAnimatedMesh;
class IMeshManipulator;
}
namespace goanna {
class ModelCache;
}

class Client {
public:
    Client(ITextureSource *tsrc, IShaderSource *shsrc, const NodeDefManager *ndef, IItemDefManager *idef,
            goanna::ModelCache *models, ItemVisualsManager *item_visuals)
        : m_tsrc(tsrc), m_shsrc(shsrc), m_ndef(ndef), m_idef(idef), m_models(models),
          m_item_visuals(item_visuals) {}

    ITextureSource *tsrc() { return m_tsrc; }
    ITextureSource *getTextureSource() { return m_tsrc; }
    IShaderSource *getShaderSource() { return m_shsrc; }
    const NodeDefManager *ndef() { return m_ndef; }
    const NodeDefManager *getNodeDefManager() { return m_ndef; }
    IItemDefManager *idef() { return m_idef; }
    IItemDefManager *getItemDefManager() { return m_idef; }
    ItemVisualsManager *getItemVisualsManager() { return m_item_visuals; }
    // Texture animation clock, advanced by the session's owner each frame.
    float getAnimationTime() const { return m_animation_time; }
    void setAnimationTime(float t) { m_animation_time = t; }

    // Models from media through Goanna's ModelCache (Client::getMesh
    // semantics: grabbed for the caller; uncached ones are freshly read).
    scene::IAnimatedMesh *getMesh(const std::string &filename, bool cache = false);
    scene::IMeshManipulator *getMeshManipulator();

    void showUpdateProgressTexture(void *args, float progress) {}

private:
    ITextureSource *m_tsrc;
    IShaderSource *m_shsrc;
    const NodeDefManager *m_ndef;
    IItemDefManager *m_idef;
    goanna::ModelCache *m_models;
    ItemVisualsManager *m_item_visuals;
    float m_animation_time = 0.0f;
};
