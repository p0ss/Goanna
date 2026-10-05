// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// The texture resolution tier (docs/graphics-tiers.md, "Texture
// resolution"): every albedo and LabPBR companion a pack or the server
// supplies is held to at most a number of map pixels per art texel, and one
// larger is reduced to it when it is loaded. The cap is the setting's size
// over 16, so 128, 256 and 512 allow 8, 16 and 32 pixels to an art texel:
// a 16 texel tile's maps at 128, 256 or 512 pixels across, a 64 by 32 skin
// with maps at 16 to a texel brought to 512 by 256 at 128.
//
// Pure arithmetic on RGBA8 buffers, so goanna_texture_size_test checks it
// without the engine. GoannaTextureSource applies it (goanna_textures.cpp).

#include <cstdint>
#include <string>
#include <vector>

namespace goanna {

// What a map's channels mean, which decides how they are averaged.
enum class MapKind {
    // Colour and coverage: RGB weighted by alpha, alpha averaged.
    Albedo,
    // LabPBR _n: RG a tangent vector (with B the occlusion and A the
    // height), averaged as vectors and renormalised; B and A averaged.
    Normal,
    // LabPBR _s: R smoothness averaged; G (F0 or metal), B (porosity or
    // scattering) and A (emission) are categorical, so each takes the
    // value covering most of the output pixel. A mean across a metal and
    // a dielectric texel would invent a material in neither.
    Spec,
};

// The kind of a source image by its name: "x_n.png" a normal companion,
// "x_s.png" a specular one, anything else an albedo.
MapKind mapKindOf(const std::string &name);

// The image a name's texels are counted against: for a companion the
// image it belongs to ("x_n.png" -> "x.png"), for an albedo itself.
std::string artNameOf(const std::string &name);

// Map pixels per art texel at a texture size: 0 (no cap) for a size of 0.
inline uint32_t texelCapForSize(uint32_t size) { return size / 16; }

// The size an image of w by h must be brought to so that it has at most
// cap map pixels per texel of art_w by art_h art, by the larger of its two
// ratios, keeping its shape. False, with tw and th the image's own, when
// it is already within the cap, when cap is 0 or when the art is unknown.
bool cappedSize(uint32_t w, uint32_t h, uint32_t art_w, uint32_t art_h, uint32_t cap,
        uint32_t &tw, uint32_t &th);

// src (w by h, RGBA8) reduced to tw by th by area: each output pixel
// averages the source pixels it covers, weighted by how much of each it
// covers, by the rules of kind. A whole factor is an exact box. tw and th
// must not exceed w and h. Mipmaps are built from the result as before.
std::vector<uint8_t> downscaleRgba8(const uint8_t *src, int w, int h, int tw, int th,
        MapKind kind);

// goanna::reliefDepth for a node tile (wrapped, one node across its width,
// uncapped), on an RGBA8 _n buffer. A reduced _n reads a different depth
// from the same surface: averaging puts a one pixel chamfer's slope into
// pixels twice as wide, and the measure (the normal's slope over the
// height's) halved on some tiles and rose on others, 0.047 node at the
// 90th percentile over Mineclonia's 256 tiles brought to 128. So the depth
// is measured before the reduction and kept with the reduced image
// (GoannaTextureSource::reducedReliefDepth). 0 when there are too few
// steps to measure, as reliefDepth gives.
float tileReliefDepth(const uint8_t *px, int w, int h);

} // namespace goanna
