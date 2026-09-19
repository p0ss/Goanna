// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Inventory icons for node items, drawn the way Luanti's own drawItemStack
// draws an item mesh into a slot (luanti/src/gui/drawItemStack.cpp), on the
// CPU and into an RGBA buffer instead of onto the screen.
//
// The item mesh itself is upstream's: createItemMesh (in the transplanted
// wieldmesh.cpp) builds it through ItemVisualsManager, already turned to the
// inventory angle (-45 degrees about Y, then -30 about X) and scaled to 0.12
// of a node. What this file adds is the draw call. Upstream's is small: an
// orthographic projection two units wide with an identity view, vertex
// colours from colorizeMeshBuffer (base colour, ambient 0.5 plus a fixed
// directional light), and inventory_shader, which multiplies the nearest
// texel by that colour and discards by the material's alpha mode. Nothing in
// it needs a GPU, and doing it here keeps the shading maths in sRGB exactly
// as upstream does it, gives a finished image synchronously, and works under
// --headless, where the formspec tests run.
//
// No Godot types: the native test links this file on its own.

#include <vector>

#include "irrlichttypes_bloated.h"
#include <IImage.h>
#include <IMeshBuffer.h>
#include <SColor.h>

namespace goanna {

// The three ways upstream's inventory shader draws a buffer, by the base
// material its shader was registered with (IShaderSource::getShader).
enum class IconBlend : u8 {
    Opaque,     // EMT_SOLID: no blending, texture alpha ignored
    AlphaRef,   // EMT_TRANSPARENT_ALPHA_CHANNEL_REF: discard below 0.5
    AlphaBlend, // EMT_TRANSPARENT_ALPHA_CHANNEL: discard at 0, blend
};

// One mesh buffer, resolved on the main thread so the draw can run anywhere.
struct IconBuffer {
    const scene::IMeshBuffer *buffer = nullptr;
    // The buffer's colour before shading: the stack's base colour, or the
    // tile's own colour where ItemMeshBufferInfo::applyOverride sets one.
    video::SColor color{0xffffffff};
    IconBlend blend = IconBlend::AlphaRef;
    bool cull_back = true;
    bool clamp_u = true;
    bool clamp_v = true;
    // TileLayer::applyMaterialOptions' polygon offset, which pushes a base
    // layer behind the overlay drawn on the same faces.
    bool depth_bias = false;
    // The texture's image, or one image per layer of an array texture,
    // addressed by the vertex Aux the mesh collector writes. Empty draws
    // white, as a missing texture does not happen for a real tile.
    std::vector<const video::IImage *> layers;
};

struct IconJob {
    std::vector<IconBuffer> buffers;
    // ItemMesh::needs_shading: node meshes are shaded, extruded ones are not.
    bool needs_shading = true;
    // inventory_overlay, drawn flat over the whole slot after the mesh, as
    // drawItemStack does for a node item without an inventory image.
    const video::IImage *overlay = nullptr;
};

// Draws the job into a size by size RGBA8 image, straight (not
// premultiplied) alpha, top row first. Pixels no geometry covers are
// transparent black.
void rasteriseItemIcon(const IconJob &job, u32 size, std::vector<u8> &rgba);

// The colour colorizeMeshBuffer gives one vertex, for drawItemStack's
// inventory light: ambient 0.5 plus 0.7 of normalize(-0.6, -1.2, 0.4)
// against the absolute facing. A zero normal is left fully lit.
video::SColor shadeInventoryVertex(video::SColor base, v3f normal);

} // namespace goanna
