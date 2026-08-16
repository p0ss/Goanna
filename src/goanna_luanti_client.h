// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Luanti's meshing code (mapblock_mesh, content_mapblock, node_visuals) only
// forward-declares `class Client` and calls a handful of accessors on it.
// This is Goanna's stand-in with exactly that surface. It is deliberately a
// global-namespace class named Client so the transplanted code compiles
// against unmodified headers.

#include <string>

#include "irrlichttypes_bloated.h"

class ITextureSource;
class IShaderSource;
class NodeDefManager;
namespace scene {
class IAnimatedMesh;
class IMeshManipulator;
}
namespace goanna {
class ModelCache;
}

class Client {
public:
    Client(ITextureSource *tsrc, IShaderSource *shsrc, const NodeDefManager *ndef, goanna::ModelCache *models)
        : m_tsrc(tsrc), m_shsrc(shsrc), m_ndef(ndef), m_models(models) {}

    ITextureSource *tsrc() { return m_tsrc; }
    ITextureSource *getTextureSource() { return m_tsrc; }
    IShaderSource *getShaderSource() { return m_shsrc; }
    const NodeDefManager *ndef() { return m_ndef; }
    const NodeDefManager *getNodeDefManager() { return m_ndef; }

    // Models from media through Goanna's ModelCache (Client::getMesh
    // semantics: grabbed for the caller; uncached ones are freshly read).
    scene::IAnimatedMesh *getMesh(const std::string &filename, bool cache = false);
    scene::IMeshManipulator *getMeshManipulator();

    void showUpdateProgressTexture(void *args, float progress) {}

private:
    ITextureSource *m_tsrc;
    IShaderSource *m_shsrc;
    const NodeDefManager *m_ndef;
    goanna::ModelCache *m_models;
};
