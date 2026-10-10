// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Luanti's meshing code (mapblock_mesh, content_mapblock, node_visuals,
// wieldmesh, item_visuals_manager) only forward-declares `class Client` and
// calls a handful of accessors on it.
// This is Goanna's stand-in with exactly that surface. It is deliberately a
// global-namespace class named Client so the transplanted code compiles
// against unmodified headers.
//
// Threads: one Client per GoannaSession (meshClient()), holding pointers
// the session owns. Mesh workers call it concurrently through
// MapBlockMesh, so it holds no mutable state of its own beyond the clock
// below; whether a given call is safe off the main thread is the texture
// source's rule, not this class's (goanna_mesher.h, the crack exception).

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
    // Texture animation clock, read by item_visuals_manager.cpp. Nothing in
    // Goanna calls setAnimationTime, so it stays 0: node tiles animate in
    // the shader instead (docs/systems/node-animation.md).
    float getAnimationTime() const { return m_animation_time; }
    void setAnimationTime(float t) { m_animation_time = t; }

    // Models from media through Goanna's ModelCache, with Client::getMesh's
    // 5.17 signature: grabbed for the caller. Goanna always reads a fresh
    // mesh, so *is_shared is false and the caller need not copy it.
    scene::IAnimatedMesh *getMesh(const std::string &filename, bool *is_shared = nullptr);
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
