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
class IMesh;
class IMeshManipulator;
}

class Client {
public:
    Client(ITextureSource *tsrc, IShaderSource *shsrc, const NodeDefManager *ndef)
        : m_tsrc(tsrc), m_shsrc(shsrc), m_ndef(ndef) {}

    ITextureSource *tsrc() { return m_tsrc; }
    ITextureSource *getTextureSource() { return m_tsrc; }
    IShaderSource *getShaderSource() { return m_shsrc; }
    const NodeDefManager *ndef() { return m_ndef; }
    const NodeDefManager *getNodeDefManager() { return m_ndef; }

    // Mesh nodes (NDT_MESH): model loading is not transplanted yet.
    scene::IMesh *getMesh(const std::string &filename, bool cache = false) { return nullptr; }
    scene::IMeshManipulator *getMeshManipulator() { return nullptr; }

    void showUpdateProgressTexture(void *args, float progress) {}

private:
    ITextureSource *m_tsrc;
    IShaderSource *m_shsrc;
    const NodeDefManager *m_ndef;
};
